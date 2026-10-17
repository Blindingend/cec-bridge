#!/bin/sh
# Push the TV-side bridge and install the helper APK.
# Usage: ./install.sh <TV_IP>
set -eu

TV="${1:?usage: $0 <TV_IP>}"
BASE=/storage/emulated/0/cec-bridge
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

echo "[1/4] adb connect ${TV}:5555"
adb connect "${TV}:5555"

echo "[2/4] prepare ${BASE}"
adb shell mkdir -p "$BASE"

echo "[3/4] push scripts"
for f in cec-bridge.sh launch.sh restart.sh stop.sh; do
    adb push "$HERE/$f" "$BASE/$f"
done

echo "[4/4] install APK and start once"
adb install -r "$HERE/apk/cecbridge.apk"
adb shell am start -n io.github.cecbridge/.MainActivity

sleep 2
echo
echo "daemon pid: $(adb shell cat "$BASE/daemon.pid" 2>/dev/null | tr -d '\r')"
echo "logs:"
echo "  adb shell tail -f $BASE/daemon.log"
echo "  adb shell tail -f $BASE/launch.log"
echo
echo "Optional ADB self-heal: adb shell touch $BASE/keep-adb"
