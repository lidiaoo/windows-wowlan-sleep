<#
  Hermes WoL listener  -  two jobs in one persistent, hidden process:

  1) MAGIC PACKET / MARKER DETECTION (the "listen on the NIC" idea)
     Binds UDP ports 9, 7 (classic Wake-on-LAN ports) and 45678 (marker port, see below) and
     inspects every datagram for the magic packet pattern: 6 x 0xFF followed by at least 8
     repetitions of the adapter MAC (a real magic packet uses 16).
     Why this can work at all: the *first* magic packet that wakes a sleeping host is consumed by
     the NIC firmware in D3 and is never handed to the OS, but Wake-on-LAN senders usually emit a
     burst (3-5 copies) and any copy that arrives after the resume IS delivered - so it can be
     detected. A single-shot send consumed by the firmware cannot be seen host-side; that is a
     hardware limitation, not a software one. To make it 100% deterministic the sender can also
     hit the marker port (see below) repeatedly for ~60 s after the magic packet.
       marker: UDP port 45678, payload starting with "HERMES-WOL-MARKER" -> counts as "the user
       just woke this machine on purpose", no MAC pattern needed.

  2) TRACE ARMING (so the NDIS wake reason is captured)
     Keeps the NDIS ETW session armed while the machine is idle (arm at >=45 s idle, disarm
     below 20 s), checked every ~10 s. This is much finer than the 2-minute poll, so a sleep the
     user starts manually shortly after leaving the keyboard still gets its trace armed in time.

  Writes:
     pkt-magicpacket-seen.log     append-only: every detected packet/marker
     pkt-magicpacket-last.txt     v2|time=...|kind=magic|marker|src=ip:port|len=N
     trace-arm-history.log    arm/disarm decisions (shared with resleep.ps1)

  Single instance is enforced through a lock file.
#>
param(
  [int[]]$Ports = @(9, 7, 67, 68),
  [int]$MarkerPort = 45678,
  [int]$ArmIdleSeconds = 45,
  [int]$DisarmIdleSeconds = 20,
  [string]$AdapterMac = '',
  [switch]$Once
)

$ErrorActionPreference = 'Continue'
$BaseDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$SeenLog  = Join-Path $BaseDir 'pkt-magicpacket-seen.log'
$LastFile = Join-Path $BaseDir 'pkt-magicpacket-last.txt'
$TraceLog = Join-Path $BaseDir 'trace-arm-history.log'
$LockFile = Join-Path $BaseDir 'pkt-listener.lock'
$DllPath  = Join-Path $BaseDir 'NativeIdle2.dll'

