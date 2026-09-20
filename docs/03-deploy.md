# 03 · 部署与验证

前置：KM2 已刷 CoreELEC 并连网（见 `01`），已按 `02` 接线。

> 当前普通 KM2 的启动和联动尚未实测。正式运行安装脚本前，请先处理
> [交接记录中的代码与实机验证待办](04-session-2026-09-20.md)。安装脚本会启用开机自启。

## 1. 把项目传到 KM2

```bash
# 在你电脑上（把 <km2-ip> 换成 KM2 的 IP）
scp -r cec-bridge root@<km2-ip>:/storage/
```

CoreELEC 默认用户是 `root`，SSH 需先在 CoreELEC 设置里开启（默认常开）。

## 2. 让出 CEC 接口（关键）

Kodi 会独占 CEC 接口，必须先禁用 Kodi 的 CEC 外设，`cec-client` 才能接管：

- Kodi 主界面 → **设置 → 系统 → 输入 → 外设（Peripherals）→ CEC Adapter → 禁用**

## 3. 编辑配置

```bash
ssh root@<km2-ip>
cp /storage/cec-bridge/src/config.example.json /storage/cec-bridge/src/config.json
vi /storage/cec-bridge/src/config.json
```

需要确认/修改：

- `bridge.physical_address`：KM2 直连的电视口（默认 `3.0.0.0`）
- 每个 `sources[]` 的 `physical_address`：对应设备的口（PS5=`1.0.0.0`，
  AppleTV/Switch=`2.0.0.0`）
- `appletv.ping_host`：**填 AppleTV 的真实 IP**（兜底检测用；其它设备可留 `null`）
- `sources[]` 里 AppleTV 和 Switch 同物理地址 `2.0.0.0` 是正常的——它俩共用一个口

## 4. 安装并启动服务

```bash
chmod +x /storage/cec-bridge/scripts/install.sh
/storage/cec-bridge/scripts/install.sh
systemctl start cec-bridge.service
systemctl status cec-bridge.service
```

## 5. 核对物理地址 / 逻辑地址（部署后必做一次）

实际设备树可能与「口序号」不完全一致，用 cec-client 实测核对：

```bash
# 先停掉服务，避免争用 CEC 接口
systemctl stop cec-bridge.service

# 扫描总线，看各设备的物理地址(physical address)和逻辑地址(logical address)
echo scan | cec-client -d 8
```

对照输出，把 `config.json` 里各 `physical_address` 和 `logical_address` 改成实测值，
再 `systemctl start cec-bridge.service`。

> 桥自身的逻辑地址（`bridge.logical_address`）也在输出里能查到；若实测不是 4，
> 改掉，否则发 Active Source 命令时源地址不对。

## 6. 验证效果

看日志：

```bash
journalctl -u cec-bridge -f
```

依次测试：

1. **唤醒 + 切源**：电视息屏，按 AppleTV 遥控开机 → 电视应被唤醒并切到 AppleTV 源；
   PS5 手柄开机同理。
2. **关机联动**：电视遥控关机 → PS5 / AppleTV 应跟随待机。
3. **开机态切源**：电视已开机时启动 AppleTV → 电视切到 AppleTV 源（这个由
   Active Source 命令补上，绕开电视的 5V 检测缺陷）。

## 排错

| 现象 | 处理 |
|------|------|
| `cec-client 未运行` | CoreELEC 是否装了 cec-utils？`command -v cec-client` |
| 看不到 `TRAFFIC` 日志 | `cec_client_args` 里 `-d` 调大到 `8`；确认 Kodi CEC 已禁用 |
| 发送 Active Source 没效果 | 核对 `bridge.logical_address` 是否等于实测逻辑地址 |
| AppleTV 开机不触发 | 确认 `ping_host` 是对的 IP；或 AppleTV 设置里开启
  「控制电视与接收器（HDMI-CEC）」相关选项 |
| 电视切源乱跳 | 切换器若开了自动切换，把它关掉，切源全交给 CEC |
