#!/system/bin/sh
# cec-bridge daemon: compensates for Xiaomi HdmiControlService xiaoai-standby bug.
# - While TV Sleep (PowerManager Asleep), watch CEC traffic; on a device power-on
#   message, pre-select its HDMI input and wake the TV.
# - On the Awake->Asleep transition, send CEC <Standby> to all known CEC devices.
PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
BASE=/storage/emulated/0/cec-bridge
LOG=$BASE/daemon.log
HB=$BASE/heartbeat
LOCK=$BASE/lock
PIDF=$BASE/daemon.pid
SERVICE=/system/bin/service
DUMPSYS=/system/bin/dumpsys

mkdir -p "$BASE" 2>/dev/null

# single instance, heartbeat-based
if ! mkdir "$LOCK" 2>/dev/null; then
  now=$(date +%s)
  hb=$(stat -c %Y "$HB" 2>/dev/null)
  [ -z "$hb" ] && hb=0
  if [ $((now - hb)) -ge 0 ] && [ $((now - hb)) -lt 15 ]; then
    exit 0
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ > "$PIDF"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$$] $*" >> "$LOG"; }

sz=$(stat -c %s "$LOG" 2>/dev/null)
if [ -n "$sz" ] && [ "$sz" -gt 1048576 ]; then mv -f "$LOG" "$LOG.1"; fi

log "daemon start"

hdmi_dump() { "$DUMPSYS" hdmi_control 2>/dev/null; }

hist_lines() {
  if [ -n "$CEC_TEST_HIST" ] && [ -f "$CEC_TEST_HIST" ]; then
    grep 'time=' "$CEC_TEST_HIST"
    return
  fi
  hdmi_dump | sed -n '/CEC message history:/,/^mEarcControlFeatureEnabled/p' | grep 'time='
}

power_asleep() {
  "$DUMPSYS" power 2>/dev/null | grep -m1 'mWakefulness=' | grep -q 'Asleep'
}

last_hist_line() { hist_lines | tail -1; }

input_for_src() {
  # $1 = decimal CEC logical address -> mitv tvplayer input id (HDMI1=23 ... HDMI4=26).
  # Parse the address as hex and map only via the TV's own port_id; never guess a port.
  local hex port
  hex=$(printf '%02x' "$1")
  port=$(hdmi_dump \
    | grep -i "CEC: logical_address: 0x${hex} " \
    | sed -n 's/.*port_id: \([0-9][0-9]*\).*/\1/p' \
    | head -1)
  if [ -z "$port" ]; then
    log "input_for_src: no CEC device for logical 0x${hex}"
    return 1
  fi
  case "$port" in
    1) echo 23 ;;
    2) echo 24 ;;
    3) echo 25 ;;
    4) echo 26 ;;
    *) log "input_for_src: unsupported port_id=$port for logical 0x${hex}"; return 1 ;;
  esac
}

routing_path() {
  "$DUMPSYS" hdmi_control 2>/dev/null | sed -n 's/.*mActiveRoutingPath: \(0x[0-9a-fA-F]*\).*/\1/p' | head -1
}

resumed_is_external() {
  "$DUMPSYS" activity activities 2>/dev/null \
    | grep -m1 'mResumedActivity' \
    | grep -q 'com.xiaomi.mitv.tvplayer/.ExternalSourceActivity'
}

do_wake() {
  local src="$1" input want path n t
  input=$(input_for_src "$src") || { log "wake aborted: no input mapping for src=$src"; return; }
  case "$input" in
    23) want=0x1000 ;;
    24) want=0x2000 ;;
    25) want=0x3000 ;;
    26) want=0x4000 ;;
    *)  log "wake aborted: invalid input=$input for src=$src"; return ;;
  esac
  log "wake trigger: src logical=$src input=$input"

  # Wake first. Waking brings the home activity to the foreground, so an input
  # activity started before the wake gets covered by home.
  n=0
  while [ "$n" -lt 4 ]; do
    t=$("$DUMPSYS" power 2>/dev/null | sed -n 's/.*mLastSleepTime=\([0-9][0-9]*\).*/\1/p' | head -1)
    [ -z "$t" ] && t=0
    "$SERVICE" call power 9 i64 $((t + 1)) s16 'android.policy:POWER' s16 android >>"$LOG" 2>&1
    sleep 1
    power_asleep || break
    n=$((n + 1))
  done
  if power_asleep; then log "wake FAILED src=$src"; return; fi
  log "TV awake"

  # Let the post-wake home activity settle, then select the input and verify.
  # NOTE: mActiveRoutingPath alone is not enough. The Apple TV's <Active Source>
  # sets it to 0x1000 before/while we wake, while tvhome is still foreground and
  # the TV keeps showing the launcher. Only skip if ExternalSourceActivity is
  # actually resumed as well.
  sleep 2
  path=$(routing_path)
  if [ "$path" = "$want" ] && resumed_is_external; then
    log "wake preselect already ok src=$src path=$path"
    return
  fi
  if [ "$path" = "$want" ]; then
    log "wake: path ok but foreground not ExternalSourceActivity, forcing input src=$src"
  fi
  n=0
  while [ "$n" -lt 5 ]; do
    "$SERVICE" call TvService 3000 s16 start s16 \
      "-a com.xiaomi.mitv.tvplayer.EXTSRC_PLAY -n com.xiaomi.mitv.tvplayer/com.xiaomi.mitv.tvplayer.ExternalSourceActivity --ei input $input" >>"$LOG" 2>&1
    sleep 2
    path=$(routing_path)
    if [ "$path" = "$want" ] && resumed_is_external; then
      log "wake preselect ok src=$src path=$path"
      return
    fi
    n=$((n + 1))
  done
  fg=$("$DUMPSYS" activity activities 2>/dev/null | grep -m1 'mResumedActivity' | sed 's/^ *//')
  log "wake preselect FAILED src=$src path=${path:-none} want=$want fg=$fg"
}

