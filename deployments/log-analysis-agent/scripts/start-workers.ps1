<#
.SYNOPSIS
    启动多个 Tornado Worker 进程 (Windows 多进程版)

.DESCRIPTION
    在当前目录下启动 N 个 Python 进程，每个监听不同端口。
    用于配合 Nginx upstream 实现多进程并发。

.PARAMETER PortStart
    起始端口号 (默认 8801)

.PARAMETER WorkerCount
    Worker 进程数 (默认 4)

.PARAMETER AgentTimeout
    Agent 调用超时秒数 (默认 60)

.PARAMETER MaxLogSizeMB
    最大日志大小 MB (默认 50)

.EXAMPLE
    .\start-workers.ps1
    .\start-workers.ps1 -PortStart 9000 -WorkerCount 8 -AgentTimeout 120
#>

param(
    [int]$PortStart = 8801,
    [int]$WorkerCount = 4,
    [int]$AgentTimeout = 60,
    [int]$MaxLogSizeMB = 50,
    [string]$Python = "python",
    [switch]$NoWindow = $true
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $scriptDir "worker-pids.txt"

Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  日志分析 Agent — 多 Worker 启动器            ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── 预检查 ──
Write-Host "[预检查]" -ForegroundColor Yellow
Write-Host "  Python: $Python"
& $Python --version 2>&1 | Write-Host -ForegroundColor Gray
Write-Host "  起始端口: $PortStart"
Write-Host "  Worker 数: $WorkerCount"
Write-Host "  Agent 超时: ${AgentTimeout}s"
Write-Host "  最大日志: ${MaxLogSizeMB}MB"
Write-Host ""

# 检查 app.py 存在
$appPath = Join-Path $scriptDir "app.py"
if (-not (Test-Path $appPath)) {
    Write-Host "[错误] app.py 不存在: $appPath" -ForegroundColor Red
    exit 1
}

# 检查端口占用
Write-Host "[端口检查]" -ForegroundColor Yellow
for ($i = 0; $i -lt $WorkerCount; $i++) {
    $port = $PortStart + $i
    $existing = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  ⚠ 端口 $port 已被占用 (PID: $($existing.OwningProcess))" -ForegroundColor Red
        $answer = Read-Host "  是否终止占用进程? [y/N]"
        if ($answer -eq 'y') {
            Stop-Process -Id $existing.OwningProcess -Force
            Write-Host "  已终止 PID $($existing.OwningProcess)" -ForegroundColor Gray
        } else {
            Write-Host "  跳过端口 $port" -ForegroundColor Yellow
            continue
        }
    } else {
        Write-Host "  端口 $port 空闲" -ForegroundColor Green
    }
}
Write-Host ""

# ── 启动 Workers ──
Write-Host "[启动 Workers]" -ForegroundColor Yellow
$processes = @()

for ($i = 0; $i -lt $WorkerCount; $i++) {
    $port = $PortStart + $i
    $workerName = "worker-$($i+1)"

    Write-Host "  $workerName → 端口 $port ... " -NoNewline

    try {
        $procArgs = @(
            "-u",  # unbuffered stdout
            $appPath,
            "--port", $port,
            "--agent-timeout", $AgentTimeout,
            "--max-log-size-mb", $MaxLogSizeMB
        )

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $Python
        $startInfo.Arguments = $procArgs -join " "
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $NoWindow
        $startInfo.WorkingDirectory = $scriptDir

        $proc = [System.Diagnostics.Process]::Start($startInfo)

        $processes += @{
            Id = $proc.Id
            Port = $port
            Name = $workerName
            Process = $proc
        }

        Write-Host "PID $($proc.Id)" -ForegroundColor Green
        Start-Sleep -Milliseconds 500
    } catch {
        Write-Host "失败: $_" -ForegroundColor Red
    }
}

Write-Host ""

# ── 保存 PID 文件 ──
$pids = $processes | ForEach-Object { "$($_.Id) $($_.Port) $($_.Name)" }
$pids | Out-File -FilePath $pidFile -Encoding UTF8

Write-Host "[完成] 已启动 $($processes.Count) 个 Worker" -ForegroundColor Green
Write-Host ""
Write-Host "  PID 文件: $pidFile" -ForegroundColor Gray
Write-Host "  停止命令: .\stop-workers.ps1" -ForegroundColor Gray
Write-Host "  健康检查: curl http://127.0.0.1:$PortStart/api/health" -ForegroundColor Gray
Write-Host ""

# ── 快速健康检查 ──
Write-Host "[健康检查]" -ForegroundColor Yellow
Start-Sleep -Seconds 2
foreach ($p in $processes) {
    try {
        $url = "http://127.0.0.1:$($p.Port)/api/health"
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 3 -ErrorAction Stop
        Write-Host "  $($p.Name) ($($p.Port)): $($resp.status) ✓" -ForegroundColor Green
    } catch {
        Write-Host "  $($p.Name) ($($p.Port)): 无响应 ✗" -ForegroundColor Red
    }
}
