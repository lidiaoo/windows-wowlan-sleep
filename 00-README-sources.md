# AutoReSleep 文件来源说明（source map）

> 规则：**文件名前缀 = 数据来源**。看名字就知道这条信息是谁给的、能不能信、出问题该查哪一层。

## 1. 来源前缀

| 前缀 | 数据来源 | 依赖什么 | 可信度说明 |
|---|---|---|---|
| `drv-` | 无线网卡驱动 / NDIS（ETW 事件 10305 `Wake reason: …`） | **依赖驱动厂商实现** | 报了就是准确的；不报就是 `NO_DATA`（本机 Intel/Killer 时而沉默） |
| `pkt-` | 本机 UDP 监听器（端口 9/7/67/68 上的魔法包特征 + 45678 标记包） | 与驱动无关；需发端连发或多发一个标记包 | 抓到即是魔法包/标记包，最直接 |
| `os-` | 操作系统网络状态（`netsh wlan show interfaces` / `ping` 退出码 / WLAN AutoConfig 事件日志） | **与驱动、与 Windows 版本都无关**（Vista+） | 链路是否丢失可靠；网关毫秒阈值可校准 |
| `dec-` | 判定器 AutoReSleep 的结论 | 综合上面三条链 | 是结论，行内 `src=` 指明用了哪条链 |
| `trace-` | ETW 追踪记账（哪次睡眠前真的开着追踪） | — | 用来解释"为什么 `drv-` 是 NO_DATA" |
| `state-` | 内部记号（断点/防抖/去重） | — | 不用来看结论 |

## 2. 文件清单

| 文件 | 来源 | 写入者 | 内容 / 怎么看 |
|---|---|---|---|
| `drv-wakereason-history.log` | drv | capture 任务（休眠恢复时） | 驱动每次上报的唤醒原因；含 `etl_present=` / `etl_mb=` 诊断。`class=NO_DATA` = 驱动这次没报 |
| `drv-wakereason-last.txt` | drv | capture 任务 | 最近一次驱动原因（带 `wakeTime`，判定器用它校验是否属于当前这次唤醒） |
| `drv-ndis-trace.etl` | drv | arm / resleep / listener | 睡眠期间正在录的原始 ETW 抓取 |
| `drv-ndis-trace-last.etl` / `.xml` | drv | capture 任务 | 最近一次采集保留的原始抓取：出现 `NO_DATA` 时用它区分"没开追踪"还是"驱动没上报" |
| `pkt-magicpacket-seen.log` | pkt | 监听器 | 每次抓到包的记录：`DETECTED kind=magic\|marker src=IP:端口 len=…` |
| `pkt-magicpacket-last.txt` | pkt | 监听器 | 最新包证据：`<unix秒> magic\|marker`（判定器读取） |
| `pkt-listener.lock` | pkt | 监听器 | 单实例锁（内容=监听器进程号） |
| `os-wlanlink-evidence.txt` | os | evidence 任务（恢复时） | 本次唤醒的链路判定：`class=LINK_LOST\|LINK_INTACT\|UNKNOWN` + `why=…` |
| `os-wlanlink-evidence.log` | os | evidence 任务 | 同上的**原始信号**：SSID / BSSID / 睡前快照 / 网关毫秒 / 恢复前后 WLAN 事件计数 → 用来校准阈值 |
| `os-wlanlink-presleep.txt` | os | resleep（入睡前） | 入睡前的 SSID/BSSID 快照，用于对比恢复后是否换了 AP |
| `dec-resleep.log` | dec | resleep | 判定全过程：`reason=`（结论）、`src=`（来源链）、`udp=[]`、各门控。**这是主判定日志** |
| `dec-resleep-heartbeat.txt` | dec | resleep | 每次运行覆盖写：`时间 | 决策 | 原因 | 唤醒源 | 空闲秒数` → **看它一秒判断是否还在运行** |
| `dec-wakereason-history.log` | dec | resleep | 判定器合并后的结论（`reason-src=pkt-… / os-… / drv-…`），与 `drv-` 分开存放，避免混淆 |
| `trace-arm-history.log` | trace | arm / capture / listener / resleep | 追踪账本：`ARM` / `DISARM` / `KEEP-ARMED` / `capture done` / `session-running=` / `etl-present=` |
| `trace-arm-state.txt` | trace | arm 任务 | 最近一次的武装状态 |
| `trace-armed-since.txt` | trace | resleep | 本轮到目前的武装时刻（防抖用） |
| `state-*.txt` | state | resleep | 内部记号：`state-input-tick-at-sleep`、`state-last-forced-sleep`、`state-last-user-present-skip`、`state-reason-history-last` |

