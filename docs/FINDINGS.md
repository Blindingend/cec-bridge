# 小米电视 6 至尊版 (L65M7-Z1 / walle) HDMI-CEC 逆向结论

日期：2026-10-18 · 设备：<TV_IP>（ADB）· Android 9 / MT9950 / user build / 无 root

## 一、根因（实测确认）

Xiaomi 修改了 framework 的 `HdmiControlService`：**按 goToSleep 的 reason 区分是否为"小爱息屏模式"**。

| 触发方式 | goToSleep reason | HdmiControlService 行为 | mPowerStatus |
|---|---|---|---|
| 遥控器电源键（`mitv.short.power.action=0`，息屏） | **8**（XIAOMI xiaoai） | 日志 `now is xiaoaimode, do not call onStandby`，直接跳过 `onStandby()` | 保持 **0 (ON)** |
| `input keyevent 223`（KEYCODE_SLEEP） | **6**（SLEEP_BUTTON） | 日志 `now is not xiaoaimode, call onStandby`，正常执行 | **1 (STANDBY)** |
| 真关机 / Linux standby | — | 由 MCU/厂商 CEC 处理 | 可被 CEC 唤醒（用户已知） |

这就是缺陷 ① 和 ③ 的同一根因：

- **① 息屏不响应 CEC 唤醒**：AOSP 所有 CEC 唤醒路径都被 `mPowerStatus` 门控：
  - `HdmiCecLocalDeviceTv.handleImageViewOn/handleTextViewOn`：仅当 `isPowerStandbyOrTransient() && mAutoWakeup` 才 `wakeUp()`；
  - `handleUserControlPressed`：仅当 `isPowerStandbyOrTransient()` 才响应 Power On/Toggle；
  - `handleActiveSource` 本身不唤醒。
  息屏时 `mPowerStatus` 永远停在 0，所以 Image View On / Text View On / Active Source 全部无效。
- **③ 关机不联动外设**：`onStandby()` 被跳过 → 不发 `<Standby>`、不执行 `disableDevice`。
  对照实验：用 reason 6 进入睡眠时，日志出现
  `[S] <Standby> src: 0, dst: 15`、`HdmiCecLocalDeviceTv: disableDevice is called`、`onStandbyCompleted`。

证据：电源键息屏后 logcat 出现跳过 `onStandby` 的日志（2026-10-18 00:19:53 → 00:19:55），
以及 2026-10-18 00:25:22 的 reason 6 对照实验。原始 log 未随仓库保留。

## 二、桥接方案（最终实现：电视本机守护进程）

### 1. 基本思路

reason 8 息屏时，Android 的 CEC 栈仍在运行：仍能收发 CEC、仍每 60 s 轮询外设电源状态，
只是 `HdmiControlService` 不再执行 `onStandby()`，且 `mPowerStatus` 恒为 0。因此可以让一个
运行在电视本机的 root 守护进程读取 CEC history，替电视完成“唤醒 + 切输入 + 发 Standby”。

### 2. 唤醒 + 切输入（最终顺序）

1. 休眠中每 2 s 读 `dumpsys hdmi_control` 的 CEC history，匹配 `<Image View On>`、
   `<Text View On>`、`<Active Source>`、或 `<Report Power Status params: 00>`（src ≠ 0）。
2. 先唤醒：`service call power 9 i64 <mLastSleepTime+1> s16 'android.policy:POWER' s16 android`。
   root 域读不到 `/proc/uptime`，所以用 dumpsys 的 `mLastSleepTime` 作为 eventTime。
3. 等 `mWakefulness=Awake`，再 sleep 2 s 让 tvhome 落定。
4. 再切输入：`service call TvService 3000 ... ExternalSourceActivity --ei input 23`。
5. **同时校验** `mActiveRoutingPath` 和 `mResumedActivity`。Apple TV 的 `<Active Source>`
   会先把 path 置成 `0x1000`，但前台可能仍是 `com.mitv.tvhome`；如果只看 path 就提前返回，
   屏幕会停在主页。path 已对但前台不是 `ExternalSourceActivity` 时，仍要强制拉起输入 Activity，
   最多重试 5 次，两者都满足才算成功。

> 早期设想的“先预切输入，再 `keyevent 26` 唤醒”会被唤醒后的 tvhome 覆盖，已废弃。
> `keyevent 26` 现在只作为手动调试入口。

### 3. 关机联动（缺陷 ③）

电视进入 Asleep 后 3 s，桥接向 CEC 总线上所有非 0 logical address 发 `<Standby>`：
`service call hdmi_control 30 i32 0 i32 <logical>`。Apple TV（logical 8）和 PS5（logical 4）
都会收到；Apple TV 正常会进入待机。reason 8 下电视自己不会发，必须由桥接补。

进入睡眠后 10 s 内忽略 `<Report Power Status params: 00>`：外设若仍醒着，会对 60 s 轮询回 00，
旧逻辑会把电视刚睡就重新唤醒；`<Active Source>` / `<Image View On>` 不受此限制。

### 4. 电视状态检测

```sh
adb shell dumpsys power | grep mWakefulness      # Awake / Asleep
adb shell dumpsys power | grep sGotoSleepReason  # 8=xiaoai, 6=standard sleep
adb shell dumpsys hdmi_control | grep -E "mPowerStatus|mActiveSource|mActiveRoutingPath"
```

