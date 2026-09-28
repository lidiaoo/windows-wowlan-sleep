<#
  Hermes AutoReSleep - 一键卸载（uninstall）
  ==========================================
  做什么（按顺序，全部可回滚/可重装）：
    1) 停止并删除任务计划程序库 \Hermes 下的 Hermes-* 任务（默认这 5 个）
    2) 结束后台常驻进程：wol-listener.ps1、卡住的 resleep.ps1、以及隐藏启动器 run-hidden.vbs
    3) 停掉 NDIS ETW 追踪会话 HermesNdisWake（-ets 会话；如存在同名 autologger 也一起停）
    4) 删掉安装时加的入站防火墙规则 Hermes-WoL-UDP-*（只删本项目自己的名字）
    5) -PurgeLogs      额外删除本项目产生的日志/状态文件（脚本本身保留）
    6) -RemoveToolDir  连整个工具目录一起删除（删除自身，尽力而为）

  哪一个目录？—— 从已注册任务的命令行反查（不是从本脚本所在目录猜）：
    所以在别的电脑/别的目录里双击这份 uninstall-tasks.cmd 也能卸干净；
    想手动指定就加 -ToolDir "C:\路径"。多份历史安装会列出候选，逐个卸。

  用法：
    双击 uninstall-tasks.cmd，或管理员 PowerShell：
      powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall-tasks.ps1
      powershell ... -File .\uninstall-tasks.ps1 -PurgeLogs
      powershell ... -File .\uninstall-tasks.ps1 -PurgeLogs -RemoveToolDir
      powershell ... -File .\uninstall-tasks.ps1 -DryRun     # 只看会做什么

  说明：本项目只写“计划任务 / ETW 追踪会话 / 自己的进程与文件”，不改电源方案；
  重新安装就是再跑一次 install-tasks.ps1。
