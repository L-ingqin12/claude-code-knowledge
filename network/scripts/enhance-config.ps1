#Requires -Version 5.1
<#
.SYNOPSIS
  Config Enhancer for v2rayN 7.x — reads nodes from guiNDB.db, adds multi-server
  load balancing with balancer + observatory. Supports two modes:
    - Native mode:  binConfigs\config.json exists (v2rayN wrote it) — preserves all
                    v2rayN-native routing/DNS/inbounds, only adds outbounds + balancer
    - DB mode:      config.json absent (v2rayN 7.19.5+ may not keep it) — builds a
                    standalone optimized config from the node database (ProfileItem)
.DESCRIPTION
  Node discovery is done from guiNDB.db (SQLite) instead of the old configTest
  files, which v2rayN 7.x no longer keeps in binConfigs. Subscription updates
  performed in v2rayN land in the DB automatically, so running this script after
  a subscription update regenerates the optimized multi-server config.

  Usage:
    powershell -File enhance-config.ps1 -Status              # current state
    powershell -File enhance-config.ps1 -DryRun              # preview, no apply
    powershell -File enhance-config.ps1 -Apply               # test + apply
    powershell -File enhance-config.ps1 -SetAutoUpdate 60    # enable v2rayN native
                                                            # subscription auto-update
    powershell -File enhance-config.ps1 -SqlitePath "C:\x\sqlite3.exe"   # override
#>

param(
    [switch]$DryRun,
    [switch]$Apply,
    [switch]$Status,
    [int]$SetAutoUpdate = -1,
    [string]$SqlitePath = ""
)

$ErrorActionPreference = "Stop"
$STATE_DIR = "$env:LOCALAPPDATA\network-optimizer"
if (-not (Test-Path $STATE_DIR)) { $null = New-Item -ItemType Directory -Path $STATE_DIR -Force }

# ============================================================
# HELPERS
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

function Find-Sqlite3 {
    param([string]$v2rayNDir)
    if ($SqlitePath -and (Test-Path $SqlitePath)) { return $SqlitePath }
    $candidates = @(
        "D:\Program Files\sqlite\sqlite3.exe",
        "C:\Program Files\sqlite\sqlite3.exe",
        "$env:ProgramFiles\sqlite\sqlite3.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $inPath = (Get-Command sqlite3 -EA 0).Source
    if ($inPath) { return $inPath }
    return $null
}

function Test-XrayConfig {
    param([string]$configPath, [string]$binDir)
    $result = & "$binDir\xray\xray.exe" -test -c $configPath 2>&1 | Out-String
    return $result -match "Configuration OK"
}

# v2rayN 7.x: all subscription nodes live in guiNDB.db ProfileItem
# ConfigType: 1=vmess 2=shadowsocks 3=socks 4=trojan 5=vless
function Read-SubscriptionNodes {
    param([string]$v2rayNDir)
    $sqlite = Find-Sqlite3 $v2rayNDir
    if (-not $sqlite) { Write-Host "ERROR: sqlite3 not found — install or pass -SqlitePath"; return $null }
    $db = "$v2rayNDir\guiConfigs\guiNDB.db"
    if (-not (Test-Path $db)) { Write-Host "ERROR: guiNDB.db not found at $db"; return $null }

    $sep = [string][char]0x1F
    $q = "SELECT Address, Port, Password, IFNULL(Sni,''), IFNULL(Fingerprint,''), IFNULL(PublicKey,''), IFNULL(Network,''), IFNULL(StreamSecurity,''), ConfigType, replace(replace(IFNULL(Extra,''),char(10),' '),char(13),' '), replace(replace(IFNULL(Remarks,''),char(10),' '),char(13),' ') FROM ProfileItem WHERE IsSub=1 ORDER BY Address, Port;"
    $raw = & $sqlite $db -separator $sep $q 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: sqlite query failed: $raw"; return $null }

    $nodes = @()
    foreach ($line in $raw) {
        if (-not $line -or $line -match "^\s*$") { continue }
        $f = $line -split [regex]::Escape($sep)
        if ($f.Count -lt 9) { continue }
        $node = [PSCustomObject]@{
            Address = $f[0]; Port = [int]$f[1]; UUID = $f[2]
            SNI = $f[3]; Fingerprint = $f[4]; PublicKey = $f[5]
            Network = $f[6]; Security = $f[7]; ConfigType = [int]$f[8]
            Extra = $f[9]; Remarks = $f[10]
            Protocol = ""; Flow = ""; Latency = 9999; Score = 0
        }
        if ($node.ConfigType -eq 5) { $node.Protocol = "vless" } else { continue }
        $node.Flow = "xtls-rprx-vision"
        if ($node.Extra) {
            try { $ex = $node.Extra | ConvertFrom-Json; if ($ex.Flow) { $node.Flow = $ex.Flow } } catch {}
        }
        if ($node.Security -eq "") { $node.Security = "reality" }
        if ($node.Network -eq "") { $node.Network = "tcp" }
        # Deduplicate by address:port
        $key = "$($node.Address):$($node.Port)"
        if (-not ($nodes | Where-Object { "$($_.Address):$($_.Port)" -eq $key })) { $nodes += $node }
    }
    return $nodes
}

function Test-Latency {
    param([string]$addr)
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $r = $ping.Send($addr, 2000)
        if ($r.Status -eq "Success") { return $r.RoundtripTime }
    } catch {} finally { $ping.Dispose() }
    return 9999
}

