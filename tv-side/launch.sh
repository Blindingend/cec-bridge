#!/system/bin/sh
# Called by the helper APK via TvService 4400 (runs as root via misysdiagnose).
# Optional keep-adb marker: /storage/emulated/0/cec-bridge/keep-adb
PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
BASE=/storage/emulated/0/cec-bridge
PIDF=$BASE/daemon.pid
LLOG=$BASE/launch.log
SERVICE=/system/bin/service

mkdir -p "$BASE" 2>/dev/null
sz=$(stat -c %s "$LLOG" 2>/dev/null)
if [ -n "$sz" ] && [ "$sz" -gt 262144 ]; then mv -f "$LLOG" "$LLOG.1"; fi
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$$] $*" >> "$LLOG"; }

log "launch invoked uid=$(id -u 2>/dev/null) adbd=$(getprop init.svc.adbd 2>/dev/null)"

if [ -f "$BASE/keep-adb" ]; then
  st=$(getprop init.svc.adbd 2>/dev/null)
  attempt=0
  while [ "$st" != "running" ] && [ "$attempt" -lt 2 ]; do
    attempt=$((attempt + 1))
    log "keep-adb: adbd=$st, forcing adb_enabled 0->1 (attempt $attempt)"
    # A same-value putInt(1) does not wake UsbService; toggle to force a transition.
    "$SERVICE" call TvService 4004 i32 0 >>"$LLOG" 2>&1
    sleep 1
    "$SERVICE" call TvService 4004 i32 1 >>"$LLOG" 2>&1
    n=0
    while [ "$n" -lt 8 ]; do
      sleep 1
      st=$(getprop init.svc.adbd 2>/dev/null)
      [ "$st" = "running" ] && break
      n=$((n + 1))
    done
  done
  log "keep-adb: after request adbd=$st"
fi

if [ -f "$PIDF" ]; then
  p=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$p" ] && [ -d "/proc/$p" ]; then
    if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'cec-bridge.sh'; then
      log "daemon already running pid=$p"
      exit 0
    fi
  fi
fi
log "starting daemon"
setsid /system/bin/sh "$BASE/cec-bridge.sh" </dev/null >/dev/null 2>&1 &
