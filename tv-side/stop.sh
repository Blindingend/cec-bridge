#!/system/bin/sh
BASE=/storage/emulated/0/cec-bridge
# Persist across APK watchdog jobs and TV reboots. Run through the root launcher.
touch "$BASE/disabled"
p=$(cat "$BASE/daemon.pid" 2>/dev/null)
case "$p" in ''|*[!0-9]*) exit 0 ;; esac
if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'cec-bridge.sh'; then
  kill "$p" 2>/dev/null
fi
# The daemon exits its loop and cleans up its action worker, PID and lock.