# ============================================================
# STANDALONE CONFIG (DB mode — no native config.json available)
# ============================================================

function Build-StandaloneConfig {
    param($nodes)   # PSCustomObject[] with Protocol/Address/Port/UUID/Flow/SNI/PublicKey/Fingerprint/Network/Security

    $outbounds = @()
    $balancerTags = @()
    $obsTags = @()
    $fallbackTag = ""
    foreach ($n in $nodes) {
        $tag = "px-$($n.Address.Split('.')[0])-$($n.Port)" -replace '[^a-zA-Z0-9_-]', ''
        $balancerTags += $tag
        $obsTags += $tag
        if (-not $fallbackTag) { $fallbackTag = $tag }
        $outbounds += [PSCustomObject]@{
            tag = $tag
            protocol = $n.Protocol
            settings = @{ vnext = @(@{
                address = $n.Address; port = $n.Port
                users = @(@{ id = $n.UUID; email = "t@t.tt"; security = "auto"; encryption = "none"; flow = $n.Flow })
            })}
            streamSettings = @{
                network = $n.Network; security = $n.Security
                realitySettings = @{
                    serverName = $n.SNI
                    fingerprint = $n.Fingerprint
                    publicKey = $n.PublicKey
                    shortId = ""; spiderX = "/"
                }
            }
            mux = @{ enabled = $false }
        }
    }

    $config = [ordered]@{
        log = @{ loglevel = "warning" }
        dns = @{
            hosts = @{
                "dns.google" = @("[IP已脱敏]", "[IP已脱敏]")
                "dns.alidns.com" = @("[IP已脱敏]", "[IP已脱敏]")
            }
            servers = @(
                @{ address = "https://dns.alidns.com/dns-query"; domains = @("geosite:private", "geosite:cn"); skipFallback = $true; tag = "direct-dns-1" },
                @{ address = "https://cloudflare-dns.com/dns-query"; domains = @("geosite:google"); skipFallback = $true },
                @{ address = "[IP已脱敏]"; domains = @("full:dns.alidns.com"); skipFallback = $true },
                "https://cloudflare-dns.com/dns-query"
            )
            tag = "dns-module"
        }
        inbounds = @(@{
            tag = "socks"; port = 10808; listen = "[IP已脱敏]"; protocol = "mixed"
            sniffing = @{ enabled = $true; destOverride = @("http", "tls"); routeOnly = $false }
            settings = @{ auth = "noauth"; udp = $true; allowTransparent = $false }
        })
        outbounds = @($outbounds) + @(
            @{ tag = "direct"; protocol = "freedom" },
            @{ tag = "block"; protocol = "blackhole" }
        )
        routing = @{
            domainStrategy = "AsIs"
            balancers = @(@{
                tag = "balancer"
                selector = @($balancerTags)
                strategy = @{ type = "leastPing" }
                fallbackTag = $fallbackTag
            })
            rules = @(
                @{ type = "field"; port = "443"; network = "udp"; outboundTag = "block" },
                @{ type = "field"; outboundTag = "balancer"; domain = @("geosite:google") },
                @{ type = "field"; outboundTag = "direct"; ip = @("geoip:private") },
                @{ type = "field"; outboundTag = "direct"; domain = @("geosite:private") },
                @{ type = "field"; outboundTag = "direct"; ip = @("geoip:cn") },
                @{ type = "field"; outboundTag = "direct"; domain = @("geosite:cn") },
                @{ type = "field"; network = "tcp,udp"; balancerTag = "balancer" }
            )
        }
        observatory = @{
            subjectSelector = @($obsTags)
            probeURL = "https://www.google.com/generate_204"
            probeInterval = "2m"
        }
    }
    return $config
}

