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


## 10. 2026-10-26 同源重报与 PS5 进出游戏短黑

用户报告 PS5 进入或退出游戏时短暂黑屏，游戏持续运行时正常。主代理本轮只读检查实机
`daemon.log`，发现同一 PS5（logical 4 / input 24）多次触发选择：10-25 10:14:26 为
Asleep 首开，10:14:35 已 Awake 又选择，另有 10:23:01、10:30:52、10:31:27；10-24
也有 23:16:06、23:16:41、23:21:28。当前没有这些时刻对应的完整 CEC/播放器/信号日志，
因此它们证明存在同源重复选择，不能单独证明每次黑屏均由桥接造成。

`1cf613f` 只在同源 worker 仍运行时合并消息；worker 完成后，下一条接收的
Image View On、Text View On 或 Active Source 都会再次执行 `TvService 3000 / EXTSRC_PLAY`。
同源重复 Active Source 的假设备复现，在原本已显示 PS5 时产生两次 input 24 选择。
HDMI signal loss/locked 本身不被脚本读取；Routing Change/Information 也不在触发集合。

缓存原厂 `ExternalSourceActivity` 的反编译结果提供了具体的播放器检查方向：`onNewIntent`
只保存新 Intent；后续 `onResume → initPlayerEnvironment` 会调用 `createPlayerAndSurface`
和 `handleIntent`，后者直接执行 `SourceManager.setCurrentSource(input)`，该方法自身没有
同源短路。`onPause` 则调用 `abolishPlayerEnvironment`。这说明要检查的不是只有
onNewIntent，还包括完整 pause/resume 与 source setter 时间线；下层 SourceManager 是否
同源去重、当次 Intent 是否确实引发画面重建，仍需运行日志佐证。

### 本轮修复

新增只读 `playback_input()`，通过 `dumpsys -t 2 tv_input` 解析**当前用户**的
`mainSessionToken → sessionStateMap → inputId`，仅接受物理 HW4..HW7（HDMI1..4）。
支持真实 key 行后的 SessionState 描述与 Binder/BinderProxy token，不使用 inputMap
“已连接”、CEC routing path 或第一个任意 session 推断实际画面。

仅当请求开始时电视已经 Awake、TIF 确认目标 input、播放器仍为前台且电视仍 Awake，
才记录下面的日志并跳过重选：

```text
input already active src=4 input=24; skip reselect (TIF main + foreground)
```

息屏唤醒仍执行一次真实输入选择。TIF 缺失/读失败/主 token 不可关联/指向其他输入、
或前台不为播放器，都保留原选择路径；不恢复全局冷却，也不按设备品牌写规则。
因此“CEC path 已变成 Apple TV，但 TIF 仍是 PS5”的旧故障仍会执行 input 23 选择。
第 9 节的“每个新请求至少选择一次”是 10 月 23 日策略，本节增加了更强的实际播放证据例外。

### 证据与后续验收

初次实现交付时只改源码和测试，尚未部署；后续实机兼容性结果见下段。假设备回归覆盖同源 worker 完成后的重复消息、
唤醒后再次重报、HOME 前台修复、path/Activity 相符但 TIF 不同、多会话/多用户、缺失与
重复 token、非物理 CEC child input、TIF 读失败，以及查询期间电视睡眠。

本地验证结果：`python3 -B -m unittest discover -s tests -v` 与
`BRIDGE_TEST_SHELL='busybox ash' python3 -B -m unittest discover -s tests -v` 均为
41/41 通过；`sh -n tv-side/cec-bridge.sh`、`git diff --check` 通过。已保存的实机
HDMI1 TIF dump（mitv-hub 的 `.local/tv-input-active-probe.txt`）分别经 host awk 与
BusyBox awk 解析为 input 23，验证使用本地假 dumpsys，未连接设备。

实机应在一次 PS5 进/出游戏过程同时记录以下时间线，由主代理进行：

