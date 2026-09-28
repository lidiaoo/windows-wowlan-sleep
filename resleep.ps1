<#
  Hermes AutoReSleep  -  put the PC back to sleep after an automatic wake when nobody needs it.

  Two-tier rule:
    A) UNATTENDED WAKE: the wake source was the Wi-Fi NIC and *nobody has touched the machine
       since it last went to sleep* (raw GetLastInputInfo tick compared against the value saved
       just before the sleep, so post-resume clock corrections cannot fool it).
       -> wait only $PostWakeGraceSeconds (default 60 s, so a remote session can connect) and
          then go straight back to sleep. No 10-minute wait.
    B) ANY OTHER RUN (someone touched it since the sleep, the wake was long ago, or the wake
       source is not the Wi-Fi NIC): the conservative $IdleMinutes of real keyboard/mouse idle
       is required, so this never fights a human.

  Guards (all logged):
    * wake source gate   - only wakes attributed to the Wi-Fi NIC are eligible ("wake-source-*").
                           The attribution is rebuilt from the adapters present on THIS machine
                           (their descriptions, powercfg /lastwake, powercfg /devicequery
                           wake_armed), never from a NIC model name written into this script: a
                           swapped card or a plain driver reinstall changes the name Windows puts
                           into the wake source, and a hardcoded name then classifies every wake as
                           "not the NIC" while the reason chain says the opposite.
                           kinds: wifi-nic | eth-nic | other-device | timer | fixed-feature |
                           fixed-feature-nic-suspect (no device named, no wake timer programmed,
                           NICs are the only wake-armed devices -> probably a NIC wake routed
                           through the embedded controller; eligible only with
                           -UnattributedWakePolicy=resleep-if-unattended)
    * link-state hint    - os-wlanlink-evidence LINK_LOST is a HINT only: every resume re-associates,
                           so it also fires on magic-packet wakes (see 00-README 8). It produces
                           NON_MAGIC_WLAN_LINK_LOST only for a wifi-nic wake; otherwise it shows up
                           as link=... in the log line and decides nothing.
    * magic packet gate  - if the NDIS ETW capture (drv-wakereason-last.txt) says this wake was a
                           magic packet, never re-sleep (MagicPacketPolicy=skip).
    * remote-in-use gate - an established *inbound* TCP connection (remote desktop / RustDesk /
                           VNC ...) blocks the sleep.
    * display / media / update gates, and an anti-thrash gap of $MinGapMinutes.

  Wake-reason trace management (why it lives here):
    The NDIS wake reason (ETW event 10305 "Wake reason: ...") is only recorded while an ETW
    session is armed, and it must be armed BEFORE the machine suspends. This script therefore
      - arms the trace once the machine has been idle for $ArmIdleSeconds (a sleep is plausible;
        this covers sleeps the OS itself starts from its own idle timer, which the
        Kernel-Power-42 task can miss because the transition happens immediately),
      - arms it right before it suspends the machine itself,
      - disarms it again when the user comes back (idle < 60 s) or after $ArmMaxMinutes,
      - wake-reason-capture.ps1 (resume trigger) stops it, parses it and records the reason.
    Every arm/disarm decision goes to trace-arm-history.log (append only).

  Must run inside the interactive user session (GetLastInputInfo reports the calling session's
  input; a SYSTEM/session-0 task would always see "idle forever").

  Log: <script dir>\dec-resleep.log (rotates at 1 MB) ; trace log: trace-arm-history.log
#>
param(
  [switch]$DryRun,
  [int]$IdleMinutes = 2,
  [int]$MinGapMinutes = 0,
  [int]$UserPresentSkipLogMinutes = 5,
  [ValidateSet('wifi','any')][string]$WakeSourceFilter = 'wifi',
  [ValidateSet('skip','resleep-if-unattended')][string]$UnattributedWakePolicy = 'skip',
  [bool]$SkipIfRemoteSession = $true,
  [ValidateSet('skip','ignore')][string]$MagicPacketPolicy = 'skip',
  [int]$WakeSourceMaxAgeMinutes = 0,
  [int]$PostWakeWindowMinutes = 60,
  [int]$PostWakeGraceSeconds = 60,
  [int]$UnknownIdleMinutes = 15,
  [int]$ArmIdleSeconds = 600,
  [int]$ArmMaxMinutes = 45
)

$ErrorActionPreference = 'Continue'
$BaseDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile   = Join-Path $BaseDir 'dec-resleep.log'
$StampFile = Join-Path $BaseDir 'state-last-forced-sleep.txt'
$SkipFile  = Join-Path $BaseDir 'state-last-user-present-skip.txt'
$TickFile  = Join-Path $BaseDir 'state-input-tick-at-sleep.txt'
$DllPath   = Join-Path $BaseDir 'NativeIdle2.dll'
$EtlPath   = Join-Path $BaseDir 'drv-ndis-trace.etl'
$TraceLog  = Join-Path $BaseDir 'trace-arm-history.log'
$ArmMarker = Join-Path $BaseDir 'trace-armed-since.txt'
$TraceSession = 'HermesNdisWake'