# ============================================================
# CORE: Enhance v2rayN Config
# ============================================================

function Invoke-Enhance {
    param([bool]$dry = $false)

    $dir = Find-V2rayN
    if (-not $dir) { Write-Host "ERROR: v2rayN not found"; return $false }
    $configFile = "$dir\binConfigs\config.json"
    $binDir = "$dir\bin"

    # Already enhanced? (multi-server + balancer from a previous run) — no-op
    if (Test-Path $configFile) {
        try {
            $cur = Get-Content $configFile -Raw | ConvertFrom-Json
            $curPx = @($cur.outbounds | Where-Object { $_.protocol -ne "freedom" -and $_.protocol -ne "blackhole" })
            if ($curPx.Count -ge 2) {
                Write-Host "Config already multi-server ($($curPx.Count) proxy outbounds) — nothing to do"
                return $true
            }
        } catch {}
    }

    $nodes = Read-SubscriptionNodes $dir
    if (-not $nodes -or $nodes.Count -lt 2) {
        Write-Host "ERROR: need >=2 subscription nodes in guiNDB.db (found: $($nodes.Count))"
        return $false
    }
    Write-Host "[1] Discovered $($nodes.Count) subscription nodes from guiNDB.db"
    $nodes | Select-Object -First 5 | ForEach-Object { Write-Host "    - $($_.Address):$($_.Port) [$($_.Remarks)]" }
    if ($nodes.Count -gt 5) { Write-Host "    ... ($($nodes.Count - 5) more)" }

    # Ping test
    Write-Host "[2] Ping test..."
    foreach ($n in $nodes) {
        $n.Latency = Test-Latency $n.Address
        $status = if ($n.Latency -lt 300) { "OK" } elseif ($n.Latency -lt 500) { "SLOW" } else { "DEAD" }
        Write-Host "    $($n.Address):$($n.Port) — $($n.Latency)ms [$status]"
    }

    # Score + select top diverse nodes (exclude DEAD)
    Write-Host "[3] Scoring..."
    $alive = $nodes | Where-Object { $_.Latency -lt 500 }
    foreach ($n in $alive) { $n.Score = [Math]::Round([Math]::Max(0.0, 1.0 - ($n.Latency / 500.0)), 3) }
    $diverse = $alive | Sort-Object -Property Score -Descending
    $seen = @{}; $best = @()
    foreach ($n in $diverse) {
        if (-not $seen[$n.Address] -and $best.Count -lt 3) { $seen[$n.Address] = $true; $best += $n }
    }
    if ($best.Count -lt 2) {
        Write-Host "  Too few reachable nodes — no optimization possible"
        return $false
    }
    Write-Host "  Selected: $(($best | ForEach-Object { "$($_.Address):$($_.Port)($($_.Score))" }) -join ', ')"

    # Sync geo files
    foreach ($f in @("geosite.dat", "geoip.dat")) {
        $s = "$binDir\$f"; $d = "$binDir\xray\$f"
        if ((Test-Path $s) -and (-not (Test-Path $d) -or (Get-Item $s).LastWriteTime -gt (Get-Item $d).LastWriteTime)) {
            Copy-Item $s $d -Force
        }
    }

    # ---- Mode A: native config exists — preserve v2rayN settings, add balancer ----
    $native = $false
    if (Test-Path $configFile) {
        Write-Host "[4] binConfigs\config.json exists — NATIVE mode (preserve v2rayN routing)"
        $native = $true
        try { $config = Get-Content $configFile -Raw | ConvertFrom-Json }
        catch { Write-Host "ERROR: Invalid config JSON: $_"; return $false }

        $primaryProxy = $config.outbounds | Where-Object { $_.protocol -ne "freedom" -and $_.protocol -ne "blackhole" } | Select-Object -First 1
        if (-not $primaryProxy) { Write-Host "ERROR: No proxy outbound in native config"; return $false }
        $origAddr = $primaryProxy.settings.vnext[0].address

        # Exclude the current primary and any address already in the config
        $existingAddrs = @($config.outbounds | ForEach-Object { $_.settings.vnext[0].address })
        $cands = $best | Where-Object { $_.Address -ne $origAddr -and $_.Address -notin $existingAddrs }
        if ($cands.Count -eq 0) {
            Write-Host "  All candidates equal current primary — no change needed"
            return $true
        }
        $best = $cands

        $newOutbounds = @()
        $balancerTags = @($primaryProxy.tag)
        foreach ($n in $best) {
            $tag = "px-$($n.Address.Split('.')[0])-$($n.Port)" -replace '[^a-zA-Z0-9_-]', ''
            $balancerTags += $tag
            $newOutbounds += [PSCustomObject]@{
                tag = $tag; protocol = $n.Protocol
                settings = @{ vnext = @(@{ address = $n.Address; port = $n.Port; users = @(@{ id = $n.UUID; email = "t@t.tt"; security = "auto"; encryption = "none"; flow = $n.Flow }) })}
                streamSettings = @{ network = $n.Network; security = $n.Security; realitySettings = @{ serverName = $n.SNI; fingerprint = "chrome"; publicKey = $n.PublicKey; shortId = ""; spiderX = "/" } }
                mux = @{ enabled = $false }
            }
        }

        $outboundsList = [System.Collections.ArrayList]@($config.outbounds)
        $insertIndex = 1
        foreach ($no in $newOutbounds) { $outboundsList.Insert($insertIndex, $no) }

        $routing = $config.routing
        if (-not $routing) { $routing = [PSCustomObject]@{ domainStrategy = "AsIs"; rules = @() } }
        $balancerConfig = @{ tag = "balancer"; selector = @($balancerTags); strategy = @{ type = "leastPing" } }
        if ($best.Count -gt 0) {
            $fbTag = "px-$($best[0].Address.Split('.')[0])-$($best[0].Port)" -replace '[^a-zA-Z0-9_-]', ''
            $balancerConfig.fallbackTag = $fbTag
        }
        $routing | Add-Member -MemberType NoteProperty -Name "balancers" -Value @($balancerConfig) -Force

        $rulesList = [System.Collections.ArrayList]@($routing.rules)
        for ($i = 0; $i -lt $rulesList.Count; $i++) {
            $rule = $rulesList[$i]
            if ($rule.inboundTag -and $rule.inboundTag -contains "dns-module") { continue }
            if ($rule.outboundTag -eq $primaryProxy.tag) {
                $rule.PSObject.Properties.Remove("outboundTag")
                $rule | Add-Member -MemberType NoteProperty -Name "balancerTag" -Value "balancer" -Force
            }
        }
        $hasCatchAll = $rulesList | Where-Object { ($_.network -eq "tcp,udp") -and (-not $_.domain) -and (-not $_.ip) -and (-not $_.inboundTag) -and (-not $_.port) }
        if (-not $hasCatchAll) {
            $null = $rulesList.Add([PSCustomObject]@{ type = "field"; network = "tcp,udp"; balancerTag = "balancer" })
        }
        $routing.rules = @($rulesList)

        $finalConfig = [ordered]@{
            log = $config.log; dns = $config.dns; inbounds = $config.inbounds
            outbounds = @($outboundsList); routing = $routing
        }
        $obsTags = @($balancerTags)
        $finalConfig.observatory = @{ subjectSelector = @($obsTags); probeURL = "https://www.google.com/generate_204"; probeInterval = "3m" }
    }
    # ---- Mode B: no native config — standalone template ----
    else {
        Write-Host "[4] No binConfigs\config.json — DB mode (standalone optimized config)"
        $finalConfig = Build-StandaloneConfig $best
    }

    $json = ConvertTo-Json -Depth 10 -Compress $finalConfig

    # Validate
    Write-Host "[5] Validating with xray -test..."
    $tmpValidFile = "$STATE_DIR\enhanced_validate.json"
    $json | Out-File $tmpValidFile -Encoding ascii -Force
    $valid = Test-XrayConfig $tmpValidFile $binDir
    Remove-Item $tmpValidFile -Force -EA 0
    if (-not $valid) { Write-Host "  VALIDATION FAILED — not applying"; return $false }
    Write-Host "  Configuration OK"

    if ($dry) {
        Write-Host "[DRY-RUN] Would write $($json.Length) bytes. Not applying."
        $json | Out-File "$STATE_DIR\enhanced_dry.json" -Encoding ascii -Force
        Write-Host "  Preview saved to: $STATE_DIR\enhanced_dry.json"
        return $true
    }

    # Apply
    # NOTE: v2rayN manages the core lifecycle — killing xray may make it respawn
    # (reading binConfigs\config.json = OUR config) or regenerate its own file.
    # Sequence: write config -> kill xray -> wait for v2rayN to respawn -> only
    # start xray ourselves if nothing is listening after 6s.
    Write-Host "[6] Applying..."
    $hadConfig = Test-Path $configFile
    if ($hadConfig) { Copy-Item $configFile "$STATE_DIR\config.rollback.json" -Force }
    $json | Out-File $configFile -Encoding ascii -Force

    Get-Process -Name "xray" -EA 0 | Stop-Process -Force -EA 0
    Start-Sleep -Seconds 6

    $listening = netstat -ano 2>$null | Select-String ":10808" | Select-String "LISTENING"
    $p = $null
    if (-not $listening) {
        Write-Host "  v2rayN did not respawn core — starting xray manually"
        $p = Start-Process -FilePath "$binDir\xray\xray.exe" -ArgumentList "run","-c",$configFile -WorkingDirectory $binDir -WindowStyle Hidden -PassThru
        Start-Sleep -Seconds 3
    }

    $listening = netstat -ano 2>$null | Select-String ":10808" | Select-String "LISTENING"
    if (-not $listening) {
        Write-Host "  xray not listening on 10808 — rolling back"
        Get-Process -Name "xray" -EA 0 | Stop-Process -Force -EA 0
        Start-Sleep -Seconds 1
        if ($hadConfig) { Copy-Item "$STATE_DIR\config.rollback.json" $configFile -Force } else { Remove-Item $configFile -Force -EA 0 }
        Start-Sleep -Seconds 1
        Get-Process -Name "xray" -EA 0 | Stop-Process -Force -EA 0
        Start-Sleep -Seconds 2
        if (Test-Path $configFile) {
            Start-Process -FilePath "$binDir\xray\xray.exe" -ArgumentList "run","-c",$configFile -WorkingDirectory $binDir -WindowStyle Hidden | Out-Null
        }
        return $false
    }

    $pidInfo = Get-NetTCPConnection -LocalPort 10808 -State Listen -EA 0 | Select-Object -First 1
    Write-Host "  Enhanced config applied — xray listening on 10808 (PID $(if($pidInfo){$pidInfo.OwningProcess}else{'?'}))"
    Write-Host "  Balancer: $((@($finalConfig.routing.balancers[0].selector)) -join ', ')"
    return $true
}