function Log2([string]$m) {
  try { Add-Content -Path $SeenLog -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m) -Encoding UTF8 } catch {}
}
function TraceLog([string]$m) {
  try { Add-Content -Path $TraceLog -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  listener: ' + $m) -Encoding UTF8 } catch {}
}
function Note([string]$kind, [string]$src, [int]$len) {
  # deliberately primitive: "<unixSeconds> <kind>" - no separators, keys or escapes to survive
  $epoch = [int]([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
  try { Set-Content -Path $LastFile -Value (([string]$epoch) + ' ' + $kind) -Encoding ASCII } catch {}
  Log2 ('DETECTED kind=' + $kind + ' src=' + $src + ' len=' + $len)
}

# ---- single instance: a named mutex cannot be defeated by a stale pid/lock file ----
$mutex = $null
$gotMutex = $false
try { $mutex = New-Object System.Threading.Mutex($false, 'Local\HermesWolListener'); $gotMutex = $mutex.WaitOne(0) } catch {}
if ($mutex -and -not $gotMutex) { Log2 'exit: another listener instance already owns the mutex'; exit 0 }
Set-Content -Path $LockFile -Value $PID -Encoding ASCII
try {

# ---- native helper (idle time) ----
$src = @"
using System;
using System.Runtime.InteropServices;
public static class Native {
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  static bool Raw(out uint tick) {
    LASTINPUTINFO li = new LASTINPUTINFO(); li.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
    tick = 0; if (!GetLastInputInfo(ref li)) return false; tick = li.dwTime; return true;
  }
  public static double IdleSeconds() { uint t; if (!Raw(out t)) return -1; return ((uint)Environment.TickCount - t) / 1000.0; }
}
"@
try { Add-Type -Path $DllPath -ErrorAction Stop } catch {
  try { Add-Type -TypeDefinition $src -OutputAssembly $DllPath -ErrorAction Stop } catch {}
  try { Add-Type -Path $DllPath -ErrorAction Stop } catch { try { Add-Type -TypeDefinition $src -ErrorAction Stop } catch {} }
}

# ---- which MAC to look for? ----
# Ask for the physical 802.11 adapter, not for a name: the interface name is not stable (a swapped
# card or a driver reinstall renames it - this box went from 'WLAN' to 'WLAN 5'), and a hardcoded
# fallback MAC from the card the machine shipped with silently matches nothing after a swap.
if (-not $AdapterMac) {
  try {
    $wa = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.MediaType -eq 'Native 802.11' -or $_.InterfaceDescription -match '(?i)wi-fi|wireless|wlan|802.11' } |
            Sort-Object @{ Expression = { if ($_.Status -eq 'Up') { 0 } else { 1 } } })
    if ($wa.Count -gt 0) { $AdapterMac = ($wa[0].MacAddress -replace '-', '') }
  } catch {}
}
$macBytes = @()
if ($AdapterMac -and $AdapterMac.Length -ge 12) {
  for ($i = 0; $i -lt 12; $i += 2) { $macBytes += [Convert]::ToByte($AdapterMac.Substring($i, 2), 16) }
}
if ($macBytes.Count -ne 6) { Log2 'no Wi-Fi adapter MAC found - magic-packet matching DISABLED (marker packets only)' }

$sockets = @()
foreach ($p in $Ports) {
  try {
    $s = New-Object System.Net.Sockets.UdpClient
    $s.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $s.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $p)))
    $s.Client.Blocking = $false
    $sockets += @{ sock = $s; port = $p; kind = 'magic' }
  } catch { Log2 ('cannot bind UDP ' + $p + ': ' + $_.Exception.Message) }
}
try {
  $m = New-Object System.Net.Sockets.UdpClient
  $m.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
  $m.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $MarkerPort)))
  $m.Client.Blocking = $false
  $sockets += @{ sock = $m; port = $MarkerPort; kind = 'marker' }
} catch { Log2 ('cannot bind UDP marker ' + $MarkerPort + ': ' + $_.Exception.Message) }

Log2 ('listener started pid=' + $PID + ' mac=' + $AdapterMac + ' ports=' + (($Ports + $MarkerPort) -join ','))

$armed = $false
$lastArmCheck = Get-Date
$idle = -1.0

if ($Once) { }   # single pass, used for testing

