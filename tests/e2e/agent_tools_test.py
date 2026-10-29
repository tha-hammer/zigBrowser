#!/usr/bin/env python3
"""S7b, the agent's read tools through the real chain (chat-drawer plan section 10, S7:
Closure Test S7, S7.2, S7.4, S7.5, S7.8 and the detach red; revs 16.20.34-16.20.36).

Each case runs the real binary on its own Xvfb with the real helper and the real Claude CLI
against the TLS fake Messages API (the lifecycle test's seams), in a network namespace of
its own (re-exec'd as --sealed-child). The fake scripts a `tool_use`, and the test reads the
`tool_result` the CLI sends back in its next request: the observable of the closure. The
test never calls the broker, callInProcess or the engine itself, and never fetches the text
through the socket.

- closure: window 1's `get_text css=#greeting` reaches the model as "Hello from page 1",
  never page 2's text, and the final reply is shown (DRAWER msg assistant);
- own-window: the same from window 2's drawer gives "Hello from page 2";
- tools-listed: the request lists exactly S7.5's six mcp__zigbrowser__ read tools, S8
  decision 12's hover and scroll, and decision 16's navigate and reload;
- screenshot: the tool_result holds one image whose base64 decodes to a PNG or JPEG;
- window-fixed: a model-supplied window_id is an error that reads nothing. The SDK's input
  schema (additionalProperties false) refuses it before the broker sees it; the broker's own
  refusal, "window is fixed to this drawer", is defence in depth, unit-tested in
  tests/agent_broker_test.zig, and this case does not reach it;
- refused: evaluate (no tool of the server: the CLI refuses it) is an error, and no request
  body holds the page's cookie (the other forbidden calls: agent_tools_acceptance_test.py);
- detach: closing a window while its call waits closes promptly (the browser answers within
  2 s), the call gets no answer from the browser (only the helper's or the CLI's own ending
  text when its session ends), and no broker thread is left.
Exit 1 when Xvfb, xauth, bwrap, the venv or the binary is missing."""

from __future__ import annotations

import base64
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_host_lifecycle_test as life  # noqa: E402 - its world, seams and helpers

# S7.5's six read tools, S8 decision 12's hover and scroll, and decision 16's navigate and reload.
TOOLS = {f"mcp__zigbrowser__{n}" for n in ("window_info", "query", "get_text", "get_attribute", "wait_for", "screenshot",
                                            "hover", "scroll", "navigate", "reload")}
DONE = "zb-tools-done"
COOKIE = "zbcookiecanary7c41"
PAGE = """<!doctype html><meta charset="utf-8"><title>tools</title>
<h1 id="greeting"></h1>
<script>
document.getElementById("greeting").textContent = location.hash.startsWith("#popup") ? "Hello from page 2" : "Hello from page 1";
// The detach case (#popup-close-<port>): this popup closes itself, as a page may (not
// through the automation queue), once the test's loopback server answers its image.
const port = (location.hash.match(/^#popup-close-(\\d+)$/) || [])[1];
if (port) setInterval(() => {
  const img = new Image();
  img.onload = () => window.close();
  img.src = `http://127.0.0.1:${port}/close?${Date.now()}`;
}, 100);
document.cookie = "zbcanary=%s; path=/";
window.__ready = true;
</script>""" % COOKIE


def page_url(tmp: Path) -> str:
    path = tmp / "tools-page.html"
    if not path.exists():
        path.write_text(PAGE)
    return path.resolve().as_uri()


def tool_results(entry) -> list[dict]:
    """Every tool_result block of a /v1/messages request (its user turns)."""
    blocks = []
    for message in (entry.get("body") or {}).get("messages") or []:
        content = message.get("content")
        if message.get("role") == "user" and isinstance(content, list):
            blocks += [b for b in content if isinstance(b, dict) and b.get("type") == "tool_result"]
    return blocks


def result_text(block: dict) -> str:
    content = block.get("content")
    if isinstance(content, str):
        return content
    return "".join(c.get("text", "") for c in content or [] if isinstance(c, dict))


def scripted(calls: dict[str, dict]):
    """A responder: a prompt holding a key of `calls` gets that tool_use; the request that
    carries its tool_result gets the final text."""
    def respond(entry, index):
        if tool_results(entry):
            return {"text": DONE}
        users = [m for m in (entry.get("body") or {}).get("messages") or [] if m.get("role") == "user"]
        said = json.dumps(users[-1:])  # the prompt: the CLI appends a system message after it
        for key, call in calls.items():
            if key in said:
                return {"tool_use": call}
        return {"text": "ok"}
    return respond


def start(binary: Path, tmp: Path, label: str, calls: dict[str, dict], automation: bool = True):
    fake = life.Fake(tmp)
    fake.api.responder = scripted(calls)
    from agent_common import Browser
    env = life.env_for(life.world(binary, tmp, "tools"), life.runtime_dir(), fake.seams())
    b = Browser(binary, tmp, label, ["--agent-drawer", "on", "--agent-secret-store", "file"], env=env,
                url=page_url(tmp), automation=automation)
    return b, fake