function Log([string]$m) {
  try { Add-Content -Path $LogFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m) -Encoding UTF8 } catch {}
}
function TraceLog([string]$m) {
  try {
    Add-Content -Path $TraceLog -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  resleep: ' + $m) -Encoding UTF8
    if ((Get-Item $TraceLog).Length -gt 512KB) {
      # materialise the kept lines FIRST: piping Get-Content straight into Set-Content on the same
      # path lets the writer truncate the file while the reader is still streaming through it, and
      # the log collapses to whatever happened to be buffered (that cost the whole history once)
      $keep = @(Get-Content $TraceLog -ErrorAction SilentlyContinue | Select-Object -Last 200)
      if ($keep.Count -gt 0) {
        $tmp = $TraceLog + '.tmp'
        Set-Content -Path $tmp -Value $keep -Encoding UTF8
        Move-Item -Path $tmp -Destination $TraceLog -Force
      }
    }
  } catch {}
}

# ---- rotate dec-resleep.log at 1 MB (read into memory before writing: see the note above) ----
try {
  if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1MB)) {
    $keep = @(Get-Content $LogFile -ErrorAction SilentlyContinue | Select-Object -Last 2000)
    if ($keep.Count -gt 0) {
      $tmp = $LogFile + '.tmp'
      Set-Content -Path $tmp -Value $keep -Encoding UTF8
      Move-Item -Path $tmp -Destination $LogFile -Force
    }
  }
} catch {}

# ---- native helper: precompiled DLL (fast) with compile fallback ----
$src = @"
using System;
using System.Runtime.InteropServices;
public static class Native {
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  [DllImport("powrprof.dll", SetLastError=true)] static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);
  static bool Raw(out uint tick) {
    LASTINPUTINFO li = new LASTINPUTINFO();
    li.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
    tick = 0;
    if (!GetLastInputInfo(ref li)) return false;
    tick = li.dwTime;
    return true;
  }
  public static double IdleSeconds() {
    uint t; if (!Raw(out t)) return -1;
    return ((uint)Environment.TickCount - t) / 1000.0;
  }
  // raw tick of the last input - comparing two values (instead of a delta) survives the clock
  // and tick corrections that happen right after a resume
  public static string InputTick() {
    uint t; if (!Raw(out t)) return "";
    return t.ToString();
  }
  public static bool Suspend() { return SetSuspendState(false, true, false); }
}
"@
# A shipped prebuilt DLL that fails to load (wrong bitness, blocked, truncated copy) must not
# leave the script without the native helper - try to compile it from the source above instead.
$helperOk = $false
if (Test-Path $DllPath) { try { Add-Type -Path $DllPath -ErrorAction Stop; $helperOk = $true } catch {} }
if (-not $helperOk) {
  try { Add-Type -TypeDefinition $src -OutputAssembly $DllPath -ErrorAction Stop } catch {}
  try { Add-Type -Path $DllPath -ErrorAction Stop; $helperOk = $true } catch { try { Add-Type -TypeDefinition $src -ErrorAction Stop; $helperOk = $true } catch {} }
}

# ---- ETW trace control ----
function TraceArmed {
  try { return ((((& logman query -ets 2>&1) | Out-String) -match [regex]::Escape($TraceSession))) } catch { return $false }
}
function ArmTrace([string]$reason) {
  try {
    & logman stop $TraceSession -ets 2>&1 | Out-Null
    Remove-Item $EtlPath -Force -ErrorAction SilentlyContinue
    $null = (& logman start $TraceSession -p Microsoft-Windows-NDIS 0xffffffffffffffff 4 -o $EtlPath -f bincirc -max 64 -ct system -ets 2>&1)
    $null = (& logman update $TraceSession -p Microsoft-Windows-Kernel-Power 0xffffffffffffffff 4 -ets 2>&1)
    $running = TraceArmed
    if (-not $running) {
      # seen in practice right after a stop: retry once, otherwise the wake reason for the sleep
      # that follows cannot be captured at all
      Start-Sleep -Milliseconds 800
      $null = (& logman start $TraceSession -p Microsoft-Windows-NDIS 0xffffffffffffffff 4 -o $EtlPath -f bincirc -max 64 -ct system -ets 2>&1)
      $null = (& logman update $TraceSession -p Microsoft-Windows-Kernel-Power 0xffffffffffffffff 4 -ets 2>&1)
      $running = TraceArmed
    }
    if ($running) { Set-Content -Path $ArmMarker -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Encoding ASCII }
    TraceLog ('ARM    reason=' + $reason + '  session-running=' + $running)
    return $running
  } catch { TraceLog ('ARM-FAIL reason=' + $reason + '  ' + $_.Exception.Message); return $false }
}
function StopTrace([string]$reason) {
  try { & logman stop $TraceSession -ets 2>&1 | Out-Null } catch {}
  Remove-Item $ArmMarker -Force -ErrorAction SilentlyContinue
  TraceLog ('DISARM reason=' + $reason)
}

