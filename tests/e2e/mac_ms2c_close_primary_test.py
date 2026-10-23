#!/usr/bin/env python3
"""RED (UNREGISTERED; bd zigBrowser-4pa.58, plan R30-MS2 sub-slice MS2c.6, SilverRidge c6125315) — the native close
control of the PRIMARY window matches Linux (owner default R30.3 #3): the primary leaves the automation registry,
and the browser exits when it was the last window.

On Linux a real WM_DELETE_WINDOW on the primary destroys it: it leaves page.list, a popup that remains stays
routable and the browser keeps running, and closing the last window exits the browser (observed 2026-10-22, 7f8b217).
Automation page.close and a page's window.close() still refuse or ignore the primary (unchanged here). On macOS today
ZBWindowHost handles no windowWillClose:, so the red button only hides the NSWindow.

The close is driven through the e2e-only seam ZB_DEBUG_NATIVE_CLOSE_ON_TITLE (hook 14, as in
mac_ms2c_close_button_test.py): a routed page.evaluate sets the primary's document.title to that value, and the shim
calls -[NSWindow performClose:] on it. Two launches, each with a private HOME and its own --profile-dir:
- A, the primary with a popup open. When the primary is natively closed, then
  1 the primary leaves page.list (the popup stays listed),
  2 a command routed to the popup still answers,
  3 the browser keeps running.
- B, the primary alone. When it is natively closed, then
  4 the last WINCOUNT row is 0 (removeWindow: removed the last window),
  5 the browser exits by itself with status 0 within the timeout.

Failing assertions today (Mac), the accepted red vector RED_VECTOR (red_shape.py): 1 fails with the primary still
listed, 4 with the last row WINCOUNT 1, 5 with the browser still alive; 2 and 3 pass.
Target: tests/mac/ms_runtime_rows_gate.sh (a red row, held until 3ui.13 is approved and a run is released); the
hostless proof is tests/e2e/mac_red_shape_selftest.py.
"""
import argparse
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from mac_ms2c_close_button_test import _FixtureServer, e2e_socket_path, eprint  # noqa: E402  (same fixture pages)
from mac_row_session import launch  # noqa: E402
from mac_term_teardown import install_term_only_cleanup, leak_failures  # noqa: E402
from red_shape import PASS, Red, RedShape, reply_kind  # noqa: E402

CLOSE_TITLE = "zb-native-close"
LAUNCH = launch  # the browser source; the hostless selftest injects a scripted fake (SilverRidge c78a1f6)
TEST_ID = "ms2c-close-primary"
RED_VECTOR = {"1-primary-left-page-list": Red("listed", "popup-missing"), "2-popup-routable": PASS,
              "3-alive-after-primary": PASS, "4-last-wincount-zero": Red("WINCOUNT\t1", "WINCOUNT\t2"),
              "5-last-clean-exit": Red("alive", "exit 1")}


# The row-owned recording functions (SilverRidge cf16730): main hands each the RAW observation.
def record_primary_listed(shape: RedShape, primary_id: str, popup_id: str, ids: list) -> None:
    observed = "listed" if primary_id in ids else ("popup-missing" if popup_id not in ids else "not-listed")
    shape.check("1-primary-left-page-list", observed == "not-listed",
                f"after the primary's native close page.list is {ids!r} (primary {primary_id}, popup {popup_id})",
                observed=observed)


def record_last_wincount(shape: RedShape, out_lines: list) -> None:
    wincount = [l for l in list(out_lines) if l.startswith("WINCOUNT\t")]
    shape.check("4-last-wincount-zero", bool(wincount) and wincount[-1] == "WINCOUNT\t0",
                f"the last window's native close did not remove it (WINCOUNT rows {wincount[-4:]!r})",
                observed=wincount[-1] if wincount else None)


def record_last_exit(shape: RedShape, rc) -> None:
    observed = "alive" if rc is None else f"exit {rc}"
    shape.check("5-last-clean-exit", rc == 0, f"after the last window's native close the browser is {observed}",
                observed=observed)


def wait_until(pred, timeout_sec: float, step: float = 0.05) -> bool:
    end = time.monotonic() + timeout_sec
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(step)
    return pred()


