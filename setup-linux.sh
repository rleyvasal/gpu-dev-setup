#!/bin/bash
# ============================================================
# USER CONFIG — prompted if not passed from setup-windows.ps1
# ============================================================
echo ""
echo "=== Setup Configuration ==="
[ -z "$WSL_USER" ]    && read -p "WSL username (e.g. rrx): " WSL_USER
[ -z "$SOLVEIT_KEY" ] && read -p "Solveit SSH public key: " SOLVEIT_KEY
[ -z "$CF_DOMAIN" ]   && read -p "Cloudflare domain (e.g. mydomain.com): " CF_DOMAIN
[ -z "$CF_TUNNEL" ]   && read -p "Tunnel name (e.g. wsl-gpu): " CF_TUNNEL
[ -z "$VENV_PATH" ]   && read -p "Project venv path (e.g. /home/rrx/projects/myproject/.venv): " VENV_PATH
# ============================================================
# DO NOT EDIT BELOW THIS LINE
# ============================================================

WSL_SSH_PORT=${WSL_SSH_PORT:-2222}
CF_HOSTNAME_WSL="$CF_TUNNEL.$CF_DOMAIN"
CF_HOSTNAME_WIN="win-ssh.$CF_DOMAIN"
VENV_PYTHON="$VENV_PATH/bin/python"

# Detect WSL vs native Linux
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=true
    echo "Running in WSL mode"
else
    IS_WSL=false
    echo "Running in native Linux mode"
fi

echo ""
echo "=== PRE-FLIGHT CHECKLIST ==="
echo "  1. WSL user already created (Windows only)"
echo "  2. Run 'cloudflared tunnel login' and complete browser auth"
read -p "Press Enter when ready..."

# --- Step 1: Dependencies ---
echo "=== Step 1: Installing dependencies ==="
sudo apt-get update -q
sudo apt-get install -qy openssh-server curl wget ufw

# --- Step 2: Configure SSH ---
echo "=== Step 2: Configuring SSH on port $WSL_SSH_PORT ==="
sudo sed -i -E "s/^#?Port [0-9]+/Port $WSL_SSH_PORT/" /etc/ssh/sshd_config
sudo sed -i -E "s/#?(PubkeyAuthentication).*/\1 yes/" /etc/ssh/sshd_config
sudo sed -i -E "s/#?(PasswordAuthentication).*/\1 no/" /etc/ssh/sshd_config
sudo mkdir -p /run/sshd
sudo systemctl enable ssh
sudo systemctl restart ssh

# --- Step 3: SSH keys ---
echo "=== Step 3: Adding SSH keys ==="
mkdir -p /home/${WSL_USER}/.ssh
grep -qxF "$SOLVEIT_KEY" /home/${WSL_USER}/.ssh/authorized_keys 2>/dev/null \
    || echo "$SOLVEIT_KEY" >> /home/${WSL_USER}/.ssh/authorized_keys
chmod 700 /home/${WSL_USER}/.ssh
chmod 600 /home/${WSL_USER}/.ssh/authorized_keys

# --- Step 4: Firewall ---
echo "=== Step 4: Configuring firewall ==="
sudo ufw allow $WSL_SSH_PORT/tcp comment "WSL SSH"
sudo ufw allow 22/tcp comment "OpenSSH"
sudo ufw --force enable

# --- Step 4b: Disable sleep (native Linux only) ---
if [ "$IS_WSL" = false ]; then
    echo "=== Step 4b: Disabling sleep and hibernate ==="
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
    sudo sed -i -E "s/#?(HandleSuspendKey)=.*/\1=ignore/" /etc/systemd/logind.conf
    sudo sed -i -E "s/#?(HandleLidSwitch)=.*/\1=ignore/" /etc/systemd/logind.conf
    sudo sed -i -E "s/#?(IdleAction)=.*/\1=ignore/" /etc/systemd/logind.conf
    sudo systemctl restart systemd-logind
    echo "Sleep and hibernate disabled."
fi

# --- Step 5: Install uv and venv ---
echo "=== Step 5: Installing uv ==="
if ! command -v uv &> /dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    source $HOME/.local/bin/env 2>/dev/null || source $HOME/.cargo/env 2>/dev/null || true
fi
echo 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/bin:$PATH"' >> /home/${WSL_USER}/.bashrc
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/bin:$PATH"

echo "=== Creating venv ==="
uv venv $VENV_PATH
uv pip install --python $VENV_PYTHON ipykernel jupyter_client

