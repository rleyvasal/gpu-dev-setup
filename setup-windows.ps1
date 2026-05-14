# ============================================================
# USER CONFIG — you will be prompted for these values
# ============================================================
Write-Host "=== Setup Configuration ===" -ForegroundColor Cyan
$WSL_USER        = Read-Host "WSL username (e.g. linuxuser)"
$WSL_DISTRO      = "Ubuntu"
$WSL_SSH_PORT    = "2222"
$SOLVEIT_KEY     = Read-Host "Solveit SSH public key"
$CF_DOMAIN       = Read-Host "Cloudflare domain (e.g. mydomain.com)"
$CF_TUNNEL       = Read-Host "Tunnel name (e.g. wsl-gpu)"
$VENV_PATH       = Read-Host "Project venv path (e.g. /home/linuxuser/projects/myproject/.venv)"
$SETUP_LINUX     = "https://raw.githubusercontent.com/rleyvasal/gpu-dev-setup/main/setup-linux.sh"
# ============================================================
# DO NOT EDIT BELOW THIS LINE
# ============================================================

$WINDOWS_USER = $env:USERNAME

# --- Pre-flight checklist ---
Write-Host ""
Write-Host "=== PRE-FLIGHT CHECKLIST ===" -ForegroundColor Yellow
Write-Host "  After this script completes:" -ForegroundColor Yellow
Write-Host "  1. Create your Linux username when Ubuntu prompts you" -ForegroundColor Yellow
Write-Host "  2. In the Ubuntu terminal, install cloudflared and authenticate:" -ForegroundColor Yellow
Write-Host "     wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O /tmp/cloudflared.deb" -ForegroundColor Yellow
Write-Host "     sudo dpkg -i /tmp/cloudflared.deb" -ForegroundColor Yellow
Write-Host "     cloudflared tunnel login" -ForegroundColor Yellow
Write-Host "  3. Then run setup-linux.sh:" -ForegroundColor Yellow
Write-Host "     curl -fsSL https://raw.githubusercontent.com/rleyvasal/gpu-dev-setup/main/setup-linux.sh -o /tmp/setup-linux.sh && bash /tmp/setup-linux.sh" -ForegroundColor Yellow
pause

# --- Step 1: WSL ---
Write-Host "=== Step 1: Install WSL + $WSL_DISTRO ===" -ForegroundColor Cyan
$distroInstalled = wsl --list 2>&1 | Select-String $WSL_DISTRO
if (-not $distroInstalled) {
    wsl --install -d $WSL_DISTRO
    Write-Host "Ubuntu installed. Please reboot, create your Linux user (e.g. linuxuser), then re-run." -ForegroundColor Yellow
    exit
} else {
    Write-Host "$WSL_DISTRO already installed, skipping." -ForegroundColor Green
}

# --- Step 2: OpenSSH ---
Write-Host "=== Step 2: Install and configure OpenSSH ===" -ForegroundColor Cyan
$sshInstalled = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Select-Object -ExpandProperty State
if ($sshInstalled -ne 'Installed') {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
} else {
    Write-Host "OpenSSH already installed, skipping." -ForegroundColor Green
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
$sshdConfig = "C:\ProgramData\ssh\sshd_config"
$sshdContent = Get-Content $sshdConfig -Raw
$sshdContent = $sshdContent -replace '#?PubkeyAuthentication\s+\w+', 'PubkeyAuthentication yes'
$sshdContent = $sshdContent -replace '#?PasswordAuthentication\s+\w+', 'PasswordAuthentication no'
if ($sshdContent -notmatch 'administrators_authorized_keys') {
    $sshdContent += "`r`nMatch Group administrators`r`n       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`r`n"
}
Set-Content $sshdConfig $sshdContent
Restart-Service sshd

# --- Step 3: SSH keys ---
Write-Host "=== Step 3: Adding SSH keys ===" -ForegroundColor Cyan
$adminKeyFile = "C:\ProgramData\ssh\administrators_authorized_keys"
if (-not (Test-Path "C:\ProgramData\ssh")) { mkdir "C:\ProgramData\ssh" }
$existingKeys = if (Test-Path $adminKeyFile) { Get-Content $adminKeyFile } else { @() }
if ($existingKeys -notcontains $SOLVEIT_KEY) { [System.IO.File]::AppendAllText($adminKeyFile, $SOLVEIT_KEY + "`n") }
icacls $adminKeyFile /inheritance:r /grant "SYSTEM:F" /grant "Administrators:F"

# --- Step 4: Firewall + disable sleep ---
Write-Host "=== Step 4: Firewall rules and disabling sleep ===" -ForegroundColor Cyan
$rules = @(
    @{ Name="OpenSSH Inbound";  Port=22;            Remote="Any" },
    @{ Name="WSL SSH Inbound";  Port=$WSL_SSH_PORT; Remote="Any" },
    @{ Name="OpenSSH from WSL"; Port=22;            Remote="172.16.0.0/12" }
)
foreach ($rule in $rules) {
    if (-not (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Protocol TCP `
            -LocalPort $rule.Port -RemoteAddress $rule.Remote -Action Allow
        Write-Host "Added rule: $($rule.Name)" -ForegroundColor Green
    } else {
        Write-Host "Rule exists, skipping: $($rule.Name)" -ForegroundColor Green
    }
}
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /hibernate off
Write-Host "Sleep and hibernate disabled." -ForegroundColor Green

# --- Step 5: WSL auto-start task ---
Write-Host "=== Step 5: WSL startup scheduled task ===" -ForegroundColor Cyan
$action    = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $WSL_DISTRO"
$t1        = New-ScheduledTaskTrigger -AtStartup
$t2        = New-ScheduledTaskTrigger -AtLogOn -User $WINDOWS_USER
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$WINDOWS_USER" -LogonType S4U -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "Start WSL $WSL_DISTRO" -Action $action -Trigger $t1,$t2 `
    -Principal $principal -Settings $settings -Force
Write-Host "WSL auto-start task created." -ForegroundColor Green

# --- Step 6: Run setup-linux.sh inside WSL ---
Write-Host "=== Step 6: Running Linux setup inside WSL ===" -ForegroundColor Cyan
wsl -d $WSL_DISTRO -u $WSL_USER bash -c "export WSL_USER='$WSL_USER'; export SOLVEIT_KEY='$SOLVEIT_KEY'; export CF_DOMAIN='$CF_DOMAIN'; export CF_TUNNEL='$CF_TUNNEL'; export VENV_PATH='$VENV_PATH'; curl -fsSL $SETUP_LINUX | bash"

Write-Host ""
Write-Host "✅ Windows setup complete!" -ForegroundColor Green

