<#
.SYNOPSIS
    将日志分析 Agent 安装为 Windows 服务 (通过 NSSM)

.DESCRIPTION
    使用 NSSM (Non-Sucking Service Manager) 将 Nginx 和多个
    Tornado Worker 注册为 Windows 服务，实现:
      - 开机自启
      - 崩溃自动重启
      - 标准服务管理 (services.msc / sc)

.PREREQUISITES
    - NSSM 已安装 (choco install nssm 或手动下载)
    - Nginx 位于 C:\nginx
    - app.py 和脚本位于脚本目录

.PARAMETER Install
    安装所有服务

.PARAMETER Uninstall
    卸载所有服务

.PARAMETER Start
    启动所有服务

.PARAMETER Stop
    停止所有服务

.PARAMETER Status
    显示所有服务状态

.EXAMPLE
    .\install-services.ps1 -Install
    .\install-services.ps1 -Start
    .\install-services.ps1 -Status
    .\install-services.ps1 -Stop
    .\install-services.ps1 -Uninstall
#>

param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Start,
    [switch]$Stop,
    [switch]$Status,
    [string]$NginxPath = "C:\nginx",
    [string]$AppDir = "",
    [string]$NssmPath = "nssm",  # 如果在 PATH 中直接用 "nssm"
    [int]$PortStart = 8801,
    [int]$WorkerCount = 4,
    [int]$AgentTimeout = 60
)

$ErrorActionPreference = "Stop"

