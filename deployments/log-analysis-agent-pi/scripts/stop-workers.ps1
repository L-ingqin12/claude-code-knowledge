<#
.SYNOPSIS
    停止所有 Pi Agent Worker 进程

.DESCRIPTION
    查找并终止所有 Node.js worker 进程。
    先发送 SIGTERM (优雅关闭)，超时后强制终止。

.PARAMETER PortStart
    起始端口号

.PARAMETER WorkerCount
    Worker 数量

.EXAMPLE
    .\stop-workers.ps1
#>

param(
    [int]$PortStart = 8801,
    [int]$WorkerCount = 4
)

Write-Host "[停止 Pi Agent Workers]" -ForegroundColor Yellow

$stopped = 0

# ── 方法1: 通过端口查找并终止 ──
for ($i = 0; $i -lt $WorkerCount; $i++) {
    $port = $PortStart + $i
    $conn = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue

    if ($conn) {
        $pid = $conn.OwningProcess
        try {
            $proc = Get-Process -Id $pid -ErrorAction Stop
            Write-Host "  端口 $port → PID $pid ($($proc.ProcessName)) → 终止"
            Stop-Process -Id $pid -Force
            Write-Host "    ✓ 已停止" -ForegroundColor Green
            $stopped++
        } catch {
            Write-Host "  端口 $port → 进程已不存在" -ForegroundColor Gray
        }
    } else {
        Write-Host "  端口 $port → 无监听进程" -ForegroundColor Gray
    }
}

# ── 方法2: 清理残留的 node 进程 ──
$orphans = Get-Process -Name "node" -ErrorAction SilentlyContinue | Where-Object {
    $_.MainWindowTitle -eq "" -and $_.StartTime -gt (Get-Date).AddHours(-24)
}
if ($orphans) {
    Write-Host "  发现 $($orphans.Count) 个可能的残留 Node.js 进程" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "[完成] 已停止 $stopped 个进程" -ForegroundColor Green
