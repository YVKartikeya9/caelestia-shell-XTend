#!/usr/bin/env python3
"""Checks that the installer and the hotspot helper accept the same names and passwords.

    python3 tests/test_hotspot_helper.py

The helper (system/caelestia-hotspot) refuses values create_ap's config reader
would mangle; the installer must refuse the same ones when asking for them.
"""

import importlib.util
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HELPER = REPO / "system/caelestia-hotspot"

spec = importlib.util.spec_from_file_location("install", REPO / "install.py")
install = importlib.util.module_from_spec(spec)
spec.loader.exec_module(install)

# The helper's valid() function, run on its own
valid_fn = HELPER.read_text().split("valid() {", 1)[1].split("\n}\n", 1)[0]
BASH = 'valid() {' + valid_fn + '\n}\nvalid "$1" "$2" "$3"'

CASES = [
    ("mypassword", True), ("pass word ok", True), ("x" * 63, True), ("p@$$w0rd!", True),
    ("short", False), ("x" * 64, False), (" leading", False), ("trailing ", False),
    ("back\\slash", False), ("tab\there", False), ("", False),
]

fails = 0
for value, expect in CASES:
    helper = subprocess.run(["bash", "-c", BASH, "_", value, "8", "63"]).returncode == 0
    inst = install.hotspot_value_ok(value, 8, 63)
    if not (helper == inst == expect):
        fails += 1
        print(f"FAIL {value!r}: helper={helper} installer={inst} expected={expect}")
print("OK" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
