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
        Pause; exit 1
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
    $output = wsl --list --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    if (-not $output) { return @() }

    return $output |
        ForEach-Object { $_.Trim() } |
        ForEach-Object { $_.Trim([char]0) } |
        Where-Object { $_ -ne '' -and $_ -notmatch '^docker-desktop' }
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

# Load saved config if it exists
if (Test-Path $LOCAL_CLIENT_CONFIG_FILE) {
    $saved = Get-Content $LOCAL_CLIENT_CONFIG_FILE | ConvertFrom-Json
    $WSL_DISTRO       = $saved.wsl_distro
    $SSH_PORT         = $saved.ssh_port
    $SSH_PUBLIC_KEY   = $saved.ssh_public_key
    $CF_DOMAIN        = $saved.cf_domain
    $CF_TUNNEL        = $saved.cf_tunnel
    $VENV_NAME        = $saved.venv_name
    $KERNEL_CLIENT_NAME = $saved.kernel_client_name
}

# Only prompt for values we don't already have
if (-not $WSL_DISTRO) {
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
}

if (-not $SSH_PORT) { $SSH_PORT = Read-HostDefault "Linux SSH port" "2222" }
if (-not $SSH_PUBLIC_KEY) { $SSH_PUBLIC_KEY = Read-Host "SSH public key" }
if (-not $CF_DOMAIN) { $CF_DOMAIN = Read-Host "Cloudflare domain (e.g. mydomain.com)" }
if (-not $CF_TUNNEL) { $CF_TUNNEL = Read-Host "Tunnel name (e.g. gpu-dev)" }
if (-not $VENV_NAME) { $VENV_NAME = Read-HostDefault "Project name" "myproject" }
$SETUP_LINUX = "https://raw.githubusercontent.com/rleyvasal/gpu-dev-setup/main/setup-linux.sh"

$KERNEL_CLIENT_NAME = Get-SafeName "$COMPUTER_NAME-$WINDOWS_USER"

# Save inputs early so reruns don't re-prompt
if (-not (Test-Path $LOCAL_CLIENT_CONFIG_DIR)) {
    New-Item -ItemType Directory -Path $LOCAL_CLIENT_CONFIG_DIR -Force | Out-Null
}
@{
    wsl_distro         = $WSL_DISTRO
    ssh_port           = [int]$SSH_PORT
    ssh_public_key     = $SSH_PUBLIC_KEY
    cf_domain          = $CF_DOMAIN
    cf_tunnel          = $CF_TUNNEL
    venv_name          = $VENV_NAME
    kernel_client_name = $KERNEL_CLIENT_NAME
    windows_user       = $WINDOWS_USER
} | ConvertTo-Json | Set-Content $LOCAL_CLIENT_CONFIG_FILE

Write-Host ""
Write-Host "=== PRE-FLIGHT CHECKLIST ===" -ForegroundColor Yellow
Write-Host "  1. This script assumes you are setting up Linux inside WSL." -ForegroundColor Yellow
Write-Host "  2. If the distro is not initialized yet, you may need to launch it once and create your Linux user first." -ForegroundColor Yellow
Write-Host "  3. Linux setup will read config.json from inside WSL." -ForegroundColor Yellow
Write-Host "  4. A local client config will also be written for Python/SSH clients." -ForegroundColor Yellow
pause

Run-Step "Step 1: Install WSL + distro" {
    $distroInstalled = $false
    $output = wsl --list --quiet 2>$null
    if ($LASTEXITCODE -eq 0 -and $output) {
        $cleaned = $output | ForEach-Object { $_.Trim() } | ForEach-Object { $_.Trim([char]0) } | Where-Object { $_ -ne '' }
        $distroInstalled = $cleaned -contains $WSL_DISTRO
    }

    if (-not $distroInstalled) {
        # Ensure required Windows features are enabled
        $features = @("VirtualMachinePlatform", "Microsoft-Windows-Subsystem-Linux")
        foreach ($feat in $features) {
            try {
                $state = (Get-WindowsOptionalFeature -Online -FeatureName $feat).State
                if ($state -ne "Enabled") {
                    Write-Host "Enabling $feat..." -ForegroundColor Yellow
                    Enable-WindowsOptionalFeature -Online -FeatureName $feat -All -NoRestart | Out-Null
                }
            } catch {
                Write-Host "Could not check $feat via PowerShell, will let wsl --install handle it." -ForegroundColor Yellow
            }
        }

        wsl --install -d $WSL_DISTRO
    } else {
        Write-Host "$WSL_DISTRO already installed, skipping." -ForegroundColor Green
    }
}

$WSL_USER = Get-DetectedLinuxUser -Distro $WSL_DISTRO
if (-not $WSL_USER) {
    Write-Host ""
    Write-Host "Could not detect a non-root Linux user in $WSL_DISTRO." -ForegroundColor Yellow
    Write-Host "Launch the distro once, create your Linux user, then rerun this script." -ForegroundColor Yellow
    Pause; exit 1
}

# Construct paths now that we know the Linux user
$KERNEL_WORK_DIR = "/home/$WSL_USER/gpu-dev-projects/$VENV_NAME"
$VENV_PATH = "$KERNEL_WORK_DIR/.venv"

