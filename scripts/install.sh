#!/bin/sh
# cec-bridge 部署脚本（在 KM2 / CoreELEC 上以 root 运行）
# 用法：/storage/cec-bridge/scripts/install.sh
set -e

SRC_DIR="/storage/cec-bridge"
CONF="$SRC_DIR/src/config.json"

echo "==> 检查 cec-client"
command -v cec-client >/dev/null 2>&1 || {
    echo "!! 未找到 cec-client，请确认 CoreELEC 已安装 cec-utils（默认自带）"
    exit 1
}

echo "==> 生成配置文件（若不存在）"
if [ ! -f "$CONF" ]; then
    cp "$SRC_DIR/src/config.example.json" "$CONF"
    echo "    已从模板创建 $CONF，请编辑后再启动服务！"
fi

echo "==> 安装 systemd 服务"
cp "$SRC_DIR/systemd/cec-bridge.service" /storage/.config/system.d/
systemctl daemon-reload
systemctl enable cec-bridge.service

echo "==> 完成。接下来请："
echo "    1) 编辑 $CONF（填 AppleTV 的真实 IP、确认物理地址）"
echo "    2) 在 Kodi 设置里关闭 CEC 外设，把 CEC 接口让给本脚本（见 docs/03-deploy.md）"
echo "    3) systemctl start cec-bridge.service"