## 3. 脚本（角色 / 来源 / 何时跑）

| 脚本 | 来源 | 什么时候跑 | 干什么 |
|---|---|---|---|
| `resleep.ps1` | dec | 每 2 分钟（任务兜底）＋ 监听器快路径（空闲 ≥120s 时每 30 秒）＋ 唤醒时 | 读三条链的证据 → 决定是否强制回睡；维护追踪武装；写 `dec-*` |
| `wake-reason-capture.ps1` | drv | 唤醒时 | 停追踪、解析 ETW、写 `drv-wakereason-*`（驱动视角） |
| `wake-reason-arm.ps1` | drv | 入睡时（Kernel-Power 42） | 打开 NDIS/Kernel-Power 的 ETW 追踪 |
| `wol-listener.ps1` | pkt | 登录常驻（隐藏） | 监听 9/7/67/68/45678 收魔法包/标记包；顺带每 10 秒武装追踪、空闲时触发判定快路径 |
| `wlan-wake-evidence.ps1` | os | 唤醒时 | 采样链路状态（netsh/ping/WLAN 日志）→ 写 `os-wlanlink-*` |
| `run-hidden.vbs` | — | 被任务调用 | 隐藏启动器（配合 `wscript.exe` 后任务不再闪黑窗口） |
| `NativeIdle2.dll` | — | 被脚本加载 | 空闲时间 / 原始输入 tick / 挂起 API 的小辅助（预编译，加载约 60 ms） |

## 4. 计划任务（`taskschd.msc` → 任务计划程序库 → Hermes）

| 任务 | 触发器 | 运行身份 | 作用 |
|---|---|---|---|
| `Hermes-AutoResleep` | 每 2 分钟 ＋ 从睡眠恢复时 | 当前用户（最高权限） | 判定兜底；并在监听器挂掉时把它拉起 |
| `Hermes-WakeReasonArm` | 进入睡眠（Kernel-Power 42） | SYSTEM | 打开 ETW 追踪（drv 链） |
| `Hermes-WakeReasonCapture` | 从睡眠恢复（Power-Troubleshooter 1） | SYSTEM | 采集驱动上报的唤醒原因（drv 链） |
| `Hermes-WlanWakeEvidence` | 从睡眠恢复（同上） | SYSTEM | 采集链路状态证据（os 链） |
| `Hermes-WolListener` | 用户登录 | 当前用户（最高权限） | 常驻抓包 + 追踪武装（pkt 链） |

## 5. 判定优先级（谁盖谁）

1. `pkt-` 抓到 `magic` 或 `marker` → **判为魔法包唤醒 → 永不回睡**
2. `drv-` 明确给出 `NON_MAGIC_*`（如 `AP Association Lost`） → 按非魔法处理（无人时快速回睡）
3. 唤醒源归属（`wake=` 字段）——两条独立来源，先成立者定：
   - `drv-` 事件 10305 原文 “The network adapter indicated a wake signal … Wake reason: X” 里是**无线专属原因**
     （`AP Association Lost` / `AP Disassoc` / `Roam` / `GTK rekey` / `4-Way`）→ 直接判 `wifi-nic`
     （`who=driver:NON_MAGIC_*`）。这是网卡自己说「是我唤醒的」，比 Windows 的归属更强：
     换网卡后 Windows 已经不再把唤醒归给设备（`powercfg /lastwake` 一律写「固定功能/电源按钮」），
     但驱动仍然照报，所以 **`NON_MAGIC_AP_ASSOC_LOST` 这类驱动明确的非魔法唤醒照旧回睡**。
     有线网卡只可能报 media（网线）变化，不会报 AP 关联丢失，因此这个推断是安全的。
   - 没有驱动唤醒信号时，用本机现存网卡名单（描述 + 去掉 ` #N` 的描述）匹配 `WakeSourceText`、
     再匹配 `powercfg /lastwake` 输出里的设备名：
     `wifi-nic` 才有资格快速回睡；`eth-nic` / `other-device` / `timer` 视为有意唤醒（`wake-source-*`）；
     `fixed-feature-nic-suspect`（Windows 没给设备名、没有唤醒定时器、唯一武装的唤醒设备是网卡、驱动也没报）
     默认 `-UnattributedWakePolicy=skip` 不回睡，改成 `resleep-if-unattended` 才在「上次入睡后无人操作」前提下回睡。
