#Requires -Version 5.1
<#
.SYNOPSIS
  Composite node scoring: latency + download speed → ranked list → optimized config
  Designed to be called: on subscription update, on manual trigger, or by the hook daemon
.DESCRIPTION
  Phase 1 — Ping all nodes (fast filter, <500ms)
  Phase 2 — Speed test top candidates (1MB download through temp xray)
  Phase 3 — Composite score (30% latency + 70% speed) → ranked list
  Phase 4 — Generate multi-server config with top 4 nodes
#>

param(
    [ValidateSet("Test", "Apply", "Both")]
    [string]$Action = "Both",
    [string]$V2rayNDir = $null,
    [int]$MaxSpeedTestNodes = 8,
    [int]$TopN = 4
)

$ErrorActionPreference = "SilentlyContinue"
$STATE_DIR = "$env:LOCALAPPDATA\network-optimizer"
if (-not (Test-Path $STATE_DIR)) { $null = New-Item -ItemType Directory -Path $STATE_DIR -Force }

$SPEED_TEST_URL = "http://[域名已脱敏]/1MB.zip"
$SPEED_TEST_TIMEOUT = 12
$PING_TIMEOUT_MS = 2000
$PING_THRESHOLD_MS = 500

# ============================================================
# DISCOVERY
# ============================================================

function Find-V2rayN {
    if ($V2rayNDir -and (Test-Path "$V2rayNDir\binConfigs")) { return $V2rayNDir }
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
        Select-Object -First 100 |
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
                        fingerprint = $px.streamSettings.realitySettings.fingerprint
                    }
                }
            } catch {}
        }
    return $nodes
}

# ============================================================
# PHASE 1: PING TEST
# ============================================================

function Test-PingLatency {
    param([string]$address)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ping = New-Object [域名已脱敏].NetworkInformation.Ping
    try {
        $reply = $ping.Send($address, $PING_TIMEOUT_MS)
        if ($reply.Status -eq "Success") { return $reply.RoundtripTime }
    } catch {}
    finally { $ping.Dispose() }
    return 9999
}

# ============================================================
# PHASE 2: SPEED TEST (via temp xray instance per node)
# ============================================================

function New-TempXrayConfig {
    param($node, [int]$port)
    return @{
        log = @{ loglevel = "none" }
        inbounds = @(@{
            tag = "socks"; port = $port; listen = "127.0.0.1"; protocol = "mixed"
            settings = @{ auth = "noauth"; udp = $false; allowTransparent = $false }
        })
        outbounds = @(
            @{
                tag = "proxy"; protocol = "vless"
                settings = @{ vnext = @(@{
                    address = $node.address; port = $node.port
                    users = @(@{ id = $node.uuid; email = "t@[域名已脱敏]"
                        security = "auto"; encryption = "none"
                        flow = if ($node.flow) { $node.flow } else { "xtls-rprx-vision" }
                    })
                })}
                streamSettings = @{
                    network = "tcp"; security = "reality"
                    realitySettings = @{
                        serverName = if ($node.sni) { $node.sni } else { "[域名已脱敏]" }
                        fingerprint = if ($node.fingerprint) { $node.fingerprint } else { "chrome" }
                        publicKey = if ($node.publicKey) { $node.publicKey } else { "" }
                        shortId = ""; spiderX = "/"; mldsa65Verify = ""
                    }
                }
            },
            @{ tag = "direct"; protocol = "freedom" }
        )
        routing = @{
            rules = @(
                @{ type = "field"; network = "tcp,udp"; outboundTag = "proxy" }
            )
        }
    } | ConvertTo-Json -Depth 8 -Compress
}

