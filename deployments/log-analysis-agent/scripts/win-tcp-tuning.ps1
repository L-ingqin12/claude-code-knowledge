<#
.SYNOPSIS
    Windows TCP/IP 参数调优 — 提升高并发连接处理能力

.DESCRIPTION
    调整 Windows 注册表和 netsh 参数:
      - 扩大临时端口范围 (10000-65535)
      - 缩短 TIME_WAIT (120s → 30s)
      - 启用端口复用和 TCP 窗口缩放
      - 启用 RSS / Chimney Offload

.REQUIREMENTS
    管理员权限

.EXAMPLE
    # 以管理员身份运行
    powershell -ExecutionPolicy Bypass -File win-tcp-tuning.ps1

    # 调优后查看结果
    powershell -ExecutionPolicy Bypass -File win-tcp-tuning.ps1 -ShowOnly

.NOTES
    大部分参数需要重启才能生效。
    建议先在非生产环境测试，确认网络稳定性。
#>

param(
    [switch]$ShowOnly,      # 仅显示当前值，不修改
    [switch]$Force           # 跳过确认提示
)

$ErrorActionPreference = "Stop"

Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Windows TCP/IP 高并发调优                      ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── 管理员检查 ──
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin) {
    Write-Host "[错误] 需要管理员权限。请以管理员身份运行 PowerShell。" -ForegroundColor Red
    exit 1
}

# ── 当前状态 ──
function Show-CurrentState {
    Write-Host "═══ 当前 TCP/IP 状态 ═══" -ForegroundColor Yellow
    Write-Host ""

    Write-Host "[netsh int tcp show global]"
    netsh int tcp show global
    Write-Host ""

    Write-Host "[动态端口范围]"
    netsh int ipv4 show dynamicport tcp
    Write-Host ""

    Write-Host "[注册表参数]"
    $params = @(
        "TcpTimedWaitDelay",
        "MaxUserPort",
        "Tcp1323Opts",
        "KeepAliveTime",
        "KeepAliveInterval"
    )
    $tcpPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
    foreach ($p in $params) {
        try {
            $val = Get-ItemProperty -Path $tcpPath -Name $p -ErrorAction Stop
            Write-Host "  $p = $($val.$p) (type: $($val.$p.GetType().Name))"
        } catch {
            Write-Host "  $p = (未设置，使用默认值)" -ForegroundColor Gray
        }
    }
    Write-Host ""

    # 当前连接统计
    Write-Host "[当前连接统计]"
    $timeWait = (netstat -ano | Select-String "TIME_WAIT" | Measure-Object).Count
    $established = (netstat -ano | Select-String "ESTABLISHED" | Measure-Object).Count
    Write-Host "  ESTABLISHED: $established"
    Write-Host "  TIME_WAIT:   $timeWait"
    Write-Host ""
}

Show-CurrentState

if ($ShowOnly) {
    exit 0
}

# ── 确认 ──
if (-not $Force) {
    Write-Host "⚠ 即将修改以下系统参数 (需重启生效):" -ForegroundColor Yellow
    Write-Host "  1. 动态端口 → 10000-65535 (55535 个端口)"
    Write-Host "  2. TcpTimedWaitDelay → 30s (默认 120s)"
    Write-Host "  3. MaxUserPort → 65534"
    Write-Host "  4. Tcp1323Opts → 3 (窗口缩放 + 时间戳)"
    Write-Host "  5. KeepAliveTime → 300000ms (5分钟)"
    Write-Host "  6. 启用 RSS / Chimney / NetDMA"
    Write-Host ""
    $confirm = Read-Host "继续? [y/N]"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "已取消。" -ForegroundColor Red
        exit 0
    }
}

# ── 调优操作 ──
Write-Host ""
Write-Host "═══ 应用调优 ═══" -ForegroundColor Yellow
Write-Host ""

$tcpPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"

