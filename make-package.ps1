<#
  Hermes AutoReSleep - build a copy-ready ZIP  (make-package)
  ==========================================================
  Why: carrying "the whole folder" to another PC is how half-copied
  installations happen. This produces ONE file instead.

    1) double-click make-package.cmd (no admin needed)
    2) copy dist\HermesTools-<stamp>.zip to the target PC, unzip anywhere
    3) double-click install-tasks.cmd there (UAC -> Yes)

  The zip contains ONLY what the target PC needs:
      scripts (*.ps1), run-hidden.vbs, NativeIdle2.dll,
      install/uninstall (ps1+cmd), 00-README-sources.md, QUICKSTART.txt
  Logs, *.etl traces and state-*.txt are excluded on purpose: they are
  this machine's evidence, meaningless (and large) on another one.

  Params:
    -OutDir <dir>     where to write the zip   (default: <project>\dist)
    -OutFile <path>   explicit zip path
    -NoVerify         skip the post-build check (not recommended)
    -OpenFolder       open the folder with the zip when done
#>
[CmdletBinding()]
param(
  [string]$OutDir = '',
  [string]$OutFile = '',
  [switch]$NoVerify,
  [switch]$OpenFolder
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Say { param([string]$m = '') Write-Host $m }

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $BaseDir) { Say 'ERROR: cannot resolve the script directory.'; exit 1 }
$BaseDir = [System.IO.Path]::GetFullPath($BaseDir)

# Same file list install-tasks.ps1 pre-checks on the target machine.
# RuntimeFiles are mandatory (missing one = broken install), AuxFiles are nice to have.
$RuntimeFiles = @('resleep.ps1', 'wol-listener.ps1', 'wake-reason-arm.ps1', 'wake-reason-capture.ps1', 'wlan-wake-evidence.ps1', 'run-hidden.vbs')
$AuxFiles     = @('NativeIdle2.dll', '00-README-sources.md', 'QUICKSTART.txt', 'install-tasks.ps1', 'uninstall-tasks.ps1', 'install-tasks.cmd', 'uninstall-tasks.cmd', 'make-package.ps1', 'make-package.cmd')

Say '============================================================'
Say ' Hermes AutoReSleep - 打包（生成可拷贝到别的电脑的 zip）'
Say (' 时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say '============================================================'
Say ''
Say ('项目目录：' + $BaseDir)

# ---- 1. precheck ----
Say ''
Say '---- 1. 预检 ----'
$missing = @()
foreach ($f in $RuntimeFiles) { if (-not (Test-Path (Join-Path $BaseDir $f))) { $missing += $f } }
if ($missing.Count -gt 0) { Say ('失败：缺少运行文件：' + ($missing -join ', ')); exit 1 }
Say ('  运行文件齐全：' + ($RuntimeFiles -join ', '))
foreach ($f in $AuxFiles) { if (-not (Test-Path (Join-Path $BaseDir $f))) { Say ('  [提示] 可选文件不存在，不会打进包里：' + $f) } }

# syntax check: never ship a half-written script to another machine
$badParse = @()
foreach ($f in @(($RuntimeFiles + 'install-tasks.ps1' + 'uninstall-tasks.ps1') | Where-Object { $_ -like '*.ps1' } | Select-Object -Unique)) {
  if (-not (Test-Path (Join-Path $BaseDir $f))) { continue }
  try {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $BaseDir $f), [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) { $badParse += ($f + ' -> ' + $errs[0].Message) }
  } catch { $badParse += ($f + ' -> ' + $_.Exception.Message) }
}
if ($badParse.Count -gt 0) { Say ('失败：语法检查不通过：' + ($badParse -join ' ; ')); exit 1 }
Say '  语法自检：通过'