def start(browser: Path, fixture, tmp: Path, name: str, timeout_sec: float):
    run = tmp / name
    (run / "home").mkdir(parents=True)
    socket_path = e2e_socket_path(run / "automation.sock")
    env = dict(os.environ)
    env["ZIGBROWSER_SOCKET"] = str(socket_path)
    env["HOME"] = str(run / "home")  # private HOME: never the account's own profile or caches
    env["ZB_DEBUG_EPHEMERAL_DATA_STORE"] = "1"  # e2e-only hook 16: no website data written outside the run
    env["ZB_DEBUG_NATIVE_CLOSE_ON_TITLE"] = CLOSE_TITLE
    return LAUNCH([str(browser), f"{fixture.base_url}/a", "--automation-api", "--e2e-protocol",
                   "--profile-dir", str(run / "profile")], env, socket_path, timeout_sec)


def native_close_primary(rpc, out) -> None:
    try:  # the reply may race the close
        rpc.raw("page.evaluate", {"window_id": "window-1", "expression": f"(document.title = '{CLOSE_TITLE}', true)"})
    except Exception:  # noqa: BLE001
        pass
    if not wait_until(lambda: any(l == "NATIVE_CLOSE\t1" for l in list(out)), 5.0):
        raise AssertionError("PRECONDITION the native close seam never fired on the primary (no NATIVE_CLOSE row)")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=25.0)
    args = ap.parse_args(argv)
    browser = Path(args.browser)
    if not browser.is_file():
        print("FAIL\tms2c-close-primary-binary-missing")  # rule 7: a skip is a failure
        eprint(f"binary not found: {browser}")
        return 1

    proc_holder: list[subprocess.Popen] = []
    install_term_only_cleanup(lambda: proc_holder[-1] if proc_holder else None)
    shape = RedShape(TEST_ID, RED_VECTOR)
    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-closeprim-") as tmp:
        # A: the primary with a popup open.
        session = start(browser, fixture, Path(tmp), "a", args.timeout_sec)
        proc_holder.append(session.proc)
        try:
            rpc = session.connect()

            def ids():
                return [p.get("window_id") for p in (rpc.call("page.list", {}) or {}).get("pages") or []]

            rpc.call("page.url", {"timeout_ms": 10000})
            rpc.evaluate("(window.open('/p'), true)")
            if not wait_until(lambda: len(ids()) == 2, 10.0):
                raise AssertionError(f"PRECONDITION the popup never appeared in page.list: {ids()!r}")
            popup_id = next(i for i in ids() if i != "window-1")
            native_close_primary(rpc, session.out)
            wait_until(lambda: "window-1" not in ids(), 3.0)
            record_primary_listed(shape, "window-1", popup_id, ids())
            shape.check("2-popup-routable", reply_kind(rpc.raw("page.title", {"window_id": popup_id})) == "result",
                        "the remaining popup no longer answers")
            shape.check("3-alive-after-primary", session.proc.poll() is None,
                        f"the browser exited (rc={session.proc.returncode}) while a popup remained")
        except Exception as exc:  # noqa: BLE001
            shape.problem(f"A: {exc!r} (rc={session.proc.poll()})")
        finally:
            session.stop()

        # B: the primary alone.
        session = start(browser, fixture, Path(tmp), "b", args.timeout_sec)
        proc_holder.append(session.proc)
        try:
            rpc = session.connect()
            rpc.call("page.url", {"timeout_ms": 10000})
            native_close_primary(rpc, session.out)
            wait_until(lambda: session.proc.poll() is not None, 5.0)
            record_last_wincount(shape, session.out)
            record_last_exit(shape, session.proc.poll())
        except Exception as exc:  # noqa: BLE001
            shape.problem(f"B: {exc!r} (rc={session.proc.poll()})")
        finally:
            session.stop()

    for msg in leak_failures():  # a browser SIGTERM did not end fails the row (no SIGKILL on a Mac)
        shape.problem(msg)
    return shape.report()  # a missing assertion is a failure (rule 7)


if __name__ == "__main__":
    sys.exit(main())
