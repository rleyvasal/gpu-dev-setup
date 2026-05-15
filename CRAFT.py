import base64
import json
import re
import subprocess
import sys
from pathlib import Path
import os
from IPython.core.magic import register_line_cell_magic
from IPython.display import HTML, Image, display
from jupyter_client import BlockingKernelClient
import shutil

CONFIG_PATH = Path.home() / ".config" / "gpu-dev" / "client-config.json"

# Allow override via environment variable, otherwise auto-detect, fallback to default
CLOUDFLARED_PATH = Path(
    os.environ.get("CLOUDFLARED_PATH") 
    or shutil.which("cloudflared") 
    or (Path.home() / ".local" / "bin" / "cloudflared")
)

SSH_CONFIG_PATH = Path.home() / ".ssh" / "config"


def run(cmd, check=True, capture_output=False):
    return subprocess.run(
        cmd,
        shell=True,
        check=check,
        capture_output=capture_output,
        text=True,
    )


def install_cloudflared():
    if run("which cloudflared", check=False).returncode == 0:
        return
    if sys.platform == "darwin":
        print("Please install cloudflared: brew install cloudflared")
        raise SystemExit(1)
    CLOUDFLARED_PATH.parent.mkdir(parents=True, exist_ok=True)
    run(
        f"curl -fsSL "
        f"https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 "
        f"-o {CLOUDFLARED_PATH} && chmod +x {CLOUDFLARED_PATH}"
    )


def update_ssh_config(cfg):
    block = f"""Host linux-host
    HostName {cfg['cf_hostname_linux']}
    Port {cfg['ssh_port']}
    User {cfg['linux_user']}
    IdentityFile ~/.ssh/id_ed25519_gpu_dev_solveit
    ProxyCommand {CLOUDFLARED_PATH} access tcp --hostname {cfg['cf_hostname_linux']}
    ControlMaster auto
    ControlPath ~/.ssh/control-%r@%h:%p
    ControlPersist 10m
    ServerAliveInterval 60
    ServerAliveCountMax 10
"""
    content = SSH_CONFIG_PATH.read_text() if SSH_CONFIG_PATH.exists() else ""
    content = re.sub(
        r"Host linux-host.*?(?=^Host |\Z)",
        "",
        content,
        flags=re.DOTALL | re.MULTILINE,
    ).strip()
    SSH_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    SSH_CONFIG_PATH.write_text((content + "\n\n" + block).strip() + "\n")


def ssh(cmd, capture_output=False):
    return run(f"ssh linux-host {json.dumps(cmd)}", capture_output=capture_output)


def ensure_kernel(cfg):
    kernel_name = cfg.get("kernel_client_name", "remote-kernel")
    venv_python = f"{cfg['venv_path']}/bin/python"
    work_dir = cfg.get("kernel_work_dir", f"/home/{cfg['linux_user']}/projects")
    ssh(
        f'/home/{cfg["linux_user"]}/bin/kernel-manager.sh '
        f'create "{kernel_name}" "{venv_python}" "{work_dir}"'
    )
    return kernel_name


def fetch_kernel_info(kernel_name):
    result = ssh(
        f"cat ~/.local/share/jupyter/runtime/kernel-{kernel_name}.json",
        capture_output=True,
    )
    return json.loads(result.stdout)


def start_port_forwarding(kernel_info):
    ports = [
        kernel_info["shell_port"],
        kernel_info["iopub_port"],
        kernel_info["stdin_port"],
        kernel_info["control_port"],
        kernel_info["hb_port"],
    ]
    args = ["ssh", "-N"]
    for port in ports:
        args.extend(["-L", f"{port}:127.0.0.1:{port}"])
    args.append("linux-host")
    return subprocess.Popen(args)


