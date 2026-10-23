# TV 端 CEC 桥接：部署与运维记录

初次记录：2026-10-18；代码 review 更新：2026-10-23
适用：小米电视 6 至尊版（L65M7-Z1 / walle，Android 9）

## 0. 现状

小米电视 CEC 缺陷的根因已定位；纯软件、全部运行在电视本地的桥接方案已部署，并完成
真实 Apple TV 遥控端到端验证。核心链路（休眠中收 CEC → 唤醒 → 强制切输入；
进入休眠 → 给外设发 Standby；重启自愈）均已验证，设备上的测试脚本已清理。

上段及第 5 节描述 10 月 18 日的历史验收。10 月 23 日新增亮屏切源及状态机修复，
验证范围和待做的真实遥控验收见第 9 节；不要把历史验收当作新版已经通过实机测试。

## 1. 设备与环境

- 电视：`<TV_IP>:5555`，型号 `MiTV-MFZP0`（walle，小米电视 6 至尊版 L65M7-Z1），
  Android 9 / API 28，32 位 userspace，user build，SELinux Enforcing，dm-verity Enforcing。
- ADB 已授权，`adb connect <TV_IP>:5555`。
- 验证时电视状态（2026-10-18 02:24）：**Awake**，前台 `ExternalSourceActivity`，HDMI1（Apple TV）；
  息屏仍为 goToSleep reason 8。电源键是 toggle：`adb shell input keyevent 26`
  醒着时息屏、睡着时唤醒。
- Apple TV：`<ATV_IP>`，`AppleTV14,1`，CEC logical **8**，physical **0x1000** → HDMI1 → input 23。
- PS5：CEC logical **4**，physical **0x2000** → HDMI2（ARC）→ input 24。

## 2. 根因（已实测确认）

小米修改了 framework 的 `HdmiControlService`：goToSleep reason 为 **8**（小爱息屏）时跳过
`onStandby()`，`mPowerStatus` 永远停在 0 (ON)。后果：

- 所有 CEC 唤醒路径被 `isPowerStandbyOrTransient()` 门控 → **不响应 CEC 唤醒**；
- **不发 `<Standby>`** → 不联动关闭外设。

reason 6（KEYCODE_SLEEP）行为正常，可作对照。详细证据见 `FINDINGS.md`。

## 3. 已落地方案（不依赖外部硬件/另一台常开机器）

### 3.1 root 原语

`TvService` Binder transaction **4400**（`MITV_SERVICE_MISYSDIAGNOSE`）无权限检查，写入
`vendor.misysdiagnose.cmd.arguments/.cmd.code` 后由 `init.mitv.rc` 以 root 执行
`/vendor/bin/misysdiagnose`，它会执行 `/data/diagnosis/command.sh`。
辅助 APK 通过反射调用 4400 启动 `/storage/emulated/0/cec-bridge/launch.sh`（uid 0）。

### 3.2 开机自启 / 看门狗

- APK v2（`io.github.cecbridge`）用 **persisted JobScheduler**：
  - 周期任务 4242（0x1092，15 分钟）；
  - 一次性持久链 4243↔4244（0x1093/0x1094，min latency 120 s，互相续约）。
- 该机型不给第三方 App 发 BOOT_COMPLETED，因此不能靠广播。
- 已验证：开机约 100 s JobService 启动 App 进程并拉起守护进程；运行期看门狗也会续拉
  （launch.log 中 02:02:54 的 launch invoked 即周期任务，发现 daemon 已在运行）。

### 3.3 ADB 自愈

`TvService` transaction **4004**（`ENABLE_ADB`）无权限检查：写 1 → `adb_enabled=1`。
注意：**同值 putInt(1) 不会唤醒 UsbService**，必须先写 0、等 adbd 停止，再写 1；
0→1 的停止有约 7–10 s 延迟。守护进程每 10 s 检查 `init.svc.adbd`，掉线时执行 0→1 拉起。
标记文件 `/storage/emulated/0/cec-bridge/keep-adb` 控制是否启用。

### 3.4 守护进程

- 设备路径：`/storage/emulated/0/cec-bridge/cec-bridge.sh`；
  源码：`tv-side/cec-bridge.sh`。
- 运行时 PID 以 `daemon.pid` 为准；心跳文件 `heartbeat` 每 2 s 刷新；
  `lock` 目录防重复实例。
