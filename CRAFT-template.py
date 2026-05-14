import re, json, subprocess, threading, time
from pathlib import Path
from jupyter_client import BlockingKernelClient

# ============================================================
# USER CONFIG — edit these for your machine
# ============================================================
LINUX_USER        = "linuxuser"
WINDOWS_USER    = "winuser"  # CHANGE THIS: Run $env:USERNAME in PowerShell to get Windows username
LINUX_HOSTNAME    = "YOUR_TUNNEL_NAME.YOUR_DOMAIN"   # e.g. linux-ssh.yourdomain.com
WIN_HOSTNAME    = "YOUR_TUNNEL_NAME.YOUR_DOMAIN"             # e.g. win-ssh.yourdomain.com
WSL_SSH_PORT    = 2222
KERNEL_NAME     = "solveit"
VENV_PYTHON     = "/home/linuxuser/projects/YOUR_PROJECT/.venv/bin/python"
# ============================================================
# DO NOT EDIT BELOW THIS LINE
# ============================================================

# Install cloudflared
subprocess.run(
    "curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 "
    "-o /tmp/cloudflared && chmod +x /tmp/cloudflared",
    shell=True
)

# SSH config
ssh_config = f"""
Host linux-ssh
  HostName {LINUX_HOSTNAME}
  Port {WSL_SSH_PORT}
  User {LINUX_USER}
  ProxyCommand /tmp/cloudflared access tcp --hostname {LINUX_HOSTNAME}
  ControlMaster auto
  ControlPath ~/.ssh/control-%r@%h:%p
  ControlPersist yes
  ServerAliveInterval 60
  ServerAliveCountMax 10

Host win-ssh
  HostName {WIN_HOSTNAME}
  Port 22
  User {WINDOWS_USER}
  ProxyCommand /tmp/cloudflared access tcp --hostname {WIN_HOSTNAME}
  ControlMaster no
  ServerAliveInterval 60
  ServerAliveCountMax 10
"""
config_path = "/app/data/.ssh/config"
with open(config_path, 'r') as f:
    content = f.read()
content = re.sub(r'Host linux-ssh.*?(?=Host |\Z)', '', content, flags=re.DOTALL).strip()
content = re.sub(r'Host win-ssh.*?(?=Host |\Z)', '', content, flags=re.DOTALL).strip()
with open(config_path, 'w') as f:
    f.write(content + "\n" + ssh_config)

# Accept host keys
subprocess.run("ssh -o StrictHostKeyChecking=accept-new linux-ssh echo connected", shell=True)
subprocess.run("ssh -o StrictHostKeyChecking=accept-new win-ssh echo connected", shell=True)

# Ensure kernel exists on WSL
subprocess.run(
    f"ssh linux-ssh 'kernel-manager.sh create {KERNEL_NAME} {VENV_PYTHON}'",
    shell=True
)

# Fetch kernel connection file from WSL
result = subprocess.run(
    f"ssh linux-ssh 'cat ~/.local/share/jupyter/runtime/kernel-{KERNEL_NAME}.json'",
    shell=True, capture_output=True, text=True
)
kernel_info = json.loads(result.stdout)

# Set up SSH port forwarding for kernel ports
port_base = kernel_info['shell_port']
ports = [port_base, port_base+1, port_base+2, port_base+3, port_base+4]
fwd = " ".join([f"-L {p}:localhost:{p}" for p in ports])
subprocess.Popen(f"ssh -N {fwd} linux-ssh", shell=True)
time.sleep(3)

# Connect directly to persistent kernel
kc = BlockingKernelClient()
kc.load_connection_info(kernel_info)
kc.start_channels()
kc.wait_for_ready(timeout=30)
print(f"✅ WSL GPU ready! Connected to '{KERNEL_NAME}' kernel.")

# Heartbeat to keep kernel alive
def heartbeat():
    while True:
        subprocess.run(f"ssh linux-ssh 'kernel-manager.sh heartbeat {KERNEL_NAME}'", shell=True)
        time.sleep(300)

threading.Thread(target=heartbeat, daemon=True).start()

# Sleep helper
def sleepnow():
    subprocess.run(
        "ssh win-ssh 'powershell -Command \"rundll32.exe powrprof.dll,SetSuspendState 0,1,0\"'",
        shell=True
    )
    print("💤 PC going to sleep...")

