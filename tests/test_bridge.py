"""Behavioral tests for the TV shell daemon; never contact an Android device."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHELL = shlex.split(os.environ.get("BRIDGE_TEST_SHELL", "/bin/sh"))

HDMI = """mActiveRoutingPath: 0x2000
CEC: logical_address: 0x00 physical_address: 0x0000 port_id: -1
CEC: logical_address: 0x04 physical_address: 0x2000 port_id: 2
CEC: logical_address: 0x08 physical_address: 0x1000 port_id: 1
CEC: logical_address: 0x0B physical_address: 0x3000 port_id: 3
CEC message history:
    [R] time=2026-10-23 10:00:00 message=<Report Power Status> src: 4, dst: 0, params: 01
"""


def tv_input(port=2, token="android.os.Binder@715b3a5", user=0):
    # Shape verified in the walle active dump: token + SessionState on one line.
    sessions = "" if port is None else (
        f"    {token}: com.android.server.tv.TvInputManagerService$SessionState@b1d77d2\n"
        f"      inputId: com.mediatek.tvinput/.hdmi.HDMIInputService/HW{port + 3}\n"
        f"      sessionToken: {token}\n"
    )
    return (f"User Ids (Current user: {user}):\n  {user}\nUserState ({user}):\n"
            "  inputMap: inputId -> TvInputState\n"
            "    com.mediatek.tvinput/.hdmi.HDMIInputService/HW5: state: 0\n"
            "  sessionStateMap: ITvInputSession -> SessionState\n" + sessions
            + f"  mainSessionToken: {token if port is not None else 'null'}\n"
            + "TvInputHardwareManager Info:\n")


def event(second, name="Active Source", src=8, direction="R"):
    return f"    [{direction}] time=2026-10-23 10:00:{second:02d} message=<{name}> src: {src}, dst: 15, params: 10 00\n"


class BridgeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.put("hdmi", HDMI)
        self.put("tv_input", tv_input())
        self.put("power", "  mWakefulness=Awake\n  mLastSleepTime=100\n")
        self.put("activity", "mResumedActivity: com.xiaomi.mitv.tvplayer/.ExternalSourceActivity\n")
        self.put("dumpsys", '#!/bin/sh\nif [ "$1" = -t ]; then shift 2; fi\ncase $1 in\npower) cat "$CASE_DIR/power" ;;\nhdmi_control) cat "$CASE_DIR/hdmi" ;;\nactivity) cat "$CASE_DIR/activity" ;;\ntv_input) cat "$CASE_DIR/tv_input" ;;\nesac\n')
        self.put("service", r"""#!/usr/bin/env python3
import os, pathlib, re, sys
b = pathlib.Path(os.environ['CASE_DIR'])
a = sys.argv[1:]
with (b / 'calls').open('a') as f: f.write(' '.join(a) + '\n')
if (b / 'no_effect').exists(): sys.exit(0)
if a[:3] == ['call', 'power', '9']:
    p = b / 'power'
    p.write_text(p.read_text().replace('Asleep', 'Awake'))
if a[:3] == ['call', 'TvService', '3000']:
    port = int(re.search(r'--ei input (\d+)', a[-1])[1]) - 22
    p = b / 'hdmi'
    p.write_text(re.sub(r'mActiveRoutingPath: 0x[0-9a-f]+', f'mActiveRoutingPath: 0x{port}000', p.read_text()))
    (b / 'activity').write_text('mResumedActivity: com.xiaomi.mitv.tvplayer/.ExternalSourceActivity\n')
    (b / 'tv_input').write_text(
        'User Ids (Current user: 0):\n  0\nUserState (0):\n'
        '  sessionStateMap: ITvInputSession -> SessionState\n'
        '    android.os.Binder@abcd: com.android.server.tv.TvInputManagerService$SessionState@1234\n'
        f'      inputId: com.mediatek.tvinput/.hdmi.HDMIInputService/HW{port + 3}\n'
        '  mainSessionToken: android.os.Binder@abcd\n')
""")
        (self.base / "dumpsys").chmod(0o755)
        (self.base / "service").chmod(0o755)

    def put(self, name, text):
        (self.base / name).write_text(text)

    def run_bridge(self, body):
        prelude = f"""
