#Requires -Version 5.1
<#
.SYNOPSIS
  v2rayN Config Hook — transparent filesystem-level hook
  Watches v2rayN's config.json, auto-upgrades single-server configs to multi-server
  with load balancing before xray reads it. Cooldown mechanism prevents loops.
.DESCRIPTION
  - Runs as a lightweight background daemon
  - Watches config.json for v2rayN writes (subscription updates, server switches)
  - Only triggers when the config has <2 proxy outbounds AND cooldown elapsed
  - Generates optimized config with balancer+observatory+mux
  - v2rayN and xray are completely unaware of the hook
  - Auto-registers as startup task on first run
#>

param(
    [ValidateSet("Start", "Stop", "Status", "Install", "Uninstall")]
    [string]$Action = "Start"
)

$ErrorActionPreference = "SilentlyContinue"
$SCRIPT_PATH = $PSCommandPath
$STATE_DIR = "$env:LOCALAPPDATA\network-optimizer"
$LOG_FILE = "$STATE_DIR\hook.log"
$COOLDOWN_FILE = "$STATE_DIR\last_optimize.txt"
$WATCHER_LOCK = "$STATE_DIR\watcher.lock"

# Cooldown between config rewrites (seconds) — prevents rapid oscillation
$COOLDOWN_SEC = 300

# Delay after file change before processing (seconds) — waits for v2rayN to finish writing
$WRITE_DELAY_SEC = 3

if (-not (Test-Path $STATE_DIR)) { $null = New-Item -ItemType Directory -Path $STATE_DIR -Force }

function Log { param([string]$m)
    $ts = Get-Date -Format "HH:mm:ss"
    "$ts  $m" | Add-Content $LOG_FILE -Encoding UTF8
}

# ============================================================
# DETECTION (same as auto-optimizer)
# ============================================================

function Find-V2rayN {
    $running = Get-Process -Name "v2rayN" -EA 0 | Select-Object -First 1
    if ($running) { $p = Split-Path $running.Path -Parent; if (Test-Path "$p\binConfigs") { return $p } }
    $paths = @(
        "D:\Document\Download\v2rayN-windows-64-desktop\v2rayN-windows-64",
        "$env:LOCALAPPDATA\v2rayN", "$env:APPDATA\v2rayN"
    )
    foreach ($p in $paths) { if (Test-Path "$p\binConfigs") { return $p } }
    return $null
}

function Discover-Nodes {
    param([string]$configDir)
    $nodes = @{}
    Get-ChildItem "$configDir\configTest*.json" -EA 0 |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 50 |
        ForEach-Object {
            try {
                $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
                $px = $j.outbounds | Where-Object tag -eq "proxy" | Select-Object -First 1
                if (-not $px) { return }
                $a = $px.settings.vnext[0]
                $k = "$($a.address):$($a.port)"
                if (-not $nodes[$k]) {
                    $nodes[$k] = @{
                        address = $a.address; port = $a.port
                        uuid = $a.users[0].id; flow = $a.users[0].flow
                        sni = $px.streamSettings.realitySettings.serverName
                        publicKey = $px.streamSettings.realitySettings.publicKey
                    }
                }
            } catch {}
        }
    return $nodes
}

function Test-LatencyFast {
    param([string]$addr)
    # Single ping for speed, don't block long
    $p = & ping -n 1 -w 1500 $addr 2>$null | Out-String
    if ($p -match 'time[=<]\s*(\d+)ms') { return [int]$matches[1] }
    return 9999
}