# ---------------- user input idle + raw tick ----------------
$idle = -1.0
$inputTick = ''
$helperOk = $false
try {
  $idle = [Native]::IdleSeconds()
  $inputTick = [string][Native]::InputTick()
  $helperOk = $true
} catch { Log ('ERROR helper unavailable: ' + $_.Exception.Message) }
if (-not $helperOk) { exit 1 }

# ---------------- which adapters can wake THIS machine (live inventory, no model names in code) --
# A wake is attributed to a device by NAME only, and that name is the adapter description: it
# changes when the card is swapped and even on a plain driver reinstall (Windows appends " #2").
# Keep the name set out of the script and rebuild it from the machine on every run.
$wlanDesc = @(); $ethDesc = @()
try {
  foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
    $ad = ([string]$a.InterfaceDescription).Trim()
    if (-not $ad) { continue }
    if ($a.MediaType -eq 'Native 802.11' -or $ad -match '(?i)wi-fi|wireless|wlan|802.11') { $wlanDesc += $ad }
    elseif ($ad -match '(?i)ethernet|gigabit')                                               { $ethDesc  += $ad }
  }
} catch {}
function Expand-NameToken([string[]]$tokens) {
  # WakeSourceText carries the plain description; the " #N" suffix of a reinstall is not part of
  # it, so both spellings have to be tried
  $r = @()
  foreach ($t in $tokens) {
    if (-not $t) { continue }
    $r += $t
    $b = ($t -replace ' #+[0-9]+$', '').Trim()
    if ($b -and $b -ne $t) { $r += $b }
  }
  return @($r | Select-Object -Unique)
}
function Find-NameToken([string]$text, [string[]]$tokens) {
  if ([string]::IsNullOrWhiteSpace($text)) { return '' }
  foreach ($t in $tokens) { if ($t -and $text.IndexOf($t, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $t } }
  return ''
}
$wlanTokens = Expand-NameToken $wlanDesc
$ethTokens  = Expand-NameToken $ethDesc

# ---------------- what woke the system last? (Power-Troubleshooter event 1) ----------------
$wakeKind = 'unknown'
$wakeText = ''
$wakeType = ''
$wakeTime = $null
$wakeWho  = ''
try {
  $ev = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Power-Troubleshooter'; Id=1} -MaxEvents 1 -ErrorAction SilentlyContinue
  if ($ev) {
    $x = [xml]$ev.ToXml()
    $d = @{}
    foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = [string]$n.'#text' }
    $wakeText = [string]$d['WakeSourceText']
    $wakeType = [string]$d['WakeSourceType']
    if ($d['WakeTime']) { try { $wakeTime = ([datetime]$d['WakeTime']).ToLocalTime() } catch {} }
  } else { $wakeKind = 'no-wake-event' }
} catch { $wakeKind = 'wake-read-error' }

if ($wakeKind -eq 'unknown') {
  $hitW = Find-NameToken $wakeText $wlanTokens
  $hitE = Find-NameToken $wakeText $ethTokens
  if     ($hitW) { $wakeKind = 'wifi-nic'; $wakeWho = 'name:' + $hitW }
  elseif ($hitE) { $wakeKind = 'eth-nic';  $wakeWho = 'name:' + $hitE }
  elseif ($wakeText -match '(?i)wi-fi|wireless|wlan|802.11') { $wakeKind = 'wifi-nic'; $wakeWho = 'name:generic-wlan' }
  elseif ($wakeText -match '(?i)ethernet|gigabit')           { $wakeKind = 'eth-nic';  $wakeWho = 'name:generic-eth' }
  else {
    # Windows named no device. Ask the OS a second time (powercfg /lastwake prints the same names -
    # its labels are localized, an adapter name is not), then look for a sign that the wake was
    # intentional after all: a programmed wake timer, or a wake-armed device that is not one of
    # our NICs (its line is the one that does not match any adapter description).
    $lwText = ''
    try { $lwText = ((& powercfg /lastwake 2>$null) | Out-String) } catch {}
    $hitLW = Find-NameToken $lwText $wlanTokens
    $hitLE = Find-NameToken $lwText $ethTokens
    $armedText = ''
    try { $armedText = ((& powercfg /devicequery wake_armed 2>$null) | Out-String) } catch {}
    $armedWlan  = (Find-NameToken $armedText $wlanTokens) -ne ''
    $armedOther = 0
    foreach ($al in ($armedText -split "`r?`n")) {
      $at = $al.Trim(); if ($at -eq '') { continue }
      if ((Find-NameToken $at $wlanTokens) -eq '' -and (Find-NameToken $at $ethTokens) -eq '') { $armedOther++ }
    }
    $timerProgrammed = $false
    try {
      $kp = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=107} -MaxEvents 1 -ErrorAction SilentlyContinue
      if ($kp) {
        $xp = [xml]$kp.ToXml()
        foreach ($pn in $xp.Event.EventData.Data) {
          $pv = [string]$pn.'#text'
          if (($pn.Name -like 'ProgrammedWakeTime*') -and $pv -and ($pv -notlike '1601-01-01*')) { $timerProgrammed = $true }
        }
      }
    } catch {}
    if     ($hitLW)           { $wakeKind = 'wifi-nic'; $wakeWho = 'lastwake:' + $hitLW }
    elseif ($hitLE)           { $wakeKind = 'eth-nic';  $wakeWho = 'lastwake:' + $hitLE }
    elseif ($timerProgrammed) { $wakeKind = 'timer';    $wakeWho = 'kernel-power-107' }
    else {
      $wakeKind = 'fixed-feature'
      # On some machines a NIC wake is handed to Windows through the embedded controller: the wake
      # is reported as a fixed feature (powercfg prints the power button), no device name, no NDIS
      # wake-signal event. If the only wake-armed devices are NICs and no timer was programmed,
      # the wake was very likely a NIC anyway - record that, but never as a certainty.
      if ($armedWlan -and $armedOther -eq 0) { $wakeKind = 'fixed-feature-nic-suspect'; $wakeWho = 'only-nic-armed' }
      else { $wakeWho = 'armed-non-nic=' + $armedOther }
    }
  }
}
$wakeStamp = '?'
if ($wakeTime) { $wakeStamp = $wakeTime.ToString('MM-dd HH:mm:ss') }

