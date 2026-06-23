# check-setup.ps1
# WSL2 + Docker setup status checker for company PC
# Usage: Set-ExecutionPolicy -Scope Process Bypass
#        .\check-setup.ps1

$wsl    = "$env:SystemRoot\System32\wsl.exe"
$issues = @()

function Show-Header($title) {
    Write-Host ""
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
}
function Show-Ok($msg)            { Write-Host "[OK] $msg" -ForegroundColor Green }
function Show-Ng($msg, $hint="") {
    Write-Host "[NG] $msg" -ForegroundColor Red
    if ($hint) { Write-Host "     -> $hint" -ForegroundColor Yellow }
    $script:issues += $msg
}
function Show-Na($msg) { Write-Host "[--] $msg" -ForegroundColor Gray }

# ======================================================
Show-Header "1. WSL2"
# ======================================================

# WSL2 enabled check (wsl --list output is UTF-16 LE, avoid string matching)
$wslTest = & $wsl --status 2>&1
if ($LASTEXITCODE -eq 0 -or $wslTest -match "Default") {
    Show-Ok "WSL2 is enabled"
} else {
    Show-Ng "WSL2 is not enabled" "Run as admin: wsl --install"
}

# Ubuntu check: actually run a command inside Ubuntu to verify
$ubuntuEcho = & $wsl -d Ubuntu -- echo "ok" 2>&1
$ubuntuInstalled = ($LASTEXITCODE -eq 0 -and $ubuntuEcho -match "ok")
if ($ubuntuInstalled) {
    Show-Ok "Ubuntu is installed and accessible"
} else {
    Show-Ng "Ubuntu is not installed or not accessible" "wsl --install"
}

if ($ubuntuInstalled) {
    $verOut = & $wsl --list --verbose 2>&1
    # UTF-16 LE output: join and strip null bytes before matching
    $verStr = ($verOut -join " ") -replace "`0",""
    if ($verStr -match "Ubuntu\s+Running\s+2") {
        Show-Ok "WSL version: 2"
    } else {
        Show-Ng "WSL version may not be 2" "wsl --set-version Ubuntu 2"
    }
}

# ======================================================
Show-Header "2. Docker Engine (inside WSL2 Ubuntu)"
# ======================================================

if ($ubuntuInstalled) {
    $dockerPath = & $wsl -d Ubuntu -- which docker 2>&1
    if ($dockerPath -match "/docker") {
        Show-Ok "Docker CLI installed"
    } else {
        Show-Ng "Docker CLI not installed" "curl -fsSL https://get.docker.com | sudo sh"
    }

    $dockerInfo = & $wsl -d Ubuntu -- docker info 2>&1
    if ($dockerInfo -match "Server Version") {
        Show-Ok "Docker daemon is running"
    } else {
        Show-Ng "Docker daemon is stopped" "sudo service docker start"
    }

    $groups = & $wsl -d Ubuntu -- groups 2>&1
    if ($groups -match "docker") {
        Show-Ok "User belongs to docker group"
    } else {
        Show-Ng "User not in docker group" 'sudo usermod -aG docker $USER  (then restart Ubuntu)'
    }

    $wslConf = & $wsl -d Ubuntu -- cat /etc/wsl.conf 2>&1
    if ($wslConf -match "service docker start") {
        Show-Ok "/etc/wsl.conf: Docker auto-start configured"
    } else {
        Show-Ng "/etc/wsl.conf: Docker auto-start not set" "See README step 0-3"
    }
} else {
    Show-Na "Skipped (Ubuntu not installed)"
}

# ======================================================
Show-Header "3. Windows Tools"
# ======================================================

$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if ($gitCmd -and $gitCmd.Source -match "Program Files\\Git") {
    $gitVer = & git --version 2>&1
    Show-Ok "Windows Git installed ($gitVer)"
} else {
    Show-Ng "Windows Git not installed" "https://git-scm.com/download/win"
}

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCmd) {
    $pwshVer = & pwsh --version 2>&1
    Show-Ok "PowerShell 7 installed ($pwshVer)"
} else {
    Show-Ng "PowerShell 7 (pwsh) not installed" "winget install Microsoft.PowerShell"
}

$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
if ($ghCmd) {
    $ghVer = & gh --version 2>&1 | Select-Object -First 1
    Show-Ok "gh CLI installed ($ghVer)"
    $ghAuth = & gh auth status 2>&1
    if ($ghAuth -match "Logged in") {
        Show-Ok "gh CLI: authenticated with GitHub"
    } else {
        Show-Ng "gh CLI: not authenticated" "gh auth login"
    }
} else {
    Show-Ng "gh CLI not installed" "winget install GitHub.cli"
}

# ======================================================
Show-Header "4. Project Folder"
# ======================================================

$oneDrivePath = $env:OneDrive
if ($oneDrivePath -and (Test-Path $oneDrivePath)) {
    Show-Ok "OneDrive path: $oneDrivePath"
} else {
    Show-Ng "OneDrive not found" "Check OneDrive settings"
}

$projBase = if ($oneDrivePath -and (Test-Path $oneDrivePath)) {
    "$oneDrivePath\Projects"
} else {
    "C:\Projects"
}

if (Test-Path $projBase) {
    Show-Ok "Projects folder: $projBase"
} else {
    Show-Ng "Projects folder missing: $projBase" "mkdir '$projBase'"
}

$repos = @("wsl2-infra","health-app","health-base","grafana-fiware","plateau-fiware","fiware-base")
foreach ($repo in $repos) {
    $repoPath = "$projBase\$repo"
    if (Test-Path "$repoPath\.git") {
        Show-Ok "Cloned: $repo"
    } else {
        Show-Ng "Not cloned: $repo" "gh repo clone tanakayoshiki1-oss/$repo '$repoPath'"
    }
}

# ======================================================
Show-Header "5. Windows Firewall"
# ======================================================

$fw5101 = Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match "5101" -and $_.Direction -eq "Inbound" }
if ($fw5101) {
    Show-Ok "Firewall: port 5101 (Grafana LAN) allowed"
} else {
    Show-Ng "Firewall: port 5101 not set" "Run README step 1 as admin"
}

$fw5200 = Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match "5200" -and $_.Direction -eq "Inbound" }
if ($fw5200) {
    Show-Ok "Firewall: port 5200 (Plateau LAN) allowed"
} else {
    Show-Ng "Firewall: port 5200 not set" "Run README step 1 as admin"
}

# ======================================================
Show-Header "6. Task Scheduler"
# ======================================================

$task = Get-ScheduledTask -TaskName "WSL2-Docker-startup" -ErrorAction SilentlyContinue
if ($task) {
    Show-Ok "Task 'WSL2-Docker-startup' registered (State: $($task.State))"
    if ($task.Actions[0].Arguments -match "startup.ps1") {
        Show-Ok "Task script path is set"
    } else {
        Show-Ng "Check task script path" "Open Task Scheduler to verify"
    }
} else {
    Show-Ng "Task 'WSL2-Docker-startup' not registered" "Run README step 2"
}

# ======================================================
Show-Header "Summary"
# ======================================================

if ($issues.Count -eq 0) {
    Write-Host ""
    Write-Host "  All checks passed!" -ForegroundColor Green
    Write-Host "  Verify startup.ps1 paths, then restart the PC." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "  $($issues.Count) item(s) need attention:" -ForegroundColor Yellow
    $issues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "  Follow the README steps and re-run this script when done." -ForegroundColor Cyan
}

Write-Host ""