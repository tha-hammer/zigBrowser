#!/usr/bin/env bash
# The ONE MS6 hard-gate harness (plan rev 18.1; BlueBeaver 7123, 7127; JadeBeacon 7125, 7130), run BEFORE
# seatbelt_ready: on both Macs it stages the pinned python.org runtime, the pinned dependency tree and the pinned CLI
# into a per-run nonce dir, then runs tests/mac/hard_gate/hard_gate_driver.py under the STAGED interpreter over every
# tests/mac/hard_gate/case_*.py (MS6.3's real-CLI fd-3 case, MS6.6 (B)'s R1 chain). It never goes through the browser
# and never arms ms5_setup_e2e.sh; the app stays fail closed.
#
# NOT ARMED (exit 3, before any network) until the MS5 dependency and CLI layout decision pins the tree it stages:
# packaging/macos/agent_runtime_pins.json. A missing pins file, or staging that is not written yet, is never a PASS.
# usage: tests/mac/ms6_hard_gate.sh [commit]
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
PINS=packaging/macos/agent_runtime_pins.json
if [ ! -f "$PINS" ]; then
  echo "NOT ARMED: the pinned dependency tree is not staged ($PINS is absent; the MS5 decision is pending)" >&2
  exit 3
fi
# The staging of the pinned tree is written with the MS5 decision; until then even a pins file is not enough.
echo "NOT ARMED: $PINS exists, but the harness's staging of that tree is not written yet" >&2
exit 3
