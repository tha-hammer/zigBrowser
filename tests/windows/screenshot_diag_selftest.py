#!/usr/bin/env python3
"""WS1.3 / 6c771ff screenshot-diagnostic source pin (GREEN, registered, Linux-only, no VM).

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


if __name__ == "__main__":
    unittest.main()