send_standby_all() {
  local a addrs
  # CEC displays logical addresses as two hex digits; dumpsys uses uppercase
  # for A-F (e.g. the Switch is 0x0B). Normalize before converting to decimal.
  addrs=$(hdmi_dump \
    | sed -n 's/.*CEC: logical_address: 0x\([0-9A-Fa-f][0-9A-Fa-f]\) .*/\1/p' \
    | tr 'A-F' 'a-f' \
    | sort -u)
  for a in $addrs; do
    [ "$a" = "00" ] && continue
    "$SERVICE" call hdmi_control 30 i32 0 i32 "$((0x$a))" >>"$LOG" 2>&1
    log "sent <Standby> to logical $((0x$a))"
  done
}

LAST_KA=0
keepadb_tick() {
  [ -f "$BASE/keep-adb" ] || return 0
  local st nowt
  st=$(getprop init.svc.adbd 2>/dev/null)
  [ "$st" = "running" ] && return 0
  nowt=$(date +%s)
  [ $((nowt - LAST_KA)) -lt 60 ] && return 0
  LAST_KA=$nowt
  log "keep-adb: adbd=$st, forcing adb_enabled 0->1"
  # A same-value putInt(1) does not wake UsbService; toggle to force a transition.
  "$SERVICE" call TvService 4004 i32 0 >>"$LOG" 2>&1
  sleep 1
  "$SERVICE" call TvService 4004 i32 1 >>"$LOG" 2>&1
  n=0
  while [ "$n" -lt 8 ]; do
    sleep 1
    st=$(getprop init.svc.adbd 2>/dev/null)
    [ "$st" = "running" ] && break
    n=$((n + 1))
  done
  log "keep-adb: adbd now $st"
}

SEEN=""
prev_asleep=""
last_wake=0
tick=0

while true; do
  echo "$(date +%s)" > "$HB"
  tick=$((tick + 1))
  [ $((tick % 5)) -eq 0 ] && keepadb_tick

  if power_asleep; then asleep=1; else asleep=0; fi

  if [ "$asleep" = "1" ]; then
    HIST=$(hist_lines)
    LAST=$(printf '%s\n' "$HIST" | tail -1)
    [ -z "$SEEN" ] && SEEN="$LAST"

    if printf '%s\n' "$HIST" | grep -qxF "$SEEN"; then
      NEW=$(printf '%s\n' "$HIST" | awk -v s="$SEEN" 'f{print} $0==s{f=1}')
    else
      NEW=$(printf '%s\n' "$HIST" | tail -5)
    fi

    if [ -n "$NEW" ]; then
      TRIG=""
      oldIFS=$IFS
      IFS='
'
      for line in $NEW; do
        case "$line" in
          *'message=<Image View On>'*|*'message=<Text View On>'*|*'message=<Active Source>'*)
            src=$(printf '%s' "$line" | sed -n 's/.*src: \([0-9][0-9]*\).*/\1/p')
            if [ -n "$src" ] && [ "$src" != "0" ]; then
              log "wake match: $line"
              TRIG=$src
              break
            fi
            ;;
        esac
      done
      IFS=$oldIFS

      nowt=$(date +%s)
      if [ -n "$TRIG" ] && [ $((nowt - last_wake)) -gt 20 ]; then
        last_wake=$nowt
        do_wake "$TRIG" &
      fi
    fi
    SEEN="$LAST"
  else
    [ "$prev_asleep" = "1" ] && log "TV awake"
    SEEN=$(last_hist_line)
  fi

  if [ "$asleep" = "1" ] && [ "$prev_asleep" = "0" ]; then
    log "TV entered sleep, sending <Standby> to CEC devices"
    ( sleep 3; send_standby_all ) &
  fi

  prev_asleep=$asleep
  sleep 2
done
