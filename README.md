# wsl2-infra — WSL2 + Docker 共通インフラ

Windows 11 (WSL2 + Ubuntu + Docker Engine) 上で動く複数のプロジェクトを
一元管理するための共通インフラスクリプト集。

## 要件

| 要件 | 内容 |
|------|------|
| Windows localhost アクセス | `https://127.0.0.1/` 等で各サービスにアクセスできること |
| Mac LAN アクセス | `http://192.168.3.6:PORT/` で Mac Safari から各サービスにアクセスできること |
| PC 起動時自動起動 | ログオン後 30 秒以内に全サービスが起動すること |
| WSL2 自動停止防止 | WSL2 が自動シャットダウンして Docker が落ちないこと |
| wslrelay 監視 | wslrelay リスナーが消えた場合に自動復旧すること |

## ネットワーク設計

```
[Windows Chrome / PowerShell]
        │
        │ 127.0.0.1:PORT
        ▼
[wslrelay.exe]  ←── iptables DNAT ルールを検知して自動生成
        │
        │ NAT
        ▼
[WSL2 Ubuntu] → [Docker コンテナ]


[Mac Safari]
        │
        │ 192.168.3.6:LAN_PORT
        ▼
[lan-relay.ps1]  ← 192.168.3.6 固有バインド (wslrelay に影響しない)
        │
        │ TCP relay → 127.0.0.1:PORT
        ▼
[wslrelay.exe] → [WSL2] → [Docker コンテナ]
```

### wslrelay の制約（重要）

| 禁止操作 | 理由 |
|----------|------|
| `netsh interface portproxy` | wslrelay プロセスを kill する |
| `0.0.0.0:PORT` バインド | wslrelay リスナーと競合して kill |
| `Add-Type` (Start-Job 内含む) | csc.exe/Roslyn が `0.0.0.0:PORT` を一時バインドして kill |
| docker-compose 登録ポートに `192.168.3.6:PORT` バインド | wslrelay がそのポートのリスナーを削除 |
| pwsh.exe 引数に `-WindowStyle Hidden` | 子プロセス (lan-relay.ps1) が即終了 |

### LAN リレー ポート設計

LAN リレーのポートは **docker-compose に登録していないポート** を使用する。

| LAN ポート | ターゲット | サービス | 理由 |
|-----------|-----------|---------|------|
| 192.168.3.6:**4003** | 127.0.0.1:443 | health-app (HTTPS) | 4003 は docker-compose 未登録 |
| 192.168.3.6:**5101** | 127.0.0.1:4101 | Grafana | 4101 は登録済みのため 5101 を使用 |
| 192.168.3.6:**5200** | 127.0.0.1:4200 | Plateau | 4200 は登録済みのため 5200 を使用 |

## ディレクトリ構成

```
wsl2-infra/
  startup.ps1       メイン起動スクリプト（タスクスケジューラから実行）
  lan-relay.ps1     汎用 TCP リレー
  README.md         本ドキュメント
```

## 事前準備（初回セットアップ）

> **重要: すべての手順は VSCode ではなく Windows Terminal（またはスタートメニューの PowerShell）から実行すること。**
> VSCode の統合ターミナルから実行すると認証・対話プロンプトで止まる場合がある。

### 0-1. WSL2 と Ubuntu のインストール

**管理者 PowerShell** を開いて実行する。

```powershell
# WSL2 + Ubuntu を一括インストール（再起動が必要）
wsl --install
```

再起動後、Ubuntu が自動起動してユーザー名・パスワードを設定する。
設定後、Ubuntu ターミナルを閉じて次のステップへ。

```powershell
# インストール確認
wsl --list --verbose
# NAME      STATE   VERSION
# Ubuntu    Running 2       ← VERSION が 2 であること
```

### 0-2. Docker Engine のインストール（WSL2 Ubuntu 内）

**Ubuntu ターミナル**（Windows Terminal → Ubuntu タブ）で実行する。

```bash
# Docker 公式インストールスクリプト
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# 現在のユーザーを docker グループに追加（sudo なしで docker を使えるようにする）
sudo usermod -aG docker $USER

# Docker サービスを起動
sudo service docker start

# グループ変更を反映するため Ubuntu を再起動
exit
```

```powershell
# PowerShell で Ubuntu を再起動
wsl --terminate Ubuntu
wsl -d Ubuntu
```

```bash
# Docker 動作確認（Ubuntu ターミナル）
docker run --rm hello-world
# Hello from Docker! と表示されれば OK
```

### 0-3. Docker の自動起動設定（WSL2 Ubuntu 内）

WSL2 は systemd が無効なため、Docker サービスを `/etc/wsl.conf` で自動起動させる。

```bash
# Ubuntu ターミナルで実行
sudo tee /etc/wsl.conf << 'EOF'
[boot]
command = service docker start
EOF
```

```powershell
# WSL2 を再起動して確認
wsl --terminate Ubuntu
wsl -d Ubuntu -- docker info 2>&1 | head -5
# Server: ... と表示されれば OK
```

### 0-4. Windows Git のインストール

