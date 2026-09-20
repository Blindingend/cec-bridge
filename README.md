# cec-bridge

给「小米电视 6 至尊版」补全被阉割的 HDMI-CEC 能力的中枢脚本。运行在一台刷了
**CoreELEC** 的 Amlogic 盒子（MECOOL KM2 / S905X2，2GB+8GB）上。

> **硬件验证状态（2026-09-20）**：普通 KM2 已实测——bootloader 锁定且加密，无法从
> USB 启动 CoreELEC（两个 USB 口 + 两次 `adb reboot update` 均回 Android）。该型号因
> Netflix/Google 认证锁死 bootloader，需换**非认证的通用 S905X3/X4 盒子**作桥接硬件。
> 详见 [实测记录](docs/04-session-2026-09-20.md)。

## 背景问题

小米电视 6 至尊版的 HDMI-CEC 是阉割版（软件/固件实现缺失，硬件 CEC 通路正常）：

| # | 问题 | 根因 |
|---|------|------|
| 1 | 外设（Apple TV / PS5）开机时，电视**息屏态**下不唤醒 | 息屏态不处理 CEC 唤醒，关机态才处理 |
| 2 | 电视**开机态**下 Apple TV 启动不自动跳源 | 开机态靠 HDMI 5V 检测进源，Apple TV 待机 5V 不掉 |
| 3 | 电视关机时外设不跟随关机 | 缺 CEC「关机联动」 |
| 4 | 无信号超时自动跳回电视主页，无开关 | 输入源管理逻辑，需在电视设置里关闭 |

## 方案

用一台 Amlogic 盒子刷 CoreELEC 作为 **CEC 中枢**，挂在电视某个 HDMI 口上，加入
HDMI-CEC 共享总线：监听外设的开/关机事件，并**主动**向电视发送 CEC 命令，补上
「唤醒 + 切源 + 关机联动」三个缺失能力。同一台盒子顺便当 **Kodi 4K 播放器**（直连
NAS 播片），不浪费。

```
                 ┌──────────────────────── 小米电视 6 至尊版 ───────────────────────┐
                 │  HDMI1 (2.1)   HDMI2 (2.1)            HDMI3 (2.0)                 │
                 │     │              │                      │                        │
                 │   PS5        [2进1出切换器]           KM2 (CoreELEC)               │
                 │          AppleTV   Switch            CEC 中枢 + Kodi 播放器          │
                 └────────────────────────────────────────────────────────────────────┘
                                    ▲  所有设备共享同一条 HDMI-CEC 总线
```

## 目录结构

```
cec-bridge/
├── README.md
├── docs/
│   ├── 01-flash-coreelec.md    # KM2 刷 CoreELEC 步骤
│   ├── 02-wiring.md            # 接线方案
│   ├── 03-deploy.md            # 部署与验证
│   └── 04-session-2026-09-20.md # USB 制作、测速与跨电脑交接
├── src/
│   ├── cec_bridge.py           # 核心中枢脚本（零第三方依赖）
│   └── config.example.json     # 配置模板
├── systemd/
│   └── cec-bridge.service      # 开机自启服务
├── scripts/
│   └── install.sh              # 一键部署脚本
└── .gitignore
```

## 快速开始

跨电脑继续操作，先读 [2026-09-20 操作记录与交接](docs/04-session-2026-09-20.md)：
包含 U 盘制作与测速结果、镜像校验值、当前未验证事项，以及回家后的操作顺序。

1. 刷 CoreELEC：见 `docs/01-flash-coreelec.md`
2. 接线：见 `docs/02-wiring.md`
3. 部署脚本：见 `docs/03-deploy.md`

核心流程：

```bash
# 在 KM2（CoreELEC）上
scp -r cec-bridge root@<km2-ip>:/storage/
ssh root@<km2-ip>
/storage/cec-bridge/scripts/install.sh
```

## 工作原理（简述）

`cec_bridge.py` 是一个常驻 Python 服务，通过 `cec-client` 挂在 CEC 总线上：

- **监听**：解析 `cec-client` 输出的 `TRAFFIC` 日志，识别外设的 `Active Source`、
  电视的 `Standby` / `Routing Change` 等事件；
- **兜底检测**：对 Apple TV 这种「5V 不掉、且可能不发 CEC 事件」的设备，用
  `ping` 网络通断作为开机检测的补充；
- **控制**：主动发送 `Image View On`（唤醒电视）、`Active Source`（切源）、
  `Standby`（外设待机）等 CEC 命令。

## 许可证

MIT
