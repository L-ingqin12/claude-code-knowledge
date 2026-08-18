<#
.SYNOPSIS
    启动多个 Pi Agent Node.js Worker 进程

.DESCRIPTION
    通过 Node.js cluster 模式启动多个 Worker (Primary 管理)。
    每个 Worker 监听独立端口，配合 Nginx upstream 负载均衡。

.PARAMETER WorkerCount
    Worker 进程数 (默认 4)

.PARAMETER PortStart
    起始端口号 (默认 8801)

.PARAMETER AgentTimeout
    Agent 调用超时秒数 (默认 60)

.PARAMETER MaxLogSizeMB
    最大日志大小 MB (默认 50)

.EXAMPLE
    .\start-workers.ps1
    .\start-workers.ps1 -WorkerCount 8 -PortStart 9000
#>

param(
    [int]$WorkerCount = 4,
    [int]$PortStart = 8801,
    [int]$AgentTimeout = 60,
    [int]$MaxLogSizeMB = 50,
    [string]$NodeExe = "node",
    [switch]$DevMode
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  日志分析 Agent — Pi Cluster 启动器         ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── 预检查 ──
Write-Host "[预检查]" -ForegroundColor Yellow

# Node.js
try {
    $nodeVersion = & $NodeExe --version 2>&1
    Write-Host "  Node.js: $nodeVersion" -ForegroundColor Green
} catch {
    Write-Host "  Node.js 不可用: $_" -ForegroundColor Red
    exit 1
}

# 检查 node_modules
if (-not (Test-Path (Join-Path $scriptDir ".." "node_modules"))) {
    Write-Host "  node_modules 不存在，开始安装依赖..." -ForegroundColor Yellow
    Push-Location (Join-Path $scriptDir "..")
    npm install
    Pop-Location
    Write-Host "  依赖安装完成" -ForegroundColor Green
}

# 端口检查
Write-Host "  端口范围: $PortStart - $($PortStart + $WorkerCount - 1)"
for ($i = 0; $i -lt $WorkerCount; $i++) {
    $port = $PortStart + $i
    $existing = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  ⚠ 端口 $port 已被 PID $($existing.OwningProcess) 占用" -ForegroundColor Red
    }
}

Write-Host ""

# ── 构建 TypeScript ──
Write-Host "[构建]" -ForegroundColor Yellow
Push-Location (Join-Path $scriptDir "..")

if ($DevMode) {
    Write-Host "  开发模式: 使用 tsx 直接运行 (无需编译)" -ForegroundColor Gray
    $EntryPoint = "src/cluster-server.ts"
} else {
    Write-Host "  编译 TypeScript..."
    npx tsc 2>&1 | Write-Host -ForegroundColor Gray
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  编译失败!" -ForegroundColor Red
        Pop-Location
        exit 1
    }
    Write-Host "  编译完成" -ForegroundColor Green
    $EntryPoint = "dist/cluster-server.js"
}

# ── 启动 ──
Write-Host ""
Write-Host "[启动 Cluster]" -ForegroundColor Yellow

$env:WORKERS = $WorkerCount
$env:PORT_START = $PortStart
$env:AGENT_TIMEOUT_S = $AgentTimeout
$env:MAX_LOG_SIZE_MB = $MaxLogSizeMB
$env:NODE_ENV = "production"

if ($DevMode) {
    # 开发模式: 用 tsx 运行
    $proc = Start-Process $NodeExe `
        -ArgumentList "--import tsx", $EntryPoint `
        -PassThru -WindowStyle Normal
} else {
    # 生产模式: 运行编译后的 JS
    $proc = Start-Process $NodeExe `
        -ArgumentList $EntryPoint `
        -PassThru -WindowStyle Hidden
}

Pop-Location

Write-Host "  Primary PID: $($proc.Id)" -ForegroundColor Green
Write-Host ""

# ── 等待 Worker 启动 ──
Start-Sleep -Seconds 3

# ── 健康检查 ──
Write-Host "[健康检查]" -ForegroundColor Yellow
for ($i = 0; $i -lt $WorkerCount; $i++) {
    $port = $PortStart + $i
    try {
        $resp = Invoke-RestMethod -Uri "http://[IP已脱敏]:$port/api/health" -TimeoutSec 5 -ErrorAction Stop
        Write-Host "  端口 $port: $($resp.status) ✓ (worker $($resp.worker_id))" -ForegroundColor Green
    } catch {
        Write-Host "  端口 $port: 启动中... (稍后重试)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "[完成] Pi Agent Cluster 已启动" -ForegroundColor Green
Write-Host "  Primary PID: $($proc.Id)"
Write-Host "  Workers: $WorkerCount (端口 $PortStart - $($PortStart + $WorkerCount - 1))"
Write-Host "  停止: taskkill /PID $($proc.Id) /T /F"
Write-Host ""