# --- Step 6: Install kernel-manager ---
echo "=== Step 6: Installing kernel-manager ==="
mkdir -p /home/${WSL_USER}/bin
cat > /home/${WSL_USER}/bin/kernel-manager.sh << 'KERNEL_MANAGER_EOF'
#!/bin/bash
REGISTRY="$HOME/.kernels/registry.json"
KERNELS_DIR="$HOME/.kernels"
RUNTIME_DIR="$HOME/.local/share/jupyter/runtime"
INACTIVITY_HOURS=24

mkdir -p "$KERNELS_DIR" "$RUNTIME_DIR"
[ -f "$REGISTRY" ] || echo '{}' > "$REGISTRY"

_next_port_base() {
    python3 -c "
import json
r = json.load(open('$REGISTRY'))
bases = [v['port_base'] for v in r.values()] or [56991]
print(max(bases) + 10)
"
}

_service_name() { echo "ipykernel-$1"; }

cmd_create() {
    local name=$1
    local venv_python=${2:-$(which python3)}
    [ -z "$name" ] && { echo "Usage: kernel-manager create <name> [venv_python]"; exit 1; }

    if python3 -c "import json; r=json.load(open('$REGISTRY')); exit(0 if '$name' in r else 1)" 2>/dev/null; then
        echo "Kernel '$name' already exists."
        exit 0
    fi

    local port_base=$(_next_port_base)
    local conn_file="$RUNTIME_DIR/kernel-$name.json"
    local key=$(python3 -c 'import uuid; print(uuid.uuid4())')

    cat > "$conn_file" << EOF
{
  "shell_port":   $((port_base)),
  "iopub_port":   $((port_base+1)),
  "stdin_port":   $((port_base+2)),
  "control_port": $((port_base+3)),
  "hb_port":      $((port_base+4)),
  "ip": "127.0.0.1",
  "key": "$key",
  "transport": "tcp",
  "signature_scheme": "hmac-sha256",
  "kernel_name": "python3"
}
EOF
    chmod 600 "$conn_file"

    local svc=$(_service_name $name)
    sudo tee /etc/systemd/system/$svc.service > /dev/null << EOF
[Unit]
Description=Persistent IPython Kernel ($name)
After=network.target

[Service]
User=$USER
ExecStart=$venv_python -m ipykernel_launcher -f $conn_file
Restart=always
RestartSec=5
Environment=PATH=$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable $svc
    sudo systemctl start $svc

    python3 -c "
import json, time
r = json.load(open('$REGISTRY'))
r['$name'] = {
    'port_base': $port_base,
    'conn_file': '$conn_file',
    'venv_python': '$venv_python',
    'created': time.time(),
    'last_seen': time.time()
}
json.dump(r, open('$REGISTRY', 'w'), indent=2)
"
    echo "✅ Kernel '$name' created on ports $port_base-$((port_base+4))"
}

cmd_delete() {
    local name=$1
    [ -z "$name" ] && { echo "Usage: kernel-manager delete <name>"; exit 1; }
    local svc=$(_service_name $name)
    sudo systemctl stop $svc 2>/dev/null
    sudo systemctl disable $svc 2>/dev/null
    sudo rm -f /etc/systemd/system/$svc.service
    sudo systemctl daemon-reload
    local conn_file=$(python3 -c "import json; r=json.load(open('$REGISTRY')); print(r.get('$name', {}).get('conn_file', ''))")
    [ -f "$conn_file" ] && rm -f "$conn_file"
    python3 -c "
import json
r = json.load(open('$REGISTRY'))
r.pop('$name', None)
json.dump(r, open('$REGISTRY', 'w'), indent=2)
"
    echo "🗑️  Kernel '$name' deleted."
}

cmd_list() {
    echo "=== Registered Kernels ==="
    python3 -c "
import json, time, subprocess
r = json.load(open('$REGISTRY'))
if not r:
    print('  No kernels registered.')
for name, info in r.items():
    svc = 'ipykernel-' + name
    result = subprocess.run(['systemctl', 'is-active', svc], capture_output=True, text=True)
    status = result.stdout.strip()
    last = time.time() - info.get('last_seen', 0)
    print(f\"  {name:15} ports:{info['port_base']}-{info['port_base']+4}  status:{status}  last_seen:{last/3600:.1f}h ago\")
"
}

cmd_heartbeat() {
    local name=$1
    [ -z "$name" ] && { echo "Usage: kernel-manager heartbeat <name>"; exit 1; }
    python3 -c "
import json, time
r = json.load(open('$REGISTRY'))
if '$name' in r:
    r['$name']['last_seen'] = time.time()
    json.dump(r, open('$REGISTRY', 'w'), indent=2)
"
}

cmd_cleanup() {
    echo "=== Checking for inactive kernels ==="
    ACTIVE_SSH=$(ss -tnp 2>/dev/null | grep ESTABLISHED | grep sshd | wc -l)
    if [ "$ACTIVE_SSH" -gt "0" ]; then
        echo "Active SSH sessions found, skipping cleanup."
        exit 0
    fi
    python3 -c "
import json, time
r = json.load(open('$REGISTRY'))
cutoff = time.time() - ($INACTIVITY_HOURS * 3600)
to_delete = [n for n,v in r.items() if v.get('last_seen', 0) < cutoff]
for name in to_delete:
    print(name)
" | while read name; do
        echo "  Killing inactive kernel: $name"
        cmd_delete "$name"
    done
    echo "Cleanup done."
}

case "$1" in
    create)    cmd_create "$2" "$3" ;;
    delete)    cmd_delete "$2" ;;
    list)      cmd_list ;;
    heartbeat) cmd_heartbeat "$2" ;;
    cleanup)   cmd_cleanup ;;
    *) echo "Usage: kernel-manager {create|delete|list|heartbeat|cleanup} [name] [venv_python]" ;;