. {shlex.quote(str(ROOT / 'tv-side/cec-bridge.sh'))}
BASE="$CASE_DIR"
LOG="$BASE/log"
SERVICE="$BASE/service"
DUMPSYS="$BASE/dumpsys"
HB="$BASE/heartbeat"
PIDF="$BASE/daemon.pid"
LOCK="$BASE/lock"
sleep() {{ :; }}
"""
        result = subprocess.run(SHELL + ["-c", prelude + body], text=True,
                                capture_output=True, timeout=15,
                                env={**os.environ, "CEC_BRIDGE_LIBRARY": "1", "CASE_DIR": str(self.base)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def calls(self):
        p = self.base / "calls"
        return p.read_text() if p.exists() else ""

    def log(self):
        p = self.base / "log"
        return p.read_text() if p.exists() else ""

    def append(self, text):
        return "printf '%s' " + shlex.quote(text) + ' >> "$BASE/hdmi"\n'

    def test_ps5_off_then_appletv_switches_while_awake(self):
        self.run_bridge('bridge_tick\n' + self.append(event(1, "Report Power Status", 4))
                        + self.append(event(2, "Image View On") + event(3))
                        + 'bridge_tick; wait "$ACTION_PID"; bridge_tick\n')
        self.assertIn("--ei input 23", self.calls())
        self.assertNotIn("call power", self.calls())
        self.assertEqual(self.calls().count("call TvService"), 1)
        self.assertIn("input ok src=8 path=0x1000", self.log())

    def test_asleep_still_wakes_before_selecting_input(self):
        self.put("power", "mWakefulness=Asleep\nmLastSleepTime=100\n")
        self.run_bridge('activate_source 8 Asleep')
        calls = self.calls()
        self.assertIn("call power 9 i64 101", calls)
        self.assertLess(calls.index("call power"), calls.index("call TvService"))

    def test_path_alone_does_not_skip_foreground_repair(self):
        self.put("hdmi", HDMI.replace("mActiveRoutingPath: 0x2000", "mActiveRoutingPath: 0x1000"))
        self.put("activity", "mResumedActivity: com.mitv.tvhome/.MainActivityUserMode\n")
        self.run_bridge('activate_source 8 Awake')
        self.assertIn("--ei input 23", self.calls())

    def test_matching_path_and_foreground_still_selects_actual_input(self):
        # Active Source may change the path while the same Activity still shows PS5.
        self.put("hdmi", HDMI.replace("mActiveRoutingPath: 0x2000", "mActiveRoutingPath: 0x1000"))
        self.run_bridge('activate_source 8 Awake')
        self.assertEqual(self.calls().count("call TvService"), 1)
        self.assertIn("--ei input 23", self.calls())
        self.assertNotIn("call power", self.calls())

    def test_repeated_ps5_requests_after_worker_finishes_do_not_reselect(self):
        self.run_bridge('bridge_tick\n' + self.append(event(1, src=4))
                        + 'bridge_tick; wait "$ACTION_PID"\n' + self.append(event(10, src=4))
                        + 'bridge_tick; wait "$ACTION_PID"\n')
        self.assertEqual(self.calls(), "")
        self.assertEqual(self.log().count("skip reselect (TIF main + foreground)"), 2)

    def test_wake_selects_once_then_same_source_reannouncement_is_ignored(self):
        self.put("power", "mWakefulness=Asleep\nmLastSleepTime=100\n")
        self.run_bridge('bridge_tick\n' + self.append(event(1, src=4))
                        + 'bridge_tick; wait "$ACTION_PID"\n' + self.append(event(10, src=4))
                        + 'bridge_tick; wait "$ACTION_PID"\n')
        self.assertEqual(self.calls().count("call TvService"), 1)
        self.assertIn("call power", self.calls())
        self.assertIn("skip reselect", self.log())

    def test_same_tif_input_but_home_in_foreground_still_selects(self):
        self.put("activity", "mResumedActivity: io.github.blindingend.mitvhub.launcher/.MainActivity\n")
        self.run_bridge('activate_source 4 Awake')
        self.assertIn("--ei input 24", self.calls())
        self.assertNotIn("skip reselect", self.log())

    def test_cec_route_and_foreground_match_but_different_tif_never_skip(self):
        self.put("tv_input", tv_input(port=1))
        self.run_bridge('activate_source 4 Awake')
        self.assertIn("--ei input 24", self.calls())
        self.assertNotIn("skip reselect", self.log())

    def test_missing_or_untrusted_tif_falls_back_to_selecting(self):
        cases = ["Permission Denial: cannot dump tv_input\n", tv_input(port=None),
                 tv_input().replace("mainSessionToken: android.os.Binder@715b3a5",
                                    "mainSessionToken: android.os.Binder@ffff"),
                 tv_input().replace("/HW5", "/HDMI200004"),
                 tv_input().replace("  mainSessionToken:", "  missingMainToken:")]
        for data in cases:
            with self.subTest(data=data.splitlines()[-1]):
                self.put("tv_input", data)
                self.put("calls", "")
                self.run_bridge('activate_source 4 Awake')
                self.assertEqual(self.calls().count("call TvService"), 1)

    def test_tif_read_failure_falls_back_to_real_select(self):
        (self.base / "tv_input").unlink()
        self.run_bridge('activate_source 4 Awake')
        self.assertIn("--ei input 24", self.calls())
        self.assertNotIn("skip reselect", self.log())

    def test_sleep_during_tif_check_does_not_select(self):
        self.run_bridge('''
playback_input() { printf 'mWakefulness=Asleep\\n' > "$BASE/power"; echo 24; }
activate_source 4 Awake
''')
        self.assertEqual(self.calls(), "")
        self.assertIn("activate cancelled", self.log())

    def test_tif_main_token_not_first_session_or_connected_input(self):
        data = tv_input(port=1)
        data = data.replace("  mainSessionToken:",
                            "    android.os.Binder@bbbb: com.android.server.tv.TvInputManagerService$SessionState@9999\n"
                            "      inputId: com.mediatek.tvinput/.hdmi.HDMIInputService/HW5\n"
                            "  mainSessionToken:")
        self.put("tv_input", data)
        self.assertEqual(self.run_bridge('playback_input'), "23")
        self.run_bridge('activate_source 4 Awake')
        self.assertIn("--ei input 24", self.calls())

    def test_tif_proxy_tokens_ports_and_current_user(self):
        for port in range(1, 5):
            self.put("tv_input", tv_input(port, "android.os.BinderProxy@abcd"))
            self.assertEqual(self.run_bridge('playback_input'), str(port + 22))
        other_user = "UserState (10):" + tv_input(1, user=10).split("UserState (10):", 1)[1]
        data = tv_input(2).replace("TvInputHardwareManager Info:\n", "") + other_user
        self.put("tv_input", data)
        self.assertEqual(self.run_bridge('playback_input'), "24")

    def test_tif_duplicate_token_is_not_trusted(self):
        data = tv_input().replace("  mainSessionToken:",
                                 "    android.os.Binder@715b3a5: com.android.server.tv.TvInputManagerService$SessionState@ffff\n"
                                 "      inputId: com.mediatek.tvinput/.hdmi.HDMIInputService/HW4\n"
                                 "  mainSessionToken:")
        self.put("tv_input", data)
        self.run_bridge('activate_source 4 Awake')
        self.assertIn("--ei input 24", self.calls())
        self.assertNotIn("skip reselect", self.log())

    def test_routing_messages_do_not_trigger_selection(self):
        self.run_bridge('bridge_tick\n' + self.append(event(1, "Routing Change", 4)
                        + event(2, "Routing Information", 4) + event(3, "Report Power Status", 4))
                        + 'bridge_tick\n')
        self.assertEqual(self.calls(), "")

    def test_switch_uppercase_hex_address_and_dynamic_ports(self):
        self.put("hdmi", HDMI.replace("physical_address: 0x3000 port_id: 3", "physical_address: 0x4000 port_id: 4"))
        self.run_bridge('activate_source 11 Awake')
        self.assertIn("--ei input 26", self.calls())

    def test_unknown_device_never_defaults_to_appletv(self):
        self.run_bridge('activate_source 5 Awake')
        self.assertEqual(self.calls(), "")
        self.assertIn("no input mapping", self.log())

    def test_unknown_power_state_never_wakes_or_switches(self):
        self.put("power", "dumpsys failed\n")
        self.run_bridge('activate_source 8 Asleep; activate_source 8 Awake; bridge_tick')
        self.assertEqual(self.calls(), "")

    def test_missing_sleep_timestamp_does_not_send_invalid_wake(self):
        self.put("power", "mWakefulness=Asleep\n")
        self.run_bridge('activate_source 8 Asleep')
        self.assertEqual(self.calls(), "")

    def test_sleep_during_selection_stops_retries(self):
        self.run_bridge('''
sleep() { printf 'mWakefulness=Asleep\\n' > "$BASE/power"; }
touch "$BASE/no_effect"
activate_source 8 Awake
''')
        self.assertEqual(self.calls().count("call TvService"), 1)
        self.assertIn("activate cancelled", self.log())

    def test_failed_selection_has_bounded_retries(self):
        self.put("no_effect", "")
        self.run_bridge('activate_source 8 Awake')
        self.assertEqual(self.calls().count("call TvService"), 5)
        self.assertIn("input FAILED", self.log())

    def test_latest_source_wins_in_same_batch(self):
        data = event(1, src=4) + event(2, src=8) + event(3, src=11)
        self.assertEqual(self.run_bridge('latest_source ' + shlex.quote(data)), "11")

    def test_polling_sent_and_tv_messages_do_not_trigger(self):
        data = event(1, "Report Power Status", 4) + event(2, direction="S") + event(3, src=0) + event(4, src=15)
        self.assertEqual(self.run_bridge('latest_source ' + shlex.quote(data)), "")

    def test_every_registered_source_address_is_parsed_numerically(self):
        for address in range(1, 15):
            with self.subTest(address=address):
                self.assertEqual(self.run_bridge('latest_source ' + shlex.quote(event(1, src=address))), str(address))

    def test_startup_does_not_replay_old_requests(self):
        self.put("hdmi", HDMI + event(1))
        self.run_bridge('bridge_tick')
        self.assertEqual(self.calls(), "")
        self.assertNotIn("CEC request", self.log())

    def test_history_wrap_rebaselines_instead_of_replaying_tail(self):
        self.run_bridge('bridge_tick\nprintf "%s" ' + shlex.quote("CEC message history:\n" + event(2))
                        + ' > "$BASE/hdmi"\nbridge_tick\n')
        self.assertEqual(self.calls(), "")
        self.assertIn("cursor lost", self.log())

    def test_initially_empty_history_accepts_first_new_request(self):
        self.put("hdmi", HDMI.split("CEC message history:")[0] + "CEC message history:\n")
        self.run_bridge('bridge_tick\n' + self.append(event(1)) + 'bridge_tick; wait "$ACTION_PID"')
        self.assertIn("--ei input 23", self.calls())

    def test_read_failure_preserves_history_cursor(self):
        result = self.run_bridge('bridge_tick; saved="$SEEN"; hist_lines() { return 1; }; bridge_tick; [ "$saved" = "$SEEN" ] || exit 1; echo "$HISTORY_READY"')
        self.assertEqual(result, "1")

    def test_second_device_not_blocked_by_global_cooldown(self):
        self.run_bridge('bridge_tick\n' + self.append(event(1, src=4))
                        + 'bridge_tick; wait "$ACTION_PID"\n' + self.append(event(2))
                        + 'bridge_tick; wait "$ACTION_PID"')
        self.assertIn("CEC request src=4", self.log())
        self.assertIn("CEC request src=8", self.log())
        self.assertIn("--ei input 23", self.calls())

    def test_standby_cancelled_when_tv_wakes_before_deadline(self):
        self.run_bridge('''
NOW=100; date() { echo "$NOW"; }
bridge_tick
printf 'mWakefulness=Asleep\\n' > "$BASE/power"
bridge_tick
NOW=104
printf 'mWakefulness=Awake\\n' > "$BASE/power"
bridge_tick
''')
        self.assertEqual(self.calls(), "")

    def test_standby_sent_to_discovered_devices_including_switch(self):
        self.run_bridge('''
NOW=100; date() { echo "$NOW"; }
bridge_tick
printf 'mWakefulness=Asleep\\n' > "$BASE/power"
bridge_tick
NOW=104; bridge_tick
''')
        for address in (4, 8, 11):
            self.assertIn(f"call hdmi_control 30 i32 0 i32 {address}", self.calls())
        self.assertNotIn("i32 0 i32 0", self.calls())

    def test_explicit_wake_cancels_pending_standby(self):
        self.run_bridge('''
NOW=100; date() { echo "$NOW"; }
bridge_tick
printf 'mWakefulness=Asleep\\nmLastSleepTime=100\\n' > "$BASE/power"
bridge_tick
NOW=104
''' + self.append(event(1)) + 'bridge_tick; wait "$ACTION_PID"')
        self.assertNotIn("call hdmi_control", self.calls())
        self.assertIn("call power", self.calls())

    def test_new_request_cancels_previous_worker(self):
        self.run_bridge('''
activate_source() { echo "start $1" >> "$BASE/workers"; /bin/sleep 0.2; echo "done $1" >> "$BASE/workers"; }
request_source 4 Awake
/bin/sleep 0.05
request_source 8 Awake
wait "$ACTION_PID"
''')
        lines = (self.base / "workers").read_text()
        self.assertIn("start 4", lines)
        self.assertNotIn("done 4", lines)
        self.assertIn("done 8", lines)

    def test_same_source_burst_coalesces_running_worker(self):
        self.run_bridge('''
activate_source() { echo "$1" >> "$BASE/workers"; /bin/sleep 0.2; }
request_source 8 Asleep
first="$ACTION_PID"
request_source 8 Awake
[ "$first" = "$ACTION_PID" ] || exit 1
wait "$ACTION_PID"
''')
        self.assertEqual((self.base / "workers").read_text().strip(), "8")

    def test_sleep_transition_discards_old_requests_and_cancels_worker(self):
        self.run_bridge('''
bridge_tick
activate_source() { /bin/sleep 0.2; echo done >> "$BASE/workers"; }
request_source 4 Awake
printf 'mWakefulness=Asleep\\n' > "$BASE/power"
''' + self.append(event(1)) + '''
bridge_tick
[ -z "$ACTION_PID" ] || exit 1
''')
        self.assertFalse((self.base / "workers").exists())
        self.assertEqual(self.calls(), "")

    def test_disabled_marker_prevents_main_start(self):
        self.run_bridge('touch "$BASE/disabled"; main')
        self.assertFalse((self.base / "daemon.pid").exists())

    def test_shutdown_cleans_worker_pid_and_lock(self):
        self.run_bridge('''
activate_source() { /bin/sleep 0.2; echo done > "$BASE/worker-done"; }
bridge_tick() { request_source 8 Awake; touch "$BASE/disabled"; }
main
''')
        self.assertFalse((self.base / "worker-done").exists())
        self.assertFalse((self.base / "daemon.pid").exists())
        self.assertFalse((self.base / "lock").exists())

    def test_live_pid_prevents_duplicate_even_with_stale_heartbeat(self):
        self.run_bridge('''
mkdir "$LOCK"
echo $$ > "$PIDF"
bridge_tick() { echo duplicate > "$BASE/duplicate"; touch "$BASE/disabled"; }
main
''')
        self.assertFalse((self.base / "duplicate").exists())

    def test_standby_rechecks_power_between_devices(self):
        self.put("power", "mWakefulness=Asleep\n")
        self.put("service", '#!/bin/sh\necho "$*" >> "$CASE_DIR/calls"\nprintf "mWakefulness=Awake\\n" > "$CASE_DIR/power"\n')
        self.run_bridge('send_standby_all')
        self.assertEqual(self.calls().count("call hdmi_control"), 1)

    def test_device_discovery_can_lag_first_explicit_message(self):
        self.put("hdmi", HDMI.replace("logical_address: 0x08", "logical_address: 0x09"))
        self.run_bridge('''
sleep() { sed 's/logical_address: 0x09/logical_address: 0x08/' "$BASE/hdmi" > "$BASE/new"; mv "$BASE/new" "$BASE/hdmi"; }
activate_source 8 Awake
''')
        self.assertIn("--ei input 23", self.calls())

    def test_installer_targets_one_device_and_stages_before_rename(self):
        self.put("adb", '#!/bin/sh\nprintf "%s\\n" "$*" >> "$CASE_DIR/adb-calls"\n')
        (self.base / "adb").chmod(0o755)
        self.put("sleep", '#!/bin/sh\nexit 0\n')
        (self.base / "sleep").chmod(0o755)
        result = subprocess.run(["/bin/sh", str(ROOT / "tv-side/install.sh"), "192.0.2.1"],
                                env={**os.environ, "CASE_DIR": str(self.base), "PATH": f"{self.base}:{os.environ['PATH']}"},
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.base / "adb-calls").read_text().splitlines()
        self.assertEqual(calls[0], "connect 192.0.2.1:5555")
        self.assertTrue(all(c.startswith("-s 192.0.2.1:5555 ") for c in calls[1:]))
        check = next(i for i, c in enumerate(calls) if "shell sh -n" in c)
        rename = next(i for i, c in enumerate(calls) if "shell mv" in c)
        self.assertLess(check, rename)
        self.assertTrue(calls[check].endswith("cec-bridge.sh.new"))


if __name__ == "__main__":
    unittest.main()

