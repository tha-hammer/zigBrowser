#!/usr/bin/env python3
"""WS0 live resolver regression — runs the PRODUCTION resolver against the real Win11 VM.

The hermetic selftest fakes SSH and PowerShell, which is exactly why the real uint32 CreateFile
bug (resolve_path.sh exited 1 for every path -> the gate DENYed everything) survived it. This
regression drives `gate.sh --allowed-path` with NO ZB_RESOLVE_CMD override, so the default resolver
(resolve_path.sh) runs real `ssh` + `GetFinalPathNameByHandle` on the VM:

  * an existing in-root path must ALLOW   (OLD RED: the uint32 bug made this DENY; NEW GREEN: ALLOW)
  * an escaping junction must DENY        (resolves to C:\\Windows, or fails closed)

A legitimate in-root junction resolving to ALLOW is a tracked availability refinement (bead
zigBrowser-q92), not asserted here. Skips cleanly when the VM is not configured.

Run:  ZB_WIN11_HOST=127.0.0.1 ZB_GUEST_USER=zbtext [ZB_WIN11_PORT=2222 ...] python3 -I tests/windows/resolve_live_test.py
"""
import os
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
GATE = REPO / "tests" / "windows" / "gate.sh"


def _ssh_base():
    return [
        "ssh", "-p", os.environ.get("ZB_WIN11_PORT", "2222"),
        "-i", os.environ.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key"),
        "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
        "-o", f"UserKnownHostsFile={os.environ.get('ZB_WIN_KNOWN_HOSTS', '/home/maceo/vms/win11-m8/known_hosts')}",
        "-o", "ConnectTimeout=15", "-o", "ConnectionAttempts=3",
        f"{os.environ['ZB_GUEST_USER']}@{os.environ['ZB_WIN11_HOST']}",
    ]


def _remote(cmd):
    subprocess.run(_ssh_base() + [cmd], capture_output=True, text=True, timeout=40)


def _gate_verdict(path):
    # Inherits ZB_WIN11_HOST / ZB_GUEST_USER / ZB_WIN_KEY from the environment, so gate.sh's
    # default resolver (resolve_path.sh) resolves on the real VM. No ZB_RESOLVE_CMD override.
    p = subprocess.run(["bash", str(GATE), "--allowed-path", path], capture_output=True, text=True, timeout=60)
    return (p.stdout or "").strip(), p


def main():
    host = os.environ.get("ZB_WIN11_HOST")
    user = os.environ.get("ZB_GUEST_USER")
    if not host or not user:
        print("SKIP: ZB_WIN11_HOST / ZB_GUEST_USER not set (live resolver regression needs the Win11 VM)")
        return 0

    root = rf"C:\Users\{user}\zb"
    in_root = rf"{root}\live"           # a real STRICT sub-path (the root itself is DENYed by design)
    junction = rf"{root}\zb_live_linkout"
    asserts = 0

    try:
        # (1) existing in-root sub-path -> ALLOW. Old red: the uint32 bug made the resolver fail => DENY.
        _remote(r'cmd /c "if not exist %USERPROFILE%\zb\live mkdir %USERPROFILE%\zb\live"')
        out, p = _gate_verdict(in_root)
        if out != "ALLOW":
            print(f"FAIL: production resolver on in-root {in_root!r} => {out!r} (want ALLOW)\n"
                  f"--- gate stderr ---\n{p.stderr}")
            return 1
        asserts += 1

        # (2) escaping junction (-> C:\Windows) must DENY (resolved-escape, or fail-closed).
        _remote(rf'cmd /c "rmdir {junction} 2>nul & mklink /J {junction} C:\Windows"')
        out, p = _gate_verdict(junction + r"\System32")
        if out != "DENY":
            print(f"FAIL: production resolver on escaping junction {junction!r} => {out!r} (want DENY)\n"
                  f"--- gate stderr ---\n{p.stderr}")
            return 1
        asserts += 1
    finally:
        _remote(rf'cmd /c "rmdir {junction} 2>nul & rmdir %USERPROFILE%\zb\live 2>nul"')

    print(f"PASS live resolver regression ASSERTS {asserts}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
