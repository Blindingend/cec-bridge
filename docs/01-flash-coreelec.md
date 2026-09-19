# 01 · KM2 刷 CoreELEC

目标：把 MECOOL KM2（Amlogic S905X2-B，G12A 平台，2GB+8GB）刷成 CoreELEC，
作为 CEC 中枢 + Kodi 播放器。

> **推荐用 SD 卡启动**（而不是刷入 eMMC）：零变砖风险，原安卓系统完整保留，
> 想回到安卓只要拔掉 SD 卡开机即可。KM2 有 MicroSD 卡槽，正好。

## 准备

- 一张 **Class 10 以上 MicroSD 卡**（≥8GB，建议 16GB）+ 读卡器
- 电脑上的烧录工具：**balenaEtcher**（推荐，跨平台）或 Rufus / `dd`
- KM2 的原配电源（刷机过程需断电重启）

## 步骤

### 1. 下载镜像

从 CoreELEC 官网下载 **Amlogic-ng**（或新的 Amlogic-no）的 **Generic** 镜像，
G12A/S905X2 属于支持列表：

- 官方下载页：<https://coreelec.org/>
- 选形如 `CoreELEC-Amlogic-ng.arm-<版本>-Generic.img.gz` 的文件

### 2. 写镜像到 SD 卡

用 balenaEtcher 选择 `.img.gz` 文件和 SD 卡，直接烧录（Etcher 会自动解压 gz）。

命令行方式（可选）：

```bash
gzip -d CoreELEC-Amlogic-ng.arm-*-Generic.img.gz
dd if=CoreELEC-Amlogic-ng.arm-*-Generic.img of=/dev/sdX bs=4M conv=fsync
# /dev/sdX 换成你的 SD 卡设备（务必确认，别写错盘）
```

### 3. 放置正确的 dtb（关键步骤）

烧录后 SD 卡会有一个 `device_trees` 文件夹，里面是各种 SoC 的设备树。

- 在 `device_trees` 里找到 **G12A / S905X2 / 2GB** 对应的 dtb，
  文件名形如 `g12a_s905x2_2g.dtb`（**以实际文件夹里的文件名为准**）；
- 把它**复制到 SD 卡根目录**，并**改名为 `dtb.img`**。

> 如果没放对 dtb，盒子可能黑屏/无法启动——这是最常见的坑。

### 4. 启动 CoreELEC

1. KM2 断电；
2. 插入做好的 SD 卡；
3. 用牙签/回形针**按住 AV 口内的 recovery 按钮**不放，同时通电；
4. 看到 CoreELEC 的 logo 后松开按钮，等待首次启动完成。

首次启动会引导设置（语言、网络、Kodi 界面）。连上你家的 WiFi 或网线，记下它拿到的 IP
（CoreELEC 设置里可看，或路由器后台看），后面部署要用。

## 常见问题

- **黑屏/卡 logo**：多半是 dtb 没放对或没改名 `dtb.img`，回第 3 步检查。
- **想回安卓**：关机拔掉 SD 卡再开机即可，原系统不受影响。
- **原蓝牙遥控不好用**：CoreELEC 下 KM2 原蓝牙遥控可能不通用，可用 CEC（电视遥控直接控
  Kodi）或手机装 Kodi 官方遥控 App（Kore）代替。

## 下一步

接线方案见 `02-wiring.md`。
