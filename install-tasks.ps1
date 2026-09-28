<#
  Hermes AutoReSleep - 一键注册计划任务（install）
  =================================================
  在目标电脑上要做的只有三步：
    0) 最省事：在本机先跑 make-package.cmd 生成 HermesTools-*.zip → 拷到目标电脑解压 → 双击 install-tasks.cmd
       （从任何位置双击都会把项目复制到 %LOCALAPPDATA%\HermesTools 再注册，所以 U盘/下载目录拔掉也不影响）
    1) 或者直接：把整个 HermesTools 目录拷过去（至少包含 *.ps1 / run-hidden.vbs / NativeIdle2.dll）
    2) 双击 install-tasks.cmd（UAC 点“是”），或者管理员 PowerShell 执行：
         powershell -NoProfile -ExecutionPolicy Bypass -File .\install-tasks.ps1
    3) 看到“全部完成”即可；想先看会改什么就加 -DryRun

  目标电脑上会被改动的东西（全部可由 uninstall-tasks 回滚）：
    - 注册 5 个计划任务（下面那张表）
    - 入站防火墙规则 Hermes-WoL-UDP-<端口>（仅 UDP 9/7/67/68/45678，仅本地子网，仅 powershell.exe）
      ← 防火墙开着时，这正是 pkt 链能看到魔法包/标记包的前提；不想加就加 -NoFirewallRule
    - 不改电源方案、不改网卡的 WoL 高级属性（那部分见 00-README-sources.md 第 8 节）

  注册的任务（与 00-README-sources.md 第 4 节一致）：
    Hermes-AutoResleep        每 N 分钟 ＋ 从睡眠恢复      当前用户(最高权限)  判定兜底 / 回睡
    Hermes-WolListener        用户登录                     当前用户(最高权限)  常驻抓包 ＋ 追踪武装
    Hermes-WakeReasonArm      进入睡眠(Kernel-Power 42)     SYSTEM              打开 NDIS ETW 追踪
    Hermes-WakeReasonCapture  从睡眠恢复(Power-Troubleshooter 1) SYSTEM         采集驱动唤醒原因(drv 链)
    Hermes-WlanWakeEvidence   从睡眠恢复(同上)             SYSTEM              采集链路证据(os 链)

  为什么 AutoResleep/WolListener 必须用“当前用户 + 最高权限”：
    GetLastInputInfo 读的是“调用者所在会话”的空闲时间，SYSTEM/会话 0 里永远是“空闲很久”，
    会把正在使用的机器睡掉；而 powercfg /requests 又需要管理员，所以只能用
    Interactive + RunLevel Highest。代价：只有该用户处于登录状态（含锁屏）时才有效。

  常用参数：
    -IdleMinutes <int>               B 档需要的真实键鼠空闲分钟数（默认 2）
    -UnknownIdleMinutes <int>        三条证据链都拿不到时所需的空闲分钟数（默认 15）
    -UnattributedWakePolicy <skip|resleep-if-unattended>
                                     Windows 未归因、且只有网卡是武装设备的唤醒如何处理（默认 skip）
    -RepeatMinutes <int>             兜底判定周期（分钟，默认 2）
    -TaskPath <string>               任务目录（默认 \Hermes）
    -UserId <域\用户>                任务运行身份（默认取资源管理器的登录用户）
    -InstallDir <路径>               先把脚本复制到该目录，再按该目录注册任务
    -NoStartListener                 注册后不立刻拉起常驻监听器
    -NoSmokeTest                     跳过安装后自检
    -DryRun                          只打印计划，不改动系统

  卸载：uninstall-tasks.ps1（或双击 uninstall-tasks.cmd）