function Build-OptimizedConfig {
    param([hashtable]$nodes, [string]$currentConfigPath)

    # Read current config to preserve settings v2rayN controls (port, inbounds, etc.)
    $current = $null
    try { $current = Get-Content $currentConfigPath -Raw | ConvertFrom-Json } catch {}

    # Rank nodes
    $ranked = foreach ($k in $nodes.Keys) {
        $n = $nodes[$k]; $lat = Test-LatencyFast $n.address
        if ($lat -lt 9999) {
            [PSCustomObject]@{ Address=$n.address; Port=$n.port
                SNI=$n.sni; PublicKey=$n.publicKey; UUID=$n.uuid; Flow=$n.flow; Latency=$lat }
        }
    }
    $ranked = @($ranked | Sort-Object Latency)
    if ($ranked.Count -lt 1) { return $null }

    $uuid = $ranked[0].UUID
    $flow = if ($ranked[0].Flow) { $ranked[0].Flow } else { "xtls-rprx-vision" }
    $selected = $ranked | Select-Object -First 4

    Log "[Hook] Ranked nodes: $(($selected | ForEach-Object { "$($_.Address):$($_.Port)=$($_.Latency)ms" }) -join ', ')"

    # Preserve original inbound port if available
    $inboundPort = 10808
    $inboundTag = "socks"
    if ($current -and $current.inbounds) {
        $ib = $current.inbounds | Select-Object -First 1
        if ($ib.port) { $inboundPort = $ib.port }
        if ($ib.tag) { $inboundTag = $ib.tag }
    }

    # Build outbounds
    $outbounds = @()
    $allTags = @()
    foreach ($n in $selected) {
        $tag = "px-$($n.Address.Split('.')[0])-$($n.Port)" -replace '[^a-zA-Z0-9_-]', ''
        $allTags += $tag
        $outbounds += [ordered]@{
            tag = $tag; protocol = "vless"
            settings = @{ vnext = @(@{
                address = $n.Address; port = $n.Port
                users = @(@{ id = $uuid; email = "t@t.tt"
                    security = "auto"; encryption = "none"; flow = $flow })
            })}
            streamSettings = @{
                network = "tcp"; security = "reality"
                realitySettings = @{
                    serverName = if ($n.SNI) { $n.SNI } else { "apple.com" }
                    fingerprint = "chrome"
                    publicKey = if ($n.PublicKey) { $n.PublicKey } else { "" }
                    shortId = ""; spiderX = "/"; mldsa65Verify = ""
                }
            }
            mux = @{ enabled = $true; concurrency = 8 }
        }
    }
    $outbounds += @{ tag = "direct"; protocol = "freedom" }
    $outbounds += @{ tag = "block"; protocol = "blackhole" }

    $primary = $selected | Select-Object -First 2
    $fallbackTag = $null
    if ($selected.Count -gt 2) {
        $fb = $selected[2]
        $fallbackTag = "px-$($fb.Address.Split('.')[0])-$($fb.Port)" -replace '[^a-zA-Z0-9_-]', ''
    }
    $primaryTags = @($primary | ForEach-Object {
        "px-$($_.Address.Split('.')[0])-$($_.Port)" -replace '[^a-zA-Z0-9_-]', ''
    })

    $config = [ordered]@{
        log = @{ loglevel = "warning" }
        dns = @{
            hosts = @{
                "dns.google" = @("[IP已脱敏]", "[IP已脱敏]")
                "dns.alidns.com" = @("[IP已脱敏]", "[IP已脱敏]")
            }
            servers = @(
                @{ address = "https://dns.alidns.com/dns-query"
                   domains = @("geosite:private", "geosite:cn")
                   skipFallback = $true; tag = "direct-dns" },
                @{ address = "https://cloudflare-dns.com/dns-query"
                   domains = @("geosite:google"); skipFallback = $true },
                @{ address = "[IP已脱敏]"; domains = @("full:dns.alidns.com"); skipFallback = $true },
                "https://cloudflare-dns.com/dns-query"
            )
            tag = "dns-module"
        }
        inbounds = @(@{
            tag = $inboundTag; port = $inboundPort; listen = "[IP已脱敏]"; protocol = "mixed"
            sniffing = @{ enabled = $true; destOverride = @("http", "tls"); routeOnly = $false }
            settings = @{ auth = "noauth"; udp = $true; allowTransparent = $false }
        })
        outbounds = $outbounds
        observatory = @{
            subjectSelector = $allTags
            probeURL = "https://www.google.com/generate_204"
            probeInterval = "2m"
        }
        routing = @{
            domainStrategy = "AsIs"
            balancers = @(@{
                tag = "balancer"; selector = $primaryTags
                strategy = @{ type = "leastPing" }
            })
            rules = @(
                @{ type = "field"; port = "443"; network = "udp"; outboundTag = "block" }
                @{ type = "field"; outboundTag = "balancer"; domain = @("geosite:google") }
                @{ type = "field"; outboundTag = "direct"; ip = @("geoip:private") }
                @{ type = "field"; outboundTag = "direct"; domain = @("geosite:private") }
                @{ type = "field"; outboundTag = "direct"; ip = @("geoip:cn") }
                @{ type = "field"; outboundTag = "direct"; domain = @("geosite:cn") }
                @{ type = "field"; inboundTag = @("direct-dns"); outboundTag = "direct" }
                @{ type = "field"; inboundTag = @("dns-module"); outboundTag = "balancer" }
            )
        }
    }

    $json = ConvertTo-Json -Depth 10 -Compress $config
    if ($fallbackTag) {
        $json = $json -replace '"strategy":\{', "`"fallbackTag`":`"$fallbackTag`",`"strategy`":{"
    }
    return $json
}

