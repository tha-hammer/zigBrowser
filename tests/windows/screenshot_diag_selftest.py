#!/usr/bin/env python3
"""WS1.3 / 6c771ff / 52a5aba src/webview2_shim.cpp source pins (GREEN, registered, Linux-only, no VM).

Also pins (RoseCat 4cd6a14): the screenshot e2e-seam forwarding (zb_run_screenshot carries the bit into
run_core instead of hard-coding 0) and the zb_version_line fail-closed shape (no fabricated OS/arch).

RoseCat 6c771ff: the live screenshot suite reaches only the NavigationCompleted branch, and deleting any
of the other failure branches' diagnostics (watchdog timeout, synchronous Navigate failure, async
document-script completion failure, and the capture/stream/write failures) leaves the suite green. The
shim is C++ that only runs on Windows, so runtime branch-selection needs the VM; as a Linux anti-drift
guard this pins the EXACT `zigBrowser: screenshot: ...` diagnostic for every failure branch in
src/webview2_shim.cpp — deleting (or editing) any one reds this test. The runtime branch-selecting live
tests (inert e2e seams for the three non-NavigationCompleted branches) are the VM-side follow-up.

Run alone:  python3 -I -X dev tests/windows/screenshot_diag_selftest.py -v
"""
import pathlib
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
SHIM = REPO / "src" / "webview2_shim.cpp"

# Reason strings passed to screenshot_diag(app, "<reason>") — printed as "zigBrowser: screenshot: <reason>".
_DIAG_REASONS = [
    "navigation timed out before the page loaded",       # watchdog timeout
    "no WebView available to navigate",                  # missing WebView at navigate
    "ICoreWebView2::Navigate failed to start",           # synchronous Navigate failure
    "AddScriptToExecuteOnDocumentCreated failed",        # async document-script completion failure
    "navigation failed; the page did not load",          # NavigationCompleted IsSuccess == false
]
# Full fprintf diagnostics in the capture/stream/write path (each begins "zigBrowser: screenshot: ").
_DIAG_FULL = [
    "zigBrowser: screenshot: no WebView to capture",
    "zigBrowser: screenshot: no output path",
    "zigBrowser: screenshot: CreateStreamOnHGlobal failed",
    "zigBrowser: screenshot: null capture stream",
    "zigBrowser: screenshot: IStream::Stat failed",
    "zigBrowser: screenshot: unexpected capture size",
    "zigBrowser: screenshot: GetHGlobalFromStream failed",
    "zigBrowser: screenshot: GlobalLock failed",
    "zigBrowser: screenshot: short write",
]


class ScreenshotDiagSourcePin(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SHIM.exists(), "src/webview2_shim.cpp must exist")
        self.src = SHIM.read_text()

    def test_every_screenshot_diag_reason_is_present(self):
        # Each failure branch must carry its exact diagnostic reason; deleting a screenshot_diag call reds this.
        for reason in _DIAG_REASONS:
            self.assertIn('screenshot_diag(app, "%s")' % reason, self.src,
                          "missing screenshot_diag branch reason: %r" % reason)

    def test_every_capture_diagnostic_line_is_present(self):
        for line in _DIAG_FULL:
            self.assertIn(line, self.src, "missing capture/stream/write diagnostic: %r" % line)

    def test_screenshot_diag_emits_the_pinned_prefix(self):
        # The helper that prints the branch reasons must use the exact "zigBrowser: screenshot: %s" format.
        self.assertIn('fprintf(stderr, "zigBrowser: screenshot: %s\\n", reason)', self.src,
                      "screenshot_diag must print the exact 'zigBrowser: screenshot: <reason>' line")


class ScreenshotSeamReachableSourcePin(unittest.TestCase):
    """52a5aba: zb_run_screenshot must FORWARD the e2e bit into run_core, not hard-code 0.

    The ZB_E2E_FORCE_SCREENSHOT_FAIL branch-selection seam gates on app->e2e_protocol. While
    zb_run_screenshot called run_core(..., 0, true, out_path) the seam could never fire from the
    screenshot path, so the three forced branches were dead. The C++ runs only on Windows; this pins
    the forwarding on Linux. Reverting to the hard-coded 0 reds this test. (cli.zig proves the CLI now
    accepts --e2e-protocol; tests/e2e/screenshot_branches_live_test.py proves the branches on the VM.)
    """

    def setUp(self):
        self.src = SHIM.read_text()

    def test_zb_run_screenshot_forwards_the_e2e_bit(self):
        self.assertIn("return run_core(uri, print_title, e2e_protocol, true, out_path);", self.src,
                      "zb_run_screenshot must forward e2e_protocol into run_core")
        self.assertNotIn("return run_core(uri, print_title, 0, true, out_path);", self.src,
                         "zb_run_screenshot must NOT hard-code the e2e bit to 0 (seam becomes unreachable)")
        self.assertIn("int print_title, int e2e_protocol)", self.src,
                      "zb_run_screenshot must take the e2e_protocol parameter")