[https://git-scm.com/download/win](https://git-scm.com/download/win) からダウンロードしてインストール。
インストール時のオプションはデフォルトで OK。

```powershell
# PowerShell で確認
git --version
# git version 2.x.x.windows.x
```

### 0-5. PowerShell 7 (pwsh) のインストール

```powershell
# Microsoft Store からインストール（またはコマンドで）
winget install Microsoft.PowerShell
```

インストール後、スタートメニューに「PowerShell 7」が追加される。

### 0-6. gh CLI のインストール

```powershell
winget install GitHub.cli
```

```powershell
# 認証（ブラウザが開くので GitHub アカウントでログイン）
gh auth login
# → GitHub.com → HTTPS → Login with web browser を選択
```

### 0-7. リポジトリのクローン

```powershell
# C:\Projects フォルダを作成してクローン
mkdir C:\Projects
cd C:\Projects
gh repo clone tanakayoshiki1-oss/wsl2-infra
gh repo clone tanakayoshiki1-oss/health-app
gh repo clone tanakayoshiki1-oss/health-base
gh repo clone tanakayoshiki1-oss/grafana-fiware
gh repo clone tanakayoshiki1-oss/plateau-fiware
gh repo clone tanakayoshiki1-oss/fiware-base
```

### 0-8. startup.ps1 のユーザー名を修正

`C:\Projects\wsl2-infra\startup.ps1` の pwsh パスにユーザー名が含まれているため修正する。

```powershell
# 現在の pwsh パスを確認
(Get-Command pwsh).Source
# 例: C:\Users\<username>\AppData\Local\Microsoft\WindowsApps\pwsh.exe
```

[startup.ps1](startup.ps1) の以下の行を実際のユーザー名に合わせて修正する。

```powershell
# 修正前（個人 PC のユーザー名）
$pwsh  = "C:\Users\tanak\AppData\Local\Microsoft\WindowsApps\pwsh.exe"

# 修正後（社給 PC のユーザー名に変更）
$pwsh  = "C:\Users\<username>\AppData\Local\Microsoft\WindowsApps\pwsh.exe"
```

---

## セットアップ手順

### 1. Windows Firewall 規則の追加（管理者 PowerShell）

```powershell
# health-app LAN アクセス用（4003 は wslrelay が既存規則で許可済みの場合が多い）
New-NetFirewallRule -DisplayName "WSL2 LAN relay Grafana 5101" -Direction Inbound -Protocol TCP -LocalPort 5101 -Action Allow -Profile Any
New-NetFirewallRule -DisplayName "WSL2 LAN relay Plateau 5200" -Direction Inbound -Protocol TCP -LocalPort 5200 -Action Allow -Profile Any
```

### 2. タスクスケジューラへの登録

```powershell
$pwsh   = "C:\Users\<USERNAME>\AppData\Local\Microsoft\WindowsApps\pwsh.exe"
$script = "C:\Projects\wsl2-infra\startup.ps1"

$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$trigger.Delay = "PT30S"
$action   = New-ScheduledTaskAction -Execute $pwsh `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$script`""
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Days 3650) `
    -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName "WSL2-Docker-startup" `
    -Trigger $trigger -Action $action -Settings $settings -RunLevel Limited -Force
```

### 3. Mac に SSL 証明書をインストール

health-app の自己署名 CA を Mac の Keychain にインストール（Safari での HTTPS アクセスに必要）。

```bash
# Mac 側
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain rootCA.pem
```

## 管理プロジェクト

`startup.ps1` が `docker compose up -d` を実行するプロジェクト一覧。
各コンテナに `restart: unless-stopped` が設定されているため、
Docker 再起動時は自動で復旧するが、初回や明示的な停止後のために明示起動する。

| プロジェクト | パス | 主なサービス |
|-------------|------|------------|
| health-base | /mnt/c/Projects/health-base | Keycloak, HAPI FHIR |
| health-app | /mnt/c/Projects/health-app | nginx, Flask API, PostgreSQL |
| grafana-fiware | /mnt/c/Projects/grafana-fiware | Grafana |
| plateau-fiware | /mnt/c/Projects/plateau-fiware | Plateau フロント, API |
| fiware-base | /mnt/c/Projects/fiware-base | Orion, Draco(NiFi), MongoDB, PostgreSQL |

## アクセス URL 一覧

| サービス | Windows | Mac (Safari) |
|---------|---------|-------------|
| 開発ダッシュボード | https://127.0.0.1/status.html | https://192.168.3.6:4003/status.html |
| 健康BOX | https://127.0.0.1/ | https://192.168.3.6:4003/ |
| Keycloak 管理 | https://127.0.0.1:8443/ | — |
| Grafana | http://127.0.0.1:4101/ | http://192.168.3.6:5101/ |
| Plateau | http://127.0.0.1:4200/ | http://192.168.3.6:5200/ |
| FIWARE Orion | http://127.0.0.1:4226/v2/entities | — |
| FIWARE Draco | http://127.0.0.1:4250/ / :4290/ | — |

## ログ

- 起動ログ: `%TEMP%\wsl2_startup.log`
- LAN リレーログ: `%TEMP%\lan-relay.log`

## トラブルシューティング

| 症状 | 原因 | 対処 |
|------|------|------|
| `ERR_CONNECTION_REFUSED` (Windows) | wslrelay リスナーが消えた | `docker restart phr-viewer` で iptables DNAT 変更をトリガー |
| `ERR_ADDRESS_UNREACHABLE` (Mac Chrome) | Chrome Private Network Access ポリシー | Safari を使用 |
| LAN リレーが起動しない | `-WindowStyle Hidden` を pwsh.exe 引数に渡した | `Start-Process` の `-WindowStyle Hidden` パラメータとして渡す（引数ではなく） |
| タスクスケジューラ 0x80070002 | pwsh.exe のフルパス未指定 | `$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe` を使用 |
| Docker 頻繁再起動 | WSL2 keepalive なし | `wsl.exe -d Ubuntu -- tail -f /dev/null` を起動時に実行 |