# ============================================================
# DISPATCH
# ============================================================

if ($Status) {
    $dir = Find-V2rayN
    if (-not $dir) { Write-Host "v2rayN not found"; return }
    Write-Host "v2rayN: $dir"
    $sqlite = Find-Sqlite3 $dir
    Write-Host "sqlite3: $(if($sqlite){$sqlite}else{'NOT FOUND'})"
    $nodes = Read-SubscriptionNodes $dir
    Write-Host "Subscription nodes in guiNDB.db: $($nodes.Count)"
    $cfg = "$dir\binConfigs\config.json"
    if (Test-Path $cfg) {
        try {
            $c = Get-Content $cfg -Raw | ConvertFrom-Json
            $px = @($c.outbounds | Where-Object { $_.protocol -ne "freedom" -and $_.protocol -ne "blackhole" })
            Write-Host "binConfigs\config.json: EXISTS ($($px.Count) proxy outbounds)"
            $hasBalancer = $c.routing.balancers -and $c.routing.balancers.Count -gt 0
            Write-Host "Balancer: $(if($hasBalancer){'YES'}else{'NO'})"
        } catch { Write-Host "binConfigs\config.json: EXISTS (unreadable: $_)" }
    } else {
        Write-Host "binConfigs\config.json: MISSING (DB mode will be used)"
    }
    # Subscription auto-update state
    $db = "$dir\guiConfigs\guiNDB.db"
    $sqliteExe = Find-Sqlite3 $dir
    if ($sqliteExe -and (Test-Path $db)) {
        $sep = [string][char]0x1F
        $rows = & $sqliteExe $db -separator $sep "SELECT Remarks, IFNULL(AutoUpdateInterval,0) FROM SubItem WHERE Enabled=1;"
        foreach ($r in $rows) { if ($r) { $f = $r -split [regex]::Escape($sep); Write-Host "Subscription: $($f[0]) auto-update: $($f[1]) min" } }
    }
    return
}