# ---------------- NDIS ETW wake-reason marker ----------------
# wake-reason-capture.ps1 (resume trigger) records the miniport's own wake reason
# (NDIS event 10305) and writes drv-wakereason-last.txt. Only trust it when it describes
# the same wake we are looking at.
$reasonClass = 'UNKNOWN'
$reasonRaw   = ''
$drvWlanSignal = $false
try {
  $mk = Join-Path $BaseDir 'drv-wakereason-last.txt'
  if (Test-Path $mk) {
    # field extraction by regex: separator agnostic (the on-disk separator must not matter)
    $txt = (Get-Content $mk -Raw -ErrorAction SilentlyContinue)
    if ($txt) {
      $mWake = [regex]::Match($txt, 'wakeTime=([0-9T:.Z+-]+)')
      $mCls  = [regex]::Match($txt, 'class=([A-Za-z_]+)')
      $mRaw  = [regex]::Match($txt, 'raw=(.*)')
      if ($mWake.Success -and $mCls.Success -and $wakeTime) {
        try {
          $mw = ([datetime]$mWake.Groups[1].Value).ToLocalTime()
          if ([math]::Abs(($mw - $wakeTime).TotalSeconds) -lt 15) {
            $reasonClass = [string]$mCls.Groups[1].Value
            if ($mRaw.Success) { $reasonRaw = [string]$mRaw.Groups[1].Value }
            # "The network adapter indicated a wake signal ... Wake reason: X" is the interface
            # telling Windows that IT woke the host. Only the Wi-Fi-specific reasons may be used to
            # name the Wi-Fi NIC as the wake source: a wired NIC can report media (cable) changes,
            # never "AP Association Lost".
            if ($reasonRaw -match '(?i)wake signal' -and
                $reasonClass -match '^NON_MAGIC_(AP_ASSOC_LOST|AP_DISASSOC|ROAM|GTK_REKEY|4WAY_HANDSHAKE)$') {
              $drvWlanSignal = $true
            }
          }
        } catch {}
      }
    }
  }
} catch {}

# ---------------- attribution upgrade: the driver's own wake signal ----------------
# The OS attribution above is not always able to name the device (after the Wi-Fi card was swapped
# this box reports "fixed feature / power button" for every wake), yet the miniport still reports a
# wake signal. When it does, and names a Wi-Fi-only reason, the wake WAS the Wi-Fi NIC - and a
# driver-reported non-magic wake is exactly the case that has to go back to sleep.
if ($drvWlanSignal -and ($wakeKind -ne 'wifi-nic') -and ($wakeKind -ne 'eth-nic')) {
  $wakeKind = 'wifi-nic'
  $wakeWho  = 'driver:' + $reasonClass
}

# ---------------- UDP magic-packet / marker evidence ----------------
# wol-listener.ps1 records the last magic packet (or sender marker) it received. A WoL sender
# usually emits a burst, and/or the sender also hits the marker port, so a packet seen right
# around the wake is strong evidence that this wake was asked for.
$udpMagic = ''
try {
  $ml = Join-Path $BaseDir 'pkt-magicpacket-last.txt'
  if ((Test-Path $ml) -and $wakeTime) {
    # the listener writes "<unixSeconds> <kind>" (kind = magic | marker): split on the space only
    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($ml) } catch {}
    $parts = @($raw.Trim() -split ' +')
    # two accepted shapes:  "<unixSeconds> <kind>"  (new listener)  or  "v2|time=...|kind=..." (old)
    $epoch = -1
    $kind = ''
    if ($parts.Count -ge 2 -and $parts[0] -match '^[0-9]+$') {
      $epoch = [int]$parts[0]
      $kind = [string]$parts[1]
    } else {
      $mT = [regex]::Match($raw, 'time=([0-9]+-[0-9]+-[0-9]+ [0-9]+:[0-9]+:[0-9]+)')
      $mK = [regex]::Match($raw, 'kind=([A-Za-z]+)')
      if ($mT.Success -and $mK.Success) {
        try {
          $dt = [datetime]::Parse($mT.Groups[1].Value.Trim())
          $epoch = [int](([System.DateTimeOffset]::new($dt)).ToUnixTimeSeconds())
          $kind = [string]$mK.Groups[1].Value
        } catch {}
      }
    }
    if ($epoch -gt 0 -and $kind -ne '') {
      # compare AGES, not wall clocks: both are differences measured in their own clock family,
      # so no UTC<->local conversion is involved and the Kind pitfalls of DateTime cannot bite
      $packetAge = ([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) - $epoch
      $wakeAge   = ((Get-Date) - $wakeTime).TotalSeconds
      $rel = $wakeAge - $packetAge          # > 0 => the packet arrived after the wake
      if ($rel -ge -10 -and $rel -le 180) {
        $reasonClass = 'MAGIC_PACKET'
        $udpMagic = $kind + '@+' + [int]$rel + 's'
      }
    }
  }
} catch {}