# ---- 2. stage ----
Say ''
Say '---- 2. 收集文件 ----'
$stage = Join-Path $env:TEMP ('hermes-pkg-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$stageRoot = Join-Path $stage 'HermesTools'
try {
  New-Item -ItemType Directory -Path $stageRoot -Force -ErrorAction Stop | Out-Null
} catch { Say ('失败：无法创建临时目录 ' + $stageRoot + ' -> ' + $_.Exception.Message); exit 1 }

$staged = @()
foreach ($f in ($RuntimeFiles + $AuxFiles)) {
  $src = Join-Path $BaseDir $f
  if (Test-Path $src) {
    try { Copy-Item -Path $src -Destination (Join-Path $stageRoot $f) -Force -ErrorAction Stop; $staged += $f }
    catch { Say ('  [警告] 复制失败：' + $f + ' -> ' + $_.Exception.Message) }
  }
}
Say ('  已收集 ' + $staged.Count + ' 个文件：' + ($staged -join ', '))

# ---- 3. zip ----
Say ''
Say '---- 3. 生成 zip ----'
if (-not $OutFile) {
  $dir = $OutDir
  if (-not $dir) { $dir = Join-Path $BaseDir 'dist' }
  $OutFile = Join-Path $dir ('HermesTools-' + (Get-Date -Format 'yyyyMMdd-HHmm') + '.zip')
}
$OutFile = [System.IO.Path]::GetFullPath($OutFile)
$outParent = Split-Path -Parent $OutFile
try { New-Item -ItemType Directory -Path $outParent -Force -ErrorAction Stop | Out-Null } catch { Say ('失败：无法创建目录 ' + $outParent); exit 1 }
if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
try {
  Compress-Archive -Path $stageRoot -DestinationPath $OutFile -CompressionLevel Optimal -ErrorAction Stop
  Say ('  [OK] ' + $OutFile)
} catch {
  Say ('失败：打包出错 -> ' + $_.Exception.Message)
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  exit 1
}
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

# ---- 4. verify the zip itself (open it again and look inside) ----
$sha = ''
$size = 0
$entries = @()
if (-not $NoVerify) {
  Say ''
  Say '---- 4. 校验 zip ----'
  try {
    $size = (Get-Item $OutFile).Length
    $sha = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $za = [System.IO.Compression.ZipFile]::OpenRead($OutFile)
    foreach ($e in $za.Entries) { if (-not $e.Name) { continue } $entries += $e.Name }
    $za.Dispose()
    $inZip = @($entries)
    $notIn = @()
    foreach ($f in $RuntimeFiles) { if ($inZip -notcontains $f) { $notIn += $f } }
    if ($notIn.Count -gt 0) { Say ('失败：zip 里缺少运行文件：' + ($notIn -join ', ')); exit 1 }
    Say ('  条目 ' + $inZip.Count + ' 个，运行文件全部在包里')
    Say ('  大小 ' + [math]::Round($size / 1KB, 1) + ' KB')
    Say ('  SHA256 ' + $sha)
  } catch {
    Say ('  [警告] 打开 zip 校验失败：' + $_.Exception.Message)
  }
} else { Say ''; Say '已按 -NoVerify 跳过校验。' }

# ---- 5. how to use it on the other machine ----
Say ''
Say '==================== 打包完成 ===================='
Say (' zip：' + $OutFile)
if ($sha) { Say (' sha256：' + $sha + '   （拷过去后可当面核对，确认没拷坏）') }
Say ''
Say ' 在别的电脑上（三步）：'
Say '   1) 把上面的 zip 拷过去，随便解压到哪个目录'
Say '   2) 双击解压出来的 install-tasks.cmd → UAC 点“是”'
Say '      （它会先把项目复制到 %LOCALAPPDATA%\HermesTools 再注册任务，所以解压目录/U盘拔掉都没关系）'
Say '   3) 看到“全部完成”即可；想先看会改什么就在第 2 步前先跑一次 install-tasks.cmd -DryRun'
Say ''
Say ' 想卸载：双击解压目录里的 uninstall-tasks.cmd（它从已注册任务反查安装目录，从哪儿双击都行）'
Say '        加 -PurgeLogs 连日志一起删，加 -PurgeLogs -RemoveToolDir 连目录一起删。'
Say ''
Say ' 包里没有日志/ETW 抓取（那些只对生成它的那台机器有意义）；换机器前建议先看一遍'
Say ' 安装脚本 -DryRun 打印的 WoL 现状（*WakeOnMagicPacket / *WakeOnPattern 是网卡驱动设置，不属于本项目）。'

if ($OpenFolder) { try { Start-Process explorer.exe -ArgumentList ('/select,"' + $OutFile + '"') } catch {} }