function Test-DownloadSpeed {
    param($node, [string]$xrayPath, [string]$workDir, [int]$port)
    $config = New-TempXrayConfig $node $port
    $configFile = "$STATE_DIR\temp_xray_${port}.json"
    $config | Out-File $configFile -Encoding ascii -Force

    # Start temp xray
    $proc = Start-Process -FilePath $xrayPath `
        -ArgumentList "run", "-c", $configFile `
        -WorkingDirectory $workDir `
        -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2

    if ($proc.HasExited) {
        Remove-Item $configFile -Force -EA 0
        return 0
    }

    # Download speed test
    $speed = 0
    try {
        $result = & curl -s -o "$STATE_DIR\speed_test.tmp" -w "%{speed_download}" `
            --max-time $SPEED_TEST_TIMEOUT --socks5 "127.0.0.1:$port" `
            $SPEED_TEST_URL 2>$null
        if ($result -match '^\d+') { $speed = [double]$result }
        Remove-Item "$STATE_DIR\speed_test.tmp" -Force -EA 0
    } catch {}

    # Cleanup
    Stop-Process -Id $proc.Id -Force -EA 0
    Start-Sleep -Seconds 1
    Remove-Item $configFile -Force -EA 0
    return $speed
}

# ============================================================
# PHASE 3: COMPOSITE SCORING
# ============================================================

function Get-CompositeScore {
    param($latencyMs, $speedBps)
    # Normalize latency: lower is better, 0-1 scale (20ms=1.0, 500ms=0.0)
    $latScore = [Math]::Max(0, 1 - ($latencyMs / 500))
    # Normalize speed: higher is better, 0-1 scale (10MB/s=1.0, 0=0.0)
    $speedScore = [Math]::Min(1, $speedBps / 10485760)
    # Composite: 30% latency, 70% speed
    $composite = ($latScore * 0.3) + ($speedScore * 0.7)
    return [Math]::Round($composite, 4)
}

# ============================================================
# PHASE 4: GENERATE CONFIG
# ============================================================

function New-OptimizedConfig {
    param([array]$rankedNodes, [string]$currentConfigPath)
    $uuid = $rankedNodes[0].UUID
    $flow = if ($rankedNodes[0].Flow) { $rankedNodes[0].Flow } else { "xtls-rprx-vision" }
    $selected = $rankedNodes | Select-Object -First $TopN

    $inboundPort = 10808
    if (Test-Path $currentConfigPath) {
        try {
            $c = Get-Content $currentConfigPath -Raw | ConvertFrom-Json
            if ($c.inbounds[0].port) { $inboundPort = $c.inbounds[0].port }
        } catch {}
    }

    $outbounds = @()
    $allTags = @()
    foreach ($n in $selected) {
        $tag = "px-$($n.Address.Split('.')[0])-$($n.Port)" -replace '[^a-zA-Z0-9_-]', ''
        $allTags += $tag
        $outbounds += [ordered]@{
            tag = $tag; protocol = "vless"
            settings = @{ vnext = @(@{
                address = $n.Address; port = $n.Port
                users = @(@{ id = $uuid; email = "t@[域名已脱敏]"
                    security = "auto"; encryption = "none"; flow = $flow })
            })}
            streamSettings = @{
                network = "tcp"; security = "reality"
                realitySettings = @{
                    serverName = if ($n.SNI) { $n.SNI } else { "[域名已脱敏]" }
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
    $fb = $selected | Select-Object -Skip 2 -First 1
    $primaryTags = @($primary | ForEach-Object {
        "px-$($_.Address.Split('.')[0])-$($_.Port)" -replace '[^a-zA-Z0-9_-]', ''
    })
    $fbTag = if ($fb) { "px-$($fb.Address.Split('.')[0])-$($fb.Port)" -replace '[^a-zA-Z0-9_-]', '' } else { $null }

    $config = [ordered]@{
        log = @{ loglevel = "warning" }
        dns = @{
            hosts = @{ "[域名已脱敏]" = @("[IP已脱敏]", "[IP已脱敏]"); "[域名已脱敏]" = @("[IP已脱敏]", "[IP已脱敏]") }
            servers = @(
                @{ address = "https://[域名已脱敏]/dns-query"; domains = @("geosite:private", "geosite:cn"); skipFallback = $true; tag = "direct-dns" }
                @{ address = "https://[域名已脱敏]/dns-query"; domains = @("geosite:google"); skipFallback = $true }
                @{ address = "[IP已脱敏]"; domains = @("full:[域名已脱敏]"); skipFallback = $true }
                "https://[域名已脱敏]/dns-query"
            )
            tag = "dns-module"
        }
        inbounds = @(@{
            tag = "socks"; port = $inboundPort; listen = "127.0.0.1"; protocol = "mixed"
            sniffing = @{ enabled = $true; destOverride = @("http", "tls"); routeOnly = $false }
            settings = @{ auth = "noauth"; udp = $true; allowTransparent = $false }
        })
        outbounds = $outbounds
        observatory = @{ subjectSelector = $allTags; probeURL = "https://[域名已脱敏]/generate_204"; probeInterval = "2m" }
        routing = @{
            domainStrategy = "AsIs"
            balancers = @(@{ tag = "balancer"; selector = $primaryTags; strategy = @{ type = "leastPing" } })
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
    if ($fbTag) {
        $json = $json -replace '"strategy":\{', "`"fallbackTag`":`"$fbTag`",`"strategy`":{"
    }
    return $json
}

# ============================================================
# MAIN
# ============================================================

function Invoke-NodeScoring {
    $dir = Find-V2rayN
    if (-not $dir) { Write-Host "ERROR: v2rayN not found"; return $null }

    $configDir = "$dir\binConfigs"
    $xrayPath = "$dir\bin\xray\xray.exe"
    $workDir = "$dir\bin"

    # Sync geo files
    foreach ($f in @("geosite.dat", "geoip.dat")) {
        if ((Test-Path "$workDir\$f") -and (-not (Test-Path "$workDir\xray\$f"))) {
            Copy-Item "$workDir\$f" "$workDir\xray\$f" -Force
        }
    }

    Write-Host "`n========== Node Composite Scoring =========="
    Write-Host "[1/4] Discovering nodes..."

    $nodes = Discover-Nodes $configDir
    Write-Host "  Found $($nodes.Count) unique nodes"

    if ($nodes.Count -eq 0) { Write-Host "No nodes found!"; return $null }

    # Phase 1: Ping
    Write-Host "`n[2/4] Phase 1 — Ping test (threshold: ${PING_THRESHOLD_MS}ms)..."
    $pingResults = @()
    foreach ($k in $nodes.Keys) {
        $n = $nodes[$k]
        $lat = Test-PingLatency $n.address
        $status = if ($lat -lt $PING_THRESHOLD_MS) { "PASS" } elseif ($lat -lt 9999) { "SLOW" } else { "DEAD" }
        Write-Host "  $($n.address):$($n.Port) — ${lat}ms [$status]"
        if ($lat -lt $PING_THRESHOLD_MS) {
            $pingResults += [PSCustomObject]@{
                Address=$n.address; Port=$n.port; Latency=$lat
                UUID=$n.uuid; Flow=$n.flow; SNI=$n.sni
                PublicKey=$n.publicKey; Fingerprint=$n.fingerprint
                Speed=0; Score=0
            }
        }
    }

    $candidates = $pingResults | Sort-Object Latency | Select-Object -First $MaxSpeedTestNodes
    Write-Host "  Candidates for speed test: $($candidates.Count)"

    if ($candidates.Count -eq 0) {
        Write-Host "No nodes passed ping test!"
        return $null
    }

    # Phase 2: Speed test
    Write-Host "`n[3/4] Phase 2 — Speed test (1MB download per node)..."
    $portBase = 20800
    $idx = 0
    foreach ($node in $candidates) {
        $port = $portBase + $idx
        Write-Host -NoNewline "  $($node.Address):$($node.Port) ... "
        $speed = Test-DownloadSpeed $node $xrayPath $workDir $port
        $node.Speed = $speed
        $speedKB = [Math]::Round($speed / 1024, 1)
        $speedMB = [Math]::Round($speed / 1048576, 2)
        if ($speed -gt 1048576) {
            Write-Host "${speedMB} MB/s"
        } else {
            Write-Host "${speedKB} KB/s"
        }
        $idx++
    }

    # Phase 3: Composite score
    Write-Host "`n[4/4] Phase 3 — Composite scoring (30% latency + 70% speed)..."
    $maxSpeed = ($candidates | Measure-Object -Property Speed -Maximum).Maximum
    if ($maxSpeed -eq 0) { $maxSpeed = 1 }

    foreach ($node in $candidates) {
        $node.Score = Get-CompositeScore $node.Latency $node.Speed
    }

    $ranked = $candidates | Sort-Object -Property Score -Descending

    Write-Host "`n  Final Ranking:"
    Write-Host "  " + ("-" * 65)
    Write-Host "  Rank  Node                          Latency   Speed      Score"
    Write-Host "  " + ("-" * 65)
    $rank = 1
    foreach ($n in $ranked) {
        $label = "$($n.Address):$($n.Port)"
        $speedStr = if ($n.Speed -gt 1048576) { "$([Math]::Round($n.Speed/1048576,1)) MB/s" } else { "$([Math]::Round($n.Speed/1024,0)) KB/s" }
        Write-Host ("  {0,-5} {1,-28} {2,-8}ms {3,-10} {4}" -f "[$rank]", $label, $n.Latency, $speedStr, $n.Score)
        $rank++
    }
    Write-Host "  " + ("-" * 65)

    # Save results
    $ranked | ConvertTo-Json -Depth 3 | Out-File "$STATE_DIR\node_scores.json" -Encoding utf8 -Force

    return $ranked
}