- 亮屏和休眠中均约每 2 s 读 `dumpsys hdmi_control` 的 CEC history，只匹配收到的显式请求：
  `<Image View On>`、`<Text View On>`、`<Active Source>`（src 1–14）。没有全局冷却；
  同设备尚在执行的请求合并，换设备取消旧任务，同一批消息取最新请求。
- **不使用 `<Report Power Status params: 00>` 触发唤醒**：它可能是 60 s 轮询的正常回复，
  也可能是待机设备的误报（PS5/Switch 都出现过），用它做触发会导致电视刚睡就被叫醒。
  任何设备真正唤醒时都应发送显式的 `<Image View On>` / `<Text View On>` / `<Active Source>`。
- logical address 统一按两位十六进制解析（`0x0B` 与 `0x0b` 等价）；
  输入只通过 TV 自己的 `port_id` 映射（1→23、2→24、3→25、4→26）。
  查不到设备或端口时**不猜默认值**，记录日志并放弃切源，避免把 Switch 误切到 Apple TV。
- 息屏时顺序：**先 wakeUp，等 Awake，sleep 2 s 让主页落定，再启动输入 Activity，
  最后同时校验 `mActiveRoutingPath` 和 `mResumedActivity`**。本来亮屏时直接切输入。
- 每个新请求至少执行一次真实输入选择，不能因 path 和前台 Activity 已匹配就提前返回：
  CEC 可以先更新 path，而显示 PS5 与 Apple TV 的 Activity 名称完全相同。
  最多尝试 5 次；调用后两项系统状态都匹配才记录 `input ok`，实际画面仍需确认。
- 唤醒：
  `service call power 9 i64 <mLastSleepTime+1> s16 'android.policy:POWER' s16 android`
  （root 域读不到 `/proc/uptime`，用 dumpsys 的 mLastSleepTime 代替；mLastWakeTime 也可）。
- 切输入：`service call TvService 3000 s16 start s16
  "-a com.xiaomi.mitv.tvplayer.EXTSRC_PLAY -n com.xiaomi.mitv.tvplayer/com.xiaomi.mitv.tvplayer.ExternalSourceActivity --ei input 23"`
  。返回 `Not a data message` 是回包解析噪音，命令实际生效。
  input 23/24/25/26 ↔ routing path `0x1000/0x2000/0x3000/0x4000`。
- 进入休眠至少 3 s 后，对已发现的 logical address 1–14 发
  `service call hdmi_control 30 i32 0 i32 <logical>`（`<Standby>`）。主循环在下一次轮询执行，
  发送前复查状态；电视已醒或收到切源请求时取消待机。跳过电视和广播地址。

## 4. root 域（u:r:misysdiagnose:s0, uid 0）能力边界

- 可以：`dumpsys`、`service call`、读写 `/sdcard`、运行后台脚本、`setsid`。
- 不可以：读 `/proc/uptime`（Permission denied）、`app_process`、`/system/bin/settings`、
  `cmd settings/activity`、`setprop service.adb.tcp.port` / `ctl.start`、dmesg、
  `/dev/input`、`/dev/block`、`setenforce`、`/data/local/tmp`（shell_data_file 拒绝）。
  → 需要这些能力时必须走 TvService 原语，不要试图在 root 脚本里直接做。

## 5. 已验证结果（2026-10-18）

- **休眠中 CEC 收发正常**：reason-8 息屏期间电视仍每 60 s 发 `<Give Device Power Status>`
  并收到各设备的 `<Report Power Status params: 01>`；history 持续更新。
  这是整个触发方案成立的前提。
- **唤醒 + 预切输入**：用模拟 CEC history（`CEC_TEST_HIST`）在休眠中注入 `<Active Source>`
  src=8，守护进程成功唤醒并切到 HDMI1：`wake preselect ok src=8 path=0x1000`，
  `mResumedActivity=ExternalSourceActivity t4`，截图确认显示 Apple TV 画面。
- **真实 Apple TV 遥控端到端（2026-10-18 02:23）**：02:23:32 收到 src=8 触发，
  02:23:33 唤醒，02:23:35 记录
  `wake: path ok but foreground not ExternalSourceActivity, forcing input src=8`，
  02:23:38 `wake preselect ok src=8 path=0x1000`；随后
  `mResumedActivity=ExternalSourceActivity t7`、`mActiveSource=(0x08,0x1000)`，
  屏幕停在 Apple TV 输入。此前 02:13 的失败是旧逻辑只校验 path、误判“已切好”直接返回。
