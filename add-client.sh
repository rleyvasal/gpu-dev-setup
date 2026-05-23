#!/bin/bash
# add-client.sh - Add new client's SSH public key and print client config

KEY=$1
DEFAULT_IDENTITY="~/.ssh/id_ed25519_gpu_dev_solveit"

if [ -z "$KEY" ]; then
    echo "Usage: $0 '<ssh-public-key>'"
    echo ""
    echo "Example:"
    echo "  $0 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID... user@laptop'"
    exit 1
fi

echo ""
echo "This is the path to your SSH private key on your local machine."
echo "(The matching public key is the one you're adding above.)"
read -p "Identity file path [$DEFAULT_IDENTITY]: " IDENTITY_FILE
IDENTITY_FILE=${IDENTITY_FILE:-$DEFAULT_IDENTITY}

HOME_DIR=${HOME}
AUTH_KEYS="$HOME_DIR/.ssh/authorized_keys"
CONFIG_FILE="$HOME_DIR/.config/gpu-dev/client-config.json"

mkdir -p "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"

# Check if key already exists
if grep -qxF "$KEY" "$AUTH_KEYS" 2>/dev/null; then
    echo "Key already exists"
else
    echo "$KEY" >> "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    echo "✅ Key added for $(echo $KEY | awk '{print $3}')"
fi

# Print client configuration
if [ -f "$CONFIG_FILE" ]; then
    echo ""
    echo "========================================"
    echo "  NEW CLIENT CONFIGURATION"
    echo "========================================"
    echo ""

    # Extract values from server config
    CF_DOMAIN=$(grep '"cf_domain"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)
    CF_TUNNEL=$(grep '"cf_tunnel"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)
    CF_HOSTNAME_LINUX=$(grep '"cf_hostname_linux"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)
    CF_HOSTNAME_WIN=$(grep '"cf_hostname_win"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)
    SSH_PORT=$(grep '"ssh_port"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)
    LINUX_USER=$(grep '"linux_user"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)
    WINDOWS_USER=$(grep '"windows_user"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)
    VENV_PATH=$(grep '"venv_path"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)
    KERNEL_CLIENT_NAME=$(grep '"kernel_client_name"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)
    KERNEL_WORK_DIR=$(grep '"kernel_work_dir"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)

    echo "1. FOR SOLVEIT / PYTHON CLIENTS:"
    echo "   Save as: ~/.config/gpu-dev/client-config.json"
    echo ""
    cat <<EOF
{
  "connection": {
    "domain": "$CF_DOMAIN",
    "tunnel": "$CF_TUNNEL",
    "linux_hostname": "$CF_HOSTNAME_LINUX",
    "windows_hostname": "$CF_HOSTNAME_WIN",
    "ssh_port": $SSH_PORT,
    "linux_user": "$LINUX_USER"
  },
  "client": {
    "_comment": "EDIT: Set paths for your local machine",
    "identity_file": "$IDENTITY_FILE",
    "_identity_note": "Windows: %USERPROFILE%\\\\.ssh\\\\id_ed25519_gpu_dev_solveit, Mac: ~/.ssh/id_ed25519_gpu_dev_solveit",
    "cloudflared_path": "~/.local/bin/cloudflared",
    "_cloudflared_note": "Windows: C:\\\\Program Files\\\\Cloudflare\\\\cloudflared.exe, Mac: /opt/homebrew/bin/cloudflared",
    "profile": "cloudflared-remote",
    "_profile_note": "Use 'vscode-local' for direct localhost connection without cloudflared"
  },
  "kernel": {
    "venv_path": "$VENV_PATH",
    "kernel_client_name": "$KERNEL_CLIENT_NAME",
    "work_dir": "$KERNEL_WORK_DIR"
  }
}
EOF
    echo ""
    echo "2. FOR VS CODE SSH:"
    echo "   Add to: ~/.ssh/config"
    echo ""
    echo "Host gpu-linux"
    echo "  HostName $CF_HOSTNAME_LINUX"
    echo "  Port $SSH_PORT"
    echo "  User $LINUX_USER"
    echo "  IdentityFile $IDENTITY_FILE"
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
    echo "  IdentityFile $IDENTITY_FILE"
    echo "  ProxyCommand ~/.local/bin/cloudflared access tcp --hostname $CF_HOSTNAME_WIN"
    echo ""
    echo "========================================"
    echo ""
    echo "Prerequisites for new client:"
    echo "  1. Install cloudflared: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
    echo "  2. Generate SSH key: ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_gpu_dev_solveit"
    echo ""
fi

