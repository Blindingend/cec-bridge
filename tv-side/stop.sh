#!/system/bin/sh
BASE=/storage/emulated/0/cec-bridge
p=$(cat "$BASE/daemon.pid" 2>/dev/null)
[ -n "$p" ] && kill "$p" 2>/dev/null && sleep 1 && kill -9 "$p" 2>/dev/null
rm -rf "$BASE/lock"
