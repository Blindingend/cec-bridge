#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cec-bridge —— 小米电视 HDMI-CEC 补全中枢

运行环境：刷了 CoreELEC 的 Amlogic 盒子（MECOOL KM2 / S905X2）。
依赖：cec-client（CoreELEC 自带），Python 3 标准库（零第三方依赖）。

原理：盒子通过 HDMI 口挂在电视的 CEC 共享总线上，本脚本用 cec-client
监听总线事件，并主动发送 CEC 命令，补上小米电视阉割掉的三个能力：

  1. 外设开机 -> 唤醒电视（Image View On）
  2. 外设开机 -> 自动切换输入源（Active Source）
  3. 电视关机 -> 外设跟随待机（Standby）

对 Apple TV 这种「待机时 5V 不掉、且可能不发 CEC 事件」的设备，额外用
ping 网络通断做开机检测的兜底（见 config 里 sources[].ping_host）。
"""

import json
import logging
import os
import re
import subprocess
import sys
import threading
import time

# ---------------------------------------------------------------------------
# CEC 常量
# ---------------------------------------------------------------------------

OPCODE_IMAGE_VIEW_ON = 0x04   # 唤醒/显示
OPCODE_STANDBY = 0x36         # 待机
OPCODE_ROUTING_CHANGE = 0x80  # 电视切源（广播，参数: 旧物理地址->新物理地址）
OPCODE_ACTIVE_SOURCE = 0x82   # 某设备成为活跃源（广播，参数: 物理地址）
OPCODE_REPORT_POWER_STATUS = 0x90  # 上报电源状态

LOGICAL_ADDR_TV = 0
LOGICAL_ADDR_BROADCAST = 15

# 解析 cec-client 输出的 TRAFFIC 行，形如：
#   TRAFFIC: [         1534054 ] << 20:82:20:00
# 字段：方向(>>发/<<收)  header(源<<4|目标)  opcode  [参数]
_TRAFFIC_RE = re.compile(
    r"TRAFFIC:.*?(>>|<<)\s+([0-9a-fA-F]{2}):([0-9a-fA-F]{2})"
    r"(?::([0-9a-fA-F ]+))?"
)


def pa_to_hex(pa):
    """把物理地址 "2.0.0.0" 编码为十六进制字符串 "2000"（2 字节）。"""
    val = 0
    for part in pa.split("."):
        val = (val << 4) | int(part)
    return "%04x" % val


class Source:
    """一个 HDMI 输入源（PS5 / AppleTV / Switch …）。"""

    def __init__(self, cfg):
        self.name = cfg["name"]
        self.pa = cfg["physical_address"]
        self.pa_hex = pa_to_hex(self.pa)
        self.logical = cfg.get("logical_address")
        self.ping_host = cfg.get("ping_host")
        self.wake_tv = cfg.get("wake_tv", True)
        self.auto_switch = cfg.get("auto_switch", True)
        self._was_reachable = None  # ping 状态跳变检测


class CECBridge:
    def __init__(self, config):
        self.cfg = config
        self.bridge_logical = config["bridge"].get("logical_address", 4)
        self.sources = {s.name: Source(s) for s in config["sources"]}
        self.features = config.get("features", {})

        self._proc = None
        self._send_lock = threading.Lock()
        self._stop = threading.Event()

        logging.basicConfig(
            level=getattr(logging, config.get("log_level", "INFO")),
            format="%(asctime)s %(levelname)s %(message)s",
        )
        self.log = logging.getLogger("cec-bridge")

    # ------------------------------------------------------------------ 进程管理

    def start(self):
        """启动 cec-client 交互进程，建立 stdin/stdout 双向管道。"""
        cmd = [self.cfg.get("cec_client", "cec-client")]
        cmd += self.cfg.get("cec_client_args", ["-d", "8"])
        self.log.info("启动 cec-client: %s", " ".join(cmd))
        self._proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,  # 行缓冲
        )
        # 读线程：把 cec-client 的每一行丢给事件处理
        threading.Thread(target=self._read_loop, daemon=True).start()

    def stop(self):
        self._stop.set()
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()

    def send(self, command):
        """向 cec-client 交互式 stdin 发送一条命令。"""
        if not self._proc or self._proc.poll() is not None:
            self.log.warning("cec-client 未运行，丢弃命令: %s", command)
            return
        with self._send_lock:
            try:
                self._proc.stdin.write(command + "\n")
                self._proc.stdin.flush()
                self.log.debug("发送: %s", command)
            except (BrokenPipeError, OSError) as e:
                self.log.error("发送失败: %s", e)

    # ------------------------------------------------------------------ 事件读取

    def _read_loop(self):
        """持续读取 cec-client 输出并逐行处理。"""
        for line in self._proc.stdout:
            if self._stop.is_set():
                break
            line = line.rstrip("\n")
            if "TRAFFIC" in line:
                self._on_traffic(line)

    def _on_traffic(self, line):
        m = _TRAFFIC_RE.search(line)
        if not m:
            return
        direction, header, opcode, params = m.groups()
        header = int(header, 16)
        opcode = int(opcode, 16)
        src = header >> 4
        dst = header & 0x0F
        incoming = direction == "<<"  # << 表示从总线收到

        if opcode == OPCODE_ACTIVE_SOURCE and incoming:
            # 某设备广播成为活跃源 -> 它开机了
            pa = self._parse_pa(params)
            dev = self._find_source_by_pa(pa)
            if dev:
                self.log.info("检测到 %s 成为活跃源 (pa=%s)", dev.name, dev.pa)
                self._handle_device_woke(dev)

        elif opcode == OPCODE_STANDBY and incoming and dst == LOGICAL_ADDR_BROADCAST:
            # 电视广播 Standby -> 电视关机，外设跟随待机
            self.log.info("检测到电视待机广播")
            self._handle_tv_standby()

    @staticmethod
    def _parse_pa(params):
        """把 Active Source 的参数（如 "20 00"）解析为物理地址 "2.0.0.0"。"""
        if not params:
            return None
        raw = params.replace(":", " ").split()
        if len(raw) < 2:
            return None
        try:
            hi = int(raw[0], 16)
            lo = int(raw[1], 16)
        except ValueError:
            return None
        return "%d.%d.%d.%d" % ((hi >> 4) & 0xF, hi & 0xF, (lo >> 4) & 0xF, lo & 0xF)

    def _find_source_by_pa(self, pa):
        for dev in self.sources.values():
            if dev.pa == pa:
                return dev
        return None

    # ------------------------------------------------------------------ 状态机动作

    def _handle_device_woke(self, dev):
        """外设开机：唤醒电视 + 切到该源。"""
        if self.features.get("wake_tv", True) and dev.wake_tv:
            self.send("on %d" % LOGICAL_ADDR_TV)  # Image View On
            self.log.info("已发送唤醒电视")
        if self.features.get("auto_switch", True) and dev.auto_switch:
            # 广播 Active Source，声明该设备物理地址为活跃源，电视随之切源
            src = self.bridge_logical
            pa = dev.pa_hex
            self.send("tx %X%X:82:%s:%s" % (src, LOGICAL_ADDR_BROADCAST, pa[:2], pa[2:]))
            self.log.info("已发送切源到 %s (pa=%s)", dev.name, dev.pa)

    def _handle_tv_standby(self):
        """电视关机：让所有外设跟随待机。"""
        if not self.features.get("standby_devices", True):
            return
        for dev in self.sources.values():
            if dev.logical is not None:
                self.send("standby %d" % dev.logical)
                self.log.info("已发送待机到 %s", dev.name)

    # ------------------------------------------------------------------ ping 兜底

    def _ping_loop(self):
        """周期 ping 各 source 的 ping_host，检测「不通 -> 通」的跳变（开机）。"""
        interval = self.features.get("ping_interval", 5)
        while not self._stop.wait(interval):
            for dev in self.sources.values():
                if not dev.ping_host:
                    continue
                reachable = self._icmp_ping(dev.ping_host)
                if dev._was_reachable is False and reachable is True:
                    self.log.info("ping 检测到 %s 开机 (%s)", dev.name, dev.ping_host)
                    self._handle_device_woke(dev)
                dev._was_reachable = reachable

    @staticmethod
    def _icmp_ping(host, timeout=2):
        """用系统 ping 检测主机是否可达，返回 True/False。"""
        try:
            rc = subprocess.call(
                ["ping", "-c", "1", "-W", str(timeout), host],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return rc == 0
        except Exception:
            return False

    # ------------------------------------------------------------------ 主循环

    def run(self):
        self.start()
        # ping 兜底检测线程
        if any(s.ping_host for s in self.sources.values()):
            threading.Thread(target=self._ping_loop, daemon=True).start()
        self.log.info("cec-bridge 已就绪，等待 CEC 事件…")
        try:
            while not self._stop.is_set():
                if self._proc.poll() is not None:
                    self.log.error("cec-client 退出 (code=%s)，3 秒后重启",
                                   self._proc.returncode)
                    time.sleep(3)
                    self.start()
                    continue
                time.sleep(1)
        except KeyboardInterrupt:
            self.log.info("收到中断，退出")
        finally:
            self.stop()


def main():
    config_path = sys.argv[1] if len(sys.argv) > 1 else "config.json"
    if not os.path.exists(config_path):
        print("找不到配置文件: %s" % config_path, file=sys.stderr)
        print("请从 config.example.json 复制一份并修改：cp config.example.json config.json",
              file=sys.stderr)
        sys.exit(1)
    with open(config_path, "r", encoding="utf-8") as f:
        config = json.load(f)
    CECBridge(config).run()


if __name__ == "__main__":
    main()
