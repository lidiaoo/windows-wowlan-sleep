# Runs on RESUME (Power-Troubleshooter event 1).
# Stops the NDIS ETW session armed by wake-reason-arm.ps1, converts it and writes both
#   drv-wakereason-last.txt  (machine readable marker used by resleep.ps1)
#   drv-wakereason-history.log (human readable history, last 40 entries kept)
# NDIS event 10305 carries "Wake reason: <NDIS_PM_WAKE_REASON_TYPE>".
$ErrorActionPreference = 'Continue'
$dir     = 'C:\Users\jianghh\AppData\Local\HermesTools'
$etl     = Join-Path $dir 'drv-ndis-trace.etl'
$xml     = Join-Path $dir 'drv-ndis-trace.xml'
$marker  = Join-Path $dir 'drv-wakereason-last.txt'
$history = Join-Path $dir 'drv-wakereason-history.log'
$session = 'HermesNdisWake'

$now = Get-Date
logman stop $session -ets 2>&1 | Out-Null
Start-Sleep -Seconds 2

# who/what woke us, according to Windows itself
$src = ''; $wakeTime = ''
try {
  $ev = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Power-Troubleshooter'; Id=1} -MaxEvents 1 -ErrorAction SilentlyContinue
  if ($ev) {
    $x = [xml]$ev.ToXml(); $d = @{}
    foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = [string]$n.'#text' }
    $src = [string]$d['WakeSourceText']; $wakeTime = [string]$d['WakeTime']
  }
} catch {}

$rawLines = @()
$etlPresent = (Test-Path $etl)
$etlMB = 0.0
if ($etlPresent) { try { $etlMB = [math]::Round((Get-Item $etl).Length / 1MB, 1) } catch {} }
if ($etlPresent) {
  & tracerpt $etl -o $xml -of XML -y | Out-Null
  if (Test-Path $xml) {
    foreach ($pat in @('wake signal', 'Wake reason', 'Resume reason', 'Wake Packet', 'Incoming Packet', 'reason:')) {
      $hits = @(Select-String -Path $xml -Pattern $pat -AllMatches -ErrorAction SilentlyContinue)
      foreach ($h in $hits) {
        $l = ($h.Line -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
        if ($l.Length -gt 300) { $l = $l.Substring(0, 300) }
        $rawLines += $l
      }
    }
  }
}
$rawJoined = ($rawLines | Select-Object -Unique) -join ' ;; '

$class = 'UNKNOWN'
if     ($rawJoined -eq '' -and [string]::IsNullOrWhiteSpace($src)) { $class = 'NO_DATA_EXPECTED_NON_NIC' }
elseif ($rawJoined -eq '')                                          { $class = 'NO_DATA' }
# A magic packet is reported by the miniport as a generic packet wake:
#   "The network adapter indicated a wake signal. Wake reason: Incoming Packet"
#   (NDIS_PM_WAKE_REASON_TYPE = NdisWakeReasonPacket / value 1)
# "Wake on Pattern Match" is disabled in the driver and ARP/NS are handled by firmware offload,
# so a packet wake here can only be the magic packet -> treat it as MAGIC_PACKET.
elseif ($rawJoined -match '(?i)magic|incoming packet|wake packet|reason: *1')   { $class = 'MAGIC_PACKET' }
elseif ($rawJoined -match '(?i)AP Association Lost|association lost|APDisassoc')    { $class = 'NON_MAGIC_AP_ASSOC_LOST' }
elseif ($rawJoined -match '(?i)MediaDisconnect')                                    { $class = 'NON_MAGIC_MEDIA_DISCONNECT' }
elseif ($rawJoined -match '(?i)MediaConnect')                                       { $class = 'NON_MAGIC_MEDIA_CONNECT' }
elseif ($rawJoined -match '(?i)GTK|rekey')                                          { $class = 'NON_MAGIC_GTK_REKEY' }
elseif ($rawJoined -match '(?i)4-?Way|4Way|PTK')                                    { $class = 'NON_MAGIC_4WAY_HANDSHAKE' }
elseif ($rawJoined -match '(?i)Roam')                                               { $class = 'NON_MAGIC_ROAM' }
# numeric fallback, in case a driver prints the raw NDIS_PM_WAKE_REASON_TYPE value:
#   1 = packet (magic, handled above), 2 = media disconnect, 3 = media connect,
#   4 = 4-way handshake, 5 = GTK rekey, 6 = AP disassoc, 7 = 802.11 roam
elseif ($rawJoined -match '(?i)reason: *2')                                         { $class = 'NON_MAGIC_MEDIA_DISCONNECT' }
elseif ($rawJoined -match '(?i)reason: *3')                                         { $class = 'NON_MAGIC_MEDIA_CONNECT' }
elseif ($rawJoined -match '(?i)reason: *4')                                         { $class = 'NON_MAGIC_4WAY_HANDSHAKE' }
elseif ($rawJoined -match '(?i)reason: *5')                                         { $class = 'NON_MAGIC_GTK_REKEY' }
elseif ($rawJoined -match '(?i)reason: *6')                                         { $class = 'NON_MAGIC_AP_DISASSOC' }
elseif ($rawJoined -match '(?i)reason: *7')                                         { $class = 'NON_MAGIC_ROAM' }

# single line with '|' separators on purpose: it must not depend on escape sequences or on
# line endings surviving whatever writes the file (the previous newline-joined version ended up
# as one space separated line, which silently broke the reader)
$markerText = 'v2|time=' + $now.ToString('yyyy-MM-dd HH:mm:ss') +
              '|wakeTime=' + ([string]$wakeTime) +
              '|wakeSource=' + ([string]$src -replace '\|', '/') +
              '|class=' + $class +
              '|raw=' + ($rawJoined -replace '\|', '/')
Set-Content -Path $marker -Value $markerText -Encoding UTF8

"[$($now.ToString('yyyy-MM-dd HH:mm:ss'))] class=$class etl_present=$etlPresent etl_mb=$etlMB wakeTime=$wakeTime source=$src raw=$rawJoined" | Add-Content -Path $history -Encoding UTF8
if ((Test-Path $history) -and ((Get-Item $history).Length -gt 256KB)) {
  Get-Content $history | Select-Object -Last 40 | Set-Content -Path $history -Encoding UTF8
}

Remove-Item $xml -Force -ErrorAction SilentlyContinue
# keep the raw capture so a NO_DATA can be diagnosed later (was the trace armed at all? did the
# miniport report nothing?). Only the newest file is kept, so disk cost stays bounded by -max.
if (Test-Path $etl) {
  Move-Item -Path $etl -Destination (Join-Path $dir 'drv-ndis-trace-last.etl') -Force -ErrorAction SilentlyContinue
}
# NOTE: the trace is intentionally NOT re-armed here. Keeping it armed while the machine is
# awake produced ~10 MB/min of ETL (only useful during S3). resleep.ps1 arms it when a sleep is
# imminent and wake-reason-arm.ps1 (trigger: Kernel-Power 42 = entering sleep) arms it otherwise.
"[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] capture done: etl_present=$etlPresent etl_kept_as=drv-ndis-trace-last.etl, waiting for the next sleep to re-arm" | Add-Content -Path (Join-Path $dir 'trace-arm-history.log') -Encoding UTF8