- **Apple TV 显式唤醒复测（2026-10-18 21:57）**：21:57:52 Apple TV 发
  `<Image View On> src: 8`；21:57:53 `wake trigger: src logical=8 input=23`；
  21:57:59 `wake preselect ok src=8 path=0x1000`。确认移除 `Report Power Status 00`
  触发后，ATV 仍通过显式 CEC 消息正常唤醒。
- **通用唤醒策略实测（2026-10-18 18:38–21:52）**：
  - 18:38:07 息屏，18:38:10 向 logical 4/8/11 全部发 `<Standby>`；之后电视持续 Asleep，
    期间 PS5/Switch 的轮询回报不再触发唤醒。
  - 21:52:44 Switch（logical **0x0B**，HDMI3）发 `<Image View On>` + `<Active Source>`
    （physical 0x3000）；21:52:45 记录 `wake trigger: src logical=11 input=25`；
    21:52:49 `wake preselect already ok src=11 path=0x3000`。
  - 同一次唤醒中 Apple TV 在 21:52:48 仍回报 `power_status 01`，没有被误唤醒。
  - PS5 的主动唤醒（15:19:38 `<Text View On>` + `<Active Source>`）同样正常。
- **旧逻辑的失败模式（已移除）**：
  - `input_for_src` 用 `0x0$1` 拼地址，logical 11 变成 `0x011` 查不到，默认落到 HDMI1；
  - `send_standby_all` 的 `[0-9a-f]` 不匹配大写 `0x0B`，Switch 从未收到 Standby；
  - 用 `Report Power Status 00` 做唤醒触发，PS5/Switch 的轮询回复会反复叫醒电视。
- **关机联动**：进入息屏后 `[S] <Standby> src: 0, dst: 4/8/11` 已发出；Apple TV 会进入待机，
  PS5 可能忽略该 Standby（需在 PS5 开启 Power Off Link 才能跟随睡眠）。
- **ADB 自愈 / 开机自启**：persisted JobScheduler 在重启后拉起 App、launch.sh 恢复 adbd；
  运行期看门狗继续生效。
- **WOL 失败**：向 Apple TV 的 ARP MAC 与 AirPlay deviceid MAC 发 magic packet 均未唤醒
  （疑似 Wi-Fi、无 WoWLAN）。真实唤醒测试必须用 Apple TV 遥控器。

## 6. 清理与后续

1. 真实端到端测试已完成：
   - Apple TV（02:23）：遥控唤醒 → HDMI1 → `path=0x1000`；
   - PS5（15:19）：手柄唤醒 → `<Text View On>`/`<Active Source>` → HDMI2 → `path=0x2000`；
   - Switch（21:52）：`<Image View On>` src=0x0B → HDMI3 → `path=0x3000`，Apple TV 未被误唤醒。
2. 设备上的测试脚本/日志已清理，保留运行必需文件：`cec-bridge.sh`、`launch.sh`、
   `daemon.log`、`launch.log`、`daemon.pid`、`heartbeat`、`lock`、`keep-adb`、
   `restart.sh`、`stop.sh`。
3. 重启自愈已验证：2026-10-18 01:46 与 13:09 两次重启后，守护进程均由 persisted jobs
   自动拉起，脚本版本未丢。
4. 可选：再接入一台新 HDMI-CEC 设备，确认只靠 `logical address + port_id` 即可自动工作，
   不需要新增设备特例。

## 7. 常用命令

```sh
adb connect <TV_IP>:5555
adb shell dumpsys power | grep -E 'mWakefulness|mLastSleepTime|mLastWakeTime'
adb shell dumpsys hdmi_control | sed -n '/CEC message history:/,/^mEarcControlFeatureEnabled/p' | tail -20
adb shell 'tail -20 /storage/emulated/0/cec-bridge/daemon.log'
adb shell input keyevent 26          # 电源键 toggle：醒→睡 / 睡→醒
adb shell input keyevent 3           # 回主页
```

## 8. 关键文件

- `docs/FINDINGS.md` — 逆向结论与证据。
- `tv-side/cec-bridge.sh` — 守护进程源码。
- `tv-side/launch.sh` — root 启动脚本（部署在设备同路径）。
- `tv-side/apk/` — APK 源码（smali + AndroidManifest）。
- `tv-side/install.sh` — 一键推送 + 安装脚本。
- 设备侧目录：`/storage/emulated/0/cec-bridge/`。

