#!/bin/sh
# Push the TV-side bridge and install the helper APK.
# Usage: ./install.sh <TV_IP>
set -eu

TV="${1:?usage: $0 <TV_IP>}"
SERIAL="${TV}:5555"
BASE=/storage/emulated/0/cec-bridge
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

echo "[1/4] adb connect ${TV}:5555"
adb connect "$SERIAL"
adb -s "$SERIAL" get-state >/dev/null

echo "[2/4] prepare ${BASE}"
adb -s "$SERIAL" shell mkdir -p "$BASE"

echo "[3/4] push scripts"
for f in cec-bridge.sh launch.sh restart.sh stop.sh; do
    adb -s "$SERIAL" push "$HERE/$f" "$BASE/$f.new"
    adb -s "$SERIAL" shell sh -n "$BASE/$f.new"
    adb -s "$SERIAL" shell mv "$BASE/$f.new" "$BASE/$f"
done

echo "[4/4] install APK and start once"
adb -s "$SERIAL" install -r "$HERE/apk/cecbridge.apk"
adb -s "$SERIAL" shell am start -n io.github.cecbridge/.MainActivity

sleep 2
echo
echo "daemon pid: $(adb -s "$SERIAL" shell cat "$BASE/daemon.pid" 2>/dev/null | tr -d '\r')"
echo "logs:"
echo "  adb -s $SERIAL shell tail -f $BASE/daemon.log"
echo "  adb -s $SERIAL shell tail -f $BASE/launch.log"
echo
echo "Optional ADB self-heal: adb -s $SERIAL shell touch $BASE/keep-adb"
echo "Existing daemons keep running the previous script until restarted via TvService."
echo "See docs/OPERATIONS.md for updating or resuming a disabled installation."