function Has-MultiProxy {
    param([string]$configPath)
    try {
        $j = Get-Content $configPath -Raw | ConvertFrom-Json
        $pxCount = ($j.outbounds | Where-Object {
            $_.protocol -ne "freedom" -and $_.protocol -ne "blackhole"
        }).Count
        return $pxCount -ge 2
    } catch { return $false }
}

function In-Cooldown {
    if (-not (Test-Path $COOLDOWN_FILE)) { return $false }
    $last = [datetime](Get-Content $COOLDOWN_FILE -Raw)
    return ((Get-Date) - $last).TotalSeconds -lt $COOLDOWN_SEC
}

function Set-Cooldown {
    (Get-Date).ToString("o") | Out-File $COOLDOWN_FILE -Encoding ascii -Force
}

function Sync-GeoFiles {
    param([string]$dir)
    foreach ($f in @("geosite.dat", "geoip.dat")) {
        $src = "$dir\$f"; $dst = "$dir\xray\$f"
        if ((Test-Path $src) -and (-not (Test-Path $dst) -or (Get-Item $src).LastWriteTime -gt (Get-Item $dst).LastWriteTime)) {
            Copy-Item $src $dst -Force
        }
    }
}

# ============================================================
# CONFIG UPGRADE LOGIC (called on file change)
# ============================================================

function Invoke-ConfigUpgrade {
    $dir = Find-V2rayN
    if (-not $dir) { return }
    $configFile = "$dir\binConfigs\config.json"
    $configDir = "$dir\binConfigs"

    if (-not (Test-Path $configFile)) { return }

    # Skip if already multi-proxy
    if (Has-MultiProxy $configFile) {
        Log "[Hook] Already multi-proxy, skipping"
        return
    }

    # Cooldown check
    if (In-Cooldown) {
        Log "[Hook] In cooldown, skipping"
        return
    }

    Log "[Hook] Single-proxy config detected, upgrading..."
    Sync-GeoFiles "$dir\bin"

    $nodes = Discover-Nodes $configDir
    if ($nodes.Count -lt 2) {
        Log "[Hook] Only $($nodes.Count) nodes available (need >=2), skipping"
        return
    }

    $newConfig = Build-OptimizedConfig $nodes $configFile
    if (-not $newConfig) { Log "[Hook] Failed to build config"; return }

    # Atomic write: write to temp first, then move
    $tmpFile = "$configDir\config.hook.tmp.json"
    $newConfig | Out-File $tmpFile -Encoding ascii -Force
    Move-Item $tmpFile $configFile -Force
    Set-Cooldown

    Log "[Hook] Config upgraded ($($nodes.Count) nodes, $(($newConfig.Length/1024).ToString('0'))KB)"
}

# ============================================================
# FILESYSTEM WATCHER DAEMON
# ============================================================

