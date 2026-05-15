function Run-Step {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Cyan

    try {
        & $Action
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "Step failed with exit code $LASTEXITCODE"
        }
        Write-Host "$Name completed." -ForegroundColor Green
    } catch {
        Write-Host "$Name failed: $($_.Exception.Message)" -ForegroundColor Red
        Pause; return
   }
}

function Get-SafeName {
    param([string]$Value)

    $safe = $Value.ToLower()
    $safe = $safe -replace '[^a-z0-9._-]+', '-'
    $safe = $safe.Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = "client" }
    return $safe
}

function Read-HostDefault {
    param(
        [string]$Prompt,
        [string]$Default
    )

    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

function Get-WSLDistros {
    $lines = wsl --list --quiet 2>$null
    if (-not $lines) { return @() }

    return $lines |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch '^docker-desktop' }
}

function Get-DetectedLinuxUser {
    param([string]$Distro)

    try {
        $user = wsl -d $Distro -- bash -lc "whoami" 2>$null
        if (-not $user) { return $null }

        $user = $user.Trim()
        if ([string]::IsNullOrWhiteSpace($user)) { return $null }
        if ($user -eq "root") { return $null }

        return $user
    } catch {
        return $null
    }
}

Write-Host "=== Setup Configuration ===" -ForegroundColor Cyan

$WINDOWS_USER = $env:USERNAME
$COMPUTER_NAME = $env:COMPUTERNAME
$WINDOWS_HOME = $env:USERPROFILE
$LOCAL_CLIENT_CONFIG_DIR = Join-Path $WINDOWS_HOME ".config\gpu-dev"
$LOCAL_CLIENT_CONFIG_FILE = Join-Path $LOCAL_CLIENT_CONFIG_DIR "client-config.json"

$distros = Get-WSLDistros
if ($distros.Count -eq 1) {
    $WSL_DISTRO = $distros[0]
    Write-Host "Detected WSL distro: $WSL_DISTRO" -ForegroundColor Green
} elseif ($distros.Count -gt 1) {
    Write-Host "Detected WSL distros: $($distros -join ', ')" -ForegroundColor Yellow
    $WSL_DISTRO = Read-HostDefault "WSL distro" $distros[0]
} else {
    $WSL_DISTRO = Read-HostDefault "WSL distro" "Ubuntu"
}

$SSH_PORT = Read-HostDefault "Linux SSH port" "2222"
$SSH_PUBLIC_KEY = Read-Host "SSH public key"
$CF_DOMAIN = Read-Host "Cloudflare domain (e.g. mydomain.com)"
$CF_TUNNEL = Read-Host "Tunnel name (e.g. gpu-dev)"
$VENV_PATH = Read-Host "Project venv path (e.g. /home/linuxuser/projects/myproject/.venv)"
$SETUP_LINUX = "https://raw.githubusercontent.com/rleyvasal/gpu-dev-setup/main/setup-linux.sh"

$KERNEL_CLIENT_NAME = Get-SafeName "$COMPUTER_NAME-$WINDOWS_USER"

Write-Host ""
Write-Host "=== PRE-FLIGHT CHECKLIST ===" -ForegroundColor Yellow
Write-Host "  1. This script assumes you are setting up Linux inside WSL." -ForegroundColor Yellow
Write-Host "  2. If the distro is not initialized yet, you may need to launch it once and create your Linux user first." -ForegroundColor Yellow
Write-Host "  3. Linux setup will read config.json from inside WSL." -ForegroundColor Yellow
Write-Host "  4. A local client config will also be written for Python/SSH clients." -ForegroundColor Yellow
pause

Run-Step "Step 1: Install WSL + distro" {
    $distroInstalled = wsl --list 2>&1 | Select-String -SimpleMatch $WSL_DISTRO

    if (-not $distroInstalled) {
        wsl --install -d $WSL_DISTRO
        Write-Host "WSL distro installed. Reboot if prompted, launch the distro, create your Linux user, then rerun." -ForegroundColor Yellow
      Pause; return    
} else {
        Write-Host "$WSL_DISTRO already installed, skipping." -ForegroundColor Green
    }
}

$WSL_USER = Get-DetectedLinuxUser -Distro $WSL_DISTRO
if (-not $WSL_USER) {
    Write-Host ""
    Write-Host "Could not detect a non-root Linux user in $WSL_DISTRO." -ForegroundColor Yellow
    Write-Host "Launch the distro once, create your Linux user, then rerun this script." -ForegroundColor Yellow
    Pause; return
}

$CF_HOSTNAME_LINUX = "$($WSL_USER.ToLower()).$CF_DOMAIN"
$CF_HOSTNAME_WIN = "$KERNEL_CLIENT_NAME.$CF_DOMAIN"

Run-Step "Step 2: Install and configure OpenSSH" {
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
}