# ---------------- where did the classification come from, and make the history agree ----------------
# dec-resleep.log is the *decision* log and merges two chains (NDIS wake reason + UDP listener evidence),
# while dec-wakereason-history.log is written by the capture task from the NDIS side only. So a wake
# classified as magic from the listener evidence used to show up in dec-resleep.log but not in the
# history file. Record it here as well (one line per wake+class, deduped).
# ---------------- OS-level WLAN link evidence (driver independent) ----------------
# wlan-wake-evidence.ps1 compares the pre-sleep SSID/BSSID with the post-resume one and measures how
# fast the default gateway answers. That state is a HINT, not a cause: every resume re-associates
# (or roams between APs), so "not associated right after the resume" also shows up on wakes that
# were definitely asked for - this box produced LINK_LOST on the magic-packet wake of 12:00
# (bssid-changed) and LINK_INTACT on the one at 12:40. It may therefore only contribute the
# NON_MAGIC_WLAN_LINK_LOST verdict when the wake itself is attributed to the Wi-Fi NIC; otherwise
# it goes into the log as link=... and decides nothing.
$wlanEvidence = ''
$wlanWhy = ''
$wlanHint = ''
try {
  $we = Join-Path $BaseDir 'os-wlanlink-evidence.txt'
  if ((Test-Path $we) -and $wakeTime -and ($reasonClass -eq 'UNKNOWN' -or $reasonClass -like 'NO_DATA*')) {
    $etxt = [string]((Get-Content $we -Raw -ErrorAction SilentlyContinue))
    $mEw = [regex]::Match($etxt, 'wakeTime=([0-9-]+ [0-9:]+)')
    $mEc = [regex]::Match($etxt, 'class=([A-Za-z_]+)')
    $mEy = [regex]::Match($etxt, 'why=([^|]*)')
    if ($mEw.Success -and $mEc.Success) {
      try {
        $ewt = [datetime]::Parse($mEw.Groups[1].Value.Trim())
        if ([math]::Abs(($ewt - $wakeTime).TotalSeconds) -lt 45) {
          $wlanEvidence = $mEc.Groups[1].Value.Trim()
          if ($mEy.Success) { $wlanWhy = $mEy.Groups[1].Value.Trim() }
          if ($wlanEvidence -eq 'LINK_LOST') {
            if ($wakeKind -eq 'wifi-nic') { $reasonClass = 'NON_MAGIC_WLAN_LINK_LOST' }
            else { $wlanHint = 'LINK_LOST' }
          } else { $wlanHint = $wlanEvidence }
        }
      } catch {}
    }
  }
} catch {}

$reasonSrc = 'ndis-marker-or-none'
if ($udpMagic) { $reasonSrc = 'udp-listener' }
if ($reasonClass -eq 'NON_MAGIC_WLAN_LINK_LOST') { $reasonSrc = 'wlan-evidence' }
try {
  if ($reasonClass -ne 'UNKNOWN' -and $wakeTime) {
    $hFile  = Join-Path $BaseDir 'dec-wakereason-history.log'
    $hMark  = Join-Path $BaseDir 'state-reason-history-last.txt'
    $stamp  = $wakeTime.ToString('yyyy-MM-dd HH:mm:ss') + '|' + $reasonClass + '|' + $reasonSrc
    $last   = ''
    try { $last = [string]((Get-Content $hMark -Raw)).Trim() } catch {}
    if ($last -ne $stamp) {
      Set-Content -Path $hMark -Value $stamp -Encoding ASCII
      ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] class=' + $reasonClass + ' reason-src=' + $reasonSrc +
       ' udp=' + $udpMagic + ' wakeTime=' + $wakeTime.ToString('yyyy-MM-dd HH:mm:ss') +
       ' source=resleep-decision') | Add-Content -Path $hFile -Encoding UTF8
    }
  }
} catch {}

