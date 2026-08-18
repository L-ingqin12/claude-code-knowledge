<#
.SYNOPSIS
    健康监控脚本 — Pi Agent 版

.DESCRIPTION
    定期检查所有 Worker 的健康端点，异常时重启服务。
    配合 Windows Task Scheduler 每分钟执行。

    与 opencode 版差异:
      - 检查 Node.js cluster 的多个端口
      - 遇到异常时重启整个 Primary 服务 (NSSM)

.EXAMPLE
    .\health-monitor.ps1
    .\health-monitor.ps1 -NoRestart
#>

param(
    [switch]$NoRestart,
    [string]$LogFile = "",
    [int]$PortStart = 8801,
    [int]$WorkerCount = 4,
    [int]$TimeoutMs = 3000,
    [string]$ServiceName = "LogAgent-Pi",
    [string]$NginxServiceName = "LogAgent-Nginx"
)

$ErrorActionPreference = "SilentlyContinue"
$logLines = @()

function Write-Log($msg, $color = "White") {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    $logLines += $line
    Write-Host $line -ForegroundColor $color
}

function Test-Endpoint($url, $timeoutMs) {
    try {
        $req = [System.Net.WebRequest]::Create($url)
        $req.Timeout = $timeoutMs
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $reader.ReadToEnd()
        $resp.Close()
        $json = $body | ConvertFrom-Json
        return ($json.status -eq "ok")
    } catch {
        return $false
    }
}

Write-Log "=== 健康检查 (Pi) ===" "Cyan"

$allHealthy = $true
$deadPorts = @()

# ── 检查所有 Worker 端口 ──
for ($i = 0; $i -lt $WorkerCount; $i++) {
    $port = $PortStart + $i
    $url = "http://[IP已脱敏]:$port/api/health"

    if (Test-Endpoint $url $TimeoutMs) {
        Write-Log "  :$port OK" "Green"
    } else {
        Write-Log "  :$port 无响应" "Red"
        $allHealthy = $false
        $deadPorts += $port
    }
}

# ── 检查 Nginx ──
if (Test-Endpoint "http://[IP已脱敏]/api/health" $TimeoutMs) {
    Write-Log "  Nginx OK" "Green"
} else {
    Write-Log "  Nginx 无响应" "Red"
    $allHealthy = $false
}

# ── 处理异常 ──
if (-not $allHealthy) {
    if ($deadPorts.Count -gt 0) {
        Write-Log "  异常端口: $($deadPorts -join ', ')" "Red"
    }

    if (-not $NoRestart) {
        Write-Log "  重启服务 $ServiceName..." "Yellow"
        try {
            Restart-Service $ServiceName -Force
            Write-Log "  重启命令已发送" "Yellow"
        } catch {
            Write-Log "  重启失败: $_" "Red"
        }
    }
} else {
    Write-Log "  所有服务正常" "Green"
}

# ── TIME_WAIT 检查 ──
$timeWait = (netstat -ano 2>$null | Select-String "TIME_WAIT" | Measure-Object).Count
if ($timeWait -gt 500) {
    Write-Log "  ⚠ TIME_WAIT 堆积: $timeWait" "Yellow"
}

Write-Log "=== 检查结束 ===" "Cyan"

if ($LogFile) {
    $logLines | Out-File -FilePath $LogFile -Append -Encoding UTF8
}