1. 桥接 `daemon.log` 的 CEC request、activate trigger、input already active/input ok；
2. `dumpsys hdmi_control` history 中的**新接收** Active Source/Image/Text View On，而非只看最终路由；
3. ActivityManager 的 EXTSRC_PLAY 启动/投递、ExternalSourceActivity 的 onNewIntent/source/tune 路径；
4. MTK_KL 时序与 `MtkTvInput(HdmiSelStatusThread)(HDMI)` 的 LOSS/LOCKED，记录刷新率、HDR/VRR
   是否随游戏发生变化；同时核对 TIF main session 与前台。

若看到同源重复消息后只记录 skip、没有对应 EXTSRC_PLAY，但画面仍短黑，则应继续定位
HDMI 时序/HDR/VRR 握手，不能声称该代码修复会消除链路重新锁定所需的黑屏。
TIF 查询在现有诊断 root 域中的可用性也需实机只读验证；不可用时本修复安全回退，
但不会获得同源抑制收益。


### Android 原生 awk 兼容性补修

主代理随后部署首版，实机保护回退到原选择逻辑。定位到 walle 的原生 awk 无法执行
一元逻辑非：最小 `awk 'BEGIN {x=1; print !x}'` 即报
`illegal arithmetic operator 345`。首版的 `!selected` 在 dump 第 2 行触发该错误；
host awk 和 BusyBox awk 均没有暴露这一差异。解析失败时不会错误跳过切源，但同源抑制失效。

本地补修将新解析器的一元非全部改为显式 `== 0`，保留 `!=`、`!~`，两者经实机验证正常。
只读隔离测试将本地新解析器与 fixture 传入电视原生 awk，不修改运行脚本或切源：
4 个物理端口、BinderProxy、空数据、无主会话、权限拒绝文本、CEC child、未知 token 和
已保存真实当前 HDMI1 dump 共 11 项均通过，真实 dump 解析为 input 23。
可按需明确指定已授权电视，复跑兼容性检查：

```sh
python3 -B tests/check_android_awk.py --serial '<TV_IP>:5555'
# 另可加 --fixture '<本地已保存的TIF dump>' --expected-input 23
```

该脚本只执行隔离 `printf | awk`，不上传文件、不切源、不启动服务，普通 unittest 不会
自动访问设备。补修后 41 项本地回归在默认 shell 与 BusyBox ash 下仍全部通过。
补修部署及新 daemon 实际 skip 日志由主代理另行核验。

### 2026-10-26 实际部署结果

修正Android awk兼容性后已实际部署，原脚本备份为电视上的`cec-bridge.sh.pre-20261026`。新daemon PID26578。直接读取实机当前TIF得到input23，`already_showing_input 23`返回0。

16:13:24 Apple TV真实请求触发一次input23选择，16:13:26记录input ok；16:13:28后续同源请求记录`input already active src=8 input=23; skip reselect (TIF main + foreground)`，没有再次执行TvService选择。同期独立输入采集返回HDMI1 observed 3840×2160/60Hz/逐行/Dolby Vision。这证明新root守护进程的真实读取与抑制分支生效，不只是host测试通过。

PS5进出游戏场景本轮没有现场复现，不能据Apple TV去重验证声称PS5的每次黑屏已消除。用户反馈为仅进出游戏时短黑、游戏内稳定。PS5官方支持文档说明HDR自动/按支持输出、120Hz、VRR与ALLM的设置行为；模式重新锁定是待对照的解释，本轮未关闭这些画质功能。参考：https://www.playstation.com/en-us/support/hardware/ps5-4k-resolution-guide/ 。

## 11. 2026-11-12 服务停止与自启恢复

11月11日经pve检查，电视网络和原厂MiLink服务正常，地址未变，但ADB与MiTV控制端口均拒绝连接。11月12日用户重新启用ADB后继续只读核查，发现：

- 没有运行中的CEC守护进程。`daemon.pid`残留5500，但该PID已经属于`com.xiaomi.mi_connect_service`，不能用PID文件或`kill -0`单独判断服务存活，更不能直接杀这个PID。
- 心跳最后更新为11月7日；最后一次启动器日志为11月3日。当前电视已于11月12日重新启动过，旧PID、心跳和锁只是残留文件。
- 辅助APK `io.github.cecbridge`仍已安装、未禁用，但处于`stopped=true`；JobScheduler中没有它的任务。另一个电视控制APK也处于stopped状态，本次没有恢复或启动它。
- 四个运行脚本均与`3f98c9a`完全一致，未发现脚本被改写。`keep-adb`存在、`disabled`不存在。因此已证实的是“守护进程停止，辅助APK停止且自启任务缺失”，不是新的CEC报文解析缺陷。
- 现存日志没有记录是谁或什么机制停止了APK，不能归因于用户清后台、系统升级或某个具体进程；启动器最后日志时间也不能当成APK准确被停止时间。

21:16:16（Asia/Shanghai）启动现有辅助APK入口，恢复既有逻辑，没有重装APK或替换脚本：

```sh
# 先读取电源、前台、disabled标记、PID对应cmdline与心跳；保留原始日志。
# 确认本轮需要恢复CEC且没有有意停用后，再执行：
adb -s '<TV_IP>:5555' shell am start -n io.github.cecbridge/.MainActivity
```

此入口调用启动器、注册任务后立即finish，回到原桌面。避免使用`am start -W`等待这个没有界面的瞬时Activity：本次实际服务已启动后，`-W`客户端仍等待显示结果；已精确结束等待客户端，没有停止恢复后的服务。

恢复后实测：

- `stopped=false`，新守护进程PID14297，心跳持续刷新；启动器正确识别旧PID已非本脚本并回收过期锁，没有误杀旧PID对应的系统进程。
- 15分钟周期任务4242和120秒持久链重新出现，均标记`PERSISTED`。21:18:20任务4243自然运行并续约4244；21:20:23任务4244自然运行并续约4243。两次启动器均确认同一daemon仍在运行，未重复启动。没有用`cmd jobscheduler run -f`冒充自然调度。
- 电视恢复前后保持Awake / Display ON，前台仍为MiTV Hub桌面；没有重启电视、主动唤醒外设、切换输入、改PS5画质或开启摄像头/麦克风。守护进程启动后没有重放历史CEC事件。
- 本次只验证运行恢复、心跳和自然看门狗链；没有重启电视验证本次跨启动恢复，也没有新的真实遥控请求完成端到端切源验收。下一次正常重启和真实外设请求仍需对应日志确认，不能用任务存在或旧验收代替。

后续若再次失效，应先检查APK stopped状态、任务是否仍在、PID身份及心跳是否新鲜，再看CEC历史；不能只读`daemon.pid`就报告“仍在运行”。自启链恢复也不证明再次进入stopped状态后能自行恢复，仍需查清停用来源。本次无需修改CEC匹配或同源保护逻辑。

简化排查命令（读取JobScheduler时仅筛选本应用，避免保存其他应用信息）：

```sh
adb -s '<TV_IP>:5555' shell dumpsys package io.github.cecbridge
adb -s '<TV_IP>:5555' shell 'cat /storage/emulated/0/cec-bridge/daemon.pid; cat /storage/emulated/0/cec-bridge/heartbeat'
adb -s '<TV_IP>:5555' shell 'tail -20 /storage/emulated/0/cec-bridge/launch.log; tail -20 /storage/emulated/0/cec-bridge/daemon.log'
```

精简现场证据保存在关联mitv-hub工作区的忽略目录`.local/cec-status-20261112/`。本机可用技能目录仍未找到`yx-workflow`或`agent-work-tracker`，本次没有写入Obsidian；本节保留调查与恢复记录。