# ---------------- unattended-wake detection (tier A) ----------------
# A wake the OS cannot attribute to a device, but which can only have come from a NIC (see the
# classification above), counts as a NIC wake only when -UnattributedWakePolicy allows it. With the
# default ('skip') the engine keeps its hands off unattributed wakes: honest, but it means such a
# wake is never re-slept until the driver or the OS starts naming the NIC again.
$nicWakeEligible = ($wakeKind -eq 'wifi-nic') -or (($wakeKind -eq 'fixed-feature-nic-suspect') -and ($UnattributedWakePolicy -eq 'resleep-if-unattended'))
$sinceWakeSec = -1
if ($wakeTime -and $nicWakeEligible) { $sinceWakeSec = ((Get-Date) - $wakeTime).TotalSeconds }
# this box's clock gets re-synced in jumps (we have seen +- minutes); a negative value just means
# "the wake is right now" - clamp it instead of disabling the fast path
if ($sinceWakeSec -lt 0 -and $sinceWakeSec -gt -600) { $sinceWakeSec = 0 }
$postWake = ($sinceWakeSec -ge 0 -and $sinceWakeSec -le ($PostWakeWindowMinutes * 60))

$noInputSinceSleep = $false
try {
  if (Test-Path $TickFile) {
    $vals = (Get-Content $TickFile -Raw).Trim() -split ';'
    if ($vals.Count -ge 2 -and $vals[1].Trim() -ne '' -and $inputTick -ne '') {
      $noInputSinceSleep = ([string]$vals[1].Trim() -eq [string]$inputTick)
    }
  }
} catch {}
# only trust the tick comparison when that sleep happened before this wake
if ($noInputSinceSleep -and (Test-Path $TickFile)) {
  try {
    $st = [datetime]::Parse(((Get-Content $TickFile -Raw).Trim() -split ';')[0].Trim())
    if ($wakeTime -and $st -gt $wakeTime) { $noInputSinceSleep = $false }
  } catch {}
}

# ---------------- is somebody connected inwards right now? ----------------
$inboundCount = 0
$inboundInfo  = ''
if ($SkipIfRemoteSession) {
  try {
    $lp  = @((Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue).LocalPort | Select-Object -Unique)
    $inb = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
             Where-Object { ($lp -contains $_.LocalPort) -and ($_.RemoteAddress -notmatch '^(127\.|::1|0\.0\.0\.0|::$)') })
    $inboundCount = $inb.Count
    if ($inboundCount -gt 0) {
      $parts = @()
      foreach ($c in ($inb | Select-Object -First 6)) {
        $pn = (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        $parts += ("$($c.RemoteAddress):$($c.RemotePort)->$($c.LocalPort)/$pn")
      }
      $inboundInfo = ' inbound=[' + ($parts -join ',') + ']'
    }
  } catch { $inboundInfo = ' inbound-check-error' }
}

# ---------------- powercfg /requests ----------------
# Section headers are localized but always appear in this fixed order:
# DISPLAY, SYSTEM, AWAYMODE, EXECUTION, PERFBOOST, ACTIVELOCKSCREEN
$names = @('Display','System','AwayMode','Execution','PerfBoost','ActiveLockScreen')
$sections = @{}
foreach ($n in $names) { $sections[$n] = @() }
$seen = 0
$idx = -1
foreach ($line in ((& powercfg /requests 2>$null) | Out-String) -split "`r?`n") {
  if ($line -match '^\s*[^:]+:\s*$') { $idx++; $seen++; continue }
  if ($idx -ge 0 -and $idx -lt $names.Count -and $line.Trim() -ne '') { $sections[$names[$idx]] += $line.Trim() }
}
# fail safe: if powercfg output could not be read/parsed (e.g. not elevated), never suspend
# (this doubles as the elevation test for the ETW trace control below)
$parsed = ($seen -ge 4)

$execProcs     = @($sections['Execution'] | Where-Object { $_ -match '\.exe' } | ForEach-Object { Split-Path $_ -Leaf } | Select-Object -Unique)
$displayActive = @($sections['Display'] | Where-Object { $_ -match '\.exe' }).Count -gt 0
$allLines      = $sections.Values | ForEach-Object { $_ }
# ASCII-only on purpose: PowerShell 5.1 parses .ps1 as ANSI when the file has no BOM, so any
# non-ASCII literal can corrupt the parse. The app-level audio reason is English ("Playing audio")
# even on a Chinese Windows, which is what this matches.
$audioText     = @($allLines | Where-Object { $_ -match '(?i)Playing audio|audio stream' }).Count -gt 0
$audioActive   = $audioText -and ($execProcs.Count -gt 0)
$updateActive  = @($allLines | Where-Object { $_ -match '(?i)MoUsoCoreWorker|TiWorker|TrustedInstaller|WindowsUpdate|wusa' }).Count -gt 0

