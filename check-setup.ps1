# check-setup.ps1
# 社給 PC セットアップ状態チェックスクリプト
# 実行方法: PowerShell (Windows Terminal) で
#   Set-ExecutionPolicy -Scope Process Bypass
#   .\check-setup.ps1

$wsl = "$env:SystemRoot\System32\wsl.exe"
$ok  = "[OK] "
$ng  = "[NG] "
$na  = "[--] "

$issues = @()

function Show-Header($title) {
    Write-Host ""
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
}

function Show-Ok($msg) {
    Write-Host "$ok $msg" -ForegroundColor Green
}

function Show-Ng($msg, $hint = "") {
    Write-Host "$ng $msg" -ForegroundColor Red
    if ($hint) { Write-Host "     → $hint" -ForegroundColor Yellow }
    $script:issues += $msg
}

function Show-Na($msg) {
    Write-Host "$na $msg" -ForegroundColor Gray
}

# ======================================================
Show-Header "1. WSL2"
# ======================================================

# WSL2 機能が有効か
$wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -EA SilentlyContinue
if ($wslFeature.State -eq "Enabled") {
    Show-Ok "WSL2 機能が有効"
} else {
    Show-Ng "WSL2 機能が無効" "管理者 PowerShell で: wsl --install"
}

# Ubuntu がインストールされているか
$distros = & $wsl --list --quiet 2>&1
$ubuntuInstalled = $distros | Where-Object { $_ -match "Ubuntu" }
if ($ubuntuInstalled) {
    Show-Ok "Ubuntu がインストール済み ($($ubuntuInstalled -join ', '))"
} else {
    Show-Ng "Ubuntu が未インストール" "wsl --install"
}

# WSL2 バージョン確認
if ($ubuntuInstalled) {
    $versionInfo = & $wsl --list --verbose 2>&1 | Where-Object { $_ -match "Ubuntu" }
    if ($versionInfo -match "\s2\s") {
        Show-Ok "WSL バージョン: 2"
    } else {
        Show-Ng "WSL バージョンが 2 ではない" "wsl --set-version Ubuntu 2"
    }
}

# ======================================================
Show-Header "2. Docker Engine (WSL2 Ubuntu 内)"
# ======================================================

if ($ubuntuInstalled) {
    # docker コマンドが存在するか
    $dockerPath = & $wsl -d Ubuntu -- which docker 2>&1
    if ($dockerPath -match "/docker") {
        Show-Ok "Docker CLI インストール済み ($($dockerPath.Trim()))"
    } else {
        Show-Ng "Docker CLI が未インストール" "curl -fsSL https://get.docker.com | sudo sh"
    }

    # docker デーモンが起動しているか
    $dockerInfo = & $wsl -d Ubuntu -- docker info 2>&1
    if ($dockerInfo -match "Server Version") {
        Show-Ok "Docker デーモン 起動中"
    } else {
        Show-Ng "Docker デーモンが停止中" "sudo service docker start"
    }

    # docker グループにユーザーが入っているか（sudo なしで実行できるか）
    $groups = & $wsl -d Ubuntu -- groups 2>&1
    if ($groups -match "docker") {
        Show-Ok "ユーザーが docker グループに所属"
    } else {
        Show-Ng "ユーザーが docker グループ未所属" "sudo usermod -aG docker `$USER → Ubuntu 再起動"
    }

    # /etc/wsl.conf で Docker 自動起動が設定されているか
    $wslConf = & $wsl -d Ubuntu -- cat /etc/wsl.conf 2>&1
    if ($wslConf -match "service docker start") {
        Show-Ok "/etc/wsl.conf に Docker 自動起動設定あり"
    } else {
        Show-Ng "/etc/wsl.conf に Docker 自動起動設定なし" "README 手順 0-3 を参照"
    }
} else {
    Show-Na "Ubuntu 未インストールのためスキップ"
}

# ======================================================
Show-Header "3. Windows ツール"
# ======================================================

# Windows Git
$gitPath = (Get-Command git -EA SilentlyContinue)?.Source
if ($gitPath -and $gitPath -match "Program Files\\Git") {
    $gitVer = & git --version 2>&1
    Show-Ok "Windows Git インストール済み ($gitVer)"
} else {
    Show-Ng "Windows Git が未インストール（または PATH 未設定）" "https://git-scm.com/download/win"
}

