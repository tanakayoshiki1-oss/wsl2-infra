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