# ---------------- keep the wake-reason trace armed around a sleep ----------------
if ($parsed) {
  try {
    if (-not (TraceArmed)) {
      # idle long enough that a sleep is plausible -> arm so the reason is captured if it sleeps
      if ($idle -ge $ArmIdleSeconds) { [void](ArmTrace ('idle-approach idle=' + [int]$idle + 's armAt=' + $ArmIdleSeconds + 's')) }
    } else {
      $disarm = ''
      if ($idle -lt 60) { $disarm = 'user-returned idle=' + [int]$idle + 's' }
      else {
        try {
          # the listener arms the session as well and does not write this marker; adopt such a
          # session instead of throwing away the age check (a missing file used to produce a
          # PathNotFound error every run and left the trace armed indefinitely)
          if (-not (Test-Path $ArmMarker)) { Set-Content -Path $ArmMarker -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Encoding ASCII }
          $since = [datetime]::Parse((Get-Content $ArmMarker -Raw).Trim())
          if (((Get-Date) - $since).TotalMinutes -gt $ArmMaxMinutes) { $disarm = 'armed-too-long minutes=' + [int]((Get-Date) - $since).TotalMinutes }
        } catch {}
      }
      if ($disarm -ne '') { StopTrace $disarm }
    }
  } catch {}

  # keep the WoL listener alive: it detects magic packets and keeps the trace armed at 10 s
  # granularity, which a 2-minute poll cannot do
  try {
    $lock = Join-Path $BaseDir 'pkt-listener.lock'
    $alive = $false
    if (Test-Path $lock) {
      try { $owner = [int](Get-Content $lock -Raw).Trim(); if (Get-Process -Id $owner -ErrorAction SilentlyContinue) { $alive = $true } } catch {}
    }
    if (-not $alive) {
      Start-Process -FilePath 'wscript.exe' -ArgumentList @('//B', '//Nologo', (Join-Path $BaseDir 'run-hidden.vbs'), (Join-Path $BaseDir 'wol-listener.ps1')) -WindowStyle Hidden
      TraceLog 'listener (re)started by resleep'
    }
  } catch {}
}

# ---------------- minimum gap between our own forced sleeps (anti-thrash) ----------------
$gapOk = $true
if (Test-Path $StampFile) {
  try {
    $last = [datetime]::Parse((Get-Content $StampFile -Raw).Trim())
    if (((Get-Date) - $last).TotalMinutes -lt $MinGapMinutes) { $gapOk = $false }
  } catch {}
}

$detail = 'wake=' + $wakeKind + '@' + $wakeStamp + '  who=' + $wakeWho + '  reason=' + $reasonClass + '  src=' + $reasonSrc + '  link=' + $wlanHint + '  udp=[' + $udpMagic + ']' +
          '  unattended=' + ($postWake -and $noInputSinceSleep) + '  sinceWake=' + [int]$sinceWakeSec + 's' +
          '  idle=' + [int]$idle + 's  sections=' + $seen +
          '  display=' + $displayActive + '  audio=' + $audioActive + '  update=' + $updateActive +
          '  inbound=' + $inboundCount + '  gap=' + $gapOk + $inboundInfo

# ---------------- tier A: short grace instead of the long idle rule ----------------
if ($postWake -and $noInputSinceSleep -and -not $DryRun -and $sinceWakeSec -lt $PostWakeGraceSeconds) {
  $wait = [int][math]::Ceiling($PostWakeGraceSeconds - $sinceWakeSec)
  if ($wait -gt 90) { $wait = 90 }
  if ($wait -gt 1) {
    Log ('WAIT   post-wake grace ' + $wait + 's before re-check   ' + $detail)
    Start-Sleep -Seconds $wait
    $sinceWakeSec = ((Get-Date) - $wakeTime).TotalSeconds
    # re-check the two things that could have changed in the meantime
    try { if ([string][Native]::InputTick() -ne [string]$inputTick) { $noInputSinceSleep = $false } } catch {}
    if ($SkipIfRemoteSession) {
      try {
        $lp2  = @((Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue).LocalPort | Select-Object -Unique)
        $inb2 = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
                  Where-Object { ($lp2 -contains $_.LocalPort) -and ($_.RemoteAddress -notmatch '^(127\.|::1|0\.0\.0\.0|::$)') })
        $inboundCount = $inb2.Count
        if ($inboundCount -gt 0) {
          $parts = @()
          foreach ($c in ($inb2 | Select-Object -First 6)) {
            $pn = (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            $parts += ("$($c.RemoteAddress):$($c.RemotePort)->$($c.LocalPort)/$pn")
          }
          $inboundInfo = ' inbound=[' + ($parts -join ',') + ']'
        } else { $inboundInfo = '' }
      } catch {}
    }
  }
}

