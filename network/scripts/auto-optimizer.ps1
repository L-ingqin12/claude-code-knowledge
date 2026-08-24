#Requires -Version 5.1
<#
.SYNOPSIS
  Network Auto-Optimizer (v2rayN 7.x) — scheduled-task wrapper that watches the
  node database for subscription changes and re-applies the multi-server config.
.DESCRIPTION
  - Detects changes in guiNDB.db (ProfileItem) or a config.json that v2rayN has
    overwritten/cleaned, then invokes enhance-config.ps1 -Apply to rebuild the
    balancer config. Enhancement logic lives in enhance-config.ps1 only.
  - Runs as a scheduled task every 30 min. Skips work when nothing changed,
    so idle runs cost ~1s and do not restart xray.
  - Router auto-optimization was removed: router changes belong to the manual
    xiaomi-router workflow, not to a background timer.
.NOTES
  Register once: powershell -File "...\auto-optimizer.ps1" -Action Register
  Then it runs automatically every 30 min via Task Scheduler.
#>

param(
    [ValidateSet("Run", "Register", "Unregister", "Status")]
    [string]$Action = "Run"
)

$ErrorActionPreference = "SilentlyContinue"
$SCRIPT_PATH = $PSCommandPath
$SCRIPT_DIR = Split-Path $SCRIPT_PATH -Parent
$STATE_DIR = "$env:LOCALAPPDATA\network-optimizer"
$LOG_FILE = "$STATE_DIR\optimizer.log"
$HASH_CACHE = "$STATE_DIR\nodes.hash"
$ENHANCE_SCRIPT = "$SCRIPT_DIR\enhance-config.ps1"
$MAX_LOG_BYTES = 512KB

if (-not (Test-Path $STATE_DIR)) { $null = New-Item -ItemType Directory -Path $STATE_DIR -Force }

function Log { param([string]$m)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $m" | Add-Content $LOG_FILE -Encoding UTF8
    if ((Get-Item $LOG_FILE -EA 0).Length -gt $MAX_LOG_BYTES) {
        Get-Content $LOG_FILE -Tail 200 | Set-Content $LOG_FILE -Encoding UTF8
    }
}

function Find-V2rayN {
    $paths = @(
        "D:\Document\Download\v2rayN-windows-64-desktop\v2rayN-windows-64",
        "$env:LOCALAPPDATA\v2rayN",
        "$env:APPDATA\v2rayN"
    )
    $running = Get-Process -Name "v2rayN" -EA 0 | Select-Object -First 1
    if ($running) {
        $procPath = Split-Path $running.Path -Parent
        if ($procPath -and (Test-Path "$procPath\binConfigs")) { return $procPath }
    }
    foreach ($p in $paths) { if (Test-Path "$p\binConfigs") { return $p } }
    return $null
}