if (-not $AppDir) {
    $AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$servicePrefix = "LogAgent"

# ── 服务名列表 ──
$services = @(
    @{Name="$servicePrefix-Tornado-$($PortStart+0)"; Display="日志分析Agent - Tornado Worker 1"; Exe="python"; Args="app.py --port $($PortStart+0) --agent-timeout $AgentTimeout"; Dir=$AppDir},
    @{Name="$servicePrefix-Tornado-$($PortStart+1)"; Display="日志分析Agent - Tornado Worker 2"; Exe="python"; Args="app.py --port $($PortStart+1) --agent-timeout $AgentTimeout"; Dir=$AppDir},
    @{Name="$servicePrefix-Tornado-$($PortStart+2)"; Display="日志分析Agent - Tornado Worker 3"; Exe="python"; Args="app.py --port $($PortStart+2) --agent-timeout $AgentTimeout"; Dir=$AppDir},
    @{Name="$servicePrefix-Tornado-$($PortStart+3)"; Display="日志分析Agent - Tornado Worker 4"; Exe="python"; Args="app.py --port $($PortStart+3) --agent-timeout $AgentTimeout"; Dir=$AppDir}
)

$nginxService = @{
    Name = "$servicePrefix-Nginx"
    Display = "日志分析Agent - Nginx 反向代理"
    Exe = Join-Path $NginxPath "nginx.exe"
    Args = "-p `"$NginxPath`""
    Dir = $NginxPath
}

# ── NSSM 检查 ──
function Test-NssmAvailable {
    try {
        $null = & $NssmPath version 2>&1
        return $true
    } catch {
        return $false
    }
}

# ── 安装单个服务 ──
function Install-OneService($svc) {
    $name = $svc.Name
    Write-Host "  安装服务: $name ... " -NoNewline

    # 如果已存在，先删除
    $existing = Get-Service $name -ErrorAction SilentlyContinue
    if ($existing) {
        & $NssmPath stop $name 2>$null
        & $NssmPath remove $name confirm 2>$null
    }

    & $NssmPath install $name $svc.Exe $svc.Args
    & $NssmPath set $name AppDirectory $svc.Dir
    & $NssmPath set $name DisplayName $svc.Display
    & $NssmPath set $name Start SERVICE_AUTO_START
    & $NssmPath set $name AppExit Default Restart
    & $NssmPath set $name AppRestartDelay 5000

    Write-Host "✓" -ForegroundColor Green
}

# ── 卸载单个服务 ──
function Uninstall-OneService($svc) {
    $name = $svc.Name
    Write-Host "  卸载服务: $name ... " -NoNewline
    try {
        & $NssmPath stop $name 2>$null
        Start-Sleep -Seconds 1
        & $NssmPath remove $name confirm 2>$null
        Write-Host "✓" -ForegroundColor Green
    } catch {
        Write-Host "跳过 ($_)" -ForegroundColor Gray
    }
}

# ── 主逻辑 ──
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  日志分析 Agent — Windows 服务管理              ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# 检查管理员权限
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin) {
    Write-Host "[错误] 服务管理需要管理员权限" -ForegroundColor Red
    exit 1
}

if (-not (Test-NssmAvailable)) {
    Write-Host "[错误] NSSM 不可用。请安装: choco install nssm" -ForegroundColor Red
    Write-Host "  或下载: https://nssm.cc/download" -ForegroundColor Red
    exit 1
}

Write-Host "NSSM 版本: $(& $NssmPath version)" -ForegroundColor Gray
Write-Host "Nginx 路径: $NginxPath" -ForegroundColor Gray
Write-Host "App 目录:   $AppDir" -ForegroundColor Gray
Write-Host ""

# ── Install ──
if ($Install) {
    Write-Host "[安装服务]" -ForegroundColor Yellow

    Install-OneService $nginxService
    foreach ($svc in $services[0..($WorkerCount-1)]) {
        Install-OneService $svc
    }

    Write-Host ""
    Write-Host "安装完成! 启动服务: .\install-services.ps1 -Start" -ForegroundColor Green
}

# ── Uninstall ──
if ($Uninstall) {
    Write-Host "[卸载服务]" -ForegroundColor Yellow

    Uninstall-OneService $nginxService
    foreach ($svc in $services[0..($WorkerCount-1)]) {
        Uninstall-OneService $svc
    }

    Write-Host ""
    Write-Host "卸载完成!" -ForegroundColor Green
}

# ── Start ──
if ($Start) {
    Write-Host "[启动服务]" -ForegroundColor Yellow

    # 先启动 Tornado workers，再启动 Nginx
    foreach ($svc in $services[0..($WorkerCount-1)]) {
        Write-Host "  启动: $($svc.Name) ... " -NoNewline
        Start-Service $svc.Name
        Write-Host "✓" -ForegroundColor Green
        Start-Sleep -Milliseconds 500
    }

    Write-Host "  启动: $($nginxService.Name) ... " -NoNewline
    Start-Service $nginxService.Name
    Write-Host "✓" -ForegroundColor Green

    Write-Host ""
    Write-Host "所有服务已启动!" -ForegroundColor Green
}

# ── Stop ──
if ($Stop) {
    Write-Host "[停止服务]" -ForegroundColor Yellow

    # 先停 Nginx，再停 Tornado
    Write-Host "  停止: $($nginxService.Name) ... " -NoNewline
    Stop-Service $nginxService.Name -Force -ErrorAction SilentlyContinue
    Write-Host "✓" -ForegroundColor Green

    foreach ($svc in $services[0..($WorkerCount-1)]) {
        Write-Host "  停止: $($svc.Name) ... " -NoNewline
        Stop-Service $svc.Name -Force -ErrorAction SilentlyContinue
        Write-Host "✓" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "所有服务已停止!" -ForegroundColor Green
}

# ── Status ──
if ($Status) {
    Write-Host "[服务状态]" -ForegroundColor Yellow
    Write-Host ""

    $allServices = @($nginxService) + $services[0..($WorkerCount-1)]
    foreach ($svc in $allServices) {
        try {
            $s = Get-Service $svc.Name -ErrorAction Stop
            $color = if ($s.Status -eq "Running") { "Green" } else { "Red" }
            Write-Host "  $($svc.Name)" -NoNewline
            Write-Host "  [$($s.Status)]" -ForegroundColor $color
        } catch {
            Write-Host "  $($svc.Name)  [未安装]" -ForegroundColor Gray
        }
    }
}

# ── 如果没有任何操作参数，显示帮助 ──
if (-not ($Install -or $Uninstall -or $Start -or $Stop -or $Status)) {
    Write-Host "用法:" -ForegroundColor Yellow
    Write-Host "  .\install-services.ps1 -Install    安装所有服务"
    Write-Host "  .\install-services.ps1 -Start      启动所有服务"
    Write-Host "  .\install-services.ps1 -Stop       停止所有服务"
    Write-Host "  .\install-services.ps1 -Status     查看服务状态"
    Write-Host "  .\install-services.ps1 -Uninstall  卸载所有服务"
}