4. `os-` 的 `LINK_LOST` **只是线索**（`link=` 字段），不单独构成结论：只有当 `wake=wifi-nic` 时才升级为
   `NON_MAGIC_WLAN_LINK_LOST`，否则不影响判定（见第 8 节）。
5. 三条都拿不到 → **不猜**：本地键鼠空闲 ≥15 分钟且无远程连接才回睡
6. 任何情况下 `remote-in-use`（有入站远程会话）、`display-in-use`（全屏视频）、`media-playing`、`update-running` 都会挡住回睡

## 6. 常见问题 → 该看哪个文件

| 问题 | 看这里 |
|---|---|
| 这次是不是魔法包唤醒？ | `dec-resleep.log` 的 `reason=` + `src=`；原始证据在 `pkt-magicpacket-seen.log` |
| 为什么历史里没有驱动原因？ | `drv-wakereason-history.log` 的 `etl_present/etl_mb`，再看 `trace-arm-history.log` 有没有 ARM | 
| 判定说「不是网卡」但理由又是 `NON_MAGIC_WLAN_LINK_LOST`？ | 说明出现了矛盾：看 `dec-resleep.log` 行里的 `who=`（归属依据：`name:` / `lastwake:` / `only-nic-armed`）和 `link=`（线索）。`who=` 里的名字必须和 `Get-NetAdapter` 里现存网卡对得上 |
| 换网卡之后一直不回睡？ | `dec-resleep.log` 的 `wake=`：`fixed-feature-nic-suspect` 说明 Windows 没把唤醒归给设备名（只有网卡是武装设备）→ 要么改成 `-UnattributedWakePolicy=resleep-if-unattended`，要么先把网卡的报告行为修好（`*WakeOnPattern=0` 减少非魔法唤醒） |
| 这套东西还在运行吗？ | `dec-resleep-heartbeat.txt` 的时间戳（2.5 分钟内即正常） |
| 关键睡眠期间追踪开着没有？ | `trace-arm-history.log`：`ARM` / `KEEP-ARMED` / `DISARM` / `capture done` |
| 想调链路判据的阈值？ | `os-wlanlink-evidence.log` 里的 `gwMs` / `bssid` / `ev=` 分布 |

## 7. 维护命令

```powershell
# 重启监听器（清掉任何残留实例，需要管理员）
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? { $_.CommandLine -match 'wol-listener' } | % { Stop-Process -Id $_.ProcessId -Force }
Remove-Item "$env:LOCALAPPDATA\HermesTools\pkt-listener.lock" -Force -ErrorAction SilentlyContinue
Start-Process wscript.exe -ArgumentList '//B','//Nologo',"$env:LOCALAPPDATA\HermesTools\run-hidden.vbs","$env:LOCALAPPDATA\HermesTools\wol-listener.ps1" -WindowStyle Hidden

# 看是否在跑
Get-Content "$env:LOCALAPPDATA\HermesTools\dec-resleep-heartbeat.txt"

# 追踪手动收尾
logman stop HermesNdisWake -ets
```

## 8. 已知限制（先说清楚，免得误判）

