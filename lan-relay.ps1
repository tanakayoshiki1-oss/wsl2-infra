# lan-relay.ps1
# TCP relay: 192.168.3.6:4003 -> 127.0.0.1:443 (via wslrelay)
#
# Port 4003 is NOT in docker-compose, so wslrelay does not monitor it.
# Binding 192.168.3.6:4003 is safe -- wslrelay's 127.0.0.1:443 stays alive.
#
# No Add-Type: avoids launching csc.exe/Roslyn which would bind 0.0.0.0 and kill wslrelay.
# Uses runspaces instead of compiled C#.
#
# nginx extracts port from Host header ($fwd_port):
#   Mac sends:  Host: 192.168.3.6:4003
#   nginx sets: X-Forwarded-Port: 4003
#   Keycloak generates redirect URIs with port 4003
#
# Usage:
#   pwsh        -ExecutionPolicy Bypass -File lan-relay.ps1
#   powershell  -ExecutionPolicy Bypass -File lan-relay.ps1

param(
    [string]$LanIP      = "192.168.3.6",
    [int]   $LanPort    = 4003,
    [string]$TargetIP   = "127.0.0.1",
    [int]   $TargetPort = 443,
    [string]$LogFile    = "$env:TEMP\lan-relay.log"
)

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    Write-Host $line
}

Write-Log "=== LAN relay start: ${LanIP}:${LanPort} -> ${TargetIP}:${TargetPort} ==="

$listener = $null
try {
    $listener = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Parse($LanIP), $LanPort)
    $listener.Start()
    Write-Log "[OK] Listening ${LanIP}:${LanPort} -> ${TargetIP}:${TargetPort}"
} catch {
    Write-Log "[ERROR] Bind failed: $_"
    exit 1
}

Write-Log "Running. Press Ctrl+C to stop."

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()

        $targetIP_   = $TargetIP
        $targetPort_ = $TargetPort

        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('client',     $client)
        $rs.SessionStateProxy.SetVariable('targetIP',   $targetIP_)
        $rs.SessionStateProxy.SetVariable('targetPort', $targetPort_)

        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            $backend = $null
            try {
                $backend = [System.Net.Sockets.TcpClient]::new($targetIP, $targetPort)
                $cs = $client.GetStream()
                $bs = $backend.GetStream()
                [System.Threading.Tasks.Task]::WaitAny($cs.CopyToAsync($bs), $bs.CopyToAsync($cs))
            } catch {}
            finally {
                try { $client.Close()                    } catch {}
                try { if ($backend) { $backend.Close() } } catch {}
                try { $ps.Dispose()                      } catch {}
                try { $rs.Dispose()                      } catch {}
            }
        })
        [void]$ps.BeginInvoke()
    }
} finally {
    try { $listener.Stop() } catch {}
    Write-Log "=== LAN relay stopped ==="
}