Run-Step "Step 3: Add SSH key" {
    $adminKeyFile = "C:\ProgramData\ssh\administrators_authorized_keys"
    if (-not (Test-Path "C:\ProgramData\ssh")) {
        New-Item -ItemType Directory -Path "C:\ProgramData\ssh" | Out-Null
    }

    $existingKeys = if (Test-Path $adminKeyFile) { Get-Content $adminKeyFile } else { @() }
    if ($existingKeys -notcontains $SSH_PUBLIC_KEY) {
        [System.IO.File]::AppendAllText($adminKeyFile, $SSH_PUBLIC_KEY + "`n")
    }

    icacls $adminKeyFile /inheritance:r /grant "SYSTEM:F" /grant "Administrators:F" | Out-Null
}

Run-Step "Step 4: Firewall rules" {
    $rules = @(
        @{ Name="OpenSSH Inbound"; Port=22; Remote="Any" },
        @{ Name="Linux SSH Inbound $SSH_PORT"; Port=$SSH_PORT; Remote="Any" },
        @{ Name="OpenSSH from WSL"; Port=22; Remote="172.16.0.0/12" }
    )

    foreach ($rule in $rules) {
        if (-not (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Protocol TCP `
                -LocalPort $rule.Port -RemoteAddress $rule.Remote -Action Allow | Out-Null
            Write-Host "Added rule: $($rule.Name)" -ForegroundColor Green
        } else {
            Write-Host "Rule exists, skipping: $($rule.Name)" -ForegroundColor Green
        }
    }
}

Run-Step "Step 5: WSL startup scheduled task" {
    $action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $WSL_DISTRO"
    $t1 = New-ScheduledTaskTrigger -AtStartup
    $t2 = New-ScheduledTaskTrigger -AtLogOn -User $WINDOWS_USER
    $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$WINDOWS_USER" -LogonType S4U -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName "Start WSL $WSL_DISTRO" -Action $action -Trigger $t1,$t2 `
        -Principal $principal -Settings $settings -Force | Out-Null
}

Run-Step "Step 6: Write Linux config.json" {
    $linuxConfigObject = [ordered]@{
        linux_user         = $WSL_USER
        ssh_port           = [int]$SSH_PORT
        ssh_public_key     = $SSH_PUBLIC_KEY
        cf_domain          = $CF_DOMAIN
        cf_tunnel          = $CF_TUNNEL
        cf_hostname_linux  = $CF_HOSTNAME_LINUX
        cf_hostname_win    = $CF_HOSTNAME_WIN
        venv_path          = $VENV_PATH
        kernel_client_name = $KERNEL_CLIENT_NAME
        kernel_work_dir    = "/home/$WSL_USER/gpu_dev_projects"
        windows_user       = $WINDOWS_USER
        wsl_distro         = $WSL_DISTRO
    }

    $linuxConfigJson = $linuxConfigObject | ConvertTo-Json -Depth 4
    $linuxConfigDir = "/home/$WSL_USER/.config/gpu-dev"
    $linuxConfigFile = "$linuxConfigDir/config.json"

    wsl -d $WSL_DISTRO -u root -- bash -lc @"
set -e
mkdir -p '$linuxConfigDir'
cat > '$linuxConfigFile' <<'EOF'
$linuxConfigJson
EOF
chown -R '$WSL_USER':'$WSL_USER' '/home/$WSL_USER/.config'
chmod 700 '$linuxConfigDir'
chmod 600 '$linuxConfigFile'
"@
}

Run-Step "Step 7: Write local client config" {
    $clientConfigObject = [ordered]@{
        linux_user         = $WSL_USER
        windows_user       = $WINDOWS_USER
        ssh_port           = [int]$SSH_PORT
        cf_domain          = $CF_DOMAIN
        cf_tunnel          = $CF_TUNNEL
        cf_hostname_linux  = $CF_HOSTNAME_LINUX
        cf_hostname_win    = $CF_HOSTNAME_WIN
        venv_path          = $VENV_PATH
        kernel_client_name = $KERNEL_CLIENT_NAME
        kernel_work_dir    = "/home/$WSL_USER/gpu_dev_projects"
        ssh_key_path       = (Join-Path $WINDOWS_HOME ".ssh\id_ed25519")
        source_platform    = "windows-wsl"
    }

    if (-not (Test-Path $LOCAL_CLIENT_CONFIG_DIR)) {
        New-Item -ItemType Directory -Path $LOCAL_CLIENT_CONFIG_DIR -Force | Out-Null
    }

    $clientConfigObject | ConvertTo-Json -Depth 4 | Set-Content $LOCAL_CLIENT_CONFIG_FILE
    Write-Host "Local client config written to $LOCAL_CLIENT_CONFIG_FILE" -ForegroundColor Green
}

Run-Step "Step 8: Run Linux setup" {
    wsl -d $WSL_DISTRO -u $WSL_USER -- bash -lc @"
curl -fsSL '$SETUP_LINUX' -o /tmp/setup-linux.sh
bash /tmp/setup-linux.sh
"@
}

Write-Host ""
Write-Host "Windows setup complete!" -ForegroundColor Green

