#!/usr/bin/env python3
"""Real-binary closure for the MS6.5 VM-containment stub (RoseCat 7199 #2): the BUILT binary, invoked as
`--agent-setup`, must FAIL CLOSED before any setup child or probe starts when
`ZIGBROWSER_AGENT_VM_CONTAINMENT` is `on` or malformed, and must let the VM gate PASS when it is unset. The
gate is the first statement of runAgentSetup, so a nonzero exit with the refusal proves nothing downstream ran.

Host-neutral: the gate is the same code on Linux and macOS, so this runs anywhere the binary builds. For MS6
acceptance it is run on both Macs too (it supplements, not replaces, the two-arch run).

  python3 tests/e2e/mac_vm_containment_e2e.py --binary zig-out/bin/zigBrowser
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys

VM = "ZIGBROWSER_AGENT_VM_CONTAINMENT"
NOT_AVAIL = "VM containment is not available yet"
INVALID = "must be 'on' or 'off'"


def run(binary: str, value: str | None) -> tuple[int, str]:
    # Drop every inherited agent switch AND HOME/XDG so the unset control stops at the next gate (the home
    # check), never doing real setup work.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("ZIGBROWSER_AGENT_") and k not in ("HOME", "XDG_DATA_HOME")}
    if value is not None:
        env[VM] = value
    p = subprocess.run([binary, "--agent-setup"], env=env, capture_output=True, text=True, timeout=60)
    return p.returncode, (p.stderr or "") + (p.stdout or "")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default="zig-out/bin/zigBrowser")
    binary = os.path.abspath(ap.parse_args().binary)
    if not os.access(binary, os.X_OK):
        print(f"FAIL mac-vm-containment-e2e: binary not executable: {binary}")
        return 1

    ok = True
    # ON -> fail closed with the not-available refusal, before any setup child.
    rc, out = run(binary, "on")
    if rc == 0 or NOT_AVAIL not in out:
        ok = False; print(f"FAIL on: rc={rc} out={out!r}")
    else:
        print("ok on: nonzero + not-available refusal")
    # malformed -> fail closed with the invalid-value refusal (no silent fallback to off).
    rc, out = run(binary, "onn")
    if rc == 0 or INVALID not in out:
        ok = False; print(f"FAIL malformed: rc={rc} out={out!r}")
    else:
        print("ok malformed: nonzero + invalid-value refusal")
    # unset control -> the VM gate must NOT fire; it proceeds past (whatever the next gate does is not ours).
    rc, out = run(binary, None)
    if NOT_AVAIL in out or INVALID in out:
        ok = False; print(f"FAIL unset: the VM gate fired when the setting was off: rc={rc} out={out!r}")
    else:
        print(f"ok unset: VM gate passed (rc={rc})")

    print("PASS mac-vm-containment-e2e" if ok else "FAIL mac-vm-containment-e2e")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