class RemoteExecutionManager:
    def __init__(self):
        self.remote_kc = None
        self.mode = "local"
        self._display_handles = {}
        self._tunnel_proc = None
        self._skip_next = False

    def setup_remote(self):
        if not CONFIG_PATH.exists():
            print(f"Config not found at {CONFIG_PATH}")
            return False

        cfg = json.loads(CONFIG_PATH.read_text())
        install_cloudflared()
        update_ssh_config(cfg)
        run("ssh -o StrictHostKeyChecking=accept-new linux-host echo SSH_OK", check=False)

        kernel_name = ensure_kernel(cfg)
        kernel_info = fetch_kernel_info(kernel_name)

        if self._tunnel_proc and self._tunnel_proc.poll() is None:
            self._tunnel_proc.terminate()
        self._tunnel_proc = start_port_forwarding(kernel_info)

        kc = BlockingKernelClient()
        local_info = dict(kernel_info)
        local_info["ip"] = "127.0.0.1"
        kc.load_connection_info(local_info)
        kc.start_channels()
        kc.wait_for_ready(timeout=30)

        self.remote_kc = kc
        self.mode = "remote"
        print(f"Remote kernel '{kernel_name}' ready")
        return True

    def shutdown_remote(self):
        if self.remote_kc is not None:
            try:
                self.remote_kc.stop_channels()
            except Exception:
                pass
        self.remote_kc = None
        if self._tunnel_proc and self._tunnel_proc.poll() is None:
            self._tunnel_proc.terminate()
        self._tunnel_proc = None
        self._display_handles.clear()
        self.mode = "local"

    def _output_hook(self, msg):
        msg_type = msg["msg_type"]
        content = msg.get("content", {})

        if msg_type == "stream":
            out = sys.stderr if content.get("name") == "stderr" else sys.stdout
            print(content.get("text", ""), end="", flush=True, file=out)
            return

        if msg_type == "error":
            traceback = "\n".join(content.get("traceback", []))
            ansi_re = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
            display(HTML(f"<pre>{ansi_re.sub('', traceback)}</pre>"))
            return

        if msg_type == "clear_output":
            from IPython.display import clear_output
            clear_output(wait=content.get("wait", False))
            return

        if msg_type not in ("display_data", "update_display_data", "execute_result"):
            return

        data = content.get("data", {})
        display_id = content.get("transient", {}).get("display_id")

        if "text/html" in data:
            html = HTML(data["text/html"])
            if msg_type == "update_display_data" and display_id in self._display_handles:
                self._display_handles[display_id].update(html)
            else:
                handle = display(html, display_id=display_id or True)
                if display_id:
                    self._display_handles[display_id] = handle
            return

        if "image/png" in data:
            display(Image(base64.b64decode(data["image/png"])))
            return

        if "image/jpeg" in data:
            display(Image(base64.b64decode(data["image/jpeg"])))
            return

        if "image/svg+xml" in data:
            display(HTML(data["image/svg+xml"]))
            return

        if "text/plain" in data:
            print(data["text/plain"])

    def execute_remote(self, code, verbose=False):
        if self.remote_kc is None:
            raise RuntimeError("Remote kernel not connected. Run %remote first.")
        result = self.remote_kc.execute_interactive(code=code, output_hook=self._output_hook)
        self.remote_kc.last_result = result
        if verbose:
            return result

    def _execute_remotely(self, lines):
        if self._skip_next:
            self._skip_next = False
            return lines

        code = "".join(lines)
        if "get_ipython()" in code:
            return lines

        if code.strip().startswith(
            (
                "%local",
                "%%local",
                "%remote",
                "%%remote",
                "%gpu",
                "shutdown_remote(",
                "set_sticky(",
                "unset_sticky(",
            )
        ):
            return lines

        return [f"_exec_mgr.execute_remote({code!r})\n"]

    def set_sticky(self):
        ip = get_ipython()
        for func in ip.input_transformers_cleanup[:]:
            if getattr(func, "__name__", "") == "_execute_remotely":
                print("Already executing remotely")
                return
        ip.input_transformers_cleanup.append(self._execute_remotely)
        self.mode = "remote"
        print("Remote sticky mode enabled")

    def unset_sticky(self):
        ip = get_ipython()
        for func in ip.input_transformers_cleanup[:]:
            if getattr(func, "__name__", "") == "_execute_remotely":
                ip.input_transformers_cleanup.remove(func)
        self.mode = "local"
        print("Remote sticky mode disabled")


_exec_mgr = RemoteExecutionManager()


@register_line_cell_magic
def remote(line, cell=None):
    if cell is not None:
        _exec_mgr.execute_remote(cell)
        return
    if _exec_mgr.setup_remote():
        _exec_mgr.set_sticky()


@register_line_cell_magic
def local(line, cell=None):
    if cell is not None:
        _exec_mgr._skip_next = True
        get_ipython().run_cell(cell)
        return
    _exec_mgr.unset_sticky()


get_ipython().register_magic_function(remote, "line_cell", "gpu")

print("GPU Dev remote kernel loaded")
print("  %remote or %gpu      connect and enable remote sticky mode")
print("  %local               disable remote sticky mode")
print("  %%gpu or %%remote    run one cell remotely")
print("  %%local              run one cell locally")

