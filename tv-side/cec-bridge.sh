#!/system/bin/sh
# cec-bridge daemon: compensates for Xiaomi HdmiControlService xiaoai-standby bug.
# - Watch explicit CEC source requests in both Awake and Asleep states.
# - Wake only when asleep, then select and verify the requested HDMI input.
# - On the Awake->Asleep transition, send CEC <Standby> to all known CEC devices.
PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
BASE=/storage/emulated/0/cec-bridge
LOG=$BASE/daemon.log
HB=$BASE/heartbeat
LOCK=$BASE/lock
PIDF=$BASE/daemon.pid
SERVICE=/system/bin/service
DUMPSYS=/system/bin/dumpsys

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$$] $*" >> "$LOG"; }

hdmi_dump() { "$DUMPSYS" hdmi_control 2>/dev/null; }

hist_lines() {
  if [ -n "$CEC_TEST_HIST" ] && [ -f "$CEC_TEST_HIST" ]; then
    grep 'time=' "$CEC_TEST_HIST"
    return
  fi
  local dump
  dump=$(hdmi_dump) || return 1
  printf '%s\n' "$dump" | grep -q 'CEC message history:' || return 1
  printf '%s\n' "$dump" | sed -n '/CEC message history:/,/^mEarcControlFeatureEnabled/p' | grep 'time=' || :
}

power_state() {
  "$DUMPSYS" power 2>/dev/null | awk -F= '
    /^[[:space:]]*mWakefulness=/ {
      state=$2; sub(/[[:space:]]*$/, "", state)
      if (state == "Awake" || state == "Asleep") print state
      exit
    }'
}

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

activate_source() {
  local src="$1" initial_state="$2" input want path n t state fg
  # Discovery can lag behind Image/Text View On; retry briefly without guessing.
  n=0
  while ! input=$(input_for_src "$src"); do
    n=$((n + 1))
    [ "$n" -ge 3 ] && { log "activate aborted: no input mapping for src=$src"; return; }
    sleep 1
  done
  case "$input" in
    23) want=0x1000 ;;
    24) want=0x2000 ;;
    25) want=0x3000 ;;
    26) want=0x4000 ;;
    *)  log "activate aborted: invalid input=$input for src=$src"; return ;;
  esac
  log "activate trigger: src logical=$src input=$input state=$initial_state"

  # Wake first. Waking brings the home activity to the foreground, so an input
  # activity started before the wake gets covered by home.
  if [ "$initial_state" = Asleep ]; then
    n=0
    while [ "$n" -lt 4 ]; do
      state=$(power_state)
      [ "$state" = Awake ] && break
      [ "$state" = Asleep ] || { log "wake aborted: unknown power state"; return; }
      t=$("$DUMPSYS" power 2>/dev/null | sed -n 's/.*mLastSleepTime=\([0-9][0-9]*\).*/\1/p' | head -1)
      [ -n "$t" ] || { log "wake aborted: missing sleep time"; return; }
      "$SERVICE" call power 9 i64 $((t + 1)) s16 'android.policy:POWER' s16 android >>"$LOG" 2>&1
      sleep 1
      n=$((n + 1))
    done
    [ "$(power_state)" = Awake ] || { log "wake FAILED src=$src"; return; }
    log "TV awake"
    sleep 2
  fi

  # Always issue one real input selection for a fresh CEC request. Active Source
  # can update the routing path while ExternalSourceActivity still displays the
  # previous HDMI input, so even path + foreground cannot justify skipping it.
  # Afterwards both are useful checks that the selection command took effect.
  [ "$(power_state)" = Awake ] || { log "activate cancelled: TV no longer awake src=$src"; return; }
  n=0
  while [ "$n" -lt 5 ]; do
    [ "$(power_state)" = Awake ] || { log "activate cancelled: TV no longer awake src=$src"; return; }
    "$SERVICE" call TvService 3000 s16 start s16 \
      "-a com.xiaomi.mitv.tvplayer.EXTSRC_PLAY -n com.xiaomi.mitv.tvplayer/com.xiaomi.mitv.tvplayer.ExternalSourceActivity --ei input $input" >>"$LOG" 2>&1
    sleep 2
    path=$(routing_path)
    if [ "$path" = "$want" ] && resumed_is_external; then
      log "input ok src=$src path=$path"
      return
    fi
    n=$((n + 1))
  done
  fg=$("$DUMPSYS" activity activities 2>/dev/null | grep -m1 'mResumedActivity' | sed 's/^ *//')
  log "input FAILED src=$src path=${path:-none} want=$want fg=$fg"
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
    case "$a" in 00|0f) continue ;; esac
    [ "$(power_state)" = Asleep ] || { log "standby cancelled: TV no longer asleep"; return; }
    "$SERVICE" call hdmi_control 30 i32 0 i32 "$((0x$a))" >>"$LOG" 2>&1
    log "sent <Standby> to logical $((0x$a))"
  done
}