#>
[CmdletBinding()]
param(
  [string]$TaskPath = '\Hermes',
  [string]$UserId = '',
  [int]$IdleMinutes = 2,
  [int]$UnknownIdleMinutes = 15,
  [ValidateSet('skip', 'resleep-if-unattended')][string]$UnattributedWakePolicy = 'skip',
  [int]$RepeatMinutes = 2,
  [string]$InstallDir = '',
  [switch]$NoFirewallRule,
  [switch]$NoStartListener,
  [switch]$NoSmokeTest,
  [switch]$SkipSelfElevate,
  [string]$LogFile = '',
  [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$script:LogPath = $LogFile
function Say {
  param([string]$m = '')
  Write-Host $m
  if ($script:LogPath) { try { Add-Content -Path $script:LogPath -Value $m -Encoding UTF8 } catch {} }
}
function Test-Admin {
  try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}
function Stop-WithError {
  param([string]$m)
  Say ''
  Say ('失败：' + $m)
  exit 1
}

Say '============================================================'
Say ' Hermes AutoReSleep - 一键注册计划任务'
Say (' 时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '   模式：' + $(if ($DryRun) { 'DryRun（不改动系统）' } else { '正式注册' }))
Say '============================================================'

# ---------------- 0. 提权（注册 Highest/SYSTEM 任务必须管理员；-DryRun 只打印计划，不需要） ----------------
if (-not (Test-Admin) -and -not $DryRun) {
  if ($SkipSelfElevate) { Stop-WithError '需要管理员权限（注册计划任务、结束监听器、控制 ETW 会话都要管理员）。请右键“以管理员身份运行”。' }
  $log = $LogFile
  if (-not $log) { $log = Join-Path $env:TEMP ('hermes-install-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log') }
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-SkipSelfElevate',
               '-TaskPath', ('"' + $TaskPath + '"'),
               '-IdleMinutes', "$IdleMinutes", '-UnknownIdleMinutes', "$UnknownIdleMinutes",
               '-RepeatMinutes', "$RepeatMinutes", '-UnattributedWakePolicy', $UnattributedWakePolicy,
               '-LogFile', ('"' + $log + '"'))
  if ($UserId) { $argList += @('-UserId', ('"' + $UserId + '"')) }
  if ($InstallDir) { $argList += @('-InstallDir', ('"' + $InstallDir + '"')) }
  if ($NoStartListener) { $argList += '-NoStartListener' }
  if ($NoSmokeTest) { $argList += '-NoSmokeTest' }
  if ($NoFirewallRule) { $argList += '-NoFirewallRule' }

  Say ''
  Say '当前不是管理员：正在弹出 UAC，请在弹窗中点“是”。'
  try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait
  } catch {
    Stop-WithError ('提权失败或被拒绝：' + $_.Exception.Message)
  }
  Say ''
  Say '================ 提权进程的输出（完整记录） ================'
  if (Test-Path $log) { Get-Content -Path $log -Encoding UTF8 | ForEach-Object { Write-Host $_ } } else { Say '（提权进程没有留下日志）' }
  exit 0
}
if (-not (Test-Admin)) {
  Say ''
  Say '[提示] 当前不是管理员：DryRun 只打印计划、不注册任务，所以无需提权；正式安装时才会弹 UAC。'
}

# ---------------- 1. 定位脚本目录 / 可选复制到固定目录 ----------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { Stop-WithError '无法确定脚本所在目录。' }
$ScriptDir = [System.IO.Path]::GetFullPath($ScriptDir)

$RuntimeFiles = @('resleep.ps1', 'wol-listener.ps1', 'wake-reason-arm.ps1', 'wake-reason-capture.ps1', 'wlan-wake-evidence.ps1', 'run-hidden.vbs')
$AuxFiles     = @('NativeIdle2.dll', '00-README-sources.md', 'QUICKSTART.txt', 'install-tasks.ps1', 'uninstall-tasks.ps1', 'install-tasks.cmd', 'uninstall-tasks.cmd', 'make-package.ps1', 'make-package.cmd')

$BaseDir = $ScriptDir
Say ''
Say ('脚本目录：' + $ScriptDir)

if ($InstallDir) {
  $target = [System.IO.Path]::GetFullPath($InstallDir)
  if ($target.TrimEnd('\') -ne $ScriptDir.TrimEnd('\')) {
    Say ('安装目录：' + $target + '（先复制项目文件）')
    if ($DryRun) {
      Say '  [DryRun] 复制以下文件到该目录：' + (($RuntimeFiles + $AuxFiles) -join ', ')
    } else {
      try { New-Item -ItemType Directory -Path $target -Force | Out-Null } catch { Stop-WithError ('无法创建目录 ' + $target + '：' + $_.Exception.Message) }
      $copied = 0
      foreach ($f in ($RuntimeFiles + $AuxFiles)) {
        $src = Join-Path $ScriptDir $f
        if (Test-Path $src) { try { Copy-Item -Path $src -Destination (Join-Path $target $f) -Force -ErrorAction Stop; $copied++ } catch {} }
      }
      Say ('  已复制 ' + $copied + ' 个文件')
    }
    $BaseDir = $target
  } else {
    Say '安装目录与脚本目录相同，无需复制。'
  }
}

# DryRun 说到做到（不复制任何文件），所以目标目录此刻还是空的：
# 预检必须去看“将要被复制过去的源目录”，否则 -InstallDir 配 -DryRun 会误报“缺少运行文件”。
# （install-tasks.cmd 默认就会带上 -InstallDir，所以这条路径是换电脑时最先走的那条。）
$CheckDir = $BaseDir
$checkNote = ''
if ($DryRun -and -not (Test-Path (Join-Path $BaseDir 'resleep.ps1')) -and (Test-Path (Join-Path $ScriptDir 'resleep.ps1'))) {
  $CheckDir = $ScriptDir
  $checkNote = '（来自脚本目录；正式安装时会先复制到 ' + $BaseDir + '）'
}

# ---------------- 2. 预检：文件是否齐全 ----------------
Say ''
Say '---- 预检 ----'
$missing = @()
foreach ($f in $RuntimeFiles) { if (-not (Test-Path (Join-Path $CheckDir $f))) { $missing += $f } }
if ($missing.Count -gt 0) { Stop-WithError ('缺少运行文件：' + ($missing -join ', ') + '（请把整个项目目录一起复制过来）') }
Say ('  运行文件齐全：' + ($RuntimeFiles -join ', ') + $checkNote)
foreach ($f in $AuxFiles) { if (-not (Test-Path (Join-Path $CheckDir $f))) { Say ('  [提示] 可选文件不存在，不影响运行：' + $f) } }

# 语法自检：拷了一半 / 被同步工具截断的 .ps1 在这里就暴露出来，
# 而不是等到半夜任务静默失败（PowerShell 5.1 读无 BOM 的 .ps1 会当 ANSI，中文变成解析错误）
$badParse = @()
foreach ($f in @($RuntimeFiles | Where-Object { $_ -like '*.ps1' })) {
  try {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $CheckDir $f), [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) { $badParse += ($f + ' -> ' + $errs[0].Message) }
  } catch { $badParse += ($f + ' -> ' + $_.Exception.Message) }
}
if ($badParse.Count -gt 0) { Stop-WithError ('以下脚本没过语法检查（多半是拷贝不完整或编码被改）：' + ($badParse -join ' ; ')) }
Say '  语法自检：全部通过'

# 预编译辅助 DLL：加载失败不影响运行（脚本会自己从源码重编译），但值得报告出来
$dll = Join-Path $CheckDir 'NativeIdle2.dll'
if (Test-Path $dll) {
  try { Add-Type -Path $dll -ErrorAction Stop; Say '  辅助 DLL：NativeIdle2.dll 可加载' }
  catch { Say ('  [提示] NativeIdle2.dll 加载失败（' + $_.Exception.Message + '）：脚本会自动从内嵌源码重编译，功能不受影响，只是首次启动慢约 20 秒。') }
} else { Say '  [提示] 没有 NativeIdle2.dll：脚本会在首次运行时自行编译生成（首次启动慢约 20 秒）。' }

$wlan = @()
try {
  $wlan = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.MediaType -eq 'Native 802.11' -or $_.InterfaceDescription -match '(?i)wi-fi|wireless|wlan|802.11' })
} catch {}
if ($wlan.Count -gt 0) {
  foreach ($a in $wlan) { Say ('  无线网卡：' + $a.InterfaceDescription + '  状态=' + $a.Status + '  MAC=' + $a.MacAddress) }
  Say '  提示：magic-packet 匹配会自动取“本机现存的无线网卡”，不需要手写型号。'
} else {
  Say '  [警告] 没有发现无线网卡：pkt 链只能靠标记包(4567x 端口)，且唤醒源判定按本机实际网卡重建。'
}

