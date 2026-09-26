# Runs when the system is ENTERING sleep (Kernel-Power event 42).
# Arms an NDIS ETW session so the miniport's wake-reason event (10305) is recorded
# while the machine sleeps. Nothing is logged during S3, so the ETL stays tiny.
$ErrorActionPreference = 'Continue'
$dir     = 'C:\Users\jianghh\AppData\Local\HermesTools'
$etl     = Join-Path $dir 'drv-ndis-trace.etl'
$session = 'HermesNdisWake'
$state   = Join-Path $dir 'trace-arm-state.txt'
$hist    = Join-Path $dir 'trace-arm-history.log'

$msg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] arm: system entering sleep"
$msg | Set-Content -Path $state -Encoding UTF8
$msg | Add-Content -Path $hist -Encoding UTF8

logman stop $session -ets 2>&1 | Out-Null
Remove-Item $etl -Force -ErrorAction SilentlyContinue

$o1 = logman start $session -p Microsoft-Windows-NDIS 0xffffffffffffffff 4 -o $etl -f bincirc -max 256 -ct system -ets 2>&1
$o2 = logman update $session -p Microsoft-Windows-Kernel-Power 0xffffffffffffffff 4 -ets 2>&1
($o1 + $o2) | ForEach-Object { $_ | Add-Content -Path $state -Encoding UTF8 }
$running = ((((& logman query -ets 2>&1) | Out-String) -match [regex]::Escape($session)))
"[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] arm done: session-running=$running etl-present=$((Test-Path $etl))" | Add-Content -Path $hist -Encoding UTF8