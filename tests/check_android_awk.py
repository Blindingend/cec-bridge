"""Explicit opt-in Android awk compatibility check; no files or playback changes.

Run: python3 -B tests/check_android_awk.py --serial TV_IP:5555
Optionally pass --fixture PATH for a locally saved TIF dump and --expected-input N.
The regular unittest suite never invokes this device check.
"""
import argparse
from pathlib import Path
import shlex
import subprocess

from test_bridge import ROOT, tv_input


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--expected-input", type=int, choices=range(23, 27))
    args = parser.parse_args()
    if (args.fixture is None) != (args.expected_input is None):
        parser.error("--fixture and --expected-input must be supplied together")

    source = (ROOT / "tv-side/cec-bridge.sh").read_text()
    function = source.split("playback_input() {", 1)[1].split("\nalready_showing_input()", 1)[0]
    program = function.split("| awk '\n", 1)[1].rsplit("'", 1)[0]
    cases = [(f"port-{p}", tv_input(p), str(p + 22)) for p in range(1, 5)]
    cases += [
        ("proxy", tv_input(1, "android.os.BinderProxy@abcd"), "23"),
        ("empty", "", ""),
        ("no-main", tv_input(None), ""),
        ("denied", "Permission Denial\n", ""),
        ("cec-child", tv_input().replace("/HW5", "/HDMI200004"), ""),
        ("unknown-token", tv_input().replace(
            "mainSessionToken: android.os.Binder@715b3a5",
            "mainSessionToken: android.os.Binder@abcd"), ""),
    ]
    if args.fixture:
        cases.append(("saved-device-dump", args.fixture.read_text(), str(args.expected_input)))
    for name, data, expected in cases:
        # Quote both the fixed parser and fixture as data. printf runs remotely to
        # supply EOF reliably: adb exec-out stdin does not always propagate EOF.
        command = "printf %s " + shlex.quote(data) + " | awk " + shlex.quote(program)
        result = subprocess.run(["adb", "-s", args.serial, "shell", command],
                                text=True, capture_output=True, timeout=15)
        if (result.returncode != (0 if expected else 1)
                or result.stdout.strip() != expected or result.stderr):
            raise SystemExit(f"FAIL {name}: code={result.returncode}, "
                             f"stdout={result.stdout!r}, stderr={result.stderr!r}")
        print(f"PASS {name}")
    print(f"{len(cases)} Android awk cases passed")


if __name__ == "__main__":
    main()
