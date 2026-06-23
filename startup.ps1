# startup.ps1
# WSL2 + Docker 共通起動スクリプト
#
# 管理プロジェクト:
#   health-base    Keycloak + HAPI FHIR
#   health-app     nginx + API + DB
#   grafana-fiware Grafana
#   plateau-fiware Plateau 3D
#   fiware-base    Orion + Draco + MongoDB + PostgreSQL
#
# ネットワーク構成 (WSL2 NAT モード):
#   Windows localhost : wslrelay.exe が 127.0.0.1:PORT → WSL2 へ転送
#   Mac LAN           : lan-relay.ps1 が 192.168.3.6:PORT → 127.0.0.1:PORT へ転送
#
# LAN リレー一覧:
#   192.168.3.6:4003 → 127.0.0.1:443  health-app (HTTPS)
#   192.168.3.6:5101 → 127.0.0.1:4101 Grafana
#   192.168.3.6:5200 → 127.0.0.1:4200 Plateau
#
# 重要: portproxy / Add-Type / 0.0.0.0 バインドは wslrelay を kill する
#       LAN リレーは 192.168.3.6 固有バインド + Runspace 方式を使用

$wsl      = "$env:SystemRoot\System32\wsl.exe"
$logFile  = "$env:TEMP\wsl2_startup.log"
$selfDir  = $PSScriptRoot

function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    Add-Content -Path $logFile -Value $line
    Write-Host $line
}

function Test-TcpPort($h, $p) {
    $t = [System.Net.Sockets.TcpClient]::new()
    try { $t.Connect($h, $p); $true } catch { $false } finally { $t.Dispose() }
}

function Start-LanRelay($lanPort, $targetPort, $name) {
    $relay = "$selfDir\lan-relay.ps1"
    $pwsh  = "C:\Users\tanak\AppData\Local\Microsoft\WindowsApps\pwsh.exe"
    Start-Process $pwsh `
        -ArgumentList "-ExecutionPolicy Bypass -File `"$relay`" -LanIP 192.168.3.6 -LanPort $lanPort -TargetIP 127.0.0.1 -TargetPort $targetPort" `
        -WindowStyle Hidden
    Start-Sleep -Seconds 3
    $ok = [bool](Get-NetTCPConnection -LocalAddress "192.168.3.6" -LocalPort $lanPort -State Listen -EA SilentlyContinue)
    Log "LAN relay 192.168.3.6:${lanPort} (${name}): $(if ($ok) {'started'} else {'FAILED'})"
}

Log "=== wsl2-infra startup ==="

# ── 1. WSL2 Ubuntu 起動 + keepalive ──────────────────────────────────
Log "WSL2 Ubuntu starting..."
& $wsl -d Ubuntu -- echo "wake" | Out-Null
Start-Process $wsl -ArgumentList "-d Ubuntu -- tail -f /dev/null" -WindowStyle Hidden

# ── 2. Docker daemon 起動待機（最大90秒）────────────────────────────
Log "Waiting for Docker daemon..."
$elapsed = 0
do {
    Start-Sleep -Seconds 5; $elapsed += 5
    $status = & $wsl -d Ubuntu -- docker info 2>&1
} while (($status -join "") -match "Cannot connect|command not found" -and $elapsed -lt 90)

if ($elapsed -ge 90) { Log "ERROR: Docker daemon did not start"; exit 1 }
Log "Docker daemon ready (${elapsed}s)"

# ── 3. 全プロジェクト起動（restart:unless-stopped で自動再起動済みの場合は冪等）──
$projects = @(
    "/mnt/c/Projects/health-base",
    "/mnt/c/Projects/health-app",
    "/mnt/c/Projects/grafana-fiware",
    "/mnt/c/Projects/plateau-fiware",
    "/mnt/c/Projects/fiware-base"
)
foreach ($p in $projects) {
    $name = Split-Path $p -Leaf
    Log "docker compose up -d: $name"
    & $wsl -d Ubuntu -- bash -c "cd $p && docker compose up -d" 2>&1 |
        ForEach-Object { if ($_ -match "error|Error") { Log "  [$name] $_" } }
}