> 本文档是部署与运维记录；TvService 事务号、Activity 名称等均可能随固件版本变化，
> 升级电视系统后需要重新核对。

## 9. 2026-10-23 review 与交接

### 工作区与证据来源

- 当前维护目录为 `/home/yx/cec-bridge`。本轮从 GitHub 获取 `main`，基线为 `07618a7`。
  远端历史已重写，旧目录不能直接 fast-forward；旧提交已保留到本地分支
  `archive/pre-sync-2026-10-23`，再将 main 对齐最新版本。修复作为工作区改动保留。
- Claude 的相关会话为 `b4309177-689b-42cf-9403-ba3bd686992f` 和
  `e840e127-ed53-445c-b4c5-617132366932`；dsh 后续会话为
  `session-1cfe5ff8-c58f-422a-bdd7-c07580d7d51e`。
- 旧研究工作区 `/home/yx/mitv-inspect` 中的 `HANDOFF-cec.md`、`FINDINGS-cec.md`
  和 `.gh-cec-bridge` 保存了 10 月 18 日过程与发布快照。Claude memory 中的
  “外接盒子待定”“先切输入再唤醒”等描述已过时，以当前代码及本仓库文档为准。
- 用户已明确要求：纯软件、全部在电视上运行、无需另一台常开电脑；按 CEC 地址和端口
  通用处理，不能为每个设备追加品牌特例。

### 用户报告与现场核对

用户报告 10 月 22 日“关掉 PS5 后打开 Apple TV，没有自动切过去”。10 月 23 日约 14:59
只读查看电视：守护进程仍是旧版，MD5 为 `b202682ae4dd4687c35f780148bbb2db`。
电视 Asleep，PS5 与 Apple TV 均回报 standby；这说明该次快照中 PS5 已待机，不能证明
它是被桥接的 Standby 触发，不能据此宣称 PS5 跟随待机问题完全验收。

10 月 22 日日志有 20:17:28 PS5 唤醒和 23:24:19 电视息屏记录，没有亮屏期间的切源处理。
原始 CEC history 已被后续轮询覆盖，无法重建昨天 Apple TV 的完整消息序列。
不过代码中 Awake 分支直接丢弃新增消息是确定缺陷，能够解释该场景。

### Review 发现及处理

| 优先级 | 问题 | 本轮处理 |
|---|---|---|
| 高 | Awake 时跳过 CEC 消息，电视亮着时换设备不切输入 | 两种电源状态共用事件处理；Awake 仅切源，Asleep 才唤醒 |
| 高 | path + 前台 Activity 匹配仍可能显示旧 HDMI，提前返回造成漏切 | 每个新请求至少执行一次输入选择，再检查两项系统状态 |
| 高 | 全局 20 s 冷却吞掉新设备请求；并行切源可能互相覆盖 | 移除全局冷却，合并同设备进行中的请求，新请求取消旧任务 |
| 高 | 延迟待机子进程不复查状态，可能关掉刚启动的外设 | 主循环维护待机截止时间，亮屏/切源请求取消，逐条发送前复查 |
| 中 | CEC history 游标丢失时重放尾部 5 行，可能重放旧唤醒 | 启动和游标丢失时重新建立基线，不回放未知时间范围的事件 |
| 中 | 电源查询失败被当成 Awake；设备发现稍慢就放弃 | 未知电源状态不控制；端口发现最多查询 3 次，仍不猜默认输入 |
| 中 | stop 后 APK 看门狗马上重新拉起；退出未清理子任务 | disabled 标记阻止启动；正常退出清理工作进程、PID 与锁 |
| 中 | install 未指定 ADB serial，原地覆盖运行中的 shell 文件 | 所有命令使用 -s；先上传 .new、语法检查，再 rename |
| 低 | daemon.log 只在进程启动时轮转 | 运行期间也定期检查 1 MiB 阈值并轮转一次 |

保留的限制：

- 依然是轮询而非 CEC 事件订阅。极快的息屏/唤醒发生在同一轮询间隔内可能无法区分；
  刚观察到息屏时丢弃上一轮的消息，以避免把息屏前的请求重新当成唤醒。
- 历史游标丢失时优先避免误动作，这一轮的新请求也可能被跳过，需要设备再次发显式请求。
- 切源后的路由与 Activity 检查是系统状态证据，并不是画面识别；真实画面要用遥控验收。
- root 仍受 misysdiagnose SELinux 域限制；本轮未修改 APK、厂商固件或权限策略。
  只有这台 Android 9 机型有历史实测依据，不扩展兼容性承诺。