esac
KERNEL_MANAGER_EOF
chmod +x /home/${WSL_USER}/bin/kernel-manager.sh

# --- Step 7: Kernel cleanup timer ---
echo "=== Step 7: Installing kernel cleanup timer ==="
sudo tee /etc/systemd/system/kernel-cleanup.service > /dev/null << EOF
[Unit]
Description=Cleanup inactive ipykernels

[Service]
Type=oneshot
User=${WSL_USER}
ExecStart=/home/${WSL_USER}/bin/kernel-manager.sh cleanup
EOF

sudo tee /etc/systemd/system/kernel-cleanup.timer > /dev/null << EOF
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
sudo systemctl start kernel-cleanup.timer

# --- Step 8: Install cloudflared ---
echo "=== Step 8: Installing cloudflared ==="
if ! command -v cloudflared &> /dev/null; then
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
        -O /tmp/cloudflared.deb
    sudo dpkg -i /tmp/cloudflared.deb
else
    echo "cloudflared already installed, skipping."
fi

# --- Step 9: Cloudflare tunnel setup ---
echo "=== Step 9: Cloudflare tunnel setup ==="
if ! cloudflared tunnel list 2>/dev/null | grep -q "$CF_TUNNEL"; then
    cloudflared tunnel create $CF_TUNNEL
else
    echo "Tunnel '$CF_TUNNEL' already exists, skipping."
fi
TUNNEL_ID=$(cloudflared tunnel list | grep "$CF_TUNNEL" | awk '{print $1}')

echo "=== Creating DNS records ==="
cloudflared tunnel route dns $CF_TUNNEL $CF_HOSTNAME_WSL 2>/dev/null \
    || echo "DNS record already exists, skipping."
if [ "$IS_WSL" = true ]; then
    cloudflared tunnel route dns $CF_TUNNEL $CF_HOSTNAME_WIN 2>/dev/null \
        || echo "DNS record already exists, skipping."
fi

echo "=== Writing tunnel config ==="
CONFIG_FILE="/home/${WSL_USER}/.cloudflared/config.yml"
mkdir -p /home/${WSL_USER}/.cloudflared
if [ ! -f "$CONFIG_FILE" ]; then
    if [ "$IS_WSL" = true ]; then
        WIN_IP=$(ip route | grep default | awk '{print $3}')
        EXTRA_INGRESS="  - hostname: $CF_HOSTNAME_WIN
    service: tcp://$WIN_IP:22"
    else
        EXTRA_INGRESS=""
    fi
    cat > "$CONFIG_FILE" << EOF
tunnel: $TUNNEL_ID
credentials-file: /home/${WSL_USER}/.cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: $CF_HOSTNAME_WSL
    service: tcp://localhost:$WSL_SSH_PORT
$EXTRA_INGRESS
  - service: http_status:404
EOF
    echo "Tunnel config written."
else
    echo "Tunnel config already exists, skipping."
fi

# --- Step 10: Cloudflared systemd service ---
echo "=== Step 10: Creating cloudflared systemd service ==="
sudo tee /etc/systemd/system/cloudflared-tunnel.service > /dev/null << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
User=${WSL_USER}
ExecStart=/usr/bin/cloudflared tunnel run ${CF_TUNNEL}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable cloudflared-tunnel
sudo systemctl restart cloudflared-tunnel
echo "Cloudflared service created/updated."

echo ""
echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Create your kernels:"
echo "     kernel-manager.sh create solveit $VENV_PYTHON"
echo "     kernel-manager.sh create macbook $VENV_PYTHON"
echo "  2. Install your project packages:"
echo "     uv pip install --python $VENV_PYTHON torch torchvision"

