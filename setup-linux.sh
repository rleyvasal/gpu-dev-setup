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

import_windows_config() {
    for user_dir in /mnt/c/Users/*/; do
        win_config="${user_dir}.config/gpu-dev/client-config.json"
        if [ -f "$win_config" ]; then
            WINDOWS_USER=$(grep '"windows_user"' "$win_config" | head -1 | cut -d'"' -f4)
            KERNEL_CLIENT_NAME=$(grep '"kernel_client_name"' "$win_config" | head -1 | cut -d'"' -f4)
            echo "WINDOWS_USER=$WINDOWS_USER"
            echo "KERNEL_CLIENT_NAME=$KERNEL_CLIENT_NAME"
            return 0
        fi
    done
    return 1
}

write_client_config() {
    mkdir -p "$(dirname "$CLIENT_CONFIG_FILE")"
    
    # Import from Windows config if in WSL
    if [ "$IS_WSL" = true ]; then
        eval "$(import_windows_config)" 2>/dev/null || true
    fi
 
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
    "windows_user": os.environ.get("WINDOWS_USER_VALUE") or os.environ.get("WINDOWS_USER", ""),
    "ssh_port": int(os.environ["SSH_PORT_VALUE"]),
    "cf_domain": os.environ["CF_DOMAIN_VALUE"],
    "cf_tunnel": os.environ["CF_TUNNEL_VALUE"],
    "cf_hostname_linux": os.environ["CF_HOSTNAME_LINUX_VALUE"],
    "cf_hostname_win": os.environ["CF_HOSTNAME_WIN_VALUE"],
    "venv_path": os.environ["VENV_PATH_VALUE"],
    "kernel_client_name": os.environ.get("KERNEL_CLIENT_NAME_VALUE") or os.environ.get("KERNEL_CLIENT_NAME", ""),
    "kernel_work_dir": os.environ["KERNEL_WORK_DIR_VALUE"],
    "ssh_key_path": os.path.expanduser("~/.ssh/id_ed25519"),
    "source_platform": "linux-native" if os.environ["IS_WSL_VALUE"] == "false" else "linux-wsl",
}
path.write_text(json.dumps(data, indent=2), encoding="utf-8")
PY
    chmod 600 "$CLIENT_CONFIG_FILE"
}

# Load config from file if it exists (written by Windows setup or a previous run)
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
    PYTHON_VERSION="${PYTHON_VERSION:-$(read_config_value python_version)}"
fi

PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
LINUX_USER="${LINUX_USER:-$(whoami)}"
SSH_PORT="${SSH_PORT:-2222}"
KERNEL_WORK_DIR="${KERNEL_WORK_DIR:-$HOME/gpu-dev-projects}"

# Only prompt interactively if not called from Windows setup
if [ "${NON_INTERACTIVE:-}" != "true" ]; then
    [ -z "${SSH_PUBLIC_KEY:-}" ] && read -r -p "SSH public key: " SSH_PUBLIC_KEY
    [ -z "${CF_DOMAIN:-}" ] && read -r -p "Cloudflare domain (e.g. mydomain.com): " CF_DOMAIN
    [ -z "${CF_TUNNEL:-}" ] && read -r -p "Tunnel name (e.g. gpu-dev): " CF_TUNNEL
    read -r -p "Python version [$PYTHON_VERSION]: " _PV
    PYTHON_VERSION="${_PV:-$PYTHON_VERSION}"

    if [ -z "${VENV_PATH:-}" ]; then
        read -r -p "Project name [myproject]: " VENV_NAME
        VENV_NAME="${VENV_NAME:-myproject}"
        KERNEL_WORK_DIR="$HOME/gpu-dev-projects/$VENV_NAME"
        VENV_PATH="$KERNEL_WORK_DIR/.venv"
    fi
else
    [ -z "${SSH_PUBLIC_KEY:-}" ] && fail "SSH_PUBLIC_KEY is required but not set in config"
    [ -z "${CF_DOMAIN:-}" ] && fail "CF_DOMAIN is required but not set in config"
    [ -z "${CF_TUNNEL:-}" ] && fail "CF_TUNNEL is required but not set in config"
    [ -z "${VENV_PATH:-}" ] && fail "VENV_PATH is required but not set in config"
fi

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

if [ "${NON_INTERACTIVE:-}" != "true" ]; then
    echo ""
    echo "=== PRE-FLIGHT CHECKLIST ==="
    echo "  1. This script is Linux-native and also supports WSL."
    echo "  2. Kernel manager will be installed to ~/bin/kernel-manager.sh."
    echo "  3. If using Cloudflare tunnels, cloudflared login must be completed before tunnel management."
    echo "  4. A local client config will be written to ~/.config/gpu-dev/client-config.json."
    read -r -p "Press Enter when ready..."
fi

step "Step 1: Install dependencies"
if ! command -v sshd >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! dpkg -l | grep -q "^ii  python3-venv"; then
    sudo apt-get update -q
    sudo apt-get install -qy openssh-server curl wget python3 python3-venv
    if [ "$IS_WSL" = false ]; then
        sudo apt-get install -qy ufw
    fi
else
    echo "Dependencies already installed, skipping."
fi

step "Step 2: Configure SSH on port $SSH_PORT"
sudo sed -i -E "s/^#?Port [0-9]+/Port $SSH_PORT/" /etc/ssh/sshd_config
sudo sed -i -E "s/#?(PubkeyAuthentication).*/\1 yes/" /etc/ssh/sshd_config
sudo sed -i -E "s/#?(PasswordAuthentication).*/\1 no/" /etc/ssh/sshd_config
sudo mkdir -p /run/sshd

if systemd_usable; then
    sudo systemctl enable ssh
    sudo systemctl restart ssh
else
    echo "systemd is not available; skipping ssh service enable/restart"
    if [ "$IS_WSL" = true ]; then
        echo "WSL detected without usable systemd."
    fi
fi

step "Step 3: Add SSH key"
mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
grep -qxF "$SSH_PUBLIC_KEY" "$HOME/.ssh/authorized_keys" || echo "$SSH_PUBLIC_KEY" >> "$HOME/.ssh/authorized_keys"
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"

step "Step 4: Configure firewall"
if [ "$IS_WSL" = true ]; then
    echo "Skipping Linux firewall configuration in WSL."
else
    sudo ufw allow "$SSH_PORT/tcp" comment "Linux SSH" || true
    sudo ufw allow "22/tcp" comment "OpenSSH" || true
    sudo ufw --force enable
fi

step "Step 4b: Disable sleep/suspend for always-on GPU server"
if [ "$IS_WSL" = false ]; then
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
    echo "Sleep/suspend disabled"
else
    echo "WSL detected, skipping (handled by Windows host)"
fi


step "Step 5: Prepare paths and shell profile"
mkdir -p "$KERNEL_WORK_DIR" "$HOME/bin"
append_line_once 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/bin:$PATH"' "$HOME/.bashrc"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/bin:$PATH"

step "Step 6: Install uv and create venv"
if ! command_exists uv; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    [ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env" || true
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env" || true
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/bin:$PATH"
fi

if [ ! -f "$(dirname "$VENV_PATH")/pyproject.toml" ]; then
    (cd "$(dirname "$VENV_PATH")" && uv init --name "$(basename "$(dirname "$VENV_PATH")")")
fi
(cd "$(dirname "$VENV_PATH")" && uv python pin "$PYTHON_VERSION")

if [ ! -d "$VENV_PATH" ]; then
    mkdir -p "$(dirname "$VENV_PATH")"
    uv venv "$VENV_PATH" --project "$(dirname "$VENV_PATH")"
    (cd "$(dirname "$VENV_PATH")" && uv add ipykernel jupyter_client torch torchvision torchaudio numpy numba pandas scipy scikit-learn matplotlib plotly pillow tqdm httpx requests)
    echo "Venv created at $VENV_PATH"
else
    echo "Venv exists at $VENV_PATH, skipping creation"
    (cd "$(dirname "$VENV_PATH")" && uv add ipykernel jupyter_client torch torchvision torchaudio numpy numba pandas scipy scikit-learn matplotlib plotly pillow tqdm httpx requests)
fi


step "Step 7: Install kernel-manager.sh"
curl -fsSL "$KERNEL_MANAGER_URL" -o "$HOME/bin/kernel-manager.sh"
chmod +x "$HOME/bin/kernel-manager.sh"

step "Step 8: Install kernel cleanup timer"
if systemd_usable; then
    sudo tee /etc/systemd/system/kernel-cleanup.service > /dev/null <<EOF
[Unit]
Description=Cleanup inactive ipykernels

[Service]
Type=oneshot
User=${LINUX_USER}
ExecStart=${HOME}/bin/kernel-manager.sh cleanup
EOF

    sudo tee /etc/systemd/system/kernel-cleanup.timer > /dev/null <<EOF
[Unit]
Description=Run kernel cleanup at 10pm daily

[Timer]
OnCalendar=*-*-* 22:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable kernel-cleanup.timer
    sudo systemctl restart kernel-cleanup.timer
else
    echo "systemd is not available; skipping kernel cleanup timer"
fi

step "Step 9: Install cloudflared"
if ! command_exists cloudflared; then
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O /tmp/cloudflared.deb
    sudo dpkg -i /tmp/cloudflared.deb || sudo apt-get install -f -y
else
    echo "cloudflared already installed, skipping."
fi

step "Step 9b: Create cloudflared symlink for CRAFT compatibility"
mkdir -p "$HOME/.local/bin"
CF_ACTUAL_PATH=$(command -v cloudflared 2>/dev/null || true)
if [ -n "$CF_ACTUAL_PATH" ] && [ -x "$CF_ACTUAL_PATH" ] && [ "$CF_ACTUAL_PATH" != "$HOME/.local/bin/cloudflared" ]; then
    ln -sf "$CF_ACTUAL_PATH" "$HOME/.local/bin/cloudflared"
    echo "Created symlink: ~/.local/bin/cloudflared -> $CF_ACTUAL_PATH"
else
    echo "cloudflared symlink already exists, not found, or not executable - skipping"
fi

step "Step 10: Validate cloudflared authentication"
if ! cloudflared_authenticated; then
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
        echo "WARNING: cloudflared is not authenticated. Run 'cloudflared tunnel login' manually."
        echo "Skipping tunnel setup steps."
        SKIP_TUNNEL=true
    else
        fail "cloudflared is not authenticated. Run 'cloudflared tunnel login' and rerun the script."
    fi
else
    SKIP_TUNNEL=false
fi

if [ "${SKIP_TUNNEL:-false}" = false ]; then

step "Step 11: Create or reuse Cloudflare tunnel"
if ! cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -qx "$CF_TUNNEL"; then
    cloudflared tunnel create "$CF_TUNNEL"
fi

TUNNEL_ID="$(cloudflared tunnel list | awk -v tunnel="$CF_TUNNEL" '$2 == tunnel {print $1; exit}')"
[ -n "$TUNNEL_ID" ] || fail "Failed to determine tunnel id for $CF_TUNNEL"

CREDS_FILE="$HOME/.cloudflared/${TUNNEL_ID}.json"
[ -f "$CREDS_FILE" ] || echo "Warning: tunnel credentials file not found yet at $CREDS_FILE"

step "Step 12: Create DNS routes"
cloudflared tunnel route dns "$CF_TUNNEL" "$CF_HOSTNAME_LINUX" 2>/dev/null || echo "Linux DNS route already exists, skipping."
if [ "$IS_WSL" = true ]; then
    cloudflared tunnel route dns "$CF_TUNNEL" "$CF_HOSTNAME_WIN" 2>/dev/null || echo "Windows DNS route already exists, skipping."
fi

step "Step 13: Write cloudflared config"
CONFIG_YML="$HOME/.cloudflared/config.yml"
mkdir -p "$HOME/.cloudflared"

if [ ! -f "$CONFIG_YML" ]; then
    if [ "$IS_WSL" = true ]; then
        WIN_IP="$(ip route | awk '/default/ {print $3; exit}')"
        EXTRA_INGRESS="  - hostname: $CF_HOSTNAME_WIN
    service: tcp://$WIN_IP:22"
    else
        EXTRA_INGRESS=""
    fi

    cat > "$CONFIG_YML" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $HOME/.cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: $CF_HOSTNAME_LINUX
    service: tcp://localhost:$SSH_PORT
$EXTRA_INGRESS
  - service: http_status:404
EOF
else
    echo "Cloudflared config already exists, preserving current file."
fi

step "Step 14: Write local client config"
write_client_config
echo "Local client config written to $CLIENT_CONFIG_FILE"

step "Step 15: Create cloudflared service"
if systemd_usable; then
    sudo tee /etc/systemd/system/cloudflared-tunnel.service > /dev/null <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
User=${LINUX_USER}
ExecStart=/usr/bin/cloudflared tunnel run ${CF_TUNNEL}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable cloudflared-tunnel
    sudo systemctl restart cloudflared-tunnel
else
    echo "systemd is not available; skipping cloudflared service"
fi

fi  # end SKIP_TUNNEL

step "Step 16: Final instructions"
echo "Setup complete."
echo ""
echo "Recommended first kernel command:"
if [ -n "${KERNEL_CLIENT_NAME:-}" ]; then
    echo "  kernel-manager.sh create \"$KERNEL_CLIENT_NAME\" \"$VENV_PYTHON\" \"$KERNEL_WORK_DIR\""
else
    echo "  kernel-manager.sh create \"$(hostname)-client\" \"$VENV_PYTHON\" \"$KERNEL_WORK_DIR\""
fi
echo ""
echo "Local client config:"
echo "  $CLIENT_CONFIG_FILE"
echo ""
echo "Example package install:"
echo "  uv pip install --python \"$VENV_PYTHON\" torch torchvision"

if [ "${SKIP_TUNNEL:-false}" = true ]; then
    echo ""
    echo "NOTE: Cloudflare tunnel was not configured."
    echo "Run 'cloudflared tunnel login' then rerun this script to complete tunnel setup."
fi

. "$HOME/.bashrc" 2>/dev/null || true
step "Final: Client configuration for copy-paste"

echo ""
echo "========================================"
echo "  COPY-PASTE TO CLIENT MACHINES"
echo "========================================"
echo ""

# Read the config we just created
CLIENT_CFG=$(cat "$CLIENT_CONFIG_FILE")

echo "1. FOR SOLVEIT / PYTHON CLIENTS:"
echo "   Save as: ~/.config/gpu-dev/client-config.json"
echo ""
echo "$CLIENT_CFG"
echo ""

echo "2. FOR VS CODE SSH:"
echo "   Add to: ~/.ssh/config"
echo ""
echo "Host gpu-linux"
echo "  HostName $CF_HOSTNAME_LINUX"
echo "  Port $SSH_PORT"
echo "  User $LINUX_USER"
echo "  ProxyCommand ~/.local/bin/cloudflared access tcp --hostname $CF_HOSTNAME_LINUX"
echo "  ControlMaster auto"
echo "  ControlPath ~/.ssh/control-%r@%h:%p"
echo "  ControlPersist yes"
echo "  ServerAliveInterval 60"
echo "  ServerAliveCountMax 10"
echo ""
echo "Host gpu-windows"
echo "  HostName $CF_HOSTNAME_WIN"
echo "  Port 22"
echo "  User $WINDOWS_USER"
echo "  ProxyCommand ~/.local/bin/cloudflared access tcp --hostname $CF_HOSTNAME_WIN"
echo ""
echo "========================================"