$execPol = 'Unknown'
try { $execPol = (Get-ExecutionPolicy).ToString() } catch {}
Say ('  执行策略：' + $execPol + '（任务用 -ExecutionPolicy Bypass 启动，不受影响）')

# ---- 网卡 WoL 高级属性（只读；本项目不改它，但判定依赖它，先把现状摊开） ----
# *WakeOnMagicPacket=0 -> 魔法包唤不醒；*WakeOnPattern=1（Intel/Killer 驱动默认）-> 会被无关的
# 模式匹配包唤醒。这两项属于网卡驱动设置，安装脚本不碰（见 00-README-sources.md 第 8 节）。
try {
  foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
    $props = @(Get-NetAdapterAdvancedProperty -Name $a.Name -AllProperties -ErrorAction SilentlyContinue |
               Where-Object { $_.RegistryKeyword -eq '*WakeOnMagicPacket' -or $_.RegistryKeyword -eq '*WakeOnPattern' })
    foreach ($p in $props) {
      Say ('  WoL 设置 ' + $a.Name + '：' + $p.RegistryKeyword + ' = ' + $p.RegistryValue + '（驱动默认 ' + $p.DefaultRegistryValue + '）')
    }
  }
} catch {}

# ---------------- 3. 运行身份 / 任务目录 ----------------
if (-not $UserId) {
  $interactive = ''
  try {
    $exp = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exp) { $o = Invoke-CimMethod -InputObject $exp -MethodName GetOwner -ErrorAction SilentlyContinue; if ($o -and $o.User) { $interactive = $o.Domain + '\' + $o.User } }
  } catch {}
  if ($interactive) { $UserId = $interactive } else { $UserId = "$env:USERDOMAIN\$env:USERNAME" }
}
if (-not $UserId -or $UserId.Trim() -eq '\') { Stop-WithError '无法确定任务运行身份，请显式指定 -UserId 域\用户。' }
if ($TaskPath -notlike '\*') { $TaskPath = '\' + $TaskPath }
$TaskPath = $TaskPath.TrimEnd('\')
if (-not $TaskPath) { $TaskPath = '\Hermes' }
# Get-/Register-/Start-ScheduledTask 的 -TaskPath 必须带结尾反斜杠（'\Hermes\'）。
# 写成 '\Hermes' 不会报错，但 Get-ScheduledTask 匹配不到任何东西：覆盖检测会静默失效，
# 注册也可能落到根目录 —— 所以统一补上，读数时才去掉。
$TaskPath +='\'
Say ('  任务目录：' + $TaskPath)
Say ('  运行身份：' + $UserId + '（AutoResleep / WolListener 需要该用户处于登录状态；唤醒原因采集任务以 SYSTEM 运行）')

# ---------------- 4. 组装任务定义 ----------------
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$hidden  = '//B //Nologo "' + (Join-Path $BaseDir 'run-hidden.vbs') + '" "'

$resumeSub = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and (EventID=1)]]</Select></Query></QueryList>'
$sleepSub  = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Kernel-Power''] and (EventID=42)]]</Select></Query></QueryList>'

