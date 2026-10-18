# cec-bridge

给 **小米电视 6 至尊版（L65M7-Z1 / walle，Android 9）** 补全被砍掉的 HDMI-CEC 能力。

> **2026-10-18 更新**：当前推荐 **TV 端方案**——一个运行在电视本机的 root shell 守护进程，
> 不需要额外硬件，已在真机完成 Apple TV 遥控唤醒 + 自动切 HDMI1 + 关机联动验证。
> 早期“外接 CoreELEC 盒子”方案因目标盒子 bootloader 锁定已归档到
> [`legacy/coreelec/`](legacy/coreelec/README.md)。

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
   - 息屏时每 2 秒读 CEC history，匹配 `<Image View On>`、`<Text View On>`、
     `<Active Source>`、或 `<Report Power Status params: 00>`（src ≠ 0）。
   - 先通过 `service call power 9 ...` 唤醒（root 域读不到 `/proc/uptime`，用
     `mLastSleepTime` 作 eventTime）。
   - 等 `mWakefulness=Awake`，sleep 2 秒让 tvhome 落定，再通过 `TvService` transaction 3000
     拉起 `ExternalSourceActivity --ei input 23`。
   - **同时校验** `mActiveRoutingPath` 和 `mResumedActivity`：Apple TV 的 `<Active Source>`
     可能先把 path 置成 `0x1000`，但前台还是 tvhome；只看 path 会误判“已切好”。
   - 失败时最多重试 5 次。

3. **关机联动**
   - 检测到 Awake → Asleep 后 3 秒，向 CEC 总线上所有非 0 logical address 发
     `<Standby>`，Apple TV（logical 8）和 PS5（logical 4）都会收到。
   - 进入睡眠后 10 秒内忽略 `<Report Power Status params: 00>`，避免仍醒着的外设被
     60 秒轮询回报 00 时把电视刚睡就唤醒。
   - **PS5 特例**：PS5 在 rest mode 下会错误回报 `Report Power Status 00`，且不执行
     我们发的 directed `<Standby>`。桥接对 PS5（logical 4）的 `Report Power Status 00`
     永久忽略，只把 `<Active Source>` / `<Text View On>` / `<Image View On>` 当作唤醒请求，
     避免“电视一睡、PS5 一回报、电视又醒”的循环。若希望 PS5 真正跟随电视睡眠，请在
     PS5 设置中开启 `Settings > System > HDMI > Enable Power Off Link`。

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

一次成功的真实唤醒日志应类似：

```text
02:23:32 [26610] wake trigger: src logical=8 input=23
02:23:33 [26610] TV awake
02:23:35 [26610] wake: path ok but foreground not ExternalSourceActivity, forcing input src=8
02:23:38 [26610] wake preselect ok src=8 path=0x1000
```

同时 `mResumedActivity` / `mCurrentFocus` 应为
`com.xiaomi.mitv.tvplayer/.ExternalSourceActivity`，`mActiveRoutingPath=0x1000`。

## 安全与限制

- **仅在本机/自有设备上使用**。项目依赖小米 `TvService` 的若干无权限检查 Binder 事务
  （4400/4004/3000），这是厂商接口，不是 Android 公共 API；公开代码即公开这些接口细节。
- 不要在不信任的网络暴露 ADB；调试完成后建议关闭网络 ADB。
- `tv-side/apk/cecbridge.apk` 是 **debug 签名** 的预编译包，方便快速试用；长期使用请用
  自己的 key 重新签名，否则与其他签名版本不能互相升级。
- 仅在一台 `MiTV-MFZP0` / Android 9 上验证；不同固件的事务号、Activity 名称、CEC 行为
  可能不同，升级后需重新核对。
- Apple TV / PS5 的 CEC 行为取决于各自设置；关闭 CEC 控制后桥接无法联动。
- PS5 的 CEC 实现会忽略 directed `<Standby>` 并错误回报 `power_status 00`。桥接因此
  不会把 PS5 的 `00` 当作唤醒信号；如果希望 PS5 跟随电视睡眠，需在 PS5 开启
  `Settings > System > HDMI > Enable Power Off Link`。
- 本项目与小米、Apple、索尼无关联；使用风险自负。

## 许可证

[MIT](LICENSE)

## 致谢

- 逆向与验证基于本机 `dumpsys`、`logcat`、CEC history 和实际 Apple TV 遥控测试。
- 早期 CoreELEC 方案保留在 `legacy/coreelec/`，作为项目演进记录。
