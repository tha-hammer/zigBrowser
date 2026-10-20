#!/usr/bin/env python3
"""MS3.1 RED (unregistered) — a relative --profile-dir binds to the STARTUP CWD before the digest (RoseCat 6625).

The profile identity is a digest of the normalized path. A relative --profile-dir (the CLI deliberately
accepts `rel/profile`, cli.zig) must be resolved against the process's startup working directory BEFORE the
digest, exactly as Linux resolves it to a concrete directory. Otherwise two launches from different CWDs with
the same spelling share one managed WebKit store (an isolation leak), and an absolute spelling and its
equivalent relative spelling map to two different stores.

Two cases, both red on a build that standardizes the raw relative spelling without binding it to the CWD:

  ISOLATION  same relative spelling `relprof`, launched from CWD_A then CWD_B -> different stores
             (the cookie set under CWD_A is ABSENT under CWD_B). Buggy build: same string -> same store ->
             cookie present -> red.
  SHARE      an absolute spelling CWD_A/relprof shares the store of the relative `relprof` launched from
             CWD_A (the cookie IS present). Buggy build: abs string != rel string -> different store ->
             cookie absent -> red.

The hosts are macOS 15, so this exercises the dataStoreForIdentifier path. Fixed cookie name, unique value
per run; the profile CWDs are fresh temp dirs so the test does not collide with other runs.
"""
import argparse
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from automation_core_test import RpcClient, _read_lines  # noqa: E402
from mac_ms2a_routed_test import stop_browser_macos, _install_signal_cleanup  # noqa: E402

SKIP_EXIT = 77
REL = "relprof"  # a RELATIVE --profile-dir spelling


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=25.0)
    args = ap.parse_args()
    browser = Path(args.browser).resolve()  # absolute so a child CWD change can't lose the binary
    if not browser.is_file():
        eprint(f"SKIP: binary not found: {browser}")
        return SKIP_EXIT

    proc_holder: list[subprocess.Popen] = []
    _install_signal_cleanup(lambda: proc_holder[0] if proc_holder else None)
    failures: list[str] = []
    uniq = str(int(time.time() * 1000))
    expires = int(time.time()) + 3600  # a PERSISTENT cookie; session cookies never hit disk
    FLUSH = 1.5

    def run(cwd, profile, fn):
        """Launch with CWD=cwd and --profile-dir <profile>, run fn(rpc), return fn's value."""
        tmp = tempfile.mkdtemp(prefix="zb-ms3cwd-sock-")
        sp = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(sp)
        p = subprocess.Popen(
            [str(browser), "about:blank", "--automation-api", "--profile-dir", profile],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
            start_new_session=True, cwd=cwd,
        )
        proc_holder[:] = [p]
        o, e = [], []
        for stream, buf in ((p.stdout, o), (p.stderr, e)):
            threading.Thread(target=_read_lines, args=(stream, buf), daemon=True).start()
        rpc = None
        try:
            rpc = RpcClient(sp, args.timeout_sec)
            rpc.call("page.url", {"timeout_ms": 10000})
            return fn(rpc)
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(p)

    def cookies(rpc):
        return (rpc.raw("cookies.getAll", {}).get("result") or {}).get("cookies") or []

    def value_of(cks, name):
        c = next((c for c in cks if c.get("name") == name), None)
        return c.get("value") if c else None

    with tempfile.TemporaryDirectory(prefix="zb-ms3cwd-A-") as cwd_a, \
         tempfile.TemporaryDirectory(prefix="zb-ms3cwd-B-") as cwd_b:
        # The absolute spelling equivalent to REL launched from cwd_a. getcwd(3) canonicalizes symlinks
        # (on macOS /var -> /private/var), and the shim binds a relative --profile-dir to that canonical
        # startup CWD, so the equivalent absolute spelling is the realpath of cwd_a joined with REL.
        abs_a = os.path.join(os.path.realpath(cwd_a), REL)
        try:
            v = "cwd-" + uniq
            # seed the cookie into the store for (CWD_A, relative "relprof").
            run(cwd_a, REL, lambda rpc: (rpc.raw("cookies.set", {"name": "zbcwd", "value": v, "domain": "127.0.0.1", "path": "/", "expires": expires}), time.sleep(FLUSH)))

            # sanity: same CWD + same relative spelling sees it (same store) — holds on buggy and fixed builds.
            same = run(cwd_a, REL, lambda rpc: value_of(cookies(rpc), "zbcwd"))
            if same != v:
                failures.append(f"sanity: same CWD + same relative spelling did not persist the cookie (got {same!r})")

            # ISOLATION: same relative spelling from a DIFFERENT CWD must be a different store (cookie absent).
            other = run(cwd_b, REL, lambda rpc: value_of(cookies(rpc), "zbcwd"))
            if other == v:
                failures.append(f"ISOLATION LEAK: relative {REL!r} from a different CWD saw CWD_A's cookie (got {other!r}) — the relative path was not bound to the startup CWD")

            # SHARE: the absolute spelling equivalent to CWD_A/relprof must share CWD_A's store (cookie present).
            shared = run(cwd_a, abs_a, lambda rpc: value_of(cookies(rpc), "zbcwd"))
            if shared != v:
                failures.append(f"SHARE BROKEN: absolute {abs_a!r} did not see the cookie set via the equivalent relative {REL!r} from the same CWD (got {shared!r}, want {v!r})")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")

    if failures:
        print("FAIL\tms3-profile-cwd-isolation")
        for f in failures:
            eprint(f"  {f}")
        return 1
    print("PASS\tms3-profile-cwd-isolation")
    return 0


if __name__ == "__main__":
    sys.exit(main())
