# Capture the NDIS wake reason for the next sleep -> wake cycle.
#
# NDIS event 10305 "The network adapter indicated a wake signal. Wake reason: %2"
# (plus 10302 "Resume reason" and 10325 "indicated a Wake Packet") exist only inside an ETW
# trace - they are NOT written to the event log. That is the only place Windows records *why*
# the Wi-Fi NIC woke the host (magic packet vs media disconnect vs GTK/4-way handshake vs roam).
$ErrorActionPreference = 'Continue'
$dir     = 'C:\Users\jianghh\AppData\Local\HermesTools'
$etl     = Join-Path $dir 'ndiswake.etl'
$xml     = Join-Path $dir 'ndiswake.xml'
$report  = Join-Path $dir 'wake-reason-report.txt'
$session = 'HermesNdisWake'

function R([string]$m) { "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $m" | Add-Content -Path $report -Encoding UTF8 }

"=== wake-reason capture started ===" | Set-Content -Path $report -Encoding UTF8
& logman stop $session -ets 2>$null | Out-Null
Remove-Item $etl, $xml -Force -ErrorAction SilentlyContinue

$startedUtc = (Get-Date).ToUniversalTime()

R "starting ETW trace ($session) level=4 maxsize=128MB"
$out1 = (& logman start $session -p Microsoft-Windows-NDIS 0xffffffffffffffff 4 -o $etl -f bincirc -max 256 -ct system -ets 2>&1)
$out1 | ForEach-Object { R ("logman start: " + $_) }
$out2 = (& logman update $session -p Microsoft-Windows-Kernel-Power 0xffffffffffffffff 4 -ets 2>&1)
$out2 | ForEach-Object { R ("logman update: " + $_) }
$q = (& logman query $session -ets 2>&1)
if (($q | Out-String) -match 'HermesNdisWake') { R "trace session is running" } else { R "WARNING: trace session not found"; $q | ForEach-Object { R ("query: " + $_) } }

# ---- wait for the NEXT resume (this process is frozen while the machine sleeps, which is fine) ----
$deadline = (Get-Date).AddHours(4)
$nextWake = $null
while ((Get-Date) -lt $deadline) {
  $ev = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Power-Troubleshooter'; Id=1} -MaxEvents 1 -ErrorAction SilentlyContinue
  if ($ev -and $ev.TimeCreated.ToUniversalTime() -gt $startedUtc) { $nextWake = $ev; break }
  Start-Sleep -Seconds 15
}

if ($nextWake) {
  try {
    $x = [xml]$nextWake.ToXml(); $d = @{}
    foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = [string]$n.'#text' }
    R ("resume captured: " + $nextWake.TimeCreated + "  sleep=" + $d['SleepTime'] + "  wake=" + $d['WakeTime'] + "  wakeSourceType=" + $d['WakeSourceType'] + "  wakeSourceText=" + $d['WakeSourceText'])
  } catch { R "resume captured (fields unparsed)" }
} else { R "no resume captured within 4 hours" }

Start-Sleep -Seconds 30      # let the miniport/driver flush its wake-reason events
& logman stop $session -ets | Out-Null
R "trace stopped"

if (-not (Test-Path $etl)) { R "no ETL produced -> giving up"; return }

& tracerpt $etl -o $xml -of XML -y | Out-Null
if (-not (Test-Path $xml)) { R "tracerpt produced no XML"; return }
R ("etl size = " + [math]::Round((Get-Item $etl).Length / 1MB, 1) + " MB ; xml size = " + [math]::Round((Get-Item $xml).Length / 1MB, 1) + " MB")

# every NDIS event whose payload mentions wake, plus the event IDs that carry the reason
foreach ($pat in @('wake signal', 'Wake reason', 'Resume reason', 'Wake Packet', 'MagicPacket', 'NdisWakeReason', '10305', '10302', '10325')) {
  $hits = @(Select-String -Path $xml -Pattern $pat -AllMatches -ErrorAction SilentlyContinue)
  R ("--- pattern '" + $pat + "' : " + $hits.Count + " hit(s) ---")
  foreach ($h in ($hits | Select-Object -First 12)) {
    $line = ($h.Line -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
    if ($line.Length -gt 400) { $line = $line.Substring(0, 400) }
    R ("   " + $line)
  }
}

# sleep-entry reasons for context (Kernel-Power 42 in the XML)
$kp = @(Select-String -Path $xml -Pattern 'NdisWake|Kernel-Power' -AllMatches -ErrorAction SilentlyContinue)
R ("Kernel-Power/NdisWake lines in xml: " + $kp.Count)
R "done"