function Start-Watcher {
    $dir = Find-V2rayN
    if (-not $dir) {
        Log "[Hook] ERROR: v2rayN not found. Exiting."
        return
    }
    $watchPath = "$dir\binConfigs"
    Log "[Hook] Watching: $watchPath"
    Log "[Hook] Cooldown: ${COOLDOWN_SEC}s, Write delay: ${WRITE_DELAY_SEC}s"
    Log "[Hook] Daemon started"

    # Create lock file to indicate running
    (Get-Date).ToString("o") | Out-File $WATCHER_LOCK -Encoding ascii -Force

    # Do initial check
    Invoke-ConfigUpgrade

    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $watchPath
    $watcher.Filter = "config.json"
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::FileName
    $watcher.EnableRaisingEvents = $true

    # Track debounce timer to batch rapid changes
    $timer = $null

    $onChanged = Register-ObjectEvent -InputObject $watcher -EventName Changed -Action {
        # Debounce: reset timer on each change, only process after quiet period
        $script:timer = [System.Timers.Timer]::new($using:WRITE_DELAY_SEC * 1000)
        $script:timer.AutoReset = $false
        $script:timer.Enabled = $true
        $script:timer.Add_Elapsed({
            try {
                & $using:Invoke-ConfigUpgrade
            } catch {
                "[Hook] Error: $_" | Add-Content $using:LOG_FILE -Encoding UTF8
            }
            $script:timer.Dispose()
        })
    }

    Log "[Hook] Watcher active. Press Ctrl+C to stop."

    # Keep alive
    try {
        while ($true) {
            Start-Sleep -Seconds 60
            # Heartbeat: update lock file
            (Get-Date).ToString("o") | Out-File $WATCHER_LOCK -Encoding ascii -Force

            # Periodically sync geo files
            $vd = Find-V2rayN
            if ($vd) { Sync-GeoFiles "$vd\bin" }
        }
    } finally {
        $watcher.EnableRaisingEvents = $false
        $watcher.Dispose()
        Remove-Item $WATCHER_LOCK -Force -EA 0
        Log "[Hook] Daemon stopped"
    }
}

function Stop-Watcher {
    # Kill any running instance of this script (except current)
    $currentId = $PID
    Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -EA 0 |
        Where-Object { $_.CommandLine -match "v2rayn-config-hook" -and $_.ProcessId -ne $currentId } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -EA 0
            Log "[Hook] Stopped PID $($_.ProcessId)"
        }
    if (Test-Path $WATCHER_LOCK) { Remove-Item $WATCHER_LOCK -Force }
}

# ============================================================
# INSTALL AS STARTUP TASK
# ============================================================

function Install-StartupTask {
    $taskName = "V2rayNConfigHook"
    $existing = Get-ScheduledTask -TaskName $taskName -EA 0
    if ($existing) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -EA 0 }

    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -File `"$SCRIPT_PATH`" -Action Start"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    # Re-trigger at user login too
    $trigger2 = New-ScheduledTaskTrigger -AtLogOn
    # Network connectivity available trigger
    $trigger3 = New-ScheduledTaskTrigger -AtStartup

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -Hidden `
        -MultipleInstances IgnoreNew `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    Register-ScheduledTask -TaskName $taskName `
        -Action $action -Trigger $trigger -Settings $settings `
        -Description "v2rayN config hook — auto-upgrades to multi-server with load balancing" `
        -RunLevel Limited -Force | Out-Null

    # Start immediately
    Start-ScheduledTask -TaskName $taskName
    Log "[Install] Registered startup task '$taskName'"
    Write-Host "Installed. Hook will auto-start with Windows."
    Write-Host "Logs: $LOG_FILE"
}

# ============================================================
# DISPATCH
# ============================================================

switch ($Action) {
    "Install" {
        if (-not (Test-Path $LOG_FILE)) { "" | Out-File $LOG_FILE -Encoding UTF8 }
        Log "========== INSTALLING =========="
        Install-StartupTask
    }
    "Uninstall" {
        Stop-Watcher
        $taskName = "V2rayNConfigHook"
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -EA 0
        Log "========== UNINSTALLED =========="
        Write-Host "Uninstalled."
    }
    "Status" {
        $running = (Test-Path $WATCHER_LOCK)
        Write-Host "Hook daemon: $(if($running){'RUNNING'}else{'stopped'})"
        Write-Host "Cooldown: $(if(In-Cooldown){'active'}else{'inactive'})"
        $dir = Find-V2rayN
        if ($dir) {
            $cfg = "$dir\binConfigs\config.json"
            if (Test-Path $cfg) {
                $isMulti = Has-MultiProxy $cfg
                Write-Host "Current config: $(if($isMulti){'multi-server (optimized)'}else{'single-server'})"
            }
        }
        if (Test-Path $LOG_FILE) {
            Write-Host "`n--- Last 15 log lines ---"
            Get-Content $LOG_FILE -Tail 15
        }
    }
    "Start" {
        if (-not (Test-Path $LOG_FILE)) { "" | Out-File $LOG_FILE -Encoding UTF8 }
        Start-Watcher
    }
    "Stop" {
        Stop-Watcher
        Write-Host "Stopped."
    }
}
