#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${HOME}/.config/gpu-dev/config.json"
CLIENT_CONFIG_FILE="${HOME}/.config/gpu-dev/client-config.json"
KERNEL_MANAGER_URL="https://raw.githubusercontent.com/rleyvasal/gpu-dev-setup/main/kernel-manager.sh"

step() {
    echo ""
    echo "=== $1 ==="
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

systemd_usable() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ -d /run/systemd/system ] || return 1
    systemctl list-units >/dev/null 2>&1 || return 1
}

read_config_value() {
    local key="$1"

    python3 - "$CONFIG_FILE" "$key" <<'PY'
import json, pathlib, sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]

if not path.exists():
    raise SystemExit(0)

data = json.loads(path.read_text(encoding="utf-8"))
value = data.get(key, "")
if value is None:
    value = ""
print(value)
PY
}

append_line_once() {
    local line="$1"
    local file="$2"

    touch "$file"
    grep -Fqx "$line" "$file" || echo "$line" >> "$file"
}

cloudflared_authenticated() {
    cloudflared tunnel list >/dev/null 2>&1
}

write_client_config() {
    mkdir -p "$(dirname "$CLIENT_CONFIG_FILE")"

    LINUX_USER_VALUE="$LINUX_USER" \
    WINDOWS_USER_VALUE="${WINDOWS_USER:-}" \
    SSH_PORT_VALUE="$SSH_PORT" \
    CF_DOMAIN_VALUE="$CF_DOMAIN" \
    CF_TUNNEL_VALUE="$CF_TUNNEL" \
    CF_HOSTNAME_LINUX_VALUE="$CF_HOSTNAME_LINUX" \
    CF_HOSTNAME_WIN_VALUE="$CF_HOSTNAME_WIN" \
    VENV_PATH_VALUE="$VENV_PATH" \
    KERNEL_CLIENT_NAME_VALUE="${KERNEL_CLIENT_NAME:-}" \
    KERNEL_WORK_DIR_VALUE="$KERNEL_WORK_DIR" \
    IS_WSL_VALUE="$IS_WSL" \
    python3 - "$CLIENT_CONFIG_FILE" <<'PY'
import json, os, pathlib, sys

path = pathlib.Path(sys.argv[1])
data = {
    "linux_user": os.environ["LINUX_USER_VALUE"],
    "windows_user": os.environ.get("WINDOWS_USER_VALUE", ""),
    "ssh_port": int(os.environ["SSH_PORT_VALUE"]),
    "cf_domain": os.environ["CF_DOMAIN_VALUE"],
    "cf_tunnel": os.environ["CF_TUNNEL_VALUE"],
    "cf_hostname_linux": os.environ["CF_HOSTNAME_LINUX_VALUE"],
    "cf_hostname_win": os.environ["CF_HOSTNAME_WIN_VALUE"],
    "venv_path": os.environ["VENV_PATH_VALUE"],
    "kernel_client_name": os.environ.get("KERNEL_CLIENT_NAME_VALUE", ""),
    "kernel_work_dir": os.environ["KERNEL_WORK_DIR_VALUE"],
    "ssh_key_path": os.path.expanduser("~/.ssh/id_ed25519"),
    "source_platform": "linux-native" if os.environ["IS_WSL_VALUE"] == "false" else "linux-wsl",
}
path.write_text(json.dumps(data, indent=2), encoding="utf-8")
PY
    chmod 600 "$CLIENT_CONFIG_FILE"
}

if [ -f "$CONFIG_FILE" ]; then
    echo "Loading config from $CONFIG_FILE"

    LINUX_USER="${LINUX_USER:-$(read_config_value linux_user)}"
    SSH_PORT="${SSH_PORT:-$(read_config_value ssh_port)}"
    SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$(read_config_value ssh_public_key)}"
    CF_DOMAIN="${CF_DOMAIN:-$(read_config_value cf_domain)}"
    CF_TUNNEL="${CF_TUNNEL:-$(read_config_value cf_tunnel)}"
    CF_HOSTNAME_LINUX="${CF_HOSTNAME_LINUX:-$(read_config_value cf_hostname_linux)}"
    CF_HOSTNAME_WIN="${CF_HOSTNAME_WIN:-$(read_config_value cf_hostname_win)}"
    VENV_PATH="${VENV_PATH:-$(read_config_value venv_path)}"
    KERNEL_CLIENT_NAME="${KERNEL_CLIENT_NAME:-$(read_config_value kernel_client_name)}"
    KERNEL_WORK_DIR="${KERNEL_WORK_DIR:-$(read_config_value kernel_work_dir)}"
    WINDOWS_USER="${WINDOWS_USER:-$(read_config_value windows_user)}"
fi

LINUX_USER="${LINUX_USER:-$(whoami)}"
SSH_PORT="${SSH_PORT:-2222}"
KERNEL_WORK_DIR="${KERNEL_WORK_DIR:-$HOME/gpu_dev_projects}"

[ -z "${SSH_PUBLIC_KEY:-}" ] && read -r -p "SSH public key: " SSH_PUBLIC_KEY
[ -z "${CF_DOMAIN:-}" ] && read -r -p "Cloudflare domain (e.g. mydomain.com): " CF_DOMAIN
[ -z "${CF_TUNNEL:-}" ] && read -r -p "Tunnel name (e.g. gpu-dev): " CF_TUNNEL
[ -z "${VENV_PATH:-}" ] && read -r -p "Project venv path (e.g. /home/$LINUX_USER/projects/myproject/.venv): " VENV_PATH

CF_HOSTNAME_LINUX="${CF_HOSTNAME_LINUX:-$LINUX_USER.$CF_DOMAIN}"
CF_HOSTNAME_WIN="${CF_HOSTNAME_WIN:-${KERNEL_CLIENT_NAME:-$(hostname)}.$CF_DOMAIN}"
VENV_PYTHON="$VENV_PATH/bin/python"

if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
    echo "Running in WSL mode"
else
    IS_WSL=false
    echo "Running in native Linux mode"
fi

echo ""
echo "=== PRE-FLIGHT CHECKLIST ==="
echo "  1. This script is Linux-native and also supports WSL."
echo "  2. Kernel manager will be installed to ~/bin/kernel-manager.sh."
echo "  3. If using Cloudflare tunnels, cloudflared login must be completed before tunnel management."
echo "  4. A local client config will be written to ~/.config/gpu-dev/client-config.json."
read -r -p "Press Enter when ready..."

step "Step 1: Install dependencies"
sudo apt-get update -q
sudo apt-get install -qy openssh-server curl wget python3 python3-venv
if [ "$IS_WSL" = false ]; then
    sudo apt-get install -qy ufw
fi

step "Step 2: Configure SSH on port $SSH_PORT"
sudo sed -i -E "s/^#?Port [0-9]+/Port $SSH_PORT/" /etc/ssh/sshd_config