$why = @()
if ($WakeSourceFilter -eq 'wifi' -and -not $nicWakeEligible) { $why += ('wake-source-' + $wakeKind) }
if ($MagicPacketPolicy -eq 'skip' -and $reasonClass -eq 'MAGIC_PACKET') {
  if ($udpMagic) { $why += ('magic-packet-wake-udp-' + $udpMagic) } else { $why += 'magic-packet-wake' }
}
if ($WakeSourceMaxAgeMinutes -gt 0 -and $wakeTime -and (((Get-Date) - $wakeTime).TotalMinutes -gt $WakeSourceMaxAgeMinutes)) { $why += 'wake-too-old' }
if ($reasonClass -eq 'MAGIC_PACKET') {
  # already flagged by the magic-packet gate above (that gate only adds a reason when
  # MagicPacketPolicy=skip); nothing else to add -> the machine stays awake
} elseif ($reasonClass -notlike 'NON_MAGIC*') {
  # the wake reason is unknown / was not reported by the miniport -> be conservative: never
  # fast-sleep on a guess. Require a long local idle instead. A remote session keeps the machine
  # awake through the remote-in-use gate, so "magic packet, then connect remotely" still works.
  if ($idle -lt 0)                              { $why += 'idle-unknown' }
  elseif ($idle -lt $UnknownIdleMinutes * 60)   { $why += ('reason-unknown-idle-' + [int]$idle + 's-of-' + ($UnknownIdleMinutes * 60) + 's') }
} elseif ($postWake -and $noInputSinceSleep) {
  # nobody touched the machine since it went to sleep -> this wake was not asked for
  if ($sinceWakeSec -lt $PostWakeGraceSeconds) { $why += ('post-wake-grace-' + [int][math]::Ceiling($PostWakeGraceSeconds - $sinceWakeSec) + 's') }
} else {
  if ($idle -lt 0)                     { $why += 'idle-unknown' }
  elseif ($idle -lt $IdleMinutes * 60) { $why += 'user-present' }
}
if ($SkipIfRemoteSession -and $inboundCount -gt 0) { $why += 'remote-in-use' }
if (-not $parsed)   { $why += 'requests-unreadable' }
if ($displayActive) { $why += 'display-in-use' }
if ($audioActive)   { $why += 'media-playing' }
if ($updateActive)  { $why += 'update-running' }
if (-not $gapOk)    { $why += 'slept-recently' }

# heartbeat: written on EVERY run, even when the log line below gets throttled, so that
# "is the agent still alive?" is a one-second check on the timestamp of dec-resleep-heartbeat.txt
try {
  $dec = 'SKIP'
  if ($why.Count -eq 0) { $dec = if ($DryRun) { 'DRYRUN-WOULD-SLEEP' } else { 'SLEEP' } }
  Set-Content -Path (Join-Path $BaseDir 'dec-resleep-heartbeat.txt') -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $dec + '  reason=' + (($why -join '+')) + '  wake=' + $wakeKind + '@' + $wakeStamp + '  idle=' + [int]$idle + 's') -Encoding ASCII
} catch {}

if ($why.Count -gt 0) {
  # throttle the noisy "nothing but user-present" case so the log stays readable
  $noisy = ($why.Count -eq 1 -and $why[0] -eq 'user-present')
  $logIt = $true
  if ($noisy) {
    $logIt = $false
    if (Test-Path $SkipFile) {
      try { $p = [datetime]::Parse((Get-Content $SkipFile -Raw).Trim()); if (((Get-Date) - $p).TotalMinutes -ge $UserPresentSkipLogMinutes) { $logIt = $true } } catch { $logIt = $true }
    } else { $logIt = $true }
  }
  if ($logIt) {
    if ($noisy) { Set-Content -Path $SkipFile -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Encoding ASCII }
    Log ('SKIP   ' + $detail + '   reason=' + ($why -join '+'))
  }
  exit 0
}

if ($DryRun) {
  Log ('DRYRUN would suspend now   ' + $detail)
  exit 0
}

Log ('SLEEP  ' + $detail)
Set-Content -Path $StampFile -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Encoding ASCII
# the trace must be running BEFORE the wake happens
if ($parsed) { [void](ArmTrace 'about-to-suspend') }
# remember the raw input tick: after the resume, an unchanged tick proves nobody touched the
# machine while it was asleep -> tier A applies and we go straight back to sleep
Set-Content -Path $TickFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ';' + $inputTick + ';idle=' + [int]$idle) -Encoding ASCII
# snapshot the WLAN state before sleeping: after the resume an unchanged SSID/BSSID plus a fast
# gateway reply means the association survived (magic packet), an absent/changed one means the AP
# was lost during sleep -> consumed by wlan-wake-evidence.ps1 (driver independent)
try {
  $wtxt = (netsh wlan show interfaces 2>$null | Out-String)
  $wSsid = ''; $wBssid = ''
  foreach ($wl in ($wtxt -split "`r?`n")) {
    if ($wl -match '^ *SSID *: *(.+)$')  { if (-not $wSsid)  { $wSsid  = $Matches[1].Trim() } }
    if ($wl -match '^ *BSSID *: *(.+)$') { if (-not $wBssid) { $wBssid = $Matches[1].Trim() } }
  }
  Set-Content -Path (Join-Path $BaseDir 'os-wlanlink-presleep.txt') -Value ('v2|time=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '|ssid=' + $wSsid + '|bssid=' + $wBssid) -Encoding ASCII
} catch {}
$susp = $false
try { $susp = [Native]::Suspend() } catch { Log ('ERROR suspend: ' + $_.Exception.Message) }
if (-not $susp) {
  Log 'native SetSuspendState returned false -> falling back to rundll32'
  & rundll32.exe powrprof.dll,SetSuspendState 0,1,0
}
# this process is frozen while the machine sleeps: the next line appears at the resume,
# so its timestamp = the moment the machine came back (the SLEEP line above is the request)
Log ('SLEEP-ISSUED native-ok=' + $susp + '   (timestamp = moment of resume)')