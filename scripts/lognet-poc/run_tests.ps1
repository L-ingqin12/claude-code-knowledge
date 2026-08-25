# LogNet PoC one-shot validation runner (Windows PowerShell).
# Python interpreter is fixed by vault AGENTS.md rule #10.
$ErrorActionPreference = 'Stop'
$py = 'D:\ProgramData\miniconda3\python.exe'
Set-Location $PSScriptRoot

Write-Output '===== unittest discover ====='
& $py -m unittest discover -s . -p "test_*.py" -v
if ($LASTEXITCODE -ne 0) { Write-Output 'UNITTEST FAILED'; exit 1 }

Write-Output '===== CLI smoke: build / query / subgraph ====='
$smokeRoot = Join-Path $env:TEMP ("lognet-smoke-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$pkg = Join-Path $smokeRoot 'pkg'
$db  = Join-Path (Join-Path $smokeRoot 'out') 'lognet.db'
& $py -m tests.synth_gen $pkg | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Output 'SYNTH FAILED'; exit 1 }
& $py -m lognet_poc build $pkg --db $db
if ($LASTEXITCODE -ne 0) { Write-Output 'BUILD FAILED'; exit 1 }
& $py -m lognet_poc query --db $db --keyword ext4_io_error --limit 3
if ($LASTEXITCODE -ne 0) { Write-Output 'QUERY FAILED'; exit 1 }
$hit = & $py -m lognet_poc query --db $db --keyword watchdog --limit 1 | Select-String '^#(\d+)' | Select-Object -First 1
if (-not $hit) { Write-Output 'NO QUERY HIT'; exit 1 }
$sid = $hit.Matches[0].Groups[1].Value
& $py -m lognet_poc subgraph --db $db --node $sid --depth 2 --window 5
if ($LASTEXITCODE -ne 0) { Write-Output 'SUBGRAPH FAILED'; exit 1 }

Write-Output '===== FTS P95 benchmark ====='
& $py tests\bench_fts_p95.py
exit $LASTEXITCODE