#>
[CmdletBinding()]
param(
  [string]$TaskPath = '\Hermes',
  [string]$ToolDir = '',
  [switch]$PurgeLogs,
  [switch]$RemoveToolDir,
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

Say '============================================================'
Say ' Hermes AutoReSleep - 一键卸载'
Say (' 时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '   模式：' + $(if ($DryRun) { 'DryRun（不改动系统）' } else { '正式卸载' }))
Say '============================================================'

# ---------------- 0. 提权（-DryRun 只打印计划，不需要管理员） ----------------
if (-not (Test-Admin) -and -not $DryRun) {
  if ($SkipSelfElevate) { Say ''; Say '失败：需要管理员权限。请右键“以管理员身份运行”。'; exit 1 }
  $log = $LogFile
  if (-not $log) { $log = Join-Path $env:TEMP ('hermes-uninstall-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log') }
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-SkipSelfElevate',
               '-TaskPath', ('"' + $TaskPath + '"'), '-LogFile', ('"' + $log + '"'))
  if ($ToolDir) { $argList += @('-ToolDir', ('"' + $ToolDir + '"')) }
  if ($PurgeLogs) { $argList += '-PurgeLogs' }
  if ($RemoveToolDir) { $argList += '-RemoveToolDir' }
  if ($DryRun) { $argList += '-DryRun' }

  Say ''
  Say '当前不是管理员：正在弹出 UAC，请在弹窗中点“是”。'
  try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait } catch { Say ('提权失败或被拒绝：' + $_.Exception.Message); exit 1 }
  Say ''
  Say '================ 提权进程的输出（完整记录） ================'
  if (Test-Path $log) { Get-Content -Path $log -Encoding UTF8 | ForEach-Object { Write-Host $_ } } else { Say '（提权进程没有留下日志）' }
  exit 0
}
if (-not (Test-Admin)) {
  Say ''
  Say '[提示] 当前不是管理员：DryRun 只打印计划、不改动系统，所以无需提权；正式卸载时才会弹 UAC。'
  Say '       （注意：非管理员运行时读不到提升权限进程的命令行，也停不掉 ETW 会话，校验结果可能不完整）'
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { Say '失败：无法确定脚本所在目录。'; exit 1 }
$ScriptDir = [System.IO.Path]::GetFullPath($ScriptDir)
if ($TaskPath -notlike '\*') { $TaskPath = '\' + $TaskPath }
$TaskPath = $TaskPath.TrimEnd('\')
if (-not $TaskPath) { $TaskPath = '\Hermes' }
# 统一补结尾反斜杠：'\Hermes' 形式的 -TaskPath 不报错但匹配不到任何任务
# （卸载时表现为“没有找到任务”，可任务其实还在），必须写成 '\Hermes\'
$TaskPath +='\'

# ---------------- 0b. 工具目录：从已注册任务的命令行反查 ----------------
# 卸载常常是在“另一份拷贝”上双击的（下载目录、U盘、别的电脑拷过来的那份）。
# 那时脚本所在目录 != 被安装的目录，按脚本目录去清日志/删目录会清错地方，
# 所以这里优先从任务动作里反查真实安装目录；-ToolDir 可显式覆盖。
$OurLeaves = @('run-hidden.vbs', 'resleep.ps1', 'wol-listener.ps1', 'wake-reason-arm.ps1', 'wake-reason-capture.ps1', 'wlan-wake-evidence.ps1')
$BaseDir = $ScriptDir
$dirSource = '本脚本所在目录（没能从任务里反查出来）'
if ($ToolDir) {
  $BaseDir = [System.IO.Path]::GetFullPath($ToolDir)
  $dirSource = '-ToolDir 参数'
} else {
  $found = @()
  try {
    foreach ($t in @(Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue)) {
      foreach ($a in @($t.Actions)) {
        # 只取引号里的绝对路径，再看文件名是不是本项目的脚本 —— 不用正则转义，避免 \\ 被写坏
        foreach ($m in [regex]::Matches([string]$a.Arguments, '"([^"]+)"')) {
          $p = $m.Groups[1].Value
          if ($OurLeaves -contains (Split-Path -Leaf $p)) {
            $d = Split-Path -Parent $p
            if ($d) { $found += $d }
          }
        }
      }
    }
  } catch {}
  $found = @($found | Select-Object -Unique)
  if ($found.Count -ge 1) {
    $rank = @($found | Group-Object | Sort-Object Count -Descending)
    $BaseDir = [System.IO.Path]::GetFullPath($rank[0].Name)
    $dirSource = '已注册任务的命令行'
    if ($rank.Count -gt 1) {
      Say ''
      Say ('  [提示] 发现有 ' + $rank.Count + ' 个曾被注册的安装目录：' + (($rank | ForEach-Object { $_.Name }) -join ' ; '))
      Say ('         本次只处理 ' + $BaseDir + '；其它目录请用 -ToolDir 逐个卸。')
    }
  }
}

$Known = @('Hermes-AutoResleep', 'Hermes-WolListener', 'Hermes-WakeReasonArm', 'Hermes-WakeReasonCapture', 'Hermes-WlanWakeEvidence')
Say ''
Say ('项目目录：' + $BaseDir + '   （来源：' + $dirSource + '）')
Say ('本脚本位置：' + $ScriptDir)
Say ('任务目录：' + $TaskPath)
Say ('附加动作：PurgeLogs=' + [bool]$PurgeLogs + '  RemoveToolDir=' + [bool]$RemoveToolDir)

# ---------------- 1. 先删任务（避免 2 分钟兜底任务把监听器又拉起来） ----------------
Say ''
Say '---- 1. 删除计划任务 ----'
$targets = @()
foreach ($n in $Known) { if (Get-ScheduledTask -TaskPath $TaskPath -TaskName $n -ErrorAction SilentlyContinue) { $targets += $n } }
# 兜底：同目录下任何 Hermes-* 残留（历史版本可能留下别的名字）
try {
  foreach ($t in @(Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue)) {
    if ($t.TaskName -like 'Hermes-*' -and ($targets -notcontains $t.TaskName)) { $targets += $t.TaskName }
  }
} catch {}

if ($targets.Count -eq 0) {
  Say ('  没有找到 ' + $TaskPath + ' 下的 Hermes-* 任务（可能已卸载过）。')
} else {
  foreach ($n in $targets) {
    if ($DryRun) { Say ('  [DryRun] 停止并删除 ' + $TaskPath + $n); continue }
    try { Stop-ScheduledTask -TaskPath $TaskPath -TaskName $n -ErrorAction SilentlyContinue } catch {}
    try {
      Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $n -Confirm:$false -ErrorAction Stop
      Say ('  [OK] 已删除 ' + $TaskPath + $n)
    } catch {
      Say ('  [失败] ' + $n + ' -> ' + $_.Exception.Message)
    }
  }
}

# ---------------- 2. 结束后台进程 ----------------
Say ''
Say '---- 2. 结束后台进程 ----'
$killed = @()
# 2.1 锁文件里记录的监听器进程号
$lock = Join-Path $BaseDir 'pkt-listener.lock'
$lockPid = 0
if (Test-Path $lock) { try { $lockPid = [int]((Get-Content $lock -Raw).Trim()) } catch {} }
# 2.2 命令行匹配（覆盖锁文件过期/丢失、以及被隐藏启动器拉起的实例）
$victims = @()
try {
  $victims = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and ($_.CommandLine -match 'wol-listener\.ps1|resleep\.ps1|run-hidden\.vbs') -and ($_.ProcessId -ne $PID) })
} catch {}
$victimPids = @($victims | ForEach-Object { $_.ProcessId })
if ($lockPid -gt 0 -and ($victimPids -notcontains $lockPid)) {
  $p = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
  if ($p -and $p.ProcessName -match '(?i)powershell|wscript') { $victims += (Get-CimInstance Win32_Process -Filter ("ProcessId=$lockPid") -ErrorAction SilentlyContinue) }
}
foreach ($v in @($victims | Where-Object { $_ })) {
  if ($DryRun) { Say ('  [DryRun] 结束进程 ' + $v.ProcessId + ' ' + $v.Name + '  ' + $v.CommandLine); continue }
  try {
    Stop-Process -Id $v.ProcessId -Force -ErrorAction Stop
    $killed += [string]$v.ProcessId
    Say ('  [OK] 已结束 pid=' + $v.ProcessId + ' (' + $v.Name + ')')
  } catch {
    Say ('  [警告] 无法结束 pid=' + $v.ProcessId + '：' + $_.Exception.Message)
  }
}
if ($killed.Count -eq 0 -and -not $DryRun) { Say '  没有发现需要结束的进程（监听器未运行）。' }
if (-not $DryRun) { Remove-Item $lock -Force -ErrorAction SilentlyContinue }

# ---------------- 3. 停掉 ETW 追踪会话 ----------------
Say ''
Say '---- 3. 停止 ETW 追踪会话 ----'
$session = 'HermesNdisWake'
if ($DryRun) {
  Say ('  [DryRun] logman stop ' + $session + ' -ets ；并尝试停掉同名 autologger')
} else {
  $out = (& logman stop $session -ets 2>&1 | Out-String)
  Say ('  logman stop ' + $session + ' -ets -> ' + (($out -replace '\s+', ' ').Trim()))
  if ($out -match '(?i)拒绝访问|access is denied|access denied') { Say '  [警告] 停止 ETW 会话失败（需要管理员）：请用管理员身份重新运行本脚本。' }
  $out2 = (& logman stop $session 2>&1 | Out-String)   # 同名 autologger（本项目没建，历史上可能有）
  if ($out2 -match '(?i)error|错误|拒绝|cannot|无法') { Say ('  （没有同名 autologger，正常）') } else { Say ('  logman stop ' + $session + ' -> ' + (($out2 -replace '\s+', ' ').Trim())) }
}

# ---------------- 3b. 移除本项目加的入站防火墙规则 ----------------
Say ''
Say '---- 3b. 移除入站防火墙规则（安装时加的 Hermes-WoL-UDP-*） ----'
$fwFound = @()
if ($DryRun) {
  $fwFound = @(Get-NetFirewallRule -DisplayName 'Hermes-WoL-UDP-*' -ErrorAction SilentlyContinue)
  if ($fwFound.Count -eq 0) { Say '  没有找到 Hermes-WoL-UDP-* 规则（没装过，或安装时用了 -NoFirewallRule）。' }
  foreach ($r in $fwFound) { Say ('  [DryRun] 删除防火墙规则 ' + $r.DisplayName) }
} else {
  $fwFound = @(Get-NetFirewallRule -DisplayName 'Hermes-WoL-UDP-*' -ErrorAction SilentlyContinue)
  if ($fwFound.Count -eq 0) { Say '  没有找到 Hermes-WoL-UDP-* 规则（没装过，或安装时用了 -NoFirewallRule）。' }
  foreach ($r in $fwFound) {
    try { Remove-NetFirewallRule -DisplayName $r.DisplayName -ErrorAction Stop; Say ('  [OK] 已删除规则 ' + $r.DisplayName) }
    catch { Say ('  [警告] 无法删除规则 ' + $r.DisplayName + '：' + $_.Exception.Message) }
  }
}

# ---------------- 4. 可选：清理日志/状态文件 ----------------
$purgeList = @(
  'dec-resleep.log', 'dec-resleep-heartbeat.txt', 'dec-wakereason-history.log',
  'drv-wakereason-history.log', 'drv-wakereason-last.txt',
  'os-wlanlink-evidence.log', 'os-wlanlink-evidence.txt', 'os-wlanlink-presleep.txt',
  'pkt-magicpacket-seen.log', 'pkt-magicpacket-last.txt', 'pkt-listener.lock',
  'state-last-forced-sleep.txt', 'state-last-user-present-skip.txt', 'state-input-tick-at-sleep.txt', 'state-reason-history-last.txt',
  'trace-arm-history.log', 'trace-arm-state.txt', 'trace-armed-since.txt'
)
$purgeGlobs = @('drv-ndis-trace*.etl', 'drv-ndis-trace*.xml', '*.tmp')
$purgedBytes = 0
$purgedCount = 0
if ($PurgeLogs) {
  Say ''
  Say '---- 4. 清理日志/状态文件（脚本保留） ----'
  $items = @()
  foreach ($f in $purgeList) { $p = Join-Path $BaseDir $f; if (Test-Path $p) { $items += $p } }
  foreach ($g in $purgeGlobs) { try { $items += @(Get-ChildItem -Path (Join-Path $BaseDir $g) -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) } catch {} }
  $items = @($items | Select-Object -Unique)
  if ($items.Count -eq 0) { Say '  没有需要清理的文件。' }
  foreach ($p in $items) {
    if ($DryRun) { Say ('  [DryRun] 删除 ' + $p); continue }
    try {
      $sz = 0
      try { $sz = (Get-Item $p).Length } catch {}
      Remove-Item $p -Force -ErrorAction Stop
      $purgedBytes += $sz
      $purgedCount++
    } catch { Say ('  [警告] 无法删除 ' + $p + '：' + $_.Exception.Message) }
  }
  if (-not $DryRun) { Say ('  已删除 ' + $purgedCount + ' 个文件，约 ' + [math]::Round($purgedBytes / 1MB, 2) + ' MB。') }
} else {
  Say ''
  Say '（未指定 -PurgeLogs：日志与状态文件保留，只是不再更新）'
}

# ---------------- 5. 校验 ----------------
Say ''
Say '---- 5. 校验卸载结果 ----'
# $admin 必须在下面任何 "-not $admin" 判断之前取：原来它在文件后面才赋值，
# 于是卸载成功后仍会打印“非管理员：看不到任务…”这条误导性的警告。
$admin = Test-Admin
if ($DryRun) {
  Say '  [DryRun] 跳过校验（没有实际改动）'
} else {
  $left = @()
  try { $left = @(Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'Hermes-*' }) } catch {}
  if ($left.Count -gt 0) { Say ('  [警告] 仍存在：' + (($left | ForEach-Object { $_.TaskName }) -join ', ')) }
  elseif (-not $admin) { Say ('  [警告] 非管理员：' + $TaskPath + ' 下看不到任务，但 SYSTEM 运行的任务对普通权限不可见，是否删干净无法确认') }
  else { Say ('  计划任务：' + $TaskPath + ' 下已无 Hermes-* 任务') }
  # 任务计划程序库里若已没有任何任务，顺手把空目录删掉
  try {
    $any = @(Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue)
    if ($any.Count -eq 0 -and $TaskPath -ne '\') { Say ('  任务目录 ' + $TaskPath + ' 已空（任务计划程序界面里可能仍显示空文件夹，属正常）') }
  } catch {}

  $alive = @()
  try {
    $alive = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and ($_.CommandLine -match 'wol-listener\.ps1|resleep\.ps1|run-hidden\.vbs') -and ($_.ProcessId -ne $PID) })
  } catch {}
  if ($alive.Count -eq 0) {
    if ($admin) { Say '  后台进程：无（监听器/判定器已结束）' }
    else { Say '  后台进程：未发现（非管理员运行看不到提升权限进程的命令行，可能有遗漏）' }
  } else { Say ('  [警告] 仍在运行：' + (($alive | ForEach-Object { $_.ProcessId.ToString() + ':' + $_.Name }) -join ', ')) }

  # ETW：查不到 ≠ 已停止。logman query -ets 在没权限时不报错、只是列不出会话，
  # 所以非管理员运行时只能如实说“无法确认”，不能宣称“已停止”。
  $etsRaw = ''
  $etsLeft = $false
  $etsQueryOk = $true
  try {
    $etsRaw = (& logman query -ets 2>&1 | Out-String)
    if ($etsRaw -match '(?i)拒绝访问|access is denied|access denied') { $etsQueryOk = $false }
    $etsLeft = ($etsRaw -match $session)
  } catch { $etsQueryOk = $false }
  if (-not $admin) { Say ('  [警告] 非管理员：ETW 会话 ' + $session + ' 是否已停止无法确认（logman query -ets 无权限时不报错，只列不出会话）') }
  elseif (-not $etsQueryOk) { Say ('  [警告] 无法查询 ETW 会话列表：' + $session + ' 是否已停止无法确认') }
  elseif ($etsLeft) { Say ('  [警告] ETW 会话 ' + $session + ' 仍在运行，可手动执行： logman stop ' + $session + ' -ets') }
  else { Say ('  ETW 会话：' + $session + ' 已停止') }

  # 防火墙规则：Get-NetFirewallRule 不需要管理员，所以这条结论是可信的
  $fwLeft = @()
  try { $fwLeft = @(Get-NetFirewallRule -DisplayName 'Hermes-WoL-UDP-*' -ErrorAction SilentlyContinue) } catch {}
  if ($fwLeft.Count -gt 0) { Say ('  [警告] 防火墙规则仍在：' + (($fwLeft | ForEach-Object { $_.DisplayName }) -join ', ')) }
  else { Say '  防火墙规则：Hermes-WoL-UDP-* 已无（本项目自己加的那几条）' }
}

