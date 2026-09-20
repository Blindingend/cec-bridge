# 01 · 普通 KM2 的 CoreELEC USB 启动验证

适用目标：**MECOOL KM2，非 Plus / Plus Deluxe，S905X2-B、2GB+8GB**。
核对日期：2026-09-20。启动盘已经制作完成，**尚未在这台盒子上验证启动**。

## 兼容性结论

CoreELEC 支持 S905X2 通用平台，但这不能证明 KM2 的 bootloader 允许加载它。
[普通 KM2 的官方论坛讨论](https://discourse.coreelec.org/t/coreelec-on-mecool-km2-not-plus-possible/58438)
没有提供成功方案。KM2 Plus 的失败记录、Plus Deluxe 的教程均不能直接套用。

本文是**保留 Android、尝试 USB 启动**的验证流程，不是已验证的 KM2 刷机教程。
原文“AV 口内有 recovery 按钮”“零变砖风险”缺乏该型号依据，已撤回。
外置启动避免主动覆盖 Android 系统分区，但引导脚本可能调整启动环境，不能承诺零风险。

## 1. 当前 U 盘已准备好，不用重新烧录

2026-09-20 在当时的 D 盘 USB 上完成：

| 项目 | 内容 / 验证结果 |
|---|---|
| 启动卷标 | COREELEC，Windows 可见约 512 MiB 启动分区 |
| 镜像 | CoreELEC-Amlogic-ng.arm-21.3-Omega-Generic.img.gz |
| 镜像校验 | 压缩包 SHA-256 与官方 release asset digest 一致 |
| 写入校验 | 574619648 字节逐字节回读通过；SYSTEM / kernel.img 的 MD5 通过 |
| 设备树 | device_trees/g12a_s905x2_2g.dtb → 根目录 dtb.img，哈希一致 |
| 部署资料 | 根目录 cec-bridge/，Linux 脚本使用 LF 换行 |
| 配置 | 实际 config.json 的 ping_host 留空，CEC 地址仍需现场核对 |

该设备树对应 S905X2 / 2GB / 百兆网口，是**通用候选**，不是 KM2 专用适配。
来源：[官方 21.3 发布页](https://github.com/CoreELEC/CoreELEC/releases/tag/21.3-Omega)、
[设备树表](https://coreelec.org/dtb/)。

若 Windows 提示格式化另一分区，点取消，那是 Linux 分区。盘符可能变化，以卷标识别。

仅在重做启动盘时：从上述发布页下载同一镜像，用 Rufus / Etcher 的镜像写入功能写入
确认过的 USB，再复制上述 DTB 为 `dtb.img`。这会清除目标 USB 数据；
普通文件复制压缩包不等于制作启动盘。
见 [CoreELEC 通用安装说明](https://wiki.coreelec.org/coreelec:devgeneric)。

## 2. 先在 Android 中收集信息

先不插启动 U 盘，正常进入 Android，记录：

- 设置 → 设备偏好设置 / 系统 → 关于：型号、Android 版本、完整 Build。
- 网络页面中的局域网 IP。
- 开发者选项里实际存在的调试开关。

不要为了尝试 CoreELEC 先升级或降级 Android。MECOOL 的 KM2 Android 12 公告明确说明
该次升级后不能降级；当前设备版本以实机为准。
[厂商公告](https://www.mecool.com/blogs/news/2024-mecool-km2-android-12-upgrade)

### Windows ADB 连接

下载并解压 Google 的 [SDK Platform-Tools for Windows](https://developer.android.com/tools/releases/platform-tools)。
在解压后的 platform-tools 文件夹打开 PowerShell：

```powershell
.\adb.exe version
```

在盒子“关于”中连续点击“内部版本号 / Android TV OS build”，直到开启开发者模式。
返回开发者选项，开启实际存在的 USB 调试 / 网络调试。电脑和盒子使用同一可信局域网。
**不用打开 OEM 解锁，也不用执行 root 或 fastboot unlock。**

若固件提供传统网络 ADB，使用界面显示的端口；未显示端口时才尝试常见的 5555：

```powershell
# 替换为盒子的真实 IP 和端口；后续继续使用同一个变量。
$km2 = '<KM2_IP>:5555'
.\adb.exe connect $km2
.\adb.exe devices -l
```

电视出现授权框时允许这台电脑。只有目标状态为 `device` 才继续。
`unauthorized` 表示未授权；`offline` 表示连接未就绪；
拒绝连接或超时先检查调试开关、端口和网络，不能据此认定 bootloader 被锁。

USB 调试开关不保证固件同时开放网络 ADB。若没有网络入口、5555 也不可达，先记录
固件版本和菜单，停止此分支。不要用普通 USB-A 对 USB-A 线直接连接两个主机口。

仅当固件实际提供“无线调试 → 使用配对码配对”时，使用以下分支：

```powershell
.\adb.exe pair <KM2_IP>:配对端口
# 按提示输入配对码，然后使用无线调试主页的连接端口（可能与配对端口不同）。
$km2 = '<KM2_IP>:连接端口'
.\adb.exe connect $km2
.\adb.exe devices -l
```

Android 10/12 的 KM2 不应假定具备配对式无线调试。
连接、授权和目标选择依据：[Google ADB 文档](https://developer.android.com/tools/adb)。

### 只读诊断

```powershell
.\adb.exe -s $km2 shell getprop ro.product.model
.\adb.exe -s $km2 shell getprop ro.product.device
.\adb.exe -s $km2 shell getprop ro.hardware
.\adb.exe -s $km2 shell getprop ro.build.version.release
.\adb.exe -s $km2 shell getprop ro.build.display.id
.\adb.exe -s $km2 shell getprop ro.build.fingerprint
.\adb.exe -s $km2 shell getprop ro.boot.flash.locked
.\adb.exe -s $km2 shell getprop ro.boot.vbmeta.device_state
.\adb.exe -s $km2 shell getprop ro.boot.verifiedbootstate
```

启动属性仅是诊断线索：空值不代表解锁，locked 不能单独证明所有外置启动路径均被禁用，
unlocked 也不能证明 CoreELEC 一定兼容。保留输出，不据此直接刷入固件。

## 3. 一次实验性 USB 启动尝试

前提：型号正确、Android 正常、ADB 已授权。下面的命令会重启盒子并中断播放；
尚未验证普通 KM2 固件是否支持此启动目标。

1. 在 Windows 安全弹出 U 盘。
2. KM2 断电后插入 U 盘，HDMI 直连电视，最好接网线，然后通电。
   可先试 USB 2.0 口，这是排查顺序，不是已确认的 KM2 限制。
3. 若直接出现 CoreELEC，转第 4 节；若进入 Android，确认 IP 后执行：

```powershell
.\adb.exe connect $km2
.\adb.exe devices -l
# 确认目标是这台 KM2、状态为 device 后，只执行一次：
.\adb.exe -s $km2 reboot update
```

这里通过 ADB 请求 Amlogic 的 update 重启目标。CoreELEC 官方列有通用
`reboot update` 方法，但**不是普通 KM2 的成功证明，也不等于安装 Android OTA**。
[CoreELEC 启动方法](https://wiki.coreelec.org/coreelec:ceboot)

| 结果 | 如何处理 |
|---|---|
| CoreELEC 标志、扩容或初始化进度 | 保持供电，等初始化和可能的自动重启完成 |
| 正常回到 Android | 本次未进入外置系统；这不充分证明 DTB 有问题 |
| Android recovery 菜单 | 仅选择 Reboot system now 返回；进入 recovery 不等于能启动 CoreELEC |
| 黑屏 / 长时间停在厂商标志 | 记录画面和等待时长；没有写入或更新进度时，可断电拔 USB，检查 Android 是否正常 |
| 明确提示签名 / 校验失败 | 记录完整错误并停止，需要分析固件的启动限制 |

不要把镜像改名为 update.zip，也不要在 recovery 中选择 Apply update 来安装它，
更不要选择 Wipe data。CoreELEC 磁盘镜像不是 Android recovery 更新包。

如果 Android 正常但 USB 启动失败，可以断电换另一个 USB 口，再按同一路径试一次。
仍失败就保留诊断结果，不要无依据轮换 DTB、降级固件或解锁 bootloader。
`adb reboot recovery` 只进入恢复菜单，不是 `reboot update` 的等价替代。

## 4. 只有进入 CoreELEC 后才继续部署

完成网络设置，在 CoreELEC 设置中启用 SSH 并设置密码，记录实际 IP：

```powershell
# CoreELEC 的 IP 可能与 Android 时不同。
ssh root@<KM2_IP>
```

在 CoreELEC 的 SSH 会话中检查：

```sh
cat /etc/os-release
df -h /storage
command -v python3
command -v cec-client
ls /flash/cec-bridge
# 仅首次部署且 /storage/cec-bridge 尚不存在时复制，避免覆盖已有配置：
cp -r /flash/cec-bridge /storage/
```

确认 /storage 已扩容、依赖可用，再按[接线](02-wiring.md)和[部署验证](03-deploy.md)继续。
本盘没有自动启用 CEC 服务。现有脚本还有报文解析等问题待修复；
系统成功启动和联动功能验收是两个步骤。

正常关机后拔 USB，可尝试返回原 Android；如不能返回，停止进一步写入并记录现象。
本流程不执行 ceemmc、installtointernal、USB Burning Tool 或内置分区擦除。

## 5. 失败后需要保留的信息

- Android 版本、完整 Build、上述 getprop 输出。
- ADB 状态、reboot update 是否实际发起重启。
- 使用的 USB 口，最终进入哪个系统 / 菜单，或停在哪个画面。
- 拔 USB 后 Android 是否正常，任何签名 / 校验错误原文。

当前结论是“缺少已验证方案”，不是“这台实机已确认永久不能刷”。
排查结束后关闭不再使用的 ADB 调试。
