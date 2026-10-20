#!/usr/bin/env python3
"""MS3.1 RED (unregistered) — --profile-dir binds a persistent, isolated WKWebsiteDataStore (user decision 2026-10-20).

macOS 14+ path (the hosts are macOS 15): a cookie set under --profile-dir A survives a restart under A
(persistence) and is absent under --profile-dir B (isolation) — each profile is its own
dataStoreForIdentifier store, keyed by the path.

macOS 13 fallback (forced via the e2e seam ZB_DEBUG_FORCE_PRE_MACOS14): profiles share the default
persistent store, so a cookie set under A is visible under B; and startup prints one stderr line that
isolation needs macOS 14.

The profile path is only the identity seed (no directory is created). Fixed seeds + a unique cookie value
per run keep the test self-contained without accumulating stores.
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
PROFILE_A = "/tmp/zb-ms3-profile-A"
PROFILE_B = "/tmp/zb-ms3-profile-B"


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=25.0)
    args = ap.parse_args()
    browser = Path(args.browser)
    if not browser.is_file():
        eprint(f"SKIP: binary not found: {browser}")
        return SKIP_EXIT

    proc_holder: list[subprocess.Popen] = []
    _install_signal_cleanup(lambda: proc_holder[0] if proc_holder else None)
    failures: list[str] = []
    uniq = str(int(time.time() * 1000))
    expires = int(time.time()) + 3600  # a PERSISTENT cookie (future expiry); session cookies never hit disk
    FLUSH = 1.5  # let WebKit write the persistent cookie to disk before the (hard) stop

    def run(profile, fn, force_pre14=False):
        """Launch with --profile-dir <profile>, run fn(rpc), return fn's value; capture stderr."""
        tmp = tempfile.mkdtemp(prefix="zb-ms3prof-")
        sp = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(sp)
        if force_pre14:
            env["ZB_DEBUG_FORCE_PRE_MACOS14"] = "1"
        extra = ["--e2e-protocol"] if force_pre14 else []
        p = subprocess.Popen(
            [str(browser), "about:blank", "--automation-api", "--profile-dir", profile, *extra],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, start_new_session=True,
        )
        proc_holder[:] = [p]
        o, e = [], []
        for stream, buf in ((p.stdout, o), (p.stderr, e)):
            threading.Thread(target=_read_lines, args=(stream, buf), daemon=True).start()
        rpc = None
        try:
            rpc = RpcClient(sp, args.timeout_sec)
            rpc.call("page.url", {"timeout_ms": 10000})
            return fn(rpc), "\n".join(e)
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(p)

    def cookies(rpc):
        return (rpc.raw("cookies.getAll", {}).get("result") or {}).get("cookies") or []

    def value_of(cks, name):
        c = next((c for c in cks if c.get("name") == name), None)
        return c.get("value") if c else None

    try:
        # ---- macOS 14+ : persistence + isolation ----
        v = "persist-" + uniq
        run(PROFILE_A, lambda rpc: (rpc.raw("cookies.set", {"name": "zbpersist", "value": v, "domain": "127.0.0.1", "path": "/", "expires": expires}), time.sleep(FLUSH)))
        again, _ = run(PROFILE_A, lambda rpc: value_of(cookies(rpc), "zbpersist"))
        if again != v:
            failures.append(f"profile A did not PERSIST the cookie across restart (got {again!r}, want {v!r})")
        other, _ = run(PROFILE_B, lambda rpc: value_of(cookies(rpc), "zbpersist"))
        if other == v:
            failures.append(f"profile B saw profile A's cookie — stores are NOT isolated (got {other!r})")

        # ---- macOS 13 fallback : shared default store + warning ----
        w = "shared-" + uniq
        _, warn = run(PROFILE_A, lambda rpc: (rpc.raw("cookies.set", {"name": "zbshared", "value": w, "domain": "127.0.0.1", "path": "/", "expires": expires}), time.sleep(FLUSH)), force_pre14=True)
        if "isolation needs macOS 14" not in warn:
            failures.append(f"macOS-13 fallback did not print the isolation warning: {warn[-200:]!r}")
        shared, _ = run(PROFILE_B, lambda rpc: value_of(cookies(rpc), "zbshared"), force_pre14=True)
        if shared != w:
            failures.append(f"macOS-13 fallback did not SHARE the default store (profile B got {shared!r}, want {w!r})")
        # cleanup the shared default-store cookie so it doesn't linger for other tests.
        run(PROFILE_A, lambda rpc: rpc.raw("cookies.delete", {"name": "zbshared", "domain": "127.0.0.1"}), force_pre14=True)
    except Exception as exc:  # noqa: BLE001
        failures.append(f"unexpected error: {exc}")

    if failures:
        print("FAIL\tms3-profile-persist")
        for f in failures:
            eprint(f"  {f}")
        return 1
    print("PASS\tms3-profile-persist")
    return 0


if __name__ == "__main__":
    sys.exit(main())
