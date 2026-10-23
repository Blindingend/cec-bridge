# cec-bridge

给 **小米电视 6 至尊版（L65M7-Z1 / walle，Android 9）** 补全被砍掉的 HDMI-CEC 能力。

> **2026-10-18 更新**：当前推荐 **TV 端方案**——一个运行在电视本机的 root shell 守护进程，
> 不需要额外硬件，已在真机完成 Apple TV 遥控唤醒 + 自动切 HDMI1 + 关机联动验证。
> 早期“外接 CoreELEC 盒子”方案因目标盒子 bootloader 锁定已归档到
> [`legacy/coreelec/`](legacy/coreelec/README.md)。

> **2026-10-23 修复**：增加电视亮屏时的自动切源，覆盖“关闭 PS5 后打开 Apple TV”的场景；
> 修复全局冷却吞掉换源、旧切源任务与延迟待机互相干扰的问题。
> 本轮 review、回归结果与实机验收边界见 [`docs/OPERATIONS.md`](docs/OPERATIONS.md#9-2026-10-23-review-与交接)。

## 问题

这台电视的 HDMI-CEC 是“半残”状态：CEC 硬件和 Android CEC 栈正常，但小米修改了
`HdmiControlService` 的睡眠路径。

| # | 现象 | 直接原因 |
|---|------|----------|
| 1 | 息屏时 Apple TV / PS5 开机，电视不唤醒 | 息屏时 `mPowerStatus` 恒为 0，CEC 唤醒路径被门控 |
| 2 | 外设唤醒后电视不切到对应 HDMI | CEC 只更新了 `mActiveRoutingPath`，前台仍可能是 tvhome |
| 3 | 电视息屏/关机时外设不跟着睡 | reason 8 跳过 `onStandby()`，电视不发 `<Standby>` |
| 4 | 无信号超时自动回主页 | 电视设置项，桥接不处理 |

根因：**goToSleep reason = 8（小爱息屏）时，`onStandby()` 被跳过**，`mPowerStatus` 永远停在
`0 (ON)`。CEC 总线本身仍在工作，电视仍每 60 秒轮询外设电源状态——所以可以在电视本机观察
CEC history 并替它完成动作。

详细逆向记录见 [`docs/FINDINGS.md`](docs/FINDINGS.md)。

## 方案对比

| 方案 | 额外硬件 | 状态 |
|------|----------|------|
| **TV 端 shell 守护进程** | 无 | 2026-10 真机验证，推荐 |
| CoreELEC 外接盒子 | KM2 / S905 盒子 | 目标盒子 bootloader 锁定，归档 |

TV 端方案的核心：

```
Apple TV / PS5 ──HDMI-CEC──> 小米电视
                               ├─ HdmiControlService（reason 8 跳过 onStandby）
                               └─ cec-bridge.sh（root 守护进程）
                                    ├─ 轮询 dumpsys hdmi_control 的 CEC history
                                    ├─ 先唤醒，再强制拉起 ExternalSourceActivity
                                    ├─ 校验 mActiveRoutingPath + 前台 Activity
                                    ├─ 睡眠后给外设发 <Standby>
                                    └─ 可选：ADB 掉线自愈
```

## 工作原理

1. **启动**
   - 辅助 APK `io.github.cecbridge` 使用 persisted JobScheduler（15 分钟周期 + 120 秒
     持久链）拉起 `launch.sh`。
   - `launch.sh` 通过 `TvService` Binder transaction **4400**（`MITV_SERVICE_MISYSDIAGNOSE`，
     无权限检查）让 `misysdiagnose` 以 uid 0 执行，从而启动守护进程。
   - 该机型不给第三方 App 发 `BOOT_COMPLETED`，所以不能只靠广播。

2. **唤醒 + 切输入**
   - 亮屏和息屏时均约每 2 秒读 CEC history，**只匹配收到的显式请求**：`<Image View On>`、
     `<Text View On>`、`<Active Source>`（src ≠ 0）。不使用 `Report Power Status 00`
     做唤醒触发，避免把 60 秒轮询回复或待机误报当成开机。
   - 仅在息屏时先通过 `service call power 9 ...` 唤醒（root 域读不到 `/proc/uptime`，用
     `mLastSleepTime` 作 eventTime）。
   - 唤醒后等 `mWakefulness=Awake`，sleep 2 秒让 tvhome 落定；电视原本亮屏时直接切输入。
   - 每个新请求至少通过 `TvService` transaction 3000 执行一次真实输入选择，再检查
     `mActiveRoutingPath` 和 `mResumedActivity`。CEC 可能先改 path，且 PS5 与 Apple TV
     共用同一个输入 Activity，因此不能凭这两个值提前跳过切源。
   - 最多尝试 5 次；同设备正在处理的消息合并，新设备请求取消旧任务。没有全局 20 秒冷却。
   - 启动和 CEC 历史游标丢失时重新建立基线，不重放旧消息；不按设备品牌写特殊规则。

3. **关机联动**
   - 检测到 Awake → Asleep 至少 3 秒后，在后续轮询中向已发现的 logical address 1–14 发
     `<Standby>`。地址按两位十六进制通用解析（`0x0B` 与 `0x0b` 等价），输入按
     `port_id` 映射（1→HDMI1/23、2→HDMI2/24、3→HDMI3/25、4→HDMI4/26），
     Apple TV、PS5、Switch 走同一套规则，没有逐设备硬编码。
     每次发送前复查电视仍在息屏；重新亮屏或收到显式切源请求时取消待机计划。
   - **唤醒只认显式 CEC 消息**：`<Image View On>`、`<Text View On>`、`<Active Source>`。
     不再用 `<Report Power Status params: 00>` 触发唤醒——它既可能是 60 秒轮询的回复，
     也可能是待机设备的误报，PS5 和 Switch 都曾因此把电视反复叫醒。
   - 因此不需要 `src=4` 之类的设备特例；新设备须已被电视发现，CEC logical address 在
     0x01–0x0E 且 `port_id` 在 1–4。`0x0F` 是广播/未注册地址，不作为独立设备控制。
   - 设备是否真正跟随电视睡眠仍取决于设备自身 CEC 设置；例如 PS5 需要开启
     `Settings > System > HDMI > Enable Power Off Link`。

4. **ADB 自愈（可选）**
   - 存在 `keep-adb` 标记文件时，守护进程每 10 秒检查 `init.svc.adbd`，掉线时通过
     `TvService` transaction 4004 执行 `adb_enabled` 0→1。

更完整的部署与运维记录见 [`docs/OPERATIONS.md`](docs/OPERATIONS.md)。

## 仓库结构

```
.
├── README.md
├── LICENSE
├── docs/
│   ├── FINDINGS.md          # 逆向结论与实测证据
│   └── OPERATIONS.md        # 部署、运维、验证记录
├── tv-side/
│   ├── cec-bridge.sh        # 守护进程
│   ├── launch.sh            # root 启动脚本
│   ├── restart.sh
│   ├── stop.sh
│   ├── install.sh           # adb 一键推送 + 安装 APK
│   ├── apk/                 # 辅助 APK 源码（smali + manifest）与预编译 APK
│   └── tools/t4004.sh       # 手动启用 ADB 的小工具
├── tests/test_bridge.py     # 隔离 CEC 报文与状态机回归测试
└── legacy/
    └── coreelec/            # 已归档的外接盒子方案（Python + systemd）
```

## 安装

前提：

- 小米电视 6 至尊版（`MiTV-MFZP0` / walle，Android 9），已开启 ADB 调试；
- 电视上存在可用的 `TvService` transaction 4400/4004/3000（本机型 Android 9 实测可用）；
- 主机有 `adb`。

```sh
git clone https://github.com/Blindingend/cec-bridge.git
cd cec-bridge/tv-side
./install.sh <TV_IP>
```

`install.sh` 会：

1. `adb connect <TV_IP>:5555`
2. 创建 `/storage/emulated/0/cec-bridge/`
3. 推送 `cec-bridge.sh`、`launch.sh`、`restart.sh`、`stop.sh`
4. 安装 `apk/cecbridge.apk` 并启动一次 `MainActivity`（触发 root 启动 + 注册 JobScheduler）

所有 ADB 操作绑定指定电视；脚本先上传为 `.new`、检查语法后替换。
已有守护进程需要按运维文档重启才能加载新版；`disabled` 标记存在时安装不会自动恢复运行。

可选：启用 ADB 自愈：

```sh
adb shell touch /storage/emulated/0/cec-bridge/keep-adb
```

## 验证

```sh
adb shell dumpsys power | grep -E 'mWakefulness|sGotoSleepReason'
adb shell dumpsys hdmi_control | grep -E 'mActiveRoutingPath|mActiveSource|mPowerStatus'
adb shell dumpsys activity activities | grep -m1 mResumedActivity
adb shell 'tail -f /storage/emulated/0/cec-bridge/daemon.log'
```

新版处理 Apple TV 亮屏切源的日志应类似（示例，不是实机验收记录）：

```text
CEC request src=8 state=Awake
activate trigger: src logical=8 input=23 state=Awake
input ok src=8 path=0x1000
```

同时 `mResumedActivity` / `mCurrentFocus` 应为
`com.xiaomi.mitv.tvplayer/.ExternalSourceActivity`，`mActiveRoutingPath=0x1000`。
最终仍需看实际画面确认目标 HDMI 输入，Activity 名称本身不包含当前 HDMI 口。

本地回归测试（Python 标准库，不连接电视）：

```sh
python3 -m unittest discover -s tests -v
BRIDGE_TEST_SHELL='busybox ash' python3 -m unittest discover -s tests -v
```

## 安全与限制

- **仅在本机/自有设备上使用**。项目依赖小米 `TvService` 的若干无权限检查 Binder 事务
  （4400/4004/3000），这是厂商接口，不是 Android 公共 API；公开代码即公开这些接口细节。
- 不要在不信任的网络暴露 ADB；调试完成后建议关闭网络 ADB。
- `tv-side/apk/cecbridge.apk` 是 **debug 签名** 的预编译包，方便快速试用；长期使用请用
  自己的 key 重新签名，否则与其他签名版本不能互相升级。
- 仅在一台 `MiTV-MFZP0` / Android 9 上验证；不同固件的事务号、Activity 名称、CEC 行为
  可能不同，升级后需重新核对。
- Apple TV / PS5 / Switch 的 CEC 行为取决于各自设置；关闭 CEC 控制后桥接无法联动。
- 唤醒只认显式 `<Active Source>` / `<Text View On>` / `<Image View On>`；
  `Report Power Status 00` 不作为唤醒源，避免 PS5/Switch 的轮询误报把电视叫醒。
- 设备不执行 directed `<Standby>` 时（例如 PS5 的某些固件），电视不会被它反过来叫醒；
  若希望设备跟随电视睡眠，需在设备侧开启 CEC Power Off Link（PS5：
  `Settings > System > HDMI > Enable Power Off Link`）。
- 本项目与小米、Apple、索尼、任天堂无关联；使用风险自负。

## 许可证

[MIT](LICENSE)

## 致谢

- 逆向与验证基于本机 `dumpsys`、`logcat`、CEC history 和实际 Apple TV 遥控测试。
- 早期 CoreELEC 方案保留在 `legacy/coreelec/`，作为项目演进记录。