### 本地验证与实机验收

`tests/test_bridge.py` 用临时目录、模拟 dumpsys/service 测试真实 shell 函数；不连接电视。
覆盖亮屏 PS5 → Apple TV、息屏唤醒、输入 Activity 误判、快速换设备、Switch 大写地址、
换口、发现延迟、待机取消、未知电源状态、历史重放、进程清理与安装目标选择。

```sh
python3 -m unittest discover -s tests -v
BRIDGE_TEST_SHELL='busybox ash' python3 -m unittest discover -s tests -v
```

本轮 **30 项测试在主机 `/bin/sh` 与 BusyBox ash 下均通过**。另在电视原生 shell 中完成：

- `sh -n` 语法检查；
- 只读解析真实电源状态和 Apple TV / PS5 的端口映射；
- 模拟报文验证全部 logical address 1–14、亮屏 PS5 → Apple TV 请求及游标去重；
- 用仅打印输出的工作函数验证旧任务取消和 EXIT trap 不影响主进程。

原生检查发现 Android toybox sed 不支持 GNU BRE 的 `\|` 分支写法，解析已改用 awk，
并显式按数字比较地址，以上检查均已通过。测试中的控制函数全部被模拟，未执行真实
唤醒、切源或外设待机指令。
**新版已于 2026-10-23 15:24 部署；真实 PS5 → Apple TV 遥控场景仍待验收**。
部署只替换四个 shell 脚本并重启桥接，未重装 APK、未重启电视。
原脚本备份在电视的 `/storage/emulated/0/cec-bridge/backup-20261023-152409/`。
15:25 复核：新守护进程 PID 10679、心跳持续更新，电视始终 Asleep，没有重放历史唤醒。
四个安装文件均与工作区哈希一致；`cec-bridge.sh` 的 MD5 为
`4def643b8c8aa8bc232a096d0fa1e411`。

额外通过厂商诊断入口在实际 `uid=0 / u:r:misysdiagnose:s0` 环境核对：电源状态、
Apple TV/PS5 端口映射、历史初始化及模拟亮屏切源请求均正常；控制函数替换为打印，
没有主动唤醒、切输入或令外设待机。验证脚本和输出已从电视清理，备份保留。
部署后的验收顺序：

1. 电视亮屏显示 PS5，关闭 PS5，再用 Apple TV 遥控器打开 Apple TV；确认切到 Apple TV。
2. 20 秒内切换到另一台设备，确认没有被全局冷却或旧任务覆盖。
3. 电视息屏后分别用 Apple TV、PS5、Switch 唤醒，检查画面和输入端口。
4. 电视息屏后立即重新唤醒，确认旧待机任务不会把新设备关掉。
5. 静置超过 60 秒，确认电源状态轮询不会唤醒电视。

### 更新、停用与恢复

先备份设备上的四个 shell 脚本；`install.sh` 会推送新版，但已在运行的守护进程不会因
上传自动更换。APK 没变时也可以只逐个上传 `.new` 文件，`sh -n` 后 `mv` 替换。
保持 `keep-adb`、日志和现有 APK 数据不变。

以下命令使用现有厂商诊断入口在 root 域执行管理脚本。先设置真实电视地址；
运行前确认它处于可中断桥接服务的时段。只重启桥接，不重启电视。

```sh
TV_SERIAL='<TV_IP>:5555'
# 停用并阻止 persisted jobs 自动拉起：
adb -s "$TV_SERIAL" shell service call TvService 4400 s16 s s16 /storage/emulated/0/cec-bridge/stop.sh
# 恢复或重启，清除 disabled 标记后启动：
adb -s "$TV_SERIAL" shell service call TvService 4400 s16 s s16 /storage/emulated/0/cec-bridge/restart.sh
```

`restart.sh` 最多等旧进程 15 秒；若未退出则保留 disabled，停止继续启动，便于排查。
新 daemon 收到 TERM 会取消自己的切源工作进程并清理锁；旧版本不具备该退出清理，
首次升级应在没有进行唤醒/切源时执行。恢复旧版时同样先停桥接、还原备份，再启动。

确认日志有 `daemon start (awake source switching enabled)`、心跳持续更新且只运行一个
守护进程。亮屏切源应记录 `CEC request ... state=Awake`、`activate trigger ... input=...`
及 `input ok`；这些替代旧版的 `wake preselect ok`。
