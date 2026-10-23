#!/usr/bin/env python3
r"""WS2a.3 driver (Windows plan rev 2.21; UNREGISTERED until the WS2a.3 green, then step
windows-async-ownership-live in windows-live): the UI-thread marshal's waits are bounded.

Builds and runs tests/windows/ws2a3_async_ownership.c on the Win11 VM through the shared spike driver
(tests/windows/spike_driver.py: `build-on-windows.sh ws2a3-async-ownership-win`, a clean `git archive` of
ZB_BUILD_COMMIT, default HEAD, built with MSVC on the VM; host key pinned there; afterwards the run folder is removed
through the shared WebView2 cleanup, tests/windows/webview2_cleanup.py). The test links the real shim and calls only the
production ABI (zb_app_run, zb_automation_get_title) plus the shim's inert WS2a.3 test seams. This driver first
checks the host identity marker (%USERPROFILE%\zb\.gate-identity == ZB_WIN11_MARKER), then requires: exit 0, no
FAIL line, and an `ok` line for every REQUIRED check below; it prints `ASSERTS <number of ok lines>`.

Plan assertion (ONE named check): a call whose job is still completing gives up within deadline + waiter grace
(250 ms) with TIMEOUT and no result; no INFINITE wait remains in the marshal. Red and mutant (the INFINITE wait):
the call answers OK with the title after the held completion, so that one check is the only FAIL line.
WS2a.3b: strings are issued and freed exactly once (result, error, late-but-seen), and an automation-world eval
whose caller gave up starts no further CDP step (ONE named check). Red and mutant (drop the generation guard):
the chain dispatches the next steps for the abandoned job, so that one check is the only FAIL line.

WS2a.3c (each in a fresh child process of the test executable): a caller already waiting for the loop when zb_app_run
fails before its loop is answered NO_LOOP at once, as is every later call (ONE named check); and closing the window
as soon as it exists answers the waiting caller NO_LOOP at once, frees its job and ends zb_app_run. Red and mutant
(no loop end on run_core's early-failure paths): the waiter sits out its whole deadline (TIMEOUT), so that one check
is the only FAIL line.
WS2a.3d: a navigate and a reload that time out (a loopback server answers late) each stop their own load; a
page-initiated newer navigation that starts before the abandoned handling (seam zb_automation_debug_abandon_at_start)
goes on and commits; a newer routed navigate loads normally; and a timed-out navigation followed by an immediate close
frees every job (child process). Red: the navigate, reload and timeout-close rows FAIL. Mutants: no Stop() -> navigate
and reload; ownership guard dropped -> the overlap row only; no shutdown release -> the timeout-close row only.
ong.20 (child process): a call parked for a first load that never finishes (the window closes while the slow first page
loads) gets NO_LOOP and gives back its hold (live jobs back to the baseline). Red and mutant (no shutdown drain of the
first-load waiters): that row is the only FAIL line.

Under ZB_WIN_GATE=1 a missing host or marker exits 1 ("no Windows host configured"); standalone it exits 77.
A host run needs NavyCanyon's exact-commit approval and the orchestrator's release.

Run:  ZB_WIN_GATE=1 ZB_WIN11_HOST=127.0.0.1 ZB_WIN11_MARKER=<nonce> ZB_BUILD_COMMIT=<sha> \
      python3 -I tests/e2e/win_async_ownership_test.py
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "windows"))  # `python3 -I` drops it
from spike_driver import run_spike  # noqa: E402

STEP = "ws2a3-async-ownership-win"
REQUIRED = (
    "the fixture loads",
    "an ordinary call answers at once",
    "no job is live between calls",
    "a call whose completion is held gives up within deadline + waiter grace (TIMEOUT, no result)",
    "the held job is released once its completion ends (no leak)",
    "the loop still answers afterwards",
    "no caller string is live between calls",
    "a result string is issued once and freed once",
    "an error string is issued once and freed once",
    "a late completion the waiter still sees is reported once and its string freed once",
    "a late completion after a timeout dispatches nothing more and returns no string",
    "closing the window ends zb_app_run",
    "a caller waiting for the loop is answered NO_LOOP at once when zb_app_run fails before its loop",
    "an immediate quit wakes the waiting caller with NO_LOOP, frees its job and ends zb_app_run",
    "a timed-out navigation then an immediate close frees every job (live jobs back to the baseline)",
    "the loopback slow server starts",
    "a navigate that times out stops its own load (the page stays, the late answer never shows)",
    "a reload that times out stops its own load (the page stays, the late answer never shows)",
    "a page-initiated newer navigation that starts before the abandoned load is handled goes on and commits",
    "a newer navigate after a timed-out one loads normally",
    "a call waiting for the first load is freed when the window closes before that load (live jobs back to the baseline)",
)


if __name__ == "__main__":
    raise SystemExit(run_spike(STEP, REQUIRED, "ws2a3-async-ownership"))