- **睡眠中唤醒主机的那个魔法包在网卡固件里就被消费掉了**，主机侧任何抓包（含本项目）都看不到它本身；Linux 同样如此。`pkt-` 抓到的是回醒之后到达的重复包/标记包。
- **驱动是否上报唤醒原因由厂商决定**，本机 Intel/Killer 时而沉默 → 所以需要 `os-` 和 `pkt-` 两条备用链。
- **换网卡 / 重装驱动会改掉“唤醒源字符串”**（本机 AX1650i → AX210，接口名 WLAN → WLAN 5，描述后面还会多一个 ` #2`）。
  判定里的网卡名单必须每次从本机 `Get-NetAdapter` 重建（描述 + 去掉 ` #N` 的写法），再和 `powercfg /lastwake`、
  `powercfg /devicequery wake_armed` 对照；**绝不能在脚本里写死型号名**。历史教训：写死 `AX1650i` 之后，
  唤醒源变成别的名字 → 每一次唤醒都被判成「不是网卡」，而理由链仍然输出 `NON_MAGIC_WLAN_LINK_LOST`，
  两条链自相矛盾，回睡静默失效。
- **`os-` 的 `LINK_LOST` 不能单独当结论**：任何一次恢复都要重新关联/漫游，所以它也会出现在「确定是被要求唤醒」的
  那次上——本机 12:00 那次是魔法包唤醒（UDP 监听器抓到 magic@+2s），`os-` 给的是 `bssid-changed → LINK_LOST`；
  12:40 那次同样是魔法包唤醒，`os-` 给的是 `LINK_INTACT`。因此它只作为 `link=` 线索记录。
- **`WakeSourceType=1` + 空文本 = Windows 未能归因**（`powercfg /lastwake` 会写成「固定功能 / 电源按钮」）。
  它不等于「真的是定时器」，也不必然等于「真的按了电源键」：本机换网卡后四次自动唤醒都是这个形态。
  判定里区分：`timer`（Kernel-Power 107 有 ProgrammedWakeTime）、`fixed-feature-nic-suspect`（没定时器且只有网卡是
  武装的唤醒设备）、`fixed-feature`（还有别的武装设备）。**驱动报了无线专属唤醒原因时以驱动为准**
  （实测 00:19:55 那次：Windows 说「电源按钮」，驱动 10305 说 `Wake reason: AP Association Lost`，确实是网卡唤醒的，
  判定按驱动给了 `wifi-nic` 并回睡）。反过来，驱动没报就不能当成网卡唤醒——同一晚 00:31:03 那次 15 秒后醒来的
  唤醒既没有设备名也没有唤醒信号，只能按 `fixed-feature-nic-suspect` 记录。
- **`fixed-feature-nic-suspect` 不等于「一定是网卡」**：用户按电源键唤醒时，只要没有别的武装设备，也会落到这个分类。
  所以默认策略是 `skip`；开 `resleep-if-unattended` 时靠 tier A 的 60 秒 grace（期间会复查输入 tick）来避免和用户抢。
- **`drv-` 链路经常是空的，原因是武装时机**：`Kernel-Power 42`（进入睡眠）触发的 arm 任务在睡眠瞬间被冻结，
  往往等**恢复之后**才真正 `logman start`（本机 23:03 入睡、23:05 恢复，落盘的 ETL 只有 23:05:01–23:05:02 共 1.1 秒）；
  而监听器「用户一动就 DISARM」的策略，正好会在用户停手、机器随后入睡的那一刻把追踪关掉。
  要让 `drv-` 有数据，必须让追踪在入睡**之前**就已经开着（事件 10305 的关键字掩码 = `0x4000000000004010`，
  可用 `wevtutil gp Microsoft-Windows-NDIS /ge:true` 复查），并且恢复后不要马上停会话（网卡可能在恢复后几十秒才上报）。
- **`os-` 的判据是代理指标**（恢复瞬间是否已关联 / BSSID 是否变化 / 网关响应毫秒），阈值 3000 ms 为保守初值。
- 早起版本的旧文件名已备份：脚本为 `*.bak-name`，数据为 `wake-reason-history.log.bak-name`；旧件在 `_obsolete/`。