CEC 侧无法区分息屏与开机（息屏时 `mPowerStatus=0`，且仍每分钟轮询外设电源状态），
所以状态检测必须走 ADB / 本机 dumpsys。

### 5. 备选：把 xiaoai 息屏转换为标准 sleep（不推荐）

先 `keyevent 26` 唤醒，再 `keyevent 223`。CEC 侧会正常进入 STANDBY、发 `<Standby>`、可被 CEC 唤醒。
缺点：会闪一下屏；此睡眠路径没有 AOD 时钟（HyperScreenSaver 未启动）；会话中已回退。
**已睡着时补发 `keyevent 223` 无效**——PowerManager 不会重复广播 ACTION_SCREEN_OFF，CEC 状态不变。

## 三、CEC 现状（实测）

- 电视：logical 0，vendor 60426，name `MiTV-MFZP0`；4 个 HDMI 口 CEC 全开，port 2 ARC。
- Apple TV：logical 8，vendor 4346，physical **0x1000（HDMI1 口）**，power_status 0/1。
- PS5：logical 4，vendor 524358，physical **0x2000（HDMI2 口）**。
  接线可能因批次/改机而不同；桥接脚本按 CEC 广播里的 physical address 动态换算 HW 端口
  （0x1000→23、0x2000→24），不要硬编码。
- PS5 在 rest mode 下对 60 s 一次的 `<Give Device Power Status>` 仍回报
  `Report Power Status 00`（power on），且不执行桥接发出的 directed `<Standby>`。
  这会让电视误判“PS5 已开机”，进而唤醒电视并触发 CEC 路由，把 PS5 也完全唤醒。
- `mAutoWakeup: true`、`mAutoDeviceOff: true`，设置 `hdmi_control_auto_wakeup_enabled=1`、
  `hdmi_control_auto_device_off_enabled=1`；`hdmi_control_auto_shutdown` 未设置（默认关）。
- 电视在 xiaoai 息屏时仍每 60 s 向各设备发 `<Give Device Power Status>`，CEC HAL 与 Android 栈保持运行。
- 收到 Apple TV 的 `<Standby>`（dst 0）时，因当时息屏/默认自动关机设置，电视未进入 CEC standby。

## 四、实现注意事项

- 桥接运行在电视本机：root 守护进程读取 `dumpsys`，通过 TvService / PowerManager 原语操作，
  不需要外接常开机器。
- 切输入必须同时校验 routing path 和前台 Activity；只校验 path 会在 Apple TV 先发
  `<Active Source>` 时误判。
- 睡眠后 10 s 内忽略 `<Report Power Status params: 00>`，避免轮询回报触发“刚睡就醒”。
- **PS5 特例**：对 logical 4 的 `Report Power Status 00` 永久忽略，只认
  `<Active Source>` / `<Text View On>` / `<Image View On>`。否则电视每次 60 s 轮询都会
  被 PS5 的 00 唤醒，形成睡眠/唤醒循环。
- 建议电视固定 DHCP、保留 ADB 授权；`keep-adb` 标记文件可选启用 ADB 自愈。
- 电视真关机时 ADB 不可达，但此时原生 CEC 唤醒可用，两条路径互补。
- TvService 事务号、Activity 名称、CEC logical address 都可能随固件/设备变化，升级后需重新核对。

## 五、已解决与遗留

- **已解决（2026-10-18 02:23 实测）**：Apple TV 唤醒时，电视在 xiaoai 息屏下确实会处理 CEC
  并更新 `mActiveSource=(0x08,0x1000)`、`mActiveRoutingPath=0x1000`，但 `mResumedActivity`
  仍可能是 `com.mitv.tvhome`；仅凭 path 判定会漏切输入。桥接已改为“path + 前台 Activity”双条件，
  path 已对但前台不对时仍强制拉起 `ExternalSourceActivity`；实测 02:23:35 强制切输入、
  02:23:38 `path=0x1000`，前台为 `ExternalSourceActivity t7`。
- `port_id ↔ 物理 HDMI 口` 已现场确认：Apple TV port 1 → input 23（0x1000），
  PS5 port 2 → input 24（0x2000）。
- **PS5 误报已解决（2026-10-18 12:39 / 15:19 实测）**：12:39:13 息屏、12:39:16 发
  `<Standby>`，12:39:47 PS5 回 `Report Power Status 00`；桥接按 src=4 规则忽略，
  电视保持 Asleep 至 12:42:27 之后未醒。15:19:38 PS5 主动发 `<Text View On>` +
  `<Active Source>`，15:19:39 正常唤醒并切到 `path=0x2000`。结论：PS5 不执行
  directed `<Standby>`，但忽略其 00 后既能保持电视睡眠，也不影响用户主动唤醒 PS5。
- 已修复“刚睡就醒”竞态：进入息屏后 10 s 内忽略 `<Report Power Status params: 00>`，
  避免仍醒着的外设被 60 s 轮询回报 00 时把电视重新唤醒。
- 缺陷 ④（无信号超时回主页）是电视设置项，无需桥接干预；必要时可 `settings put` 关闭。
