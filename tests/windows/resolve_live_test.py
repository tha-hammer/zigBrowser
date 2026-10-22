#!/usr/bin/env python3
"""WS0 live resolver regression — runs the PRODUCTION resolver against the real Win11 VM.

The hermetic selftest fakes SSH and PowerShell, which is exactly why the real uint32 CreateFile
bug (resolve_path.sh exited 1 for every path -> the gate DENYed everything) survived it. This
regression drives `gate.sh --allowed-path` with any ambient `ZB_RESOLVE_CMD` **scrubbed** (RoseCat
6726), so the default resolver (resolve_path.sh) runs real `ssh` + `GetFinalPathNameByHandle` on the
VM and a stray override can never stand in for it:

The resolver FAILS CLOSED on ANY reparse point in the path (bead zigBrowser-q92, RoseCat security
block of 60f0d5e): ALLOWing a junction would reopen a swap/chain TOCTOU — the gate authorizes the
resolved NAME, not a pinned handle, so a junction ALLOWed now could be repointed outside before the
name is used. In-root junctions are not needed for launch, so every junction DENYs and the swap case
is moot (no junction is ever ALLOWed). The cases below cover a plain path, an escaping final-component
junction, an in-root junction, a descendant THROUGH an in-root junction, and a two-junction chain; each
junction setup is PROVEN first (it exists AND its reparse target is read), so a DENY can never be a
vacuous fail-closed on a path that was never created (RoseCat 6726):

  * an existing in-root NON-reparse path must ALLOW  (real dir / real sub-path)
  * an escaping junction (-> C:\\Windows) must DENY            (final-component reparse)
  * a legitimate in-root junction (-> {root}\\live) must DENY  (reparse; fail-closed, not resolved)
  * a descendant through an in-root junction (junction\\sub) must DENY   (mid-path reparse)
  * a two-junction chain (-> the in-root junction) must DENY            (reparse)
  * a forced reparse on an ORDINARY component must DENY  (ZB_RESOLVE_SELFTEST_FAULT=reparse:<seg>)
  * a forced INVALID (unreadable/transient) component must DENY  (…=invalid:<seg>)
  * a genuinely MISSING component must DENY             (real INVALID_FILE_ATTRIBUTES)

MUTANT ISOLATION: the static junction rows (2-5) also trip CreateFile (ERROR_CANT_RESOLVE_FILENAME on
this build), so removing the walk still DENYs them — they do not prove the walk is causal. The forced
rows (6-7) fault an ORDINARY directory that CreateFile resolves fine, so the DENY can only come from
the walk's own checks:
  - dropping the reparse test `if(($a -band $RP) -ne 0){exit 3}` flips row 6 (forced reparse) to ALLOW;
  - reintroducing the old exclusion `if($a -ne $INV -and ($a -band $RP) -ne 0){exit 3}` (the bug: INVALID
    silently skipped) flips row 7 (forced INVALID on an existing leaf) to ALLOW. Note INVALID_FILE_
    ATTRIBUTES is 0xFFFFFFFF, which also has the reparse bit, so the explicit `$a -eq $INV` guard must
    fire FIRST and the exclusion form is the real regression; simply deleting the explicit guard would
    still DENY via the reparse bit.
These two mutants are the causal proof.

NOTE: `--allowed-path` is a CHECK-TIME diagnostic, not a time-of-use authorization boundary (its ALLOW
must never be reused to open a path later; see gate.sh and the Windows plan). These rows verify the
check's verdict at the instant of the check only.

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


def _gate_verdict(path, extra_env=None):
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
    if extra_env:
        env.update(extra_env)
    p = subprocess.run(["bash", str(GATE), "--allowed-path", path], capture_output=True, text=True,
                       timeout=60, env=env)
    return (p.stdout or "").strip(), p


def _make_junction(link, target):
    """Create link -> target as a directory junction and PROVE it took: the link must be a reparse
    point whose target is `target` (so a later DENY is never a vacuous fail-closed on a missing path,
    RoseCat 6726). Returns (ok, detail)."""
    mk = _remote(rf'cmd /c "rmdir {link} 2>nul & mklink /J {link} {target}"')
    rb = _remote(rf"fsutil reparsepoint query {link}")
    ok = rb.returncode == 0 and target.upper() in rb.stdout.upper()
    detail = (f"{link!r} -> {target!r}: mklink rc={mk.returncode}, readback rc={rb.returncode}\n"
              f"--- mklink ---\n{mk.stdout}{mk.stderr}\n--- readback ---\n{rb.stdout}{rb.stderr}")
    return ok, detail


def main():
    host = os.environ.get("ZB_WIN11_HOST")
    user = os.environ.get("ZB_GUEST_USER")
    if not host or not user:
        print("SKIP: ZB_WIN11_HOST / ZB_GUEST_USER not set (live resolver regression needs the Win11 VM)")
        return 0

    root = rf"C:\Users\{user}\zb"
    live = rf"{root}\live"                 # a real in-root dir
    live_sub = rf"{live}\sub"              # a real in-root sub-path
    escape = rf"{root}\zb_live_linkout"    # junction -> C:\Windows  (final-component escape)
    inj = rf"{root}\zb_live_linkin"        # junction -> {root}\live  (legit in-root target)
    chain = rf"{root}\zb_live_chain"       # junction -> {inj}        (junction to a junction)
    asserts = 0

    def expect(path, want, label, extra_env=None):
        out, p = _gate_verdict(path, extra_env=extra_env)
        if out != want:
            print(f"FAIL [{label}]: resolver on {path!r} => {out!r} (want {want})\n--- gate stderr ---\n{p.stderr}")
            return False
        return True

    try:
        _remote(rf'cmd /c "mkdir {live_sub} 2>nul"')   # creates {root}\live and {root}\live\sub

        # (1) a real in-root path (no reparse anywhere) -> ALLOW.
        if not expect(live_sub, "ALLOW", "in-root real sub-path"):
            return 1
        asserts += 1

        # (2) escaping junction (final component) -> DENY. Setup proven (target is C:\Windows).
        ok, d = _make_junction(escape, r"C:\Windows")
        if not ok:
            print(f"FAIL: escaping-junction setup did not take\n{d}")
            return 1
        if not expect(escape, "DENY", "escaping junction (final component)"):
            return 1
        asserts += 1

        # (3) legitimate IN-ROOT junction -> DENY. In-root junctions are not supported for launch and
        # ALLOWing one would reopen a swap TOCTOU (gate authorizes the name, not a pinned handle), so the
        # resolver fails closed on ANY reparse point. Setup proven (target is inside the root).
        ok, d = _make_junction(inj, live)
        if not ok:
            print(f"FAIL: in-root-junction setup did not take\n{d}")
            return 1
        if not expect(inj, "DENY", "in-root junction"):
            return 1
        asserts += 1

        # (4) descendant THROUGH an in-root junction ({inj}\sub) -> DENY (mid-path reparse component).
        if not expect(rf"{inj}\sub", "DENY", "descendant through in-root junction"):
            return 1
        asserts += 1

        # (5) two-junction chain ({chain} -> {inj}) -> DENY (reparse). Setup proven.
        ok, d = _make_junction(chain, inj)
        if not ok:
            print(f"FAIL: chain-junction setup did not take\n{d}")
            return 1
        if not expect(chain, "DENY", "two-junction chain"):
            return 1
        asserts += 1

        # Causal / mutant-isolating rows (ZB_RESOLVE_SELFTEST_FAULT, DENY-only). The static junction rows
        # above also trip CreateFile (ERROR_CANT_RESOLVE_FILENAME on this build), so they do not prove
        # WHICH check denied. These force a fault on an ORDINARY directory component — CreateFile would
        # resolve it fine — so the DENY can only come from the walk's own check, and a mutant that drops
        # that check flips the row to ALLOW:

        # (6) a reparse point anywhere in the path -> DENY. Forced on the real {live} component; proves the
        # reparse-walk check (drop `($a -band $RP)` and this row ALLOWs the ordinary path).
        if not expect(live_sub, "DENY", "forced mid-path reparse (isolates reparse check)",
                      extra_env={"ZB_RESOLVE_SELFTEST_FAULT": "reparse:live"}):
            return 1
        asserts += 1

        # (7) an UNREADABLE component (GetFileAttributesW==INVALID_FILE_ATTRIBUTES) -> DENY. Forced on the
        # EXISTING leaf; proves INVALID -> DENY. Causal mutant: the old exclusion form
        # `if($a -ne $INV -and ($a -band $RP))` skips INVALID, so this row ALLOWs (CreateFile resolves the
        # real leaf). Stands in for the unreadable/transient/raced-away cases, all INVALID at the walk.
        if not expect(live_sub, "DENY", "forced unreadable component (isolates INVALID check)",
                      extra_env={"ZB_RESOLVE_SELFTEST_FAULT": "invalid:sub"}):
            return 1
        asserts += 1

        # (8) a genuinely MISSING component -> DENY (real INVALID, no seam): a non-existent leaf under root.
        if not expect(rf"{live}\does-not-exist-{os.getpid()}", "DENY", "missing component (real INVALID)"):
            return 1
        asserts += 1
    finally:
        _remote(rf'cmd /c "rmdir {chain} 2>nul & rmdir {escape} 2>nul & rmdir {inj} 2>nul & '
                rf'rmdir /s /q {live} 2>nul"')

    print(f"PASS live resolver regression ASSERTS {asserts}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