while ($true) {
  # ---- 1. drain incoming datagrams ----
  foreach ($entry in $sockets) {
    while ($true) {
      $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
      try {
        if (-not $entry.sock.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead)) { break }
        $data = $entry.sock.Receive([ref]$remote)
      } catch { break }
      if (-not $data -or $data.Length -eq 0) { continue }
      $srcTxt = $remote.Address.ToString() + ':' + $remote.Port
      if ($entry.kind -eq 'marker') {
        $txt = [Text.Encoding]::ASCII.GetString($data)
        if ($txt.StartsWith('HERMES-WOL-MARKER')) { Note 'marker' $srcTxt $data.Length }
        continue
      }
      # magic pattern: >= 8 repetitions of the MAC in one datagram (a real one repeats it 16x);
      # skipped entirely when no adapter MAC is known, so marker packets remain the only evidence
      if ($macBytes.Count -eq 6) {
        $reps = 0
        for ($off = 0; $off -le ($data.Length - 6); $off++) {
          $ok = $true
          for ($b = 0; $b -lt 6; $b++) { if ($data[$off + $b] -ne $macBytes[$b]) { $ok = $false; break } }
          if ($ok) { $reps++ ; $off += 5 } else { $reps = 0 }
          if ($reps -ge 8) { break }
        }
        if ($reps -ge 8) { Note 'magic' $srcTxt $data.Length }
      }
    }
  }

  # ---- 2. keep the wake-reason trace armed while idle ----
  if ($Once) { break }
  # fast path: run the sleep decision (resleep.ps1) every ~30 s while the machine is idle, instead
  # of waiting for the 2-minute scheduled task. The task stays as the supervisor / safety net.
  if ($idle -ge 120 -and ((-not $lastFastPath) -or ((Get-Date) - $lastFastPath).TotalSeconds -ge 30)) {
    $lastFastPath = Get-Date
    try {
      Start-Process -FilePath 'wscript.exe' -ArgumentList @('//B','//Nologo',(Join-Path $BaseDir 'run-hidden.vbs'),(Join-Path $BaseDir 'resleep.ps1')) -WindowStyle Hidden
      TraceLog ('fast-path: ran resleep (idle=' + [int]$idle + 's)')
    } catch {}
  }
  if (((Get-Date) - $lastArmCheck).TotalSeconds -ge 10) {
    $lastArmCheck = Get-Date
    try { $idle = [Native]::IdleSeconds() } catch { $idle = -1 }
    try {
      $running = ((((& logman query -ets 2>&1) | Out-String) -match 'HermesNdisWake'))
      if (-not $running -and $idle -ge $ArmIdleSeconds) {
        & logman stop HermesNdisWake -ets 2>&1 | Out-Null
        Remove-Item (Join-Path $BaseDir 'drv-ndis-trace.etl') -Force -ErrorAction SilentlyContinue
        $null = (& logman start HermesNdisWake -p Microsoft-Windows-NDIS 0xffffffffffffffff 4 -o (Join-Path $BaseDir 'drv-ndis-trace.etl') -f bincirc -max 64 -ct system -ets 2>&1)
        $null = (& logman update HermesNdisWake -p Microsoft-Windows-Kernel-Power 0xffffffffffffffff 4 -ets 2>&1)
        $armed = ((((& logman query -ets 2>&1) | Out-String) -match 'HermesNdisWake'))
        TraceLog ('ARM    reason=listener-idle idle=' + [int]$idle + 's session-running=' + $armed)
      } elseif ($running -and $idle -ge 0 -and $idle -lt $DisarmIdleSeconds) {
              # NEVER disarm shortly after a resume: the miniport emits its wake-reason event at the
              # resume, and stopping the ETW session first loses it (that is exactly what produced
              # class=NO_DATA at 10:35:56 - the listener disarmed 1 s after the wake with idle=18 s).
              $sinceResume = -1
              try {
                $evR = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Power-Troubleshooter'; Id=1} -MaxEvents 1 -ErrorAction SilentlyContinue
                if ($evR) { $sinceResume = ((Get-Date) - $evR.TimeCreated).TotalSeconds }
              } catch {}
              if ($sinceResume -ge 0 -and $sinceResume -lt 180) {
                if ((-not $lastKeepLog) -or ((Get-Date) - $lastKeepLog).TotalSeconds -ge 60) {
                  $lastKeepLog = Get-Date
                  TraceLog ('KEEP-ARMED resume=' + [int]$sinceResume + 's ago -> not disarming (idle=' + [int]$idle + 's)')
                }
              } else {
                & logman stop $TraceSession -ets 2>&1 | Out-Null
                TraceLog ('DISARM reason=listener-user-active idle=' + [int]$idle + 's')
              }
            }
    } catch { TraceLog ('arm/disarm error: ' + $_.Exception.Message) }
  }
  Start-Sleep -Milliseconds 700
}
} finally {
  foreach ($entry in $sockets) { try { $entry.sock.Close() } catch {} }
  Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}