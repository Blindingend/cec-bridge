#!/system/bin/sh
BASE=/storage/emulated/0/cec-bridge
sh "$BASE/stop.sh"
p=$(cat "$BASE/daemon.pid" 2>/dev/null)
case "$p" in ''|*[!0-9]*) p="" ;; esac
n=0
while [ -n "$p" ] && kill -0 "$p" 2>/dev/null && [ "$n" -lt 15 ]; do
  sleep 1
  n=$((n + 1))
done
if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
  echo "daemon did not stop; leaving disabled marker for inspection" >&2
  exit 1
fi
rm -f "$BASE/disabled" "$BASE/heartbeat" "$BASE/daemon.pid"
rmdir "$BASE/lock" 2>/dev/null
exec /system/bin/sh "$BASE/launch.sh"
