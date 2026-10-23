r"""Windows plan WS2a.2 (rev 2.21): `dom.*` commands run in the automation script's PRIVATE CDP world, so a page
that defines `window.__zbAutomation`, overrides `Element.prototype.click`, freezes `document.querySelector` and
spoofs the text getters gets the SAME `dom.*` results as a clean page (a metamorphic property), on the REAL
zigBrowser.exe over its authenticated socket on the Win11 VM (and, after its release, the Win10 box).
UNREGISTERED until the WS2a.2 green, which registers it as step `windows-private-world-live` in `windows-live`.

The browser is launched exactly as tests/e2e/win_transport_test.py launches it, on the HOSTILE page first; the
clean page (same body, no hostile script) is staged beside it. Requests go through the probe's `rpc` command, as
in tests/e2e/win_routed_test.py (whose request helpers are borrowed).
  * the plan's assertion is the FIRST dom.* call: dom.getText css=#heading on the hostile page == "real";
  * then getAttribute, click (+ the page's real handler ran), fill (+ the real value), waitFor and getText of a
    late element give the expected answers on the hostile page;
  * the page world still sees only its own spoof (page.evaluate: window.__zbAutomation.marker == "PAGE-SPOOF");
  * after navigating to the clean page, the same dom.* sequence gives exactly the same answers.

Expected at HEAD (WS2a.0 world + WS2a.1 port): GREEN. The failing-first evidence is the plan's mutant: install
automation.js in, and evaluate it in, the page's MAIN world; then the page's spoofs win and the first dom.* call
(the plan's assertion) is red.

Host selection, as win_transport_test.py: ZB_WIN11_HOST, ZB_WIN_EXE, ZB_WIN11_PORT, ZB_WIN11_USER, ZB_WIN11_KEY,
ZB_WIN11_KNOWN_HOSTS (all explicit once the host is set; bd zigBrowser-ong.25). With no host it skips when run by hand and FAILS under ZB_WIN_GATE=1 (plan D.1, rule 7).
Prints `ASSERTS <n>` (tests/windows/live_gate.py).

Run live (after a reviewer-approved exact commit and the orchestrator's release):
  ZB_WIN_GATE=1 ZB_WIN11_HOST=127.0.0.1 ZB_WIN_EXE=<zigBrowser.exe> python3 -I tests/e2e/win_private_world_test.py -v
"""
import os
import pathlib
import sys
import time
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # `python3 -I` drops the script dir
sys.path.insert(0, str(HERE.parent / "windows"))

import live_gate  # noqa: E402
import win_routed_test as wr  # noqa: E402
import win_transport_test as wt  # noqa: E402

NO_HOST = "no Windows host configured"

BODY = """<h1 id="heading" data-k="v1">real</h1>
<button id="btn">go</button><div id="out">idle</div>
<input id="name">
<script>
document.getElementById('btn').addEventListener('click', () => { document.getElementById('out').textContent = 'clicked'; });
setTimeout(() => {
  const late = document.createElement('div'); late.id = 'late'; late.textContent = 'late'; document.body.appendChild(late);
}, 300);
</script>"""

# Runs in the PAGE's main world before its body: a page-owned __zbAutomation, a click override, frozen query
# functions, and text getters that lie (their setters still work, so the page's own handlers are unchanged).
HOSTILE_SCRIPT = """<script>
window.__zbAutomation = { marker: 'PAGE-SPOOF', getText: function () { return 'SPOOFED'; } };
Element.prototype.click = function () { document.getElementById('out').textContent = 'SPOOF-CLICK'; };
HTMLElement.prototype.click = Element.prototype.click;
Object.defineProperty(Document.prototype, 'querySelector', { value: function () { return null; }, writable: false, configurable: false });
Object.defineProperty(Document.prototype, 'querySelectorAll', { value: function () { return []; }, writable: false, configurable: false });
Object.defineProperty(Element.prototype, 'querySelector', { value: function () { return null; }, writable: false, configurable: false });
const zbText = Object.getOwnPropertyDescriptor(Node.prototype, 'textContent');
Object.defineProperty(Node.prototype, 'textContent', { get: function () { return 'SPOOFED'; }, set: zbText.set, configurable: false });
const zbInner = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'innerText');
Object.defineProperty(HTMLElement.prototype, 'innerText', { get: function () { return 'SPOOFED'; }, set: zbInner.set, configurable: false });
</script>"""


def _page(title, head_script=""):
    return (f"<!doctype html><html><head><meta charset=\"utf-8\"><title>{title}</title>{head_script}</head>"
            f"<body>\n{BODY}\n</body></html>\n")


HOSTILE = _page("Hostile", HOSTILE_SCRIPT)
CLEAN = _page("Clean")

