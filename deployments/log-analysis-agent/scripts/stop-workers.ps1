<#
.SYNOPSIS
    停止所有 Tornado Worker 进程

.DESCRIPTION
    读取 worker-pids.txt 或扫描端口，优雅关闭所有 worker 进程。
    先发送 CloseMainWindow (等效 SIGTERM)，2 秒后强制 Kill。

.PARAMETER PidFile
    PID 文件路径 (默认当前目录 worker-pids.txt)

.PARAMETER PortStart
    如果没有 PID 文件，从该端口开始扫描

.PARAMETER WorkerCount
    扫描的端口数量

.EXAMPLE
    .\stop-workers.ps1
    .\stop-workers.ps1 -PortStart 9000 -WorkerCount 8
#>

param(
    [string]$PidFile = $null,
    [int]$PortStart = 8801,
    [int]$WorkerCount = 4
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $PidFile) {
    $PidFile = Join-Path $scriptDir "worker-pids.txt"
}

Write-Host "[停止 Workers]" -ForegroundColor Yellow

$stopped = 0

# ── 方法1: 通过 PID 文件 ──
if (Test-Path $PidFile) {
    Write-Host "  从 PID 文件读取: $PidFile"
    $pids = Get-Content $PidFile

    foreach ($line in $pids) {
        if (-not $line.Trim()) { continue }

        $parts = $line -split '\s+'
        $pid = [int]$parts[0]
        $port = if ($parts.Count -gt 1) { $parts[1] } else { "?" }
        $name = if ($parts.Count -gt 2) { $parts[2] } else { "worker" }

        if ($pid -le 0) { continue }

        try {
            $proc = Get-Process -Id $pid -ErrorAction Stop
            Write-Host "  $name (PID $pid, 端口 $port) → 发送关闭信号..."
            $proc.CloseMainWindow()
            Start-Sleep -Seconds 2
            if (-not $proc.HasExited) {
                Write-Host "    未响应，强制终止..." -ForegroundColor Red
                $proc.Kill()
            }
            Write-Host "    已停止 ✓" -ForegroundColor Green
            $stopped++
        } catch {
            Write-Host "  $name (PID $pid): 进程已不存在" -ForegroundColor Gray
        }
    }

    Remove-Item $PidFile -ErrorAction SilentlyContinue
    Write-Host "  已删除 PID 文件" -ForegroundColor Gray

} else {
    # ── 方法2: 通过端口扫描 ──
    Write-Host "  PID 文件不存在，通过端口扫描查找..."

    for ($i = 0; $i -lt $WorkerCount; $i++) {
        $port = $PortStart + $i
        $conn = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue

        if ($conn) {
            $procPid = $conn.OwningProcess
            try {
                $proc = Get-Process -Id $procPid -ErrorAction Stop
                Write-Host "  端口 $port → PID $procPid ($($proc.ProcessName)) → 终止"
                Stop-Process -Id $procPid -Force
                Write-Host "    已停止 ✓" -ForegroundColor Green
                $stopped++
            } catch {
                Write-Host "  端口 $port → PID $procPid: 已不存在" -ForegroundColor Gray
            }
        }
    }
}

Write-Host ""
Write-Host "[完成] 已停止 $stopped 个进程" -ForegroundColor Green