class SeamInertnessGuardPins(unittest.TestCase):
    """52a5aba (RoseCat 6bea364): the forced-failure seam must stay INERT in a shipped run — it may only
    fire under --e2e-protocol. Two production guards enforce that, and BOTH must be pinned or a mutant
    that removes them (making ZB_E2E_FORCE_SCREENSHOT_FAIL fire with no --e2e-protocol) survives:

      G1  the env is read ONLY under e2e_protocol:  if (app.e2e_protocol) { app.force_screenshot_fail = getenv(...) }
      G2  the branch rechecks e2e_protocol:          if (app->e2e_protocol && app->force_screenshot_fail != nullptr)

    RoseCat mutated both away and the prior pins stayed 7/7; these two regexes red on either removal.
    The live VM negative (ZB_E2E_FORCE_SCREENSHOT_FAIL set WITHOUT --e2e-protocol stays inert) is the
    runtime counterpart in tests/e2e/screenshot_branches_live_test.py.
    """

    def setUp(self):
        self.src = SHIM.read_text()

    def test_env_is_read_only_under_e2e_protocol(self):
        # G1: the getenv must be wrapped by `if (app.e2e_protocol) {`. Removing the wrapper reds this.
        self.assertRegex(
            self.src,
            r'if\s*\(\s*app\.e2e_protocol\s*\)\s*\{\s*\n\s*app\.force_screenshot_fail\s*=\s*getenv\(\s*"ZB_E2E_FORCE_SCREENSHOT_FAIL"\s*\)\s*;',
            "the ZB_E2E_FORCE_SCREENSHOT_FAIL getenv must be read ONLY inside `if (app.e2e_protocol)`")
        # And it must be read exactly once — no second, unguarded getenv of the same var.
        self.assertEqual(
            self.src.count('getenv("ZB_E2E_FORCE_SCREENSHOT_FAIL")'), 1,
            "ZB_E2E_FORCE_SCREENSHOT_FAIL must be read exactly once (the single guarded read)")

    def test_branch_rechecks_e2e_protocol(self):
        # G2: the forced-failure branch must AND in app->e2e_protocol. Removing it reds this.
        self.assertRegex(
            self.src,
            r'if\s*\(\s*app->e2e_protocol\s*&&\s*app->force_screenshot_fail\s*!=\s*nullptr\s*\)',
            "the forced-failure branch must gate on `app->e2e_protocol && app->force_screenshot_fail != nullptr`")


class VersionLineFailClosedSourcePin(unittest.TestCase):
    """6115ac1 / RoseCat 4cd6a14: zb_version_line must FAIL CLOSED, never invent OS/arch values.

    When RtlGetVersion or IsWow64Process2 can't be resolved or the call fails, the field must read an
    explicit "unavailable" token — never a fabricated 10.0.0 or a bare x86_64 default. The C++ runs only
    on Windows; this pins the fail-closed shape on Linux. Reverting either default reds this test.
    """

    def setUp(self):
        self.src = SHIM.read_text()

    def test_os_field_fails_closed_to_unavailable(self):
        self.assertIn('snprintf(os_field, sizeof(os_field), "Windows unavailable")', self.src,
                      "OS field must fall back to 'Windows unavailable' when RtlGetVersion lookup/call fails")

    def test_arch_defaults_to_unavailable_not_a_fabricated_x86_64(self):
        # arch starts "unavailable" and is overwritten ONLY inside the successful IsWow64Process2 call.
        self.assertIn('const char *arch = "unavailable";', self.src,
                      "arch must default to 'unavailable', set to a concrete value only on IsWow64Process2 success")

    def test_os_field_only_written_on_rtlgetversion_success(self):
        # The concrete "Windows %lu.%lu.%lu" line must be guarded by a successful RtlGetVersion call.
        self.assertIn("if (rgv != nullptr && rgv(&vi) == 0) {", self.src,
                      "the concrete OS build must be written only when RtlGetVersion resolves AND returns 0")


if __name__ == "__main__":
    unittest.main()
