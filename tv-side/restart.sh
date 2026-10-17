#!/system/bin/sh
BASE=/storage/emulated/0/cec-bridge
[ -f "$BASE/daemon.pid" ] && kill "$(cat "$BASE/daemon.pid")" 2>/dev/null
sleep 1
rm -rf "$BASE/lock"
exec /system/bin/sh "$BASE/launch.sh"