def answered(fake, timeout: float = 150.0):
    """The first request that carries a tool_result, once it arrives."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for entry in fake.api.messages_requests():
            if tool_results(entry):
                return entry
        time.sleep(0.1)
    return None


def finish(b, fake) -> None:
    life.release_x(b)
    b.stop()
    fake.close()


def ask(b, check, fake, prompt: str, win: int = 1):
    """Sends `prompt` in window `win` and returns the tool_result block the model got."""
    life.send(b, prompt, win)
    entry = answered(fake)
    if not check(entry is not None, f"{prompt}: a tool_result reached the API", b):
        return None
    blocks = tool_results(entry)
    check(len(blocks) == 1, f"{prompt}: exactly one tool_result ({len(blocks)})")
    return blocks[0]


def case_closure(binary: Path, tmp: Path, check) -> None:
    b, fake = start(binary, tmp, "closure", {"read-greeting": {"name": "mcp__zigbrowser__get_text", "input": {"selector": "css=#greeting"}}})
    try:
        if not check(b.wait_page(), "window 1's page loaded", b):
            return
        block = ask(b, check, fake, "read-greeting")
        if block is None:
            return
        text = result_text(block)
        check(not block.get("is_error") and "Hello from page 1" in text and "page 2" not in text,
              f"the model got window 1's text ({text[:120]!r}, is_error {block.get('is_error')})")
        check(b.wait(lambda: ("assistant", DONE) in life.bubbles(b), 60), f"the final reply is shown ({life.bubbles(b)})", b)
        tools = {t.get("name") for t in fake.api.messages_requests()[0]["body"].get("tools") or []}
        check(tools == TOOLS, f"tools-listed: exactly the six read tools, hover, scroll, navigate and reload ({sorted(tools)})")
    finally:
        finish(b, fake)


def case_own_window(binary: Path, tmp: Path, check) -> None:
    b, fake = start(binary, tmp, "own-window", {"read-two": {"name": "mcp__zigbrowser__get_text", "input": {"selector": "css=#greeting"}}})
    try:
        if not check(b.wait_page() and b.open_popup() and b.wait(lambda: b.rows("icon", 2) != [], 20), "window 2 has its drawer", b):
            return
        block = ask(b, check, fake, "read-two", win=2)
        if block is not None:
            text = result_text(block)
            check(not block.get("is_error") and "Hello from page 2" in text and "page 1" not in text,
                  f"window 2's drawer reads window 2 ({text[:120]!r})")
    finally:
        finish(b, fake)


def case_screenshot(binary: Path, tmp: Path, check) -> None:
    b, fake = start(binary, tmp, "screenshot", {"take-shot": {"name": "mcp__zigbrowser__screenshot", "input": {}}})
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        block = ask(b, check, fake, "take-shot")
        if block is None:
            return
        images = [c for c in block.get("content") or [] if isinstance(c, dict) and c.get("type") == "image"]
        check(not block.get("is_error") and len(images) == 1, f"one image block ({json.dumps(block)[:200]})")
        if images:
            source = images[0].get("source") or {}
            data = base64.b64decode(source.get("data", ""), validate=True)
            magic = data[:8] == b"\x89PNG\r\n\x1a\n" or data[:3] == b"\xff\xd8\xff"
            check(source.get("media_type") in ("image/png", "image/jpeg") and magic,
                  f"its base64 decodes to a {source.get('media_type')} ({data[:4]!r}, {len(data)} bytes)")
            check(COOKIE.encode() not in data, "the image bytes hold no cookie")
    finally:
        finish(b, fake)


def case_window_fixed(binary: Path, tmp: Path, check) -> None:
    b, fake = start(binary, tmp, "window-fixed", {"other-window": {"name": "mcp__zigbrowser__get_text",
                                                                   "input": {"selector": "css=#greeting", "window_id": "window-2"}}})
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        block = ask(b, check, fake, "other-window")
        if block is not None:
            text = result_text(block)
            check(block.get("is_error") is True and "window_id" in text and "Hello from page" not in text,
                  f"a model-supplied window_id is refused by the tool's input schema and reads nothing ({text[:120]!r})")
    finally:
        finish(b, fake)


def case_refused(binary: Path, tmp: Path, check) -> None:
    b, fake = start(binary, tmp, "refused", {"try-evaluate": {"name": "mcp__zigbrowser__evaluate", "input": {"expression": "document.cookie"}}})
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        block = ask(b, check, fake, "try-evaluate")
        if block is not None:
            check(block.get("is_error") is True, f"evaluate is refused ({result_text(block)[:120]!r})")
        bodies = json.dumps([e.get("body") for e in fake.api.messages_requests()])
        check(COOKIE not in bodies, "no request body holds the page's cookie")
        refused = [line for line in b.err if "rejected frame" in line]
        check(refused == [], f"every helper frame was valid ({refused[:2]})")
    finally:
        finish(b, fake)


def broker_threads(pid: int | None) -> list[str]:
    names = []
    if pid is None:
        return names
    for task in Path(f"/proc/{pid}/task").iterdir():
        try:
            name = (task / "comm").read_text().strip()
        except OSError:
            continue
        if name.startswith("zb-broker"):
            names.append(name)
    return names


class CloseSignal:
    """A loopback server whose /close answers 404 until `fire`, then a 1x1 GIF."""

    GIF = base64.b64decode("R0lGODlhAQABAAAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw==")

    def __init__(self) -> None:
        import http.server
        import threading
        signal = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802 - the stdlib's name
                if signal.fired:
                    self.send_response(200)
                    self.send_header("Content-Type", "image/gif")
                    self.send_header("Content-Length", str(len(CloseSignal.GIF)))
                    self.end_headers()
                    self.wfile.write(CloseSignal.GIF)
                else:
                    self.send_error(404)

            def log_message(self, *args):
                pass

        self.fired = False
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def fire(self) -> None:
        self.fired = True

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def from_browser(texts: list[str]) -> list[str]:
    """The tool_result texts only the browser gives: a JSON result or a redacted failure
    (the helper's and the CLI's own ending texts are none of these)."""
    return [t for t in texts if t.startswith(("{", "[", "no element matched", "selector ",
                                                  "the browser could not do that", "the page has a dialog open"))]


def window_count(b) -> int | None:
    """The newest WINCOUNT row: how many windows the browser has."""
    rows = [line for line in list(b.out) if line.startswith("WINCOUNT\t")]
    return int(rows[-1].split("\t")[1]) if rows else None


def case_detach(binary: Path, tmp: Path, check) -> None:
    # #greeting is shown, so waiting for it to be hidden runs until its 10 s timeout. The
    # popup closes itself when the test fires the signal, while the call waits.
    closer = CloseSignal()
    b, fake = start(binary, tmp, "detach", {"wait-long": {"name": "mcp__zigbrowser__wait_for",
                                                          "input": {"selector": "css=#greeting", "state": "hidden",
                                                                    "timeout_ms": 10000}}})
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        b.ev(f"(window.open({json.dumps(b.url + f'#popup-close-{closer.port}')}), 1)")
        if not check(b.wait(lambda: b.rows("icon", 2) != [], 20), "window 2 has its drawer", b):
            return
        life.send(b, "wait-long", win=2)
        pid = b.browser_pid()
        if not check(b.wait(lambda: broker_threads(pid) != [], 60), f"window 2's call is running in its broker ({broker_threads(pid)})", b):
            return
        fired = time.monotonic()
        closer.fire()
        if not check(b.wait(lambda: window_count(b) == 1, 20), f"window 2 closed itself ({window_count(b)} windows)", b):
            return
        took = time.monotonic() - fired
        # Any ending text the CLI passes on comes after the close; a browser answer would be early.
        early = from_browser([result_text(block) for e in fake.api.messages_requests() for block in tool_results(e)])
        if not check(early == [], f"the call was still waiting when its window closed {took:.1f} s after the signal ({early})", b):
            return
        started = time.monotonic()
        url = (b.zb.call("page.url", {"window_id": "window-1"}) or {}).get("url", "")
        check(time.monotonic() - started < 2.0 and url == b.url, f"the browser answers within 2 s of the close ({url})")
        check(b.wait(lambda: broker_threads(pid) == [], 20), f"no broker thread is left ({broker_threads(pid)})", b)
        time.sleep(2.0)
        # The session ends with the window: the helper ends its waiting call, and the CLI may
        # pass on its own interruption text. The browser's answer (a JSON result, or a
        # redacted failure) must never come.
        late = [result_text(block) for e in fake.api.messages_requests() for block in tool_results(e)]
        check(from_browser(late) == [], f"no answer from the browser for the closed window's call ({late})")
        check(b.proc.poll() is None, "the browser is still running")
    finally:
        finish(b, fake)
        closer.close()


CASES = {
    "closure": case_closure,
    "own-window": case_own_window,
    "screenshot": case_screenshot,
    "window-fixed": case_window_fixed,
    "refused": case_refused,
    "detach": case_detach,
}


def main() -> int:
    if "--sealed-child" not in sys.argv:
        done = subprocess.run(["/usr/bin/bwrap", "--unshare-net", "--die-with-parent", "--dev-bind", "/", "/",
                               "--proc", "/proc", "--", sys.executable, str(Path(__file__).resolve()),
                               "--sealed-child", *sys.argv[1:]])
        return done.returncode
    sys.argv.remove("--sealed-child")
    from agent_common import run_main
    try:
        return run_main(__doc__, CASES)
    finally:
        for d in life.RUNTIME_DIRS:
            if str(d).startswith("/tmp/zbl-"):
                subprocess.run(["find", str(d), "-delete"], check=False)


if __name__ == "__main__":
    raise SystemExit(main())
