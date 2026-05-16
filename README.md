## Installation

### Windows Setup (WSL)

#### Prerequisites

- Windows 10/11 with Administrator access
- An SSH public key for remote access
- A Cloudflare account with a registered domain

#### Run the Setup Script

Run as Administrator in PowerShell:

```powershell
.\setup-windows.ps1
```

On first run, you will be prompted for:
- WSL distro name (auto-detected if only one exists)
- Linux SSH port
- SSH public key
- Cloudflare domain and tunnel name
- Project name

These values are saved to `~/.config/gpu-dev/client-config.json` so subsequent runs
skip the prompts.

#### What the Script Automates

| Step | Description |
|---|---|
| WSL 2 | Installs WSL and your chosen Linux distro |
| OpenSSH Server | Host key generation, pubkey auth, password auth disabled |
| Windows Hello | Disables passwordless requirement for SSH compatibility |
| SSH key | Adds your public key to administrators authorized keys |
| Firewall | Opens ports for SSH (22 and custom Linux SSH port) |
| Power settings | Disables auto-sleep and hibernate (AC and DC) |
| WSL idle timeouts | Creates `.wslconfig` to prevent WSL from shutting down |
| WSL startup | Scheduled task to start WSL at boot/login |
| Config files | Written for both Linux and Windows sides |
| Linux setup | Triggers `setup-linux.sh` inside WSL automatically |

#### Manual Steps Required

1. **First WSL launch** — If your distro is freshly installed, launch it once and create
   your Linux user before running the script.

2. **Cloudflare tunnel login** — After the script runs, if no tunnel is found, you will
   be prompted to run `cloudflared tunnel login` inside WSL. This requires browser-based
   authentication with your Cloudflare account.

3. **Adding SSH keys from new clients** — The script only adds the key provided during
   setup. To add keys from additional clients (e.g. solveit), manually append them on
   Windows:
   ```powershell
   Add-Content "C:\ProgramData\ssh\administrators_authorized_keys" "<public-key>"
   icacls "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "SYSTEM:F" /grant "Administrators:F"
   Restart-Service sshd
   ```

---

### Native Linux (Standalone or WSL)

The Linux setup script supports two modes:
- **Standalone** — install directly on a Ubuntu/Debian machine with a GPU
- **WSL** — called automatically by `setup-windows.ps1`

When running in WSL mode, the script configures both Linux and Windows SSH access
through a single Cloudflare tunnel. When running standalone, it configures only
Linux SSH access.

#### Before You Start (Standalone Only)

If running standalone (not via the Windows script), complete these steps first:

1. **Install cloudflared** if not already installed:
   ```bash
   wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O /tmp/cloudflared.deb
   sudo dpkg -i /tmp/cloudflared.deb
   ```

2. **Authenticate with Cloudflare:**
   ```bash
   cloudflared tunnel login
   ```

3. **Have your SSH public key ready.** This is the public key from the client machine
   (e.g. solveit, Mac) that will connect to this server.
   - For Solveit: `cat /app/data/.ssh/id_*.pub`
   - For Mac/Linux: `cat ~/.ssh/id_ed25519.pub`

#### Run the Setup Script

```bash
curl -fsSL https://raw.githubusercontent.com/rleyvasal/gpu-dev-setup/main/setup-linux.sh -o /tmp/setup-linux.sh && bash /tmp/setup-linux.sh
```

The script will prompt you for:
- Your SSH public key
- Your Cloudflare domain (e.g. `mydomain.com`)
- Your tunnel name (e.g. `gpu-dev`)
- Your project name (e.g. `myproject`)

> **Note:** When called from the Windows script, these values are passed automatically
> via config and the script runs in non-interactive mode.

#### What the Script Automates

| Step | Description |
|---|---|
| SSH server | Configured on port 2222 with public key auth only (password auth disabled) |
| Firewall | UFW rules for SSH ports (standalone only; skipped in WSL) |
| Sleep/suspend | Disabled for always-on GPU server (standalone only; handled by Windows host in WSL) |
| Python venv | Created with uv, includes ML packages (torch, torchvision, torchaudio, numpy, pandas, scipy, scikit-learn, matplotlib, plotly, pillow, tqdm, httpx, requests) |
| Cloudflare tunnel | Created, DNS routed, and runs as a systemd service |
| Cloudflared symlink | Created at `~/.local/bin/cloudflared` for client compatibility |
| Kernel manager | Installed with daily cleanup timer (10pm) |
| Client config | Written to `~/.config/gpu-dev/client-config.json` |

#### WSL Mode Differences

When running in WSL, the script additionally:
- Creates a DNS route and ingress rule for Windows SSH access (`CF_HOSTNAME_WIN`)
- Skips UFW firewall configuration (handled by Windows)
- Skips sleep/suspend configuration (handled by Windows host)

#### Post-Install: Customizing Packages

The default venv includes common ML/data science packages. To add more:

```bash
uv pip install --python ~/gpu-dev-projects/YOUR_PROJECT/.venv/bin/python <package>
```
| Sleepnow alias | Adds `sleepnow` command to PowerShell profile for manual sleep |

