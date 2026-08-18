# v2rayN balancer rule auto-fix watcher
# Watches v2rayN config.json; when v2rayN regenerates it with the broken rule
#   {"domain": ["geosite:google"], "outboundTag": "balancer"}
# (Xray rejects outboundTag pointing at a balancer), rewrites it to balancerTag
# and restarts the xray core so the fix takes effect immediately.
$configPath = 'D:\Document\Download\v2rayN-windows-64-desktop\v2rayN-windows-64\binConfigs\config.json'
$xrayPath  = 'D:\Document\Download\v2rayN-windows-64-desktop\v2rayN-windows-64\bin\xray\xray.exe'
$utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

$last = (Get-Item $configPath).LastWriteTimeUtc
while ($true) {
    Start-Sleep -Seconds 3
    try {
        $mtime = (Get-Item $configPath).LastWriteTimeUtc
        if ($mtime -gt $last.AddSeconds(1)) {
            $last = $mtime
            Start-Sleep -Milliseconds 1500   # let v2rayN finish writing the file
            $json = Get-Content $configPath -Raw | ConvertFrom-Json
            $changed = $false
            foreach ($rule in $json.routing.rules) {
                if ($rule.domain -eq 'geosite:google' -and $rule.outboundTag -eq 'balancer') {
                    $rule.PSObject.Properties.Remove('outboundTag') | Out-Null
                    $rule | Add-Member -NotePropertyName balancerTag -NotePropertyValue 'balancer' -Force
                    $changed = $true
                }
            }
            if ($changed) {
                $text = $json | ConvertTo-Json -Depth 20
                [System.IO.File]::WriteAllText($configPath, $text, $utf8NoBom)
                Get-Process xray -ErrorAction SilentlyContinue |
                    Where-Object { $_.Path -like '*v2rayN-windows-64*' } |
                    Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
                Start-Process -WindowStyle Hidden -FilePath $xrayPath -ArgumentList @('run', '-c', $configPath)
            }
        }
    } catch {
        # transient file states (partial writes) — just retry on next poll
    }
}