LAST_KA=0
keepadb_tick() {
  [ -f "$BASE/keep-adb" ] || return 0
  local st nowt n
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
HISTORY_READY=0
PREV_STATE=""
STANDBY_AT=0
ACTION_PID=""
ACTION_SRC=""

consume_history() {
  # Sets NEW in the parent shell. Never replay the tail after a buffer reset.
  local hist="$1" last
  NEW=""
  last=$(printf '%s\n' "$hist" | tail -1)
  if [ "$HISTORY_READY" = 0 ]; then
    HISTORY_READY=1
  elif [ -z "$hist" ]; then
    return
  elif [ -z "$SEEN" ]; then
    NEW="$hist"
  elif printf '%s\n' "$hist" | grep -qxF "$SEEN"; then
    NEW=$(printf '%s\n' "$hist" | awk -v s="$SEEN" 'f{print} $0==s{f=1}')
  else
    log "CEC history cursor lost; rebaseline without replay"
  fi
  SEEN="$last"
}

latest_source() {
  # Ignore sent messages and power-status polling; newest explicit request wins.
  # Android's toybox sed does not support GNU BRE alternation (\|).
  printf '%s\n' "$1" | awk '
    index($0, "[R]") && (index($0, "message=<Image View On>") ||
      index($0, "message=<Text View On>") || index($0, "message=<Active Source>")) {
      value=$0; sub(/^.*src: /, "", value); sub(/,.*/, "", value)
      if (value ~ /^[0-9]+$/ && value+0 >= 1 && value+0 <= 14) src=value+0
    }
    END {if (src != "") print src}'
}

cancel_action() {
  if [ -n "$ACTION_PID" ]; then
    kill "$ACTION_PID" 2>/dev/null
    wait "$ACTION_PID" 2>/dev/null
  fi
  ACTION_PID=""
  ACTION_SRC=""
}

request_source() {
  if [ "$ACTION_SRC" = "$1" ] && [ -n "$ACTION_PID" ] && kill -0 "$ACTION_PID" 2>/dev/null; then
    return  # Coalesce a device's Image View On + Active Source burst.
  fi
  cancel_action
  ACTION_SRC="$1"
  ( trap - EXIT; trap 'exit 0' TERM INT; activate_source "$1" "$2" ) &
  ACTION_PID=$!
}

bridge_tick() {
  local state hist nowt src entered_sleep=0
  state=$(power_state)
  case "$state" in Awake|Asleep) ;; *) return ;; esac
  nowt=$(date +%s)
  if [ "$state" = Asleep ] && [ "$PREV_STATE" = Awake ]; then
    entered_sleep=1
    cancel_action
    STANDBY_AT=$((nowt + 3))
    log "TV entered sleep; standby pending"
  elif [ "$state" = Awake ]; then
    STANDBY_AT=0
  fi
  PREV_STATE="$state"

  if hist=$(hist_lines); then
    consume_history "$hist"
    # Messages before this observed sleep belong to the previous awake session.
    [ "$entered_sleep" = 1 ] && NEW=""
    src=$(latest_source "$NEW")
    if [ -n "$src" ]; then
      STANDBY_AT=0
      log "CEC request src=$src state=$state"
      request_source "$src" "$state"
    fi
  fi

  if [ "$STANDBY_AT" -gt 0 ] && [ "$nowt" -ge "$STANDBY_AT" ]; then
    STANDBY_AT=0
    send_standby_all
  fi
}

cleanup() {
  cancel_action
  if [ "$(cat "$PIDF" 2>/dev/null)" = "$$" ]; then
    rm -f "$PIDF" "$HB"
    rmdir "$LOCK" 2>/dev/null
  fi
}

main() {
  local now hb p sz tick=0
  mkdir -p "$BASE" 2>/dev/null
  [ -f "$BASE/disabled" ] && return
  if ! mkdir "$LOCK" 2>/dev/null; then
    p=$(cat "$PIDF" 2>/dev/null)
    case "$p" in ''|*[!0-9]*) ;; *)
      if kill -0 "$p" 2>/dev/null && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'cec-bridge.sh'; then
        return
      fi ;;
    esac
    now=$(date +%s)
    hb=$(stat -c %Y "$HB" 2>/dev/null)
    [ -z "$hb" ] && hb=0
    [ $((now - hb)) -ge 0 ] && [ $((now - hb)) -lt 15 ] && return
    rmdir "$LOCK" 2>/dev/null || return
    mkdir "$LOCK" 2>/dev/null || return
  fi
  echo $$ > "$PIDF"
  trap 'exit 0' TERM INT
  trap cleanup EXIT
  log "daemon start (awake source switching enabled)"
  while [ ! -f "$BASE/disabled" ]; do
    echo "$(date +%s)" > "$HB"
    tick=$((tick + 1))
    if [ $((tick % 150)) -eq 1 ]; then
      sz=$(stat -c %s "$LOG" 2>/dev/null)
      if [ -n "$sz" ] && [ "$sz" -gt 1048576 ]; then mv -f "$LOG" "$LOG.1"; fi
    fi
    bridge_tick
    [ $((tick % 5)) -eq 0 ] && keepadb_tick
    sleep 2
  done
}

# Source functions without starting a daemon for regression tests.
if [ "${CEC_BRIDGE_LIBRARY:-0}" != 1 ]; then main; fi