# The answers every dom.* step must give, on both pages.
EXPECTED = [
    ("dom.getAttribute #heading data-k", {"value": "v1"}),
    ("dom.click #btn", {"ok": True}),
    ("dom.getText #out", {"text": "clicked"}),
    ("dom.fill #name", {"ok": True}),
    ("#name value (page world)", {"result": "zb"}),
    ("dom.waitFor #late", {"ok": True}),
    ("dom.getText #late", {"text": "late"}),
]

_BORROWED = ("_opts", "_env", "_ssh_argv", "_ssh", "_scp", "_profile", "_probe_as", "_launch", "_release",
             "_remove", "_assert_started")
_BORROWED_RPC = ("_call", "_result", "_error_code")


class WinPrivateWorld(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        wt.WinTransport.__dict__["setUpClass"].__func__(cls)
        if cls.tmp:
            # The transport runner opens `test.html`: make it the hostile page, and stage the clean one beside it.
            pathlib.Path(cls.tmp, "test.html").write_text(HOSTILE, encoding="utf-8")
            pathlib.Path(cls.tmp, "clean.html").write_text(CLEAN, encoding="utf-8")

    tearDownClass = wt.WinTransport.__dict__["tearDownClass"]

    def setUp(self):
        if not self.host or not self.exe or not pathlib.Path(self.exe).is_file():
            live_gate.skip_or_fail(self, f"NOT RUN: {NO_HOST} (set ZB_WIN11_HOST and ZB_WIN_EXE)")
        wt.WinTransport.setUp(self)
        self._n = 0

    def _wait_title(self, title):
        deadline = time.monotonic() + 30
        reply = None
        while time.monotonic() < deadline:
            reply = self._call("page.title")
            if reply.get("result") == {"title": title}:
                return
            time.sleep(0.5)
        self.fail(f"page {title!r} never answered page.title: {reply}")

    def _dom_answers(self):
        """The dom.* sequence after the heading read; one (label, reply result or error) per step."""
        steps = [
            ("dom.getAttribute", {"selector": "css=#heading", "name": "data-k"}),
            ("dom.click", {"selector": "css=#btn"}),
            ("dom.getText", {"selector": "css=#out"}),
            ("dom.fill", {"selector": "css=#name", "value": "zb"}),
            ("page.evaluate", {"expression": "document.getElementById('name').value"}),
            ("dom.waitFor", {"selector": "css=#late", "state": "attached", "timeout_ms": 5000}),
            ("dom.getText", {"selector": "css=#late"}),
        ]
        answers = []
        for (label, _), (method, params) in zip(EXPECTED, steps):
            reply = self._call(method, params)
            answers.append((label, reply.get("result", reply.get("error"))))
        return answers

    def test_dom_commands_ignore_a_hostile_page_world(self):
        self.win, r = self._launch()
        self._assert_started(r)
        self.rel = self.win[len(self._profile(self.user)) + 1:].replace("\\", "/")
        self.sock, self.token = r["sock"], r["token"]
        cp = self._scp(self.user, os.path.join(self.tmp, "clean.html"), f"{self.rel}/clean.html")
        self.assertEqual(cp.returncode, 0, f"scp clean.html failed: {cp.stderr}")
        url_clean = wr._file_url(f"{self.win}\\clean.html")

        self._wait_title("Hostile")
        # The plan's assertion, the FIRST dom.* call: the real DOM text, not the page's spoof.
        reply = self._call("dom.getText", {"selector": "css=#heading"})
        self.assertEqual(reply.get("result"), {"text": "real"}, f"dom.getText #heading on the hostile page: {reply}")
        self.assertEqual(self._dom_answers(), EXPECTED, "hostile page: dom.* answers")
        # The page world sees only its own object, never the automation script's.
        self.assertEqual(self._result("page.evaluate", {"expression": "window.__zbAutomation.marker"}),
                         {"result": "PAGE-SPOOF"})

        # Metamorphic: the clean page gives the same answers.
        self.assertEqual(self._result("page.navigate", {"url": url_clean, "timeout_ms": 10000}), {"ok": True})
        self._wait_title("Clean")
        self.assertEqual(self._result("dom.getText", {"selector": "css=#heading"}), {"text": "real"})
        self.assertEqual(self._dom_answers(), EXPECTED, "clean page: dom.* answers")


for _name in _BORROWED:
    setattr(WinPrivateWorld, _name, wt.WinTransport.__dict__[_name])
for _name in _BORROWED_RPC:
    setattr(WinPrivateWorld, _name, wr.WinRouted.__dict__[_name])


if __name__ == "__main__":
    live_gate.main()
