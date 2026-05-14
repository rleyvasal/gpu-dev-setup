# Remote GPU Development Environment

Transform your gaming PC or any Linux machine into a remotely accessible
GPU development server. Connect securely from anywhere using Cloudflare
tunnels — no port forwarding, no static IP, no router configuration required.

Designed for deep learning training, data science, and GPU-accelerated
workloads. Accessible from Solveit, VSCode, or any SSH client.

---

## What This Does

- Converts a Windows gaming PC or Linux machine into a remote GPU server
- Exposes it securely via Cloudflare tunnels
- Manages multiple persistent Jupyter kernels — one per user or client
- Keeps kernels alive across sessions so you can resume work anytime
- Automatically cleans up inactive kernels at 10pm daily
- Works with Solveit, VSCode Remote SSH, and Mac/Linux terminals

---

## Prerequisites

**On your server machine:**
- Windows 10/11 with a GPU, or a Ubuntu/Debian Linux machine
- A Cloudflare account with a domain configured

**On your client machine (Mac/Linux laptop):**
- `cloudflared` installed ([install guide](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/))
- VSCode with Remote SSH extension (optional)
- Solveit account (optional)

---

## Configuration

Before running any scripts, have the following information ready:

| Placeholder | Description | Example |
|---|---|---|
| `linuxuser` | Your Linux/WSL username | `devuser` |
| `winuser` | Your Windows login username | `john` |
| `YOUR_DOMAIN` | Your Cloudflare domain | `mydomain.com` |
| `YOUR_TUNNEL_NAME` | Name for your Cloudflare tunnel | `wsl-gpu` |
| `YOUR_PROJECT` | Your project folder name | `myproject` |
| `YOUR_SOLVEIT_KEY` | Your Solveit SSH public key | `ssh-ed25519 AAA...` |

### Finding Your Windows Username

Your Windows username is **not** "Administrator" or the display name — it's your actual login name. To find it:

**PowerShell:**
```powershell
$env:USERNAME
```

Common examples: `john`, `johnsmith`, `j.smith` (not `John Smith`)

> **How to find your Solveit SSH key:**
> In your Solveit terminal run: `cat /app/data/.ssh/id_*.pub`

---

## Installation

### Windows (Gaming PC)

1. Open PowerShell as Administrator and run:
   ```powershell
   irm https://raw.githubusercontent.com/rleyvasal/gpu-dev-setup/main/setup-windows.ps1 | iex
   ```
2. Follow the on-screen prompts:
   - If first-time WSL install, reboot when prompted
   - Open Ubuntu from Start Menu and create your Linux user (e.g. `linuxuser`)
   - In WSL terminal, authenticate with Cloudflare:
     ```bash
     cloudflared tunnel login
     ```
   - Re-run the script to complete setup

### Native Linux

1. Authenticate with Cloudflare first:
   ```bash
   cloudflared tunnel login
   ```
2. Run:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/rleyvasal/gpu-dev-setup/main/setup-linux.sh -o /tmp/setup-linux.sh && bash /tmp/setup-linux.sh
   ```

---

## First Run — Create Your Kernels

After setup completes, SSH into your machine and create a kernel for each user:
```bash
kernel-manager.sh create solveit
kernel-manager.sh create macbook
```

Verify they are running:
```bash
kernel-manager.sh list
```

Then install your project packages:
```bash
uv pip install --python ~/projects/YOUR_PROJECT/.venv/bin/python torch torchvision
```

---

## Client Setup

### Mac SSH config
Copy `mac-ssh-config-template` into `~/.ssh/config`, replacing:
- `linuxuser` with your actual Linux username
- `winuser` with your actual Windows username
- `YOUR_TUNNEL_NAME` and `YOUR_DOMAIN` with your Cloudflare values

### Mac sleep alias (`~/.zshrc`)
```bash
alias sleepnow="ssh win-ssh 'powershell -Command \"rundll32.exe powrprof.dll,SetSuspendState 0,1,0\"'"
```

### VSCode
Copy `vscode-settings.json` into your project's `.vscode/` folder.

### Solveit CRAFT
Copy `CRAFT-template.py` into your solveit project folder and update
the `USER CONFIG` section with your actual values.

---

## Daily Usage

| Task | Command |
|---|---|
| Connect from terminal | `ssh wsl-gpu` |
| Connect from VSCode | Remote SSH → wsl-gpu |
| List running kernels | `kernel-manager.sh list` |
| Add a new kernel | `kernel-manager.sh create <name>` |
| Remove a kernel | `kernel-manager.sh delete <name>` |
| Sleep the PC (terminal) | `sleepnow` |
| Sleep the PC (Solveit) | `sleepnow()` |

---

## Kernel Management

Each user gets their own named persistent kernel with dedicated ports.
Kernels survive disconnections and reboots — resume exactly where you
left off. Kernels are automatically cleaned up at 10pm if inactive for
24 hours with no active SSH sessions.

---

## Security

- Password authentication disabled on all SSH connections
- Public key authentication only
- All connections encrypted end-to-end via Cloudflare tunnels
- No open ports required on your router or firewall