$CF_HOSTNAME_LINUX = "$($WSL_USER.ToLower()).$CF_DOMAIN"
$CF_HOSTNAME_WIN = "$KERNEL_CLIENT_NAME.$CF_DOMAIN"

Run-Step "Step 2: Install and configure OpenSSH" {
    $sshState = "Unknown"
    try {
        $sshState = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Select-Object -ExpandProperty State
    } catch {
        Write-Host "Could not check OpenSSH via DISM, attempting install anyway..." -ForegroundColor Yellow
    }

    if ($sshState -ne 'Installed') {
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
    $linuxConfigObject = @{
        linux_user         = $WSL_USER
        ssh_port           = [int]$SSH_PORT
        ssh_public_key     = $SSH_PUBLIC_KEY
        cf_domain          = $CF_DOMAIN
        cf_tunnel          = $CF_TUNNEL
        cf_hostname_linux  = $CF_HOSTNAME_LINUX
        cf_hostname_win    = $CF_HOSTNAME_WIN
        venv_name          = $VENV_NAME
        venv_path          = $VENV_PATH
        kernel_client_name = $KERNEL_CLIENT_NAME
        kernel_work_dir    = $KERNEL_WORK_DIR
        windows_user       = $WINDOWS_USER
        wsl_distro         = $WSL_DISTRO
    }

    $linuxConfigJson = $linuxConfigObject | ConvertTo-Json -Compress
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($linuxConfigJson)
    $base64Json = [Convert]::ToBase64String($jsonBytes)

    $linuxConfigDir = "/home/$WSL_USER/.config/gpu-dev"
    $linuxConfigFile = "$linuxConfigDir/config.json"

    wsl -d $WSL_DISTRO -u root -- bash -lc "mkdir -p '$linuxConfigDir'; echo '$base64Json' | base64 -d > '$linuxConfigFile'; chown -R '$WSL_USER':'$WSL_USER' '/home/$WSL_USER/.config'; chmod 700 '$linuxConfigDir'; chmod 600 '$linuxConfigFile'"
}

Run-Step "Step 7: Write local client config" {
    $existing = @{}
    if (Test-Path $LOCAL_CLIENT_CONFIG_FILE) {
        $content = Get-Content $LOCAL_CLIENT_CONFIG_FILE -Raw
        if ($content) {
            $parsed = $content | ConvertFrom-Json
            foreach ($prop in $parsed.PSObject.Properties) {
                $existing[$prop.Name] = $prop.Value
            }
        }
    }

    $existing["linux_user"]         = $WSL_USER
    $existing["windows_user"]       = $WINDOWS_USER
    $existing["ssh_port"]           = [int]$SSH_PORT
    $existing["cf_domain"]          = $CF_DOMAIN
    $existing["cf_tunnel"]          = $CF_TUNNEL
    $existing["cf_hostname_linux"]  = $CF_HOSTNAME_LINUX
    $existing["cf_hostname_win"]    = $CF_HOSTNAME_WIN
    $existing["venv_name"]          = $VENV_NAME
    $existing["venv_path"]          = $VENV_PATH
    $existing["kernel_client_name"] = $KERNEL_CLIENT_NAME
    $existing["kernel_work_dir"]    = $KERNEL_WORK_DIR
    $existing["ssh_key_path"]       = (Join-Path $WINDOWS_HOME ".ssh\id_ed25519")
    $existing["source_platform"]    = "windows-wsl"

    if (-not (Test-Path $LOCAL_CLIENT_CONFIG_DIR)) {
        New-Item -ItemType Directory -Path $LOCAL_CLIENT_CONFIG_DIR -Force | Out-Null
    }

    $existing | ConvertTo-Json -Depth 4 | Set-Content $LOCAL_CLIENT_CONFIG_FILE
    Write-Host "Local client config written to $LOCAL_CLIENT_CONFIG_FILE" -ForegroundColor Green
}
Run-Step "Step 8: Run Linux setup" {
    wsl -d $WSL_DISTRO -u $WSL_USER -- bash -lc @"
curl -fsSL '$SETUP_LINUX' -o /tmp/setup-linux.sh
NON_INTERACTIVE=true bash /tmp/setup-linux.sh
"@
}

# Check if tunnel was created by looking for it in cloudflared tunnel list
$tunnelCheck = wsl -d $WSL_DISTRO -u $WSL_USER -- bash -lc "cloudflared tunnel list 2>/dev/null | grep -q '$CF_TUNNEL' && echo 'TUNNEL_OK' || echo 'TUNNEL_MISSING'"

if ($tunnelCheck -notlike "*TUNNEL_OK*") {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  ACTION REQUIRED" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "In WSL, run: cloudflared tunnel login" -ForegroundColor Red
    Write-Host ""
    Write-Host "Tip: If the browser link only logs you in but doesn't" -ForegroundColor Yellow
    Write-Host "prompt for authentication, paste the same link again while logged in" -ForegroundColor Yellow
    Write-Host "to complete the tunnel authorization." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Then rerun this script to complete setup." -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "Setup complete!" -ForegroundColor Green
    Write-Host "Tunnel '$CF_TUNNEL' is configured and running." -ForegroundColor Green
    Write-Host ""
    Write-Host "To connect to your remote kernel, run:" -ForegroundColor Cyan
    Write-Host "  python -m remote_client" -ForegroundColor White
}

