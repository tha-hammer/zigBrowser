#!/usr/bin/env python3
"""WS0 live resolver regression — runs the PRODUCTION resolver against the real Win11 VM.

The hermetic selftest fakes SSH and PowerShell, which is exactly why the real uint32 CreateFile
bug (resolve_path.sh exited 1 for every path -> the gate DENYed everything) survived it. This
regression drives `gate.sh --allowed-path` with any ambient `ZB_RESOLVE_CMD` **scrubbed** (RoseCat
6726), so the default resolver (resolve_path.sh) runs real `ssh` + `GetFinalPathNameByHandle` on the
VM and a stray override can never stand in for it:

  * an existing in-root path must ALLOW   (OLD RED: the uint32 bug made this DENY; NEW GREEN: ALLOW)
  * an escaping junction must DENY        (resolves to C:\\Windows). Its setup is PROVEN first — the
    junction must exist and its reparse target must actually point at C:\\Windows — so a DENY can
    never be a vacuous fail-closed on a path that was never created (RoseCat 6726).
  * a legitimate IN-ROOT junction must ALLOW (bead zigBrowser-q92). OLD RED: CreateFile-follow returns
    ERROR_CANT_RESOLVE_FILENAME for any directory junction on this build, so resolve_path.sh exited 3
    and the gate DENYed even an in-root junction. NEW GREEN: the resolver reads the junction's reparse
    target (FSCTL_GET_REPARSE_POINT) and resolves THAT, so an in-root target ALLOWs while an escape
    still DENYs (case above). Its setup is proven first (the reparse target must point inside the root).

Skips cleanly when the VM is not configured.

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
    return subprocess.run(_ssh_base() + [cmd], capture_output=True, text=True, timeout=40)


def _gate_verdict(path):
    # gate.sh inherits ZB_WIN11_HOST / ZB_GUEST_USER, so its DEFAULT resolver (resolve_path.sh)
    # resolves on the real VM. Scrub any ambient ZB_RESOLVE_CMD so a stray override can never stand
    # in for the production resolver (RoseCat 6726). resolve_path.sh's ssh defaults differ from this
    # test's own (port 22 vs 2222, a relative known_hosts), so pin the SAME connection the setup used,
    # otherwise the resolver's ssh fails closed (rc 255) and the regression never reaches it.
    env = {k: v for k, v in os.environ.items() if k != "ZB_RESOLVE_CMD"}
    env.setdefault("ZB_WIN11_PORT", os.environ.get("ZB_WIN11_PORT", "2222"))
    env.setdefault("ZB_WIN_KEY", os.environ.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key"))
    env.setdefault("ZB_WIN_KNOWN_HOSTS",
                   os.environ.get("ZB_WIN_KNOWN_HOSTS", "/home/maceo/vms/win11-m8/known_hosts"))
    p = subprocess.run(["bash", str(GATE), "--allowed-path", path], capture_output=True, text=True,
                       timeout=60, env=env)
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
    in_junction = rf"{root}\zb_live_linkin"   # an in-root junction -> {root}\live (bead zigBrowser-q92)
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

        # (2) escaping junction (-> C:\Windows) must DENY. PROVE the setup first, so a DENY can never
        # be a vacuous fail-closed on a missing path (RoseCat 6726): the junction must exist AND its
        # reparse target must actually point OUTSIDE the root, at C:\Windows.
        mk = _remote(rf'cmd /c "rmdir {junction} 2>nul & mklink /J {junction} C:\Windows"')
        rb = _remote(rf"fsutil reparsepoint query {junction}")
        if rb.returncode != 0 or "C:\\WINDOWS" not in rb.stdout.upper():
            print(f"FAIL: escaping-junction setup did not take — {junction!r} is not a reparse point to "
                  f"C:\\Windows (mklink rc={mk.returncode}, readback rc={rb.returncode}).\n"
                  f"--- mklink ---\n{mk.stdout}{mk.stderr}\n--- readback ---\n{rb.stdout}{rb.stderr}")
            return 1
        out, p = _gate_verdict(junction + r"\System32")
        if out != "DENY":
            print(f"FAIL: production resolver on escaping junction {junction!r} => {out!r} (want DENY)\n"
                  f"--- gate stderr ---\n{p.stderr}")
            return 1
        asserts += 1

        # (3) legitimate IN-ROOT junction (-> {root}\live) must ALLOW (bead zigBrowser-q92). PROVE the
        # setup first: the junction must exist AND its reparse target must point INSIDE the root — so an
        # ALLOW is real, not a vacuous pass on a missing path. OLD RED: the resolver failed closed (exit
        # 3) on any junction, so the gate DENYed this in-root junction.
        mk = _remote(rf'cmd /c "rmdir {in_junction} 2>nul & mklink /J {in_junction} {in_root}"')
        rb = _remote(rf"fsutil reparsepoint query {in_junction}")
        want = rf"{root}\live".upper()
        if rb.returncode != 0 or want not in rb.stdout.upper():
            print(f"FAIL: in-root-junction setup did not take — {in_junction!r} is not a reparse point to "
                  f"{in_root!r} (mklink rc={mk.returncode}, readback rc={rb.returncode}).\n"
                  f"--- mklink ---\n{mk.stdout}{mk.stderr}\n--- readback ---\n{rb.stdout}{rb.stderr}")
            return 1
        out, p = _gate_verdict(in_junction)
        if out != "ALLOW":
            print(f"FAIL: production resolver on in-root junction {in_junction!r} => {out!r} (want ALLOW)\n"
                  f"--- gate stderr ---\n{p.stderr}")
            return 1
        asserts += 1
    finally:
        _remote(rf'cmd /c "rmdir {junction} 2>nul & rmdir {in_junction} 2>nul & rmdir %USERPROFILE%\zb\live 2>nul"')

    print(f"PASS live resolver regression ASSERTS {asserts}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