function Find-Sqlite3 {
    $candidates = @(
        "D:\Program Files\sqlite\sqlite3.exe",
        "C:\Program Files\sqlite\sqlite3.exe",
        "$env:ProgramFiles\sqlite\sqlite3.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $inPath = (Get-Command sqlite3 -EA 0).Source
    return $inPath
}

function Check-ProxyHealth {
    # @() wrapper: single result would otherwise give $null .Count
    return (@(Get-NetTCPConnection -LocalPort 10808 -EA 0 | Where-Object State -eq "Listen").Count -gt 0)
}

# Hash of the node pool — changes when the subscription updates
function Get-NodesHash {
    param([string]$v2rayNDir)
    $sqlite = Find-Sqlite3
    if (-not $sqlite) { return $null }
    $db = "$v2rayNDir\guiConfigs\guiNDB.db"
    if (-not (Test-Path $db)) { return $null }
    $q = "SELECT Address, Port, IFNULL(Password,''), IFNULL(PublicKey,''), IFNULL(Sni,'') FROM ProfileItem WHERE IsSub=1 ORDER BY Address, Port;"
    $raw = & $sqlite $db $q 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $seed = ($raw -join "|")
    $sha = [Security.Cryptography.SHA256]::Create()
    $b = [Text.Encoding]::UTF8.GetBytes($seed)
    return [BitConverter]::ToString($sha.ComputeHash($b)).Replace("-", "")
}

# Is the current binConfigs\config.json already the enhanced multi-server config?
function Test-ConfigEnhanced {
    param([string]$configFile)
    if (-not (Test-Path $configFile)) { return $false }
    try {
        $c = Get-Content $configFile -Raw | ConvertFrom-Json
        $px = @($c.outbounds | Where-Object { $_.protocol -ne "freedom" -and $_.protocol -ne "blackhole" })
        $hasBalancer = $c.routing.balancers -and @($c.routing.balancers).Count -gt 0
        return ($px.Count -ge 2 -and $hasBalancer)
    } catch { return $false }
}

function Invoke-EnhanceApply {
    Log "[Config] Invoking enhance-config.ps1 -Apply"
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $ENHANCE_SCRIPT -Apply 2>&1 | Out-String
    foreach ($line in ($out -split "`r?`n")) {
        if ($line.Trim()) { Log "[Enhance] $($line.Trim())" }
    }
    return (Check-ProxyHealth)
}

function Invoke-Optimize {
    $dir = Find-V2rayN
    if (-not $dir) { Log "[V2rayN] Not found — skip"; return }

    # Only act when the user session actually uses the proxy
    $v2rayNRunning = (Get-Process -Name "v2rayN" -EA 0 | Measure-Object).Count -gt 0
    if (-not $v2rayNRunning) { Log "[V2rayN] Not running — skip"; return }

    $configFile = "$dir\binConfigs\config.json"
    $enhanced = Test-ConfigEnhanced $configFile
    $proxyUp = Check-ProxyHealth
    $hash = Get-NodesHash $dir
    $prev = if (Test-Path $HASH_CACHE) { Get-Content $HASH_CACHE -Raw } else { "" }

    if (-not $enhanced -or -not $proxyUp -or ($hash -and $hash -ne $prev)) {
        Log "[V2rayN] Rebuilding (enhanced=$enhanced proxy=$proxyUp hashChanged=$($hash -and $hash -ne $prev))"
        Invoke-EnhanceApply | Out-Null
        if ($hash) { $hash | Out-File $HASH_CACHE -Encoding ascii -Force -NoNewline }
    } else {
        Log "[V2rayN] No changes"
    }
}

function Register-ScheduledTask {
    $taskName = "NetworkAutoOptimizer"
    $exists = Get-ScheduledTask -TaskName $taskName -EA 0
    if ($exists) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -EA 0
        Log "Removed existing task"
    }

    # wscript launches PowerShell fully hidden (no console flash), same
    # pattern as the Startup-folder balancer watcher VBS
    $vbsPath = Join-Path $SCRIPT_DIR "auto-optimizer-hidden.vbs"
    $vbs = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$SCRIPT_PATH"" -Action Run", 0, False
"@
    $vbs | Out-File $vbsPath -Encoding ascii -Force

    $action = New-ScheduledTaskAction -Execute "wscript.exe" `
        -Argument "`"$vbsPath`""
    # -Once + repetition: the -Daily -At parameter set fails to bind on PS 5.1
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 30) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -Hidden -MultipleInstances IgnoreNew

    try {
        $null = Register-ScheduledTask -TaskName $taskName `
            -Action $action -Trigger $trigger -Settings $settings `
            -Description "Rebuilds v2rayN multi-server config when subscription nodes change" `
            -RunLevel Limited -Force
    } catch {
        Log "REGISTER FAILED: $($_.Exception.Message)"
        Write-Host "Register failed: $($_.Exception.Message)"
        return
    }

    Start-ScheduledTask -TaskName $taskName -EA 0
    Log "Scheduled task '$taskName' registered (every 30 min, starting in ~1 min)"
    Write-Host "Task registered. Running every 30 minutes."
    Write-Host "Logs: $LOG_FILE"
}

function Unregister-Task {
    Unregister-ScheduledTask -TaskName "NetworkAutoOptimizer" -Confirm:$false -EA 0
    Remove-Item (Join-Path $SCRIPT_DIR "auto-optimizer-hidden.vbs") -Force -EA 0
    Write-Host "Task unregistered."
}

switch ($Action) {
    "Register" {
        if (-not (Test-Path $LOG_FILE)) { "" | Out-File $LOG_FILE -Encoding UTF8 }
        Log "========== REGISTERING SCHEDULED TASK =========="
        Register-ScheduledTask
    }
    "Unregister" { Unregister-Task }
    "Status" {
        if (Test-Path $LOG_FILE) {
            Write-Host "--- Last 20 log lines ---"
            Get-Content $LOG_FILE -Tail 20
        }
        $task = Get-ScheduledTask -TaskName "NetworkAutoOptimizer" -EA 0
        if ($task) {
            Write-Host "`nTask: $($task.TaskName) — State: $($task.State)"
        } else {
            Write-Host "`nTask not registered. Run: powershell -File auto-optimizer.ps1 -Action Register"
        }
        $dir = Find-V2rayN
        if ($dir) {
            $hash = Get-NodesHash $dir
            $prev = if (Test-Path $HASH_CACHE) { Get-Content $HASH_CACHE -Raw } else { "" }
            Write-Host "Node pool: $(if($hash){"hashed"}else{"unavailable"}) (cached: $($hash -eq $prev))"
            Write-Host "Config enhanced: $(Test-ConfigEnhanced "$dir\binConfigs\config.json")"
        }
        Write-Host "`nProxy port 10808: $(if(Check-ProxyHealth){'LISTENING'}else{'DOWN'})"
    }
    "Run" {
        if (-not (Test-Path $LOG_FILE)) { "" | Out-File $LOG_FILE -Encoding UTF8 }
        Log "========== RUN =========="
        Invoke-Optimize
        Log "========== DONE (proxy: $(if(Check-ProxyHealth){'UP'}else{'DOWN'})) =========="
    }
}
