<#
.SYNOPSIS
    健康监控脚本 — 定期探测所有 Worker 并在异常时自动重启

.DESCRIPTION
    检查 Nginx 和所有 Tornado Worker 的健康端点。
    对不响应的服务执行重启操作。
    配合 Windows 任务计划程序 (Task Scheduler) 每分钟执行一次。

.SCHEDULED_TASK_SETUP
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -File C:\log-agent\scripts\health-monitor.ps1"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName "LogAgent Health Monitor" `
        -Action $action -Trigger $trigger -RunLevel Highest

.PARAMETER NoRestart
    仅检查不重启 (干跑模式)

.PARAMETER LogFile
    监控日志文件路径

.EXAMPLE
    .\health-monitor.ps1
    .\health-monitor.ps1 -NoRestart -LogFile C:\logs\health-monitor.log
#>

param(
    [switch]$NoRestart,
    [string]$LogFile = "",
    [int]$PortStart = 8801,
    [int]$WorkerCount = 4,
    [int]$TimeoutMs = 3000,
    [int]$MaxRetries = 3
)

$ErrorActionPreference = "SilentlyContinue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── 日志函数 ──
$logLines = @()
function Write-Log($message, $color = "White") {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $message"
    $logLines += $line

    if ($color -eq "Red") {
        Write-Host $line -ForegroundColor Red
    } elseif ($color -eq "Yellow") {
        Write-Host $line -ForegroundColor Yellow
    } elseif ($color -eq "Green") {
        Write-Host $line -ForegroundColor Green
    } else {
        Write-Host $line
    }
}

# ── 健康检查函数 ──
function Test-Endpoint($url, $timeoutMs) {
    $retries = 0
    while ($retries -lt $MaxRetries) {
        try {
            $req = [System.Net.WebRequest]::Create($url)
            $req.Timeout = $timeoutMs
            $resp = $req.GetResponse()
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $body = $reader.ReadToEnd()
            $resp.Close()

            # 验证 JSON 响应
            $json = $body | ConvertFrom-Json
            if ($json.status -eq "ok") {
                return $true
            }
        } catch {
            # 重试
        }
        $retries++
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# ── 主检查循环 ──
Write-Log "=== 健康检查开始 ===" "Cyan"

$issues = @()

# ── 检查 Tornado Workers ──
for ($i = 0; $i -lt $WorkerCount; $i++) {
    $port = $PortStart + $i
    $url = "http://127.0.0.1:$port/api/health"
    $svcName = "LogAgent-Tornado-$port"

    if (Test-Endpoint $url $TimeoutMs) {
        Write-Log "  [$svcName] OK" "Green"
    } else {
        Write-Log "  [$svcName] 无响应 (端口 $port)" "Red"
        $issues += @{
            Type = "Tornado"
            ServiceName = $svcName
            Port = $port
            Url = $url
        }
    }
}

# ── 检查 Nginx ──
$nginxUrl = "http://127.0.0.1/api/health"
if (Test-Endpoint $nginxUrl $TimeoutMs) {
    Write-Log "  [LogAgent-Nginx] OK" "Green"
} else {
    Write-Log "  [LogAgent-Nginx] 无响应 (通过 Nginx 无法访问后端)" "Red"
    $issues += @{
        Type = "Nginx"
        ServiceName = "LogAgent-Nginx"
        Port = 80
        Url = $nginxUrl
    }
}

# ── 处理异常 ──
if ($issues.Count -gt 0) {
    Write-Log "发现 $($issues.Count) 个异常:" "Red"

    foreach ($issue in $issues) {
        Write-Log "  - $($issue.ServiceName) (端口 $($issue.Port))" "Red"

        if (-not $NoRestart) {
            try {
                Write-Log "    重启服务 $($issue.ServiceName)..."
                Restart-Service $issue.ServiceName -Force
                Write-Log "    重启命令已发送" "Yellow"
            } catch {
                Write-Log "    重启失败: $_" "Red"
            }
        } else {
            Write-Log "    (干跑模式，未重启)" "Yellow"
        }
    }
} else {
    Write-Log "所有服务正常" "Green"
}

# ── 连接统计 ──
$timeWait = (netstat -ano 2>$null | Select-String "TIME_WAIT" | Measure-Object).Count
if ($timeWait -gt 500) {
    Write-Log "⚠ TIME_WAIT 堆积: $timeWait 个连接" "Yellow"
}

Write-Log "=== 健康检查结束 ===" "Cyan"

# ── 写入日志文件 ──
if ($LogFile) {
    $logLines | Out-File -FilePath $LogFile -Append -Encoding UTF8
}