function New-HermesEventTrigger {
  param([string]$Subscription)
  # 事件触发器只有 CIM 这条路（New-ScheduledTaskTrigger 没有事件变体）；
  # 事件触发器上的“重复”在 GUI 里也不暴露，所以周期重复挂在日历触发器上。
  $t = New-CimInstance -CimClass (Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskEventTrigger') -ClientOnly
  $t.Enabled = $true
  $t.Subscription = $Subscription
  return $t
}

$resleepArgs = '-IdleMinutes ' + $IdleMinutes + ' -UnknownIdleMinutes ' + $UnknownIdleMinutes + ' -UnattributedWakePolicy ' + $UnattributedWakePolicy

$userPrincipal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Highest
$sysPrincipal  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$setDecision  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -StartWhenAvailable
$setListener  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$setCollector = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable

$startAt  = Get-Date
$dailyRep = New-ScheduledTaskTrigger -Daily -At $startAt
$dailyRep.Repetition = (New-ScheduledTaskTrigger -Once -At $startAt -RepetitionInterval (New-TimeSpan -Minutes $RepeatMinutes)).Repetition

$defs = @(
  @{
    Name       = 'Hermes-AutoResleep'
    Desc       = 'AutoReSleep 判定兜底：每 ' + $RepeatMinutes + ' 分钟 + 从睡眠恢复时决定是否回睡，并看护监听器'
    Action     = (New-ScheduledTaskAction -Execute $wscript -Argument ($hidden + (Join-Path $BaseDir 'resleep.ps1') + '" ' + $resleepArgs))
    Triggers   = @((New-HermesEventTrigger $resumeSub), $dailyRep)
    Principal  = $userPrincipal
    Settings   = $setDecision
  },
  @{
    Name       = 'Hermes-WolListener'
    Desc       = '常驻监听：UDP 魔法包/标记包检测 + 每 10 秒武装 NDIS ETW 追踪'
    Action     = (New-ScheduledTaskAction -Execute $wscript -Argument ($hidden + (Join-Path $BaseDir 'wol-listener.ps1') + '"'))
    Triggers   = @((New-ScheduledTaskTrigger -AtLogOn -User $UserId))
    Principal  = $userPrincipal
    Settings   = $setListener
  },
  @{
    Name       = 'Hermes-WakeReasonArm'
    Desc       = '进入睡眠(Kernel-Power 42)时打开 NDIS/Kernel-Power 的 ETW 追踪（drv 链）'
    Action     = (New-ScheduledTaskAction -Execute $psExe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $BaseDir 'wake-reason-arm.ps1') + '"'))
    Triggers   = @((New-HermesEventTrigger $sleepSub))
    Principal  = $sysPrincipal
    Settings   = $setCollector
  },
  @{
    Name       = 'Hermes-WakeReasonCapture'
    Desc       = '从睡眠恢复(Power-Troubleshooter 1)时停追踪、解析 ETW、记录驱动唤醒原因（drv 链）'
    Action     = (New-ScheduledTaskAction -Execute $psExe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $BaseDir 'wake-reason-capture.ps1') + '"'))
    Triggers   = @((New-HermesEventTrigger $resumeSub))
    Principal  = $sysPrincipal
    Settings   = $setCollector
  },
  @{
    Name       = 'Hermes-WlanWakeEvidence'
    Desc       = '从睡眠恢复(同上)时采样 WLAN 链路状态（os 链）'
    Action     = (New-ScheduledTaskAction -Execute $psExe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $BaseDir 'wlan-wake-evidence.ps1') + '"'))
    Triggers   = @((New-HermesEventTrigger $resumeSub))
    Principal  = $sysPrincipal
    Settings   = $setCollector
  }
)