if ($SetAutoUpdate -ge 0) {
    $dir = Find-V2rayN
    if (-not $dir) { Write-Host "v2rayN not found"; return }
    $sqliteExe = Find-Sqlite3 $dir
    if (-not $sqliteExe) { Write-Host "ERROR: sqlite3 not found"; return }
    $db = "$dir\guiConfigs\guiNDB.db"
    $upd = "UPDATE SubItem SET AutoUpdateInterval=$SetAutoUpdate WHERE Enabled=1;"
    & $sqliteExe $db $upd 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Subscription auto-update set to $SetAutoUpdate min (takes effect on next v2rayN restart or 60s)."
        Write-Host "NOTE: v2rayN must be restarted for AutoUpdateInterval changes to take effect."
    } else { Write-Host "ERROR: could not update SubItem" }
    return
}

if ($DryRun) { Invoke-Enhance -dry $true; return }

if ($Apply) { Invoke-Enhance -dry $false; return }

Write-Host @"
Config Enhancer (v2rayN 7.x) — multi-server upgrade from guiNDB.db

Usage:
  powershell -File enhance-config.ps1 -Status                 # show current state
  powershell -File enhance-config.ps1 -DryRun                 # test without applying
  powershell -File enhance-config.ps1 -Apply                  # test + apply
  powershell -File enhance-config.ps1 -SetAutoUpdate 60       # enable native sub auto-update
  powershell -File enhance-config.ps1 -SqlitePath <path>      # override sqlite3 location

Modes:
  NATIVE — binConfigs\config.json exists: preserves v2rayN routing, adds nodes+balancer
  DB     — no config.json (v2rayN 7.19.5+): standalone optimized config from guiNDB.db
"@
