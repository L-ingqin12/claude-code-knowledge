<#
.SYNOPSIS
    将 Pi Agent 日志分析服务安装为 Windows 服务 (通过 NSSM)

.DESCRIPTION
    Pi Agent 版与 opencode 版的主要差异:
      - 启动命令是 node + cluster-server.js (而非 python app.py)
      - 使用 Node.js cluster 内置多进程 (只注册一个 Primary 服务即可)
      - Primary 崩溃后 NSSM 自动重启 → cluster 重新 fork workers

.PARAMETER Install
    安装服务

.PARAMETER Uninstall
    卸载服务

.PARAMETER Start
    启动服务

.PARAMETER Stop
    停止服务

.PARAMETER Status
    查看服务状态

.EXAMPLE
    .\install-services.ps1 -Install
    .\install-services.ps1 -Start
    .\install-services.ps1 -Status
#>

param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Start,
    [switch]$Stop,
    [switch]$Status,
    [string]$NginxPath = "C:\nginx",
    [string]$AppDir = "",
    [string]$NssmPath = "nssm",
    [int]$PortStart = 8801,
    [int]$WorkerCount = 4,
    [string]$NodeExe = "node"
)

$ErrorActionPreference = "Stop"

if (-not $AppDir) {
    $AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $AppDir = Join-Path $AppDir ".."
    $AppDir = (Resolve-Path $AppDir).Path
}

# ── 服务定义 ──
$piService = @{
    Name    = "LogAgent-Pi"
    Display = "日志分析Agent - Pi Agent Cluster"
    Exe     = $NodeExe
    Args    = "dist/cluster-server.js"
    Dir     = $AppDir
}

$nginxService = @{
    Name    = "LogAgent-Nginx"
    Display = "日志分析Agent - Nginx 反向代理"
    Exe     = (Join-Path $NginxPath "nginx.exe")
    Args    = "-p `"$NginxPath`""
    Dir     = $NginxPath
}

# ── 函数 ──
function Test-NssmAvailable {
    try { $null = & $NssmPath version 2>&1; return $true }
    catch { return $false }
}

function Install-One($svc) {
    Write-Host "  安装: $($svc.Name) ... " -NoNewline
    $existing = Get-Service $svc.Name -ErrorAction SilentlyContinue
    if ($existing) {
        & $NssmPath stop $svc.Name 2>$null
        & $NssmPath remove $svc.Name confirm 2>$null
    }
    & $NssmPath install $svc.Name $svc.Exe $svc.Args
    & $NssmPath set $svc.Name AppDirectory $svc.Dir
    & $NssmPath set $svc.Name DisplayName $svc.Display
    & $NssmPath set $svc.Name Start SERVICE_AUTO_START
    & $NssmPath set $svc.Name AppExit Default Restart
    & $NssmPath set $svc.Name AppRestartDelay 5000

    # Pi Agent 环境变量
    if ($svc.Name -eq "LogAgent-Pi") {
        & $NssmPath set $svc.Name AppEnvironmentExtra "WORKERS=$WorkerCount"
        & $NssmPath set $svc.Name AppEnvironmentExtra "PORT_START=$PortStart"
        & $NssmPath set $svc.Name AppEnvironmentExtra "NODE_ENV=production"
    }

    Write-Host "✓" -ForegroundColor Green
}

function Uninstall-One($svc) {
    Write-Host "  卸载: $($svc.Name) ... " -NoNewline
    try {
        & $NssmPath stop $svc.Name 2>$null
        Start-Sleep -Seconds 1
        & $NssmPath remove $svc.Name confirm 2>$null
        Write-Host "✓" -ForegroundColor Green
    } catch {
        Write-Host "跳过" -ForegroundColor Gray
    }
}

# ── 管理员检查 ──
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin) {
    Write-Host "[错误] 需要管理员权限" -ForegroundColor Red
    exit 1
}

if (-not (Test-NssmAvailable)) {
    Write-Host "[错误] NSSM 不可用。安装: choco install nssm" -ForegroundColor Red
    exit 1
}

Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  日志分析 Agent — Pi 版服务管理             ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  App 目录 : $AppDir" -ForegroundColor Gray
Write-Host "  Nginx    : $NginxPath" -ForegroundColor Gray
Write-Host "  Workers  : $WorkerCount (端口 $PortStart-$($PortStart+$WorkerCount-1))" -ForegroundColor Gray
Write-Host ""

if ($Install) {
    Write-Host "[安装]" -ForegroundColor Yellow
    Install-One $piService
    Install-One $nginxService
    Write-Host "`n安装完成! 启动: .\install-services.ps1 -Start" -ForegroundColor Green
}

if ($Uninstall) {
    Write-Host "[卸载]" -ForegroundColor Yellow
    Uninstall-One $nginxService
    Uninstall-One $piService
    Write-Host "`n卸载完成!" -ForegroundColor Green
}

if ($Start) {
    Write-Host "[启动]" -ForegroundColor Yellow
    Write-Host "  启动 $($piService.Name) ... " -NoNewline
    Start-Service $piService.Name
    Write-Host "✓" -ForegroundColor Green
    Start-Sleep -Seconds 5  # 等待 Workers 启动
    Write-Host "  启动 $($nginxService.Name) ... " -NoNewline
    Start-Service $nginxService.Name
    Write-Host "✓" -ForegroundColor Green
    Write-Host "`n启动完成!" -ForegroundColor Green
}

if ($Stop) {
    Write-Host "[停止]" -ForegroundColor Yellow
    Write-Host "  停止 $($nginxService.Name) ... " -NoNewline
    Stop-Service $nginxService.Name -Force -ErrorAction SilentlyContinue
    Write-Host "✓" -ForegroundColor Green
    Write-Host "  停止 $($piService.Name) ... " -NoNewline
    Stop-Service $piService.Name -Force -ErrorAction SilentlyContinue
    Write-Host "✓" -ForegroundColor Green
    Write-Host "`n停止完成!" -ForegroundColor Green
}

if ($Status) {
    Write-Host "[状态]" -ForegroundColor Yellow
    foreach ($svc in @($piService, $nginxService)) {
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

if (-not ($Install -or $Uninstall -or $Start -or $Stop -or $Status)) {
    Write-Host "用法:" -ForegroundColor Yellow
    Write-Host "  .\install-services.ps1 -Install     安装所有服务"
    Write-Host "  .\install-services.ps1 -Start       启动所有服务"
    Write-Host "  .\install-services.ps1 -Stop        停止所有服务"
    Write-Host "  .\install-services.ps1 -Status      查看服务状态"
    Write-Host "  .\install-services.ps1 -Uninstall   卸载所有服务"
    Write-Host ""
    Write-Host "注意: Pi 版使用 Node.js cluster 内置多进程，" -ForegroundColor Gray
    Write-Host "      只需注册一个 Primary 服务即可。" -ForegroundColor Gray
}