# PowerShell 7 (pwsh)
$pwshPath = (Get-Command pwsh -EA SilentlyContinue)?.Source
if ($pwshPath) {
    $pwshVer = & pwsh --version 2>&1
    Show-Ok "PowerShell 7 インストール済み ($pwshVer)"
} else {
    Show-Ng "PowerShell 7 (pwsh) が未インストール" "winget install Microsoft.PowerShell"
}

# gh CLI
$ghPath = (Get-Command gh -EA SilentlyContinue)?.Source
if ($ghPath) {
    $ghVer = & gh --version 2>&1 | Select-Object -First 1
    Show-Ok "gh CLI インストール済み ($ghVer)"

    # gh 認証状態
    $ghAuth = & gh auth status 2>&1
    if ($ghAuth -match "Logged in") {
        Show-Ok "gh CLI: GitHub 認証済み"
    } else {
        Show-Ng "gh CLI: GitHub 未認証" "gh auth login"
    }
} else {
    Show-Ng "gh CLI が未インストール" "winget install GitHub.cli"
}

# ======================================================
Show-Header "4. プロジェクトフォルダ"
# ======================================================

# OneDrive パス
$oneDrivePath = $env:OneDrive
if ($oneDrivePath -and (Test-Path $oneDrivePath)) {
    Show-Ok "OneDrive パス: $oneDrivePath"
} else {
    Show-Ng "OneDrive が見つからない" "OneDrive の設定を確認してください"
}

# Projects フォルダ
$projBase = if ($oneDrivePath) { "$oneDrivePath\Projects" } else { "C:\Projects" }
if (Test-Path $projBase) {
    Show-Ok "Projects フォルダ: $projBase"
} else {
    Show-Ng "Projects フォルダが未作成: $projBase" "mkdir '$projBase'"
}

# 各リポジトリのクローン状態
$repos = @("wsl2-infra","health-app","health-base","grafana-fiware","plateau-fiware","fiware-base")
foreach ($repo in $repos) {
    $repoPath = "$projBase\$repo"
    if (Test-Path "$repoPath\.git") {
        Show-Ok "クローン済み: $repo"
    } else {
        Show-Ng "未クローン: $repo" "gh repo clone tanakayoshiki1-oss/$repo '$repoPath'"
    }
}

# ======================================================
Show-Header "5. Windows Firewall"
# ======================================================

$fw5101 = Get-NetFirewallRule -EA SilentlyContinue | Where-Object { $_.DisplayName -match "5101" -and $_.Direction -eq "Inbound" }
if ($fw5101) {
    Show-Ok "Firewall: ポート 5101 (Grafana LAN) 許可済み"
} else {
    Show-Ng "Firewall: ポート 5101 未設定" "管理者 PowerShell で README 手順 1 を実行"
}

$fw5200 = Get-NetFirewallRule -EA SilentlyContinue | Where-Object { $_.DisplayName -match "5200" -and $_.Direction -eq "Inbound" }
if ($fw5200) {
    Show-Ok "Firewall: ポート 5200 (Plateau LAN) 許可済み"
} else {
    Show-Ng "Firewall: ポート 5200 未設定" "管理者 PowerShell で README 手順 1 を実行"
}

# ======================================================
Show-Header "6. タスクスケジューラ"
# ======================================================

$task = Get-ScheduledTask -TaskName "WSL2-Docker-startup" -EA SilentlyContinue
if ($task) {
    $state = $task.State
    Show-Ok "タスク 'WSL2-Docker-startup' 登録済み (状態: $state)"

    # スクリプトパスが正しいか確認
    $taskScript = $task.Actions[0].Arguments
    $startupScript = "$projBase\wsl2-infra\startup.ps1"
    if ($taskScript -match [regex]::Escape("startup.ps1")) {
        Show-Ok "タスクのスクリプトパス設定あり"
    } else {
        Show-Ng "タスクのスクリプトパスを確認してください" "タスクスケジューラを開いて確認"
    }
} else {
    Show-Ng "タスク 'WSL2-Docker-startup' 未登録" "README 手順 2 を実行"
}

# ======================================================
Show-Header "結果サマリー"
# ======================================================

if ($issues.Count -eq 0) {
    Write-Host ""
    Write-Host "  すべての項目が OK です！" -ForegroundColor Green
    Write-Host "  startup.ps1 のパスを確認後、PC を再起動してください。" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "  以下の $($issues.Count) 項目が未完了です：" -ForegroundColor Yellow
    $issues | ForEach-Object { Write-Host "  ・$_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "  README の手順に従って順番に対応してください。" -ForegroundColor Yellow
    Write-Host "  完了後、再度このスクリプトを実行して確認できます。" -ForegroundColor Cyan
}

Write-Host ""