function Invoke-ApplyConfig {
    param([array]$ranked)
    if (-not $ranked -or $ranked.Count -eq 0) {
        Write-Host "No ranked nodes to apply"
        return
    }

    $dir = Find-V2rayN
    $configFile = "$dir\binConfigs\config.json"
    $workDir = "$dir\bin"

    Write-Host "`n========== Generating & Applying Config =========="
    $newConfig = New-OptimizedConfig $ranked $configFile
    if (-not $newConfig) { Write-Host "Failed to generate config"; return }

    # Backup
    if (Test-Path $configFile) {
        Copy-Item $configFile "$STATE_DIR\config.bak.json" -Force
    }

    # Write
    $newConfig | Out-File $configFile -Encoding ascii -Force
    Write-Host "Config written: $configFile"

    # Restart xray
    Get-Process -Name "xray" -EA 0 | Stop-Process -Force -EA 0
    Start-Sleep -Seconds 2

    $proc = Start-Process -FilePath "$workDir\xray\xray.exe" `
        -ArgumentList "run", "-c", "..\..\binConfigs\config.json" `
        -WorkingDirectory $workDir -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2

    if (-not $proc.HasExited) {
        Write-Host "xray restarted — PID $($proc.Id)"
        Write-Host "`nDone! Top 2 primary nodes + $($TopN-2) fallback in balancer with leastPing strategy."
    } else {
        Write-Host "ERROR: xray failed to start"
        if (Test-Path "$STATE_DIR\config.bak.json") {
            Copy-Item "$STATE_DIR\config.bak.json" $configFile -Force
            Write-Host "Rolled back to previous config"
        }
    }
}

# ============================================================
# DISPATCH
# ============================================================

$dir = Find-V2rayN
if (-not $dir) { Write-Host "v2rayN not found. Specify with -V2rayNDir"; exit 1 }

switch ($Action) {
    "Test" {
        $ranked = Invoke-NodeScoring
        if ($ranked) {
            $ranked | Select-Object Address, Port, Latency, Speed, Score |
                Format-Table -AutoSize
        }
    }
    "Apply" {
        # Load saved scores if available
        $ranked = $null
        if (Test-Path "$STATE_DIR\node_scores.json") {
            try { $ranked = Get-Content "$STATE_DIR\node_scores.json" -Raw | ConvertFrom-Json } catch {}
        }
        if (-not $ranked) {
            Write-Host "No saved scores. Run with -Action Test first."
            exit 1
        }
        Invoke-ApplyConfig $ranked
    }
    "Both" {
        $ranked = Invoke-NodeScoring
        if ($ranked) { Invoke-ApplyConfig $ranked }
    }
}