# ---------------- 6. 提示（动过的东西 / 没动的东西） ----------------
Say ''
Say '---- 6. 其它（本项目没改、所以卸载也不会还原） ----'
try {
  $armed = @(& powercfg /devicequery wake_armed 2>&1)
  if ($armed.Count -gt 0) { Say '  当前处于“可唤醒”状态的设备（网卡 WoL 设置不属于本项目）：'; foreach ($l in $armed) { if ($l.Trim()) { Say ('    ' + $l.Trim()) } } }
} catch {}
Say '  电源方案没有被本项目修改，无需还原。'
Say '  网卡 WoL 高级属性（*WakeOnMagicPacket / *WakeOnPattern）也没有被本项目修改。'

# ---------------- 7. 可选：删除整个工具目录 ----------------
if ($RemoveToolDir) {
  Say ''
  Say '---- 7. 删除工具目录 ----'
  if ($DryRun) {
    Say ('  [DryRun] 删除整个目录 ' + $BaseDir)
  } else {
    # 自己删自己：起一个脱离的 cmd，等 3 秒再 rmdir（包含本脚本本身）
    $cleanup = Join-Path $env:TEMP 'hermes-tool-cleanup.cmd'
    $text = '@echo off' + "`r`n" + 'ping -n 4 127.0.0.1 >nul' + "`r`n" + 'rmdir /s /q "' + $BaseDir + '"' + "`r`n" + 'del /f /q "%~f0"' + "`r`n"
    try {
      Set-Content -Path $cleanup -Value $text -Encoding ASCII
      Start-Process -FilePath $cleanup -WindowStyle Hidden
      Say ('  已排定 3 秒后删除 ' + $BaseDir + '（含本脚本；后台执行，删不掉通常是文件被占用）')
    } catch {
      Say ('  [警告] 无法排定删除：' + $_.Exception.Message + '；请手动删除 ' + $BaseDir)
    }
  }
}

Say ''
Say '==================== 卸载完成 ===================='
Say ' 重新安装：'
Say ('   powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $BaseDir 'install-tasks.ps1') + '"')
if ($DryRun) { Say ' （本次是 DryRun，什么都没有改动）' }