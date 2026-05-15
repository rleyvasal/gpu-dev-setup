blocks = [
        f"""Host linux-host
  HostName {linux_host}
  Port {ssh_port}
  User {linux_user}
  ProxyCommand {CLOUDFLARED_PATH} access tcp --hostname {linux_host}
  ControlMaster auto
  ControlPath ~/.ssh/control-%r@%h:%p
  ControlPersist yes
  ServerAliveInterval 60
  ServerAliveCountMax 10
""".strip()
    ]

    if windows_host and windows_user:
        blocks.append(
            f"""Host windows-host
  HostName {windows_host}
  Port 22
  User {windows_user}
  IdentityFile {ssh_key_path}
  ProxyCommand {CLOUDFLARED_PATH} access tcp --hostname {windows_host}
  ControlMaster no
  ServerAliveInterval 60
  ServerAliveCountMax 10
""".strip()
        )

    ssh_config = "\n\n".join(blocks) + "\n"

    content = SSH_CONFIG_PATH.read_text(encoding="utf-8") if SSH_CONFIG_PATH.exists() else ""
    content = re.sub(r"Host linux-host.*?(?=^Host |\Z)", "", content, flags=re.DOTALL | re.MULTILINE).strip()
    content = re.sub(r"Host windows-host.*?(?=^Host |\Z)", "", content, flags=re.DOTALL | re.MULTILINE).strip()

    SSH_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    SSH_CONFIG_PATH.write_text((content + "\n\n" + ssh_config).strip() + "\n", encoding="utf-8")


def load_remote_config():
    result = ssh("linux-host", "cat ~/.config/gpu-dev/config.json", capture_output=True)
    return json.loads(result.stdout)


def ensure_kernel(cfg):
    kernel_name = cfg.get("kernel_client_name") or "client-kernel"
    venv_python = f"{cfg['venv_path']}/bin/python"
    work_dir = cfg.get("kernel_work_dir", f"/home/{cfg['linux_user']}/gpu_dev_projects")

    ssh(
        "linux-host",
        f'kernel-manager.sh create "{kernel_name}" "{venv_python}" "{work_dir}"',
    )
    ssh("linux-host", f'kernel-manager.sh touch "{kernel_name}"')

    return kernel_name


def fetch_kernel_info(kernel_name):
    result = ssh(
        "linux-host",
        f'cat ~/.local/share/jupyter/runtime/kernel-{kernel_name}.json',
        capture_output=True,
    )
    return json.loads(result.stdout)


def start_port_forwarding(kernel_info):
    base = kernel_info["shell_port"]
    ports = [base, base + 1, base + 2, base + 3, base + 4]
    forwards = " ".join(f"-L {p}:localhost:{p}" for p in ports)
    subprocess.Popen(f"ssh -N {forwards} linux-host", shell=True)
    time.sleep(3)


def connect_kernel(kernel_info):
    kc = BlockingKernelClient()
    kc.load_connection_info(kernel_info)
    kc.start_channels()
    kc.wait_for_ready(timeout=30)
    return kc


def sleepnow():
    ssh(
        "windows-host",
        'powershell -Command "rundll32.exe powrprof.dll,SetSuspendState 0,1,0"',
        check=False,
    )
    print("PC going to sleep...")


def parse_args():
    parser = argparse.ArgumentParser(description="Connect to a managed remote GPU dev kernel.")
    parser.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CONFIG_PATH,
        help=f"Path to client config JSON (default: {DEFAULT_CONFIG_PATH})",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    cfg = load_config(args.config.expanduser())
    install_cloudflared()
    update_ssh_config(cfg)

    run("ssh -o StrictHostKeyChecking=accept-new linux-host echo connected")
    if cfg.get("cf_hostname_win") and cfg.get("windows_user"):
        run("ssh -o StrictHostKeyChecking=accept-new windows-host echo connected", check=False)

    remote_cfg = load_remote_config()
    cfg.update(remote_cfg)

    kernel_name = ensure_kernel(cfg)
    kernel_info = fetch_kernel_info(kernel_name)
    start_port_forwarding(kernel_info)
    connect_kernel(kernel_info)

    print(f"Connected to kernel '{kernel_name}'.")


if __name__ == "__main__":
    main()