# ---------------- 5. 注册 ----------------
Say ''
Say '---- 注册任务 ----'
$existed = @()
foreach ($d in $defs) { if (Get-ScheduledTask -TaskPath $TaskPath -TaskName $d.Name -ErrorAction SilentlyContinue) { $existed += $d.Name } }
if ($existed.Count -gt 0) { Say ('  已存在、将被覆盖（-Force）：' + ($existed -join ', ')) }

$failed = 0
foreach ($d in $defs) {
  if ($DryRun) {
    Say ('  [DryRun] 注册 ' + $TaskPath + $d.Name)
    Say ('           动作: ' + $d.Action.Execute + ' ' + $d.Action.Arguments)
    continue
  }
  try {
    Register-ScheduledTask -TaskName $d.Name -TaskPath $TaskPath -Action $d.Action -Trigger $d.Triggers `
      -Principal $d.Principal -Settings $d.Settings -Description $d.Desc -Force -ErrorAction Stop | Out-Null
    Say ('  [OK] ' + $TaskPath + $d.Name)
  } catch {
    Say ('  [失败] ' + $d.Name + ' -> ' + $_.Exception.Message)
    $failed++
  }
}
if ($failed -gt 0) { Say ''; Say ('有 ' + $failed + ' 个任务注册失败，请查看上面的错误。'); exit 1 }

# ---------------- 5b. 入站防火墙规则（pkt 链的前提） ----------------
# 监听器把 UDP 9/7/67/68/45678 绑在 powershell.exe 上。入站单播默认被防火墙丢弃，
# 所以防火墙开着的机器上，pkt 链会“安静地”永远抓不到魔法包/标记包 —— 这条规则就是给它的。
# 范围收得很紧：只放这些 UDP 端口、只有 powershell.exe、只来自本地子网。
Say ''
Say '---- 防火墙（入站 UDP，pkt 链能否收到包的前提） ----'
$fwPorts = @(9, 7, 67, 68, 45678)
try {
  $prof = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | ForEach-Object { $_.Name + '=' + $_.Enabled })
  Say ('  当前防火墙：' + ($prof -join '  '))
} catch {}

if ($NoFirewallRule) {
  Say '  已按 -NoFirewallRule 跳过；防火墙开着的机器上 pkt 链收不到包（drv/os 链不受影响）。'
} elseif ($DryRun) {
  foreach ($p in $fwPorts) { Say ('  [DryRun] 入站允许 UDP ' + $p + '（仅 powershell.exe / 仅本地子网）→ 规则名 Hermes-WoL-UDP-' + $p) }
} else {
  foreach ($p in $fwPorts) {
    $name = 'Hermes-WoL-UDP-' + $p
    try {
      $old = @(Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)
      if ($old.Count -gt 0) { Remove-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue }
      New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol UDP -LocalPort $p `
        -Program $psExe -Profile Any -RemoteAddress LocalSubnet `
        -Description 'Hermes AutoReSleep: magic-packet/marker UDP listener (local subnet only)' -ErrorAction Stop | Out-Null
      Say ('  [OK] 入站允许 UDP ' + $p + '（powershell.exe / 本地子网）')
    } catch {
      Say ('  [警告] 无法创建 UDP ' + $p + ' 的入站规则：' + $_.Exception.Message)
      Say '         → 防火墙开着时 pkt 链收不到包；可手动加，或用 -NoFirewallRule 明确跳过。'
    }
  }
  # 校验：确认 5 条规则都在
  $fwOk = 0
  foreach ($p in $fwPorts) { if (Get-NetFirewallRule -DisplayName ('Hermes-WoL-UDP-' + $p) -ErrorAction SilentlyContinue) { $fwOk++ } }
  Say ('  校验：' + $fwOk + '/' + $fwPorts.Count + ' 条 Hermes-WoL-UDP-* 规则存在')
}

if ($DryRun) {
  Say ''
  Say 'DryRun 结束：没有改动任何任务/进程。去掉 -DryRun 即正式安装。'
  exit 0
}

# ---------------- 6. 校验（任务本身） ----------------
Say ''
Say '---- 校验 ----'
foreach ($d in $defs) {
  $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $d.Name -ErrorAction SilentlyContinue
  if (-not $t) { Say ('  [缺失] ' + $d.Name); continue }
  Say ('  ' + $TaskPath + $d.Name + '   状态=' + $t.State + '   运行身份=' + $t.Principal.UserId + '/LogonType=' + $t.Principal.LogonType + '/RunLevel=' + $t.Principal.RunLevel)
  $i = 0
  foreach ($tr in $t.Triggers) {
    $i++
    $k = [string]$tr.CimClass.CimClassName
    $ex = ''
    if ($k -like '*Event*') { $ex = '事件订阅= ' + ($tr.Subscription -replace '\s+', ' ') }
    elseif ($k -like '*Logon*') { $ex = '用户登录= ' + $tr.UserId }
    else { $ex = '开始=' + $tr.StartBoundary + '  重复间隔=' + $tr.Repetition.Interval }
    Say ('    触发器' + $i + ' [' + $k + '] ' + $ex)
  }
  foreach ($a in $t.Actions) { Say ('    动作= ' + $a.Execute + ' ' + $a.Arguments) }
}

# ---------------- 7. 自检（只做安全动作） ----------------
if (-not $NoSmokeTest) {
  Say ''
  Say '---- 自检（只会启动常驻监听器 + 以 -DryRun 试跑判定器，不会真的睡眠） ----'

  # 7.1 监听器：启动任务并确认锁文件指向一个活着的进程
  if (-not $NoStartListener) {
    $lock = Join-Path $BaseDir 'pkt-listener.lock'
    try { Start-ScheduledTask -TaskPath $TaskPath -TaskName 'Hermes-WolListener' -ErrorAction Stop } catch { Say ('  [警告] 无法启动监听器任务：' + $_.Exception.Message) }
    $ok = $false
    $pid2 = 0
    for ($i = 0; $i -lt 15; $i++) {
      Start-Sleep -Seconds 1
      try {
        if (Test-Path $lock) {
          $pid2 = [int]((Get-Content $lock -Raw).Trim())
          if (Get-Process -Id $pid2 -ErrorAction SilentlyContinue) { $ok = $true; break }
        }
      } catch {}
    }
    if ($ok) { Say ('  监听器：正在运行（pid=' + $pid2 + '，锁文件 ' + $lock + '）') }
    else { Say ('  [警告] 监听器 15 秒内没有拿到锁文件；稍等 2 分钟兜底任务也会把它拉起来，或手动在任务计划程序里运行 ' + $TaskPath + 'Hermes-WolListener') }
  } else { Say '  已按 -NoStartListener 跳过监听器启动。' }

  # 7.2 判定器：用任务里那条完全一样的命令行 + -DryRun 试跑
  $hb = Join-Path $BaseDir 'dec-resleep-heartbeat.txt'
  $hbBefore = $null
  if (Test-Path $hb) { try { $hbBefore = (Get-Item $hb).LastWriteTime } catch {} }
  $logf = Join-Path $BaseDir 'dec-resleep.log'
  $logBefore = 0
  if (Test-Path $logf) { try { $logBefore = (Get-Item $logf).Length } catch {} }

  try {
    & $wscript '//B' '//Nologo' (Join-Path $BaseDir 'run-hidden.vbs') (Join-Path $BaseDir 'resleep.ps1') `
        '-IdleMinutes' "$IdleMinutes" '-UnknownIdleMinutes' "$UnknownIdleMinutes" '-UnattributedWakePolicy' $UnattributedWakePolicy '-DryRun' | Out-Null
  } catch { Say ('  [警告] 试跑判定器失败：' + $_.Exception.Message) }

  $changed = $false
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    if (Test-Path $hb) {
      try { if ((-not $hbBefore) -or ((Get-Item $hb).LastWriteTime -gt $hbBefore)) { $changed = $true; break } } catch {}
    }
  }
  if ($changed) {
    Say ('  判定器：试跑成功。心跳文件 ' + $hb)
    $beat = Get-Content $hb -Raw -Encoding UTF8
    if ($beat) { Say ('    ' + $beat.Trim()) }
    try {
      if ((Test-Path $logf) -and ((Get-Item $logf).Length -gt $logBefore)) {
        $tail = Get-Content $logf -Tail 1 -Encoding UTF8
        Say ('    判定日志最新一行：' + $tail)
      }
    } catch {}
  } else {
    Say '  [警告] 判定器 60 秒内没有更新心跳文件：请手动执行 resleep.ps1 -DryRun 看报错（常见原因是缺 NativeIdle2.dll 时 Add-Type 编译被策略拦住）。'
  }
} else { Say ''; Say '已按 -NoSmokeTest 跳过自检。' }