# [1] 扩大临时端口范围
Write-Host "[1/6] 扩大临时端口范围..."
try {
    netsh int ipv4 set dynamicport tcp start=10000 num=55535
    Write-Host "  ✓ TCP 动态端口: 10000-65535 (55535 个)" -ForegroundColor Green
} catch {
    Write-Host "  ✗ 失败: $_" -ForegroundColor Red
}

# [2] 缩短 TIME_WAIT
Write-Host "[2/6] 缩短 TIME_WAIT..."
try {
    Set-ItemProperty -Path $tcpPath -Name "TcpTimedWaitDelay" -Value 30 -Type DWord -Force
    Write-Host "  ✓ TcpTimedWaitDelay: 120s → 30s" -ForegroundColor Green
} catch {
    Write-Host "  ✗ 失败: $_" -ForegroundColor Red
}

# [3] 最大用户端口
Write-Host "[3/6] 设置 MaxUserPort..."
try {
    Set-ItemProperty -Path $tcpPath -Name "MaxUserPort" -Value 65534 -Type DWord -Force
    Write-Host "  ✓ MaxUserPort: 65534" -ForegroundColor Green
} catch {
    Write-Host "  ✗ 失败: $_" -ForegroundColor Red
}

# [4] TCP 窗口缩放 + 时间戳
Write-Host "[4/6] 启用 TCP 窗口缩放..."
try {
    # 1 = 窗口缩放, 2 = 时间戳, 3 = 两者皆启用
    Set-ItemProperty -Path $tcpPath -Name "Tcp1323Opts" -Value 3 -Type DWord -Force
    Write-Host "  ✓ Tcp1323Opts: 3 (窗口缩放 + 时间戳)" -ForegroundColor Green
} catch {
    Write-Host "  ✗ 失败: $_" -ForegroundColor Red
}

# [5] TCP KeepAlive (减少死连接堆积)
Write-Host "[5/6] 配置 TCP KeepAlive..."
try {
    # 首次探测前空闲时间 (ms) — 默认 2 小时，改为 5 分钟
    Set-ItemProperty -Path $tcpPath -Name "KeepAliveTime" -Value 300000 -Type DWord -Force
    # 探测间隔 (ms) — 默认 1 秒
    Set-ItemProperty -Path $tcpPath -Name "KeepAliveInterval" -Value 1000 -Type DWord -Force
    Write-Host "  ✓ KeepAliveTime: 2h → 5min, KeepAliveInterval: 1s" -ForegroundColor Green
} catch {
    Write-Host "  ✗ 失败: $_" -ForegroundColor Red
}

# [6] RSS / Chimney / NetDMA
Write-Host "[6/6] 启用网卡硬件卸载..."
try {
    netsh int tcp set global rss=enabled
    netsh int tcp set global chimney=enabled
    netsh int tcp set global netdma=enabled
    Write-Host "  ✓ RSS / Chimney / NetDMA 已启用" -ForegroundColor Green
    Write-Host "  ⚠ 如果网卡驱动不稳定，可用以下命令关闭:" -ForegroundColor Yellow
    Write-Host "    netsh int tcp set global chimney=disabled"
} catch {
    Write-Host "  ⚠ 部分参数可能不支持 (非服务器版 Windows)" -ForegroundColor Yellow
}

# ── 完成 ──
Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  调优完成!                                     ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "⚠ 需要重启系统使更改生效。" -ForegroundColor Yellow
Write-Host ""
Write-Host "重启后验证:" -ForegroundColor Gray
Write-Host "  netsh int tcp show global"
Write-Host "  netsh int ipv4 show dynamicport tcp"
Write-Host "  Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' ^| Select-Object TcpTimedWaitDelay,MaxUserPort"
Write-Host ""

# 可选回滚命令
Write-Host "── 回滚命令 (如需恢复默认) ──" -ForegroundColor Gray
Write-Host @'

# 恢复默认端口范围
netsh int ipv4 set dynamicport tcp start=49152 num=16384

# 恢复注册表默认值
Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "TcpTimedWaitDelay" -Force
Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "MaxUserPort" -Force

# 关闭硬件卸载 (如不稳定)
netsh int tcp set global chimney=disabled
netsh int tcp set global rss=disabled
'@