# ── 4. health-app 固有: Keycloak 起動待機（最大120秒）───────────────
Log "Waiting for Keycloak (max 120s)..."
$elapsed = 0
do {
    Start-Sleep -Seconds 5; $elapsed += 5
    $code = & $wsl -d Ubuntu -- docker exec phr-viewer curl -s -o /dev/null -w "%{http_code}" http://keycloak:8180/realms/health-app/ --max-time 4 2>&1
} while ($code -ne "200" -and $elapsed -lt 120)
Log "Keycloak: $(if ($code -eq '200') {"ready (${elapsed}s)"} else {"timeout (${elapsed}s)"})"

# ── 5. health-app 固有: HAPI FHIR 起動待機（最大180秒）─────────────
Log "Waiting for HAPI FHIR (max 180s)..."
$elapsed = 0
do {
    Start-Sleep -Seconds 5; $elapsed += 5
    $code = & $wsl -d Ubuntu -- docker exec phr-viewer curl -s -o /dev/null -w "%{http_code}" http://hapi-fhir:8080/fhir/metadata --max-time 4 2>&1
} while ($code -ne "200" -and $elapsed -lt 180)
Log "HAPI FHIR: $(if ($code -eq '200') {"ready (${elapsed}s)"} else {"timeout (${elapsed}s)"})"

# ── 6. wslrelay リスナー確認（なければ phr-viewer 再起動でトリガー）──
Log "Checking wslrelay listener on 127.0.0.1:443..."
$elapsed = 0
while ($elapsed -lt 15) {
    if (Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort 443 -State Listen -EA SilentlyContinue) { break }
    Start-Sleep -Seconds 3; $elapsed += 3
}
if (-not (Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort 443 -State Listen -EA SilentlyContinue)) {
    Log "wslrelay not detected, triggering via phr-viewer restart..."
    & $wsl -d Ubuntu -- docker restart phr-viewer | Out-Null
    Start-Sleep -Seconds 8
}
$has443 = [bool](Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort 443 -State Listen -EA SilentlyContinue)
Log "wslrelay 127.0.0.1:443: $(if ($has443) {'OK'} else {'WARNING: not found'})"

# ── 7. wslrelay 監視ジョブ（443 が消えたら phr-viewer 再起動）───────
$monitorJob = Start-Job -Name "wslrelay-monitor" -ArgumentList $wsl -ScriptBlock {
    param($wslExe)
    while ($true) {
        Start-Sleep -Seconds 30
        if (-not (Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort 443 -State Listen -EA SilentlyContinue)) {
            & $wslExe -d Ubuntu -- docker restart phr-viewer 2>&1 | Out-Null
            Start-Sleep -Seconds 8
        }
    }
}
Log "wslrelay monitor job: $(if ($monitorJob) {'started'} else {'FAILED'})"

# ── 8. LAN リレー起動 ─────────────────────────────────────────────────
# ポート選定の原則:
#   LAN ポートは docker-compose に含まれないポートを使用する
#   docker-compose ポートに 192.168.3.6 バインドすると wslrelay がリスナーを削除する
#
#   4003: docker-compose 未登録 → 127.0.0.1:443  health-app HTTPS
#   5101: docker-compose 未登録 → 127.0.0.1:4101 Grafana (4101 は登録済み)
#   5200: docker-compose 未登録 → 127.0.0.1:4200 Plateau (4200 は登録済み)
Log "Starting LAN relays..."
Start-LanRelay 4003 443  "health-app HTTPS"
Start-LanRelay 5101 4101 "Grafana"
Start-LanRelay 5200 4200 "Plateau"

# ── 9. 疎通確認 ────────────────────────────────────────────────────────
Log "Connectivity check:"
Log "  127.0.0.1:443  (wslrelay)        -> $(Test-TcpPort '127.0.0.1'   443)"
Log "  192.168.3.6:4003 (health-app)    -> $(Test-TcpPort '192.168.3.6' 4003)"
Log "  192.168.3.6:5101 (Grafana)       -> $(Test-TcpPort '192.168.3.6' 5101)"
Log "  192.168.3.6:5200 (Plateau)       -> $(Test-TcpPort '192.168.3.6' 5200)"

Log "=== startup complete ==="
Log "Dashboard : https://127.0.0.1/status.html"
Log "Dashboard : https://192.168.3.6:4003/status.html  (Mac)"

# ── バックグラウンドジョブを維持するため継続実行 ─────────────────────
while ($true) { Start-Sleep -Seconds 300 }