# ---------------- 8. 总结 ----------------
Say ''
Say '==================== 全部完成 ===================='
Say (' 任务目录：' + $TaskPath.TrimEnd('\') + '（任务计划程序 → 任务计划程序库 → ' + $TaskPath.TrimEnd('\') + '）')
Say (' 安装位置：' + $BaseDir)
Say (' 判定参数：-IdleMinutes ' + $IdleMinutes + ' -UnknownIdleMinutes ' + $UnknownIdleMinutes + ' -UnattributedWakePolicy ' + $UnattributedWakePolicy + ' -RepeatMinutes ' + $RepeatMinutes)
Say ''
Say ' 平时怎么看它有没有在干活：'
Say ('   ' + (Join-Path $BaseDir 'dec-resleep-heartbeat.txt') + '   时间戳在 2.5 分钟内即正常')
Say ('   ' + (Join-Path $BaseDir 'dec-resleep.log') + '        每次判定一行：reason= 结论、src= 用了哪条链')
Say ''
Say ' 卸载（完全回滚）：'
Say '   双击 uninstall-tasks.cmd（从哪儿双击都行：它会从已注册任务的命令行反查安装目录）'
Say ('   或 powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $BaseDir 'uninstall-tasks.ps1') + '"')
Say '   加 -PurgeLogs 连日志一起删，加 -RemoveToolDir 连整个目录一起删。'
Say '   卸载会删掉：5 个任务、Hermes-WoL-UDP-* 防火墙规则、监听器进程、ETW 会话。'
Say ''
Say ' 提示：网卡上的 WoL 设置（*WakeOnMagicPacket / *WakeOnPattern 等）不属于本项目，'
Say '       换机器后建议先用 -DryRun 看一遍上面打印的 WoL 现状；细节见 00-README-sources.md 第 8 节。'