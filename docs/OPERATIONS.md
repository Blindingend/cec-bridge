# TV 端 CEC 桥接：部署与运维记录

日期：2026-10-18  
适用：小米电视 6 至尊版（L65M7-Z1 / walle，Android 9）

## 0. 现状

小米电视 CEC 缺陷的根因已定位；纯软件、全部运行在电视本地的桥接方案已部署，并完成
真实 Apple TV 遥控端到端验证。核心链路（休眠中收 CEC → 唤醒 → 强制切输入；
进入休眠 → 给外设发 Standby；重启自愈）均已验证，设备上的测试脚本已清理。

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
- 休眠中每 2 s 读 `dumpsys hdmi_control` 的 CEC history，匹配以下消息触发唤醒：
  `<Image View On>`、`<Text View On>`、`<Active Source>`、
  `<Report Power Status>` 且 `params: 00`（且 src ≠ 0；**PS5 logical 4 除外**）。20 s 冷却。
  进入睡眠后 10 s 内忽略 `<Report Power Status params: 00>`：外设若仍醒着，会对 60 s 轮询
  回 00，旧逻辑会把电视刚睡就重新唤醒；`<Active Source>`/`<Image View On>` 不受此限制。
- **PS5 特例**：PS5 在 rest mode 下会错误回报 `Report Power Status 00`，且不执行我们发的
  directed `<Standby>`。因此对 src=4 的 `Report Power Status 00` **永久忽略**，只认它的
  `<Active Source>` / `<Text View On>` / `<Image View On>`。否则电视每 60 s 轮询一次，
  PS5 回报一次 00，电视就被重新唤醒，随后 CEC 路由响应又把 PS5 完全唤醒，形成睡眠/唤醒循环。
- 唤醒顺序（重要）：**先 wakeUp，等 Awake，sleep 2 s 让主页落定，再启动输入 Activity，
  最后同时校验 `mActiveRoutingPath` 和 `mResumedActivity`**。反序会被唤醒后的 tvhome 覆盖。
- ⚠️ 只校验 `mActiveRoutingPath` 不够：Apple TV 的 `<Active Source>` 会先把 path 置成
  `0x1000`，但前台可能仍是 `com.mitv.tvhome`（2026-10-18 02:13 实测踩坑）。此时必须继续
  执行切输入，不能因 path 已对直接返回；脚本最多重试 5 次，只有 path 与前台 Activity
  同时满足才记录 `wake preselect ok`。
- 唤醒：
  `service call power 9 i64 <mLastSleepTime+1> s16 'android.policy:POWER' s16 android`
  （root 域读不到 `/proc/uptime`，用 dumpsys 的 mLastSleepTime 代替；mLastWakeTime 也可）。
- 切输入：`service call TvService 3000 s16 start s16
  "-a com.xiaomi.mitv.tvplayer.EXTSRC_PLAY -n com.xiaomi.mitv.tvplayer/com.xiaomi.mitv.tvplayer.ExternalSourceActivity --ei input 23"`
  。返回 `Not a data message` 是回包解析噪音，命令实际生效。
  input 23/24/25/26 ↔ routing path `0x1000/0x2000/0x3000/0x4000`。
- 进入休眠 3 s 后，对 CEC 总线上所有非 0 logical address 发
  `service call hdmi_control 30 i32 0 i32 <logical>`（`<Standby>`）。

## 4. root 域（u:r:misysdiagnose:s0, uid 0）能力边界

- 可以：`dumpsys`、`service call`、读写 `/sdcard`、运行后台脚本、`setsid`。
- 不可以：读 `/proc/uptime`（Permission denied）、`app_process`、`/system/bin/settings`、
  `cmd settings/activity`、`setprop service.adb.tcp.port` / `ctl.start`、dmesg、
  `/dev/input`、`/dev/block`、`setenforce`、`/data/local/tmp`（shell_data_file 拒绝）。
  → 需要这些能力时必须走 TvService 原语，不要试图在 root 脚本里直接做。

## 5. 已验证结果（2026-10-18）

- **休眠中 CEC 收发正常**：reason-8 息屏期间电视仍每 60 s 发 `<Give Device Power Status>`
  并收到两台设备的 `<Report Power Status params: 01>`；history 持续更新。
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
- **睡眠自唤醒竞态（已修）**：02:20:36 电视刚睡时，仍醒着的 Apple TV 对 60 s 轮询回
  `<Report Power Status params: 00>`，旧逻辑立即触发唤醒，电视 2 s 后自己亮起。
  新逻辑在睡眠后 10 s 内忽略该回报；02:21:52 再睡后保持 Asleep，Standby 正常发出。
- **PS5 误报 / 唤醒实测（2026-10-18 12:39–15:19）**：
  - 12:39:13 息屏，12:39:16 向 4/8 发 `<Standby>`；12:39:47 PS5 回
    `Report Power Status 00`，12:39:49 按 PS5 规则忽略；电视保持 Asleep 直到 12:42:27
    之后仍未醒。
  - 15:19:38 PS5 主动发 `<Text View On>` + `<Active Source>`；15:19:39 桥接唤醒，
    15:19:42 切到 `path=0x2000`，`mResumedActivity=ExternalSourceActivity`，PS5 画面正常。
  - 结论：PS5 不执行 directed `<Standby>`，但桥接不再因它的 00 误唤醒；用户主动唤醒
    PS5 仍能正常亮屏并切 HDMI2。
- **关机联动**：进入息屏后 `[S] <Standby> src: 0, dst: 4/8` 已发出；Apple TV 会进入待机，
  PS5 可能忽略该 Standby（需在 PS5 开启 Power Off Link 才能跟随睡眠）。
- **ADB 自愈 / 开机自启**：persisted JobScheduler 在重启后拉起 App、launch.sh 恢复 adbd；
  运行期看门狗继续生效。
- **WOL 失败**：向 Apple TV 的 ARP MAC 与 AirPlay deviceid MAC 发 magic packet 均未唤醒
  （疑似 Wi-Fi、无 WoWLAN）。真实唤醒测试必须用 Apple TV 遥控器。

## 6. 清理与后续

1. 真实端到端测试已完成（2026-10-18 02:23，见 §5）：Apple TV 遥控唤醒 →
   强制切 HDMI1 → `ExternalSourceActivity` 前台、`path=0x1000`。
2. 设备上的测试脚本/日志已清理，保留运行必需文件：`cec-bridge.sh`、`launch.sh`、
   `daemon.log`、`launch.log`、`daemon.pid`、`heartbeat`、`lock`、`keep-adb`、
   `restart.sh`、`stop.sh`。
3. 重启自愈已验证：2026-10-18 约 01:46 重启后，01:48 守护进程由 persisted jobs
   拉起，02:02/02:05 看门狗继续工作。
4. 可选：观察一次“Apple TV 仍醒着时让电视息屏”，确认 10 s grace 在实战中不会误唤醒。

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
