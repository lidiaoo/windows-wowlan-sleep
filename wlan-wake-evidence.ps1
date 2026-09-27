<#
  Hermes WLAN wake evidence  -  driver-independent, Windows-version-tolerant way to tell whether a
  wake was caused by the Wi-Fi link being LOST while the machine slept.

  Why this works without any vendor driver API:
    * A magic-packet wake is handled entirely in the NIC firmware, so the association is preserved;
      after the resume the station is still associated (SSID/BSSID unchanged) and the LAN answers
      almost immediately.
    * A "AP association lost" wake means the station lost the AP during sleep; after the resume the
      OS has to (re)associate - the interface is momentarily not associated, may land on a
      different BSSID, and the gateway takes noticeably longer to answer.

  Everything used here ships with the OS and has for many versions:
    netsh wlan show interfaces   (Vista+)      -> SSID / BSSID presence (labels are not localized)
    ping                         (always)      -> gateway reachability latency via the exit code only
    WLAN-AutoConfig event log    (Vista+)      -> association/disconnect events by ID (IDs are not localized)
    Get-NetRoute / route print   (Win8+ / any) -> default gateway

  Decision:
    LINK_LOST    = not associated shortly after resume, or BSSID changed, or gateway too slow
    LINK_INTACT  = associated to the same BSSID and the gateway answers quickly
    UNKNOWN      = not enough data (report says so instead of guessing)

  Output:
    os-wlanlink-evidence.txt   v2|time=..|wakeTime=..|class=..|why=..|ssid=..|bssid=..|pre=..|gwMs=..|ev=..
    os-wlanlink-evidence.log   append-only raw samples for later threshold tuning
#>
param(
  [int]$GatewayMaxWaitMs = 3000,
  [int]$PingOverallMs    = 12000
)

$ErrorActionPreference = 'Continue'
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutFile = Join-Path $BaseDir 'os-wlanlink-evidence.txt'
$OutLog  = Join-Path $BaseDir 'os-wlanlink-evidence.log'
$PreFile = Join-Path $BaseDir 'os-wlanlink-presleep.txt'

function Log3([string]$m) {
  try {
    Add-Content -Path $OutLog -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m) -Encoding UTF8
    if ((Get-Item $OutLog).Length -gt 256KB) {
      # materialise first: writing the same path while Get-Content still streams truncates it
      $keep = @(Get-Content $OutLog -ErrorAction SilentlyContinue | Select-Object -Last 200)
      if ($keep.Count -gt 0) {
        $tmp = $OutLog + '.tmp'
        Set-Content -Path $tmp -Value $keep -Encoding UTF8
        Move-Item -Path $tmp -Destination $OutLog -Force
      }
    }
  } catch {}
}

# ---- what woke us ----
$wakeTime = $null
try {
  $ev = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Power-Troubleshooter'; Id=1} -MaxEvents 1 -ErrorAction SilentlyContinue
  if ($ev) { $wakeTime = $ev.TimeCreated }
} catch {}
if (-not $wakeTime) { $wakeTime = Get-Date }

# ---- helper: parse netsh wlan show interfaces without relying on localized labels ----
function Get-WlanState {
  $r = [ordered]@{ ssid = ''; bssid = ''; raw = ''; ok = $false }
  try {
    $txt = (netsh wlan show interfaces 2>$null | Out-String)
    $r.raw = ($txt -replace "`r?`n", ' ; ')
    foreach ($line in ($txt -split "`r?`n")) {
      if ($line -match '^\s*SSID\s*:\s*(.+)$')       { if (-not $r.ssid)  { $r.ssid  = $Matches[1].Trim() } }
      if ($line -match '^\s*BSSID\s*:\s*(.+)$')      { if (-not $r.bssid) { $r.bssid = $Matches[1].Trim() } }
    }
    $r.ok = ($r.ssid -ne '')
  } catch {}
  return $r
}

# ---- pre-sleep snapshot (written by resleep.ps1 right before it suspends) ----
$preSSID = ''; $preBSSID = ''
try {
  $p = [string]((Get-Content $PreFile -Raw -ErrorAction SilentlyContinue))
  $m1 = [regex]::Match($p, 'ssid=([^|]*)'); $m2 = [regex]::Match($p, 'bssid=([^|]*)')
  if ($m1.Success) { $preSSID = $m1.Groups[1].Value.Trim() }
  if ($m2.Success) { $preBSSID = $m2.Groups[1].Value.Trim() }
} catch {}

# ---- post-resume sample (now) ----
$post = Get-WlanState

# ---- default gateway + how long it takes to answer (exit code only = locale independent) ----
$gw = ''
try { $gw = [string]((Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop) } catch {}
if (-not $gw) {
  try {
    $rl = (route print 0.0.0.0 2>$null | Out-String) -split "`r?`n"
    foreach ($l in $rl) { $f = ($l -split '\s+') | Where-Object { $_ -ne '' }; if ($f.Count -ge 3 -and $f[0] -eq '0.0.0.0') { $gw = $f[2]; break } }
  } catch {}
}
$gwMs = -1
if ($gw) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $PingOverallMs) {
    $null = & ping -n 1 -w 400 $gw 2>&1
    if ($LASTEXITCODE -eq 0) { $gwMs = [int]$sw.ElapsedMilliseconds; break }
    Start-Sleep -Milliseconds 300
  }
  if ($gwMs -lt 0) { $gwMs = $PingOverallMs }
}

# ---- OS-side WLAN events around the resume (IDs, not localized) ----
$evCounts = @{}
try {
  $w1 = $wakeTime.AddSeconds(-10); $w2 = (Get-Date).AddSeconds(5)
  Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-WLAN-AutoConfig/Operational'; StartTime=$w1; EndTime=$w2} -ErrorAction SilentlyContinue |
    ForEach-Object { $evCounts[$_.Id] = 1 + [int]$evCounts[$_.Id] }
} catch {}
$evSummary = (($evCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { $_.Key.ToString() + 'x' + $_.Value }) -join ',')

# ---- classify ----
$why = @()
if (-not $post.ok) { $why += 'not-associated-at-resume' }
if ($preBSSID -and $post.bssid -and ($preBSSID -ne $post.bssid)) { $why += 'bssid-changed' }
if ($gwMs -gt $GatewayMaxWaitMs) { $why += ('gateway-' + $gwMs + 'ms') }
$class = 'UNKNOWN'
if ($why.Count -gt 0) { $class = 'LINK_LOST' }
elseif ($post.ok -and $gwMs -ge 0) { $class = 'LINK_INTACT' }

$line = 'v2|time=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') +
        '|wakeTime=' + $wakeTime.ToString('yyyy-MM-dd HH:mm:ss') +
        '|class=' + $class +
        '|why=' + ($why -join '+') +
        '|ssid=' + $post.ssid + '|bssid=' + $post.bssid +
        '|preSSID=' + $preSSID + '|preBSSID=' + $preBSSID +
        '|gw=' + $gw + '|gwMs=' + $gwMs +
        '|ev=' + $evSummary
try { Set-Content -Path $OutFile -Value $line -Encoding ASCII } catch {}
Log3 ('class=' + $class + ' why=' + ($why -join '+') + ' gws=' + $gwMs + ' ssid=' + $post.ssid + ' bssid=' + $post.bssid + ' pre=' + $preBSSID + ' ev=' + $evSummary)
Write-Output $line