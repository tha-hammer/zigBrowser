#!/usr/bin/env python3
"""page.recover ends a frozen web process and reloads its windows, only when
a caller confirms the incident and every window at risk (watchdog slice 2;
review log, "Recovery should be a user-confirmed safety mechanism").

One browser on its own Xvfb display, with the automation API:

- window 1 (127.0.0.1/main): a "spin" button whose click runs
  `while (true) {}`, and an "ok" button whose click sets the title;
- window 2 (127.0.0.1/sib): a same-origin popup of window 1 (the same web
  process);
- window 3 (localhost/solo): a noopener popup of window 1. It has a web
  process of its own, but it was created from window 1, so the browser
  cannot rule out that they share one: it is listed at risk too.

Checks:
1. Phase 1 on a responsive window: -32602 not_unresponsive.
2. A native click on window 1's spin button (it holds window 1's queue),
   and a page.evaluate queued behind it. page.health turns window 1
   responsive:false.
3. Phase 1 on window 1: an incident token and at_risk = windows 1, 2 and 3
   with their URLs. Nothing is ended yet (all windows still listed, window
   3 still answers).
4. Phase 2 refusals, none of which ends anything: a wrong token
   (incident_unknown), an acknowledgement missing window 3 or naming an
   extra window (acknowledge_mismatch).
5. Phase 2 confirmed: windows 1 and 2 are ended and reloaded from their
   URLs; window 3, in a process of its own, is not ended (ended:false) and
   keeps its page state. The frozen process is gone, window 3's is not.
6. The click holding window 1 and the queued page.evaluate each get one
   reply, -32012 cancelled, well before their own deadlines.
7. Afterwards: windows 1 and 2 answer with fresh pages (their old
   JavaScript state is gone), page.health shows everything responsive and
   nothing crashed, a native click works in window 1, and the used token is
   refused (incident_unknown).
8. stderr names windows 1 and 2 as ended by page.recover, and nothing
   else as terminated.

Never uses the caller's DISPLAY. Exit 77 (skip) without the binary,
Xvfb or xauth."""

from __future__ import annotations

import argparse
import http.server
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "sdk/python/src"))

from slice2_common import SKIP_EXIT, eprint, isolate_profile_env, require_file, stop_browser, xsession_prefix  # noqa: E402
from zigbrowser import ZigBrowser  # noqa: E402

# WebKit's ~3 s reply deadline plus page.health's debounce, with slack.
DETECT_S = 12.0
# The frozen click's own deadline: recovery must end it long before this.
CLICK_DEADLINE_MS = 30_000

PAGE = """<!doctype html><title>{name}</title>
<button id=spin style="position:fixed;left:20px;top:20px;width:300px;height:100px"
 onclick="while (true) {{}}">spin</button>
<button id=ok style="position:fixed;left:20px;top:160px;width:300px;height:100px"
 onclick="document.title = 'clicked'">ok</button><p id=name>{name}</p>"""


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - http.server API
        name = self.path.strip("/") or "main"
        body = PAGE.format(name=name).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args) -> None:
        pass


def web_processes(pid: int) -> set[int]:
    found: set[int] = set()
    queue = [pid]
    while queue:
        parent = queue.pop()
        try:
            children = Path(f"/proc/{parent}/task/{parent}/children").read_text().split()
        except OSError:
            continue
        for child in children:
            queue.append(int(child))
            try:
                if Path(f"/proc/{child}/comm").read_text().startswith("WebKitWebProces"):
                    found.add(int(child))
            except OSError:
                pass
    return found


def error_of(fn) -> tuple[int | None, str | None]:
    """(code, reason) of the JSON-RPC error `fn` raised; (None, None) if it
    answered."""
    try:
        fn()
    except Exception as exc:  # noqa: BLE001 - the SDK raises per code range
        code = getattr(exc, "code", None)
        data = getattr(exc, "data", None) or getattr(exc, "diagnostics", None) or {}
        reason = data.get("reason") if isinstance(data, dict) else None
        if reason is None:
            reason = getattr(exc, "error_name", None)
        return code, reason
    return None, None


def run(binary: Path, origin: str, other: str, check) -> None:
    with tempfile.TemporaryDirectory(prefix="zb-page-recover-e2e-") as tmp_name:
        tmp = Path(tmp_name)
        env = isolate_profile_env(dict(os.environ))
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "ZIGBROWSER_SOCKET"):
            env.pop(name, None)
        socket_path = tmp / "automation.sock"
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        stderr: list[str] = []
        proc = subprocess.Popen(
            xsession_prefix(True) + [str(binary.resolve()), f"{origin}/main", "--automation-api",
                                     "--profile-dir", str(tmp / "profile")],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env,
        )
        threading.Thread(target=lambda: stderr.extend(proc.stderr), daemon=True).start()  # type: ignore[arg-type]
        try:
            deadline = time.monotonic() + 20
            while not socket_path.exists():
                if proc.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError(f"no automation socket (browser exit {proc.poll()})")
                time.sleep(0.05)
            with ZigBrowser(socket_path=str(socket_path)) as zb:
                checks(zb, proc, socket_path, origin, other, check)
            time.sleep(0.3)
            ended = sorted(line.rstrip() for line in stderr if "web process" in line)
            want = ["zigBrowser: window 1: web process ended by page.recover",
                    "zigBrowser: window 2: web process ended by page.recover"]
            check(ended == want, f"stderr names windows 1 and 2 as ended by page.recover, nothing else ({ended})")
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            check(False, f"error={exc!r}")
            eprint("browser stderr (last 30 lines):\n" + "".join(stderr[-30:]))
        finally:
            stop_browser(proc)


def connected(socket_path: Path) -> ZigBrowser:
    client = ZigBrowser(socket_path=str(socket_path))
    client.connect()
    return client


def checks(zb: ZigBrowser, proc: subprocess.Popen, socket_path: Path, origin: str, other: str, check) -> None:
    def ev(window: str, expression: str):
        return zb.call("page.evaluate", {"expression": expression, "window_id": window})["result"]

    def recover(params: dict) -> dict:
        return zb.call("page.recover", params)

    def health() -> dict[str, dict]:
        return {p["window_id"]: p for p in zb.call("page.health", {})["pages"]}

    def wait_title(window: str, want: str, timeout: float = 15) -> str | None:
        end = time.monotonic() + timeout
        got = None
        while time.monotonic() < end:
            try:
                got = ev(window, "document.title")
                if got == want:
                    return got
            except Exception:  # noqa: BLE001 - loading
                pass
            time.sleep(0.1)
        return got

    check(wait_title("window-1", "main") == "main", "window 1 loaded")
    ev("window-1", f"(window.__state = 'main state', window.open('{origin}/sib'), "
                   f"window.open('{other}/solo', '_blank', 'noopener'), 1)")
    deadline = time.monotonic() + 15
    by_url: dict[str, str] = {}
    while not ("sib" in by_url and "solo" in by_url) and time.monotonic() < deadline:
        time.sleep(0.05)
        by_url = {p["url"].rsplit("/", 1)[-1]: p["window_id"] for p in zb.page.list()["pages"]}
    sib, solo = by_url.get("sib"), by_url.get("solo")
    if sib is None or solo is None:
        raise TimeoutError(f"expected the sib and solo popups: {zb.page.list()}")
    check(wait_title(sib, "sib") == "sib" and wait_title(solo, "solo") == "solo", "both popups loaded")
    ev(sib, "(window.__state = 'sib state', 1)")
    ev(solo, "(window.__state = 'solo state', 1)")
    processes = web_processes(proc.pid)
    check(len(processes) == 2, f"two web processes: windows 1+2, and the solo popup ({processes})")

    # 1. Nothing to recover while the window responds.
    code, reason = error_of(lambda: recover({"window_id": "window-1"}))
    check((code, reason) == (-32602, "not_unresponsive"), f"phase 1 on a responsive window: -32602 not_unresponsive ({code}, {reason})")

    # 2. Freeze window 1 with a native click; queue a command behind it.
    replies: dict[str, tuple] = {}

    def held(name: str, method: str, params: dict) -> None:
        client = connected(socket_path)
        started = time.monotonic()
        code, reason = error_of(lambda: client.call(method, params))
        replies[name] = (code, reason, round(time.monotonic() - started, 1))

    threading.Thread(target=held, args=("click", "dom.click", {
        "selector": "css=#spin", "options": {"input": "native", "timeout_ms": CLICK_DEADLINE_MS}}), daemon=True).start()
    time.sleep(1.0)
    threading.Thread(target=held, args=("queued", "page.evaluate", {
        "expression": "1", "window_id": "window-1"}), daemon=True).start()
    frozen_by = time.monotonic() + DETECT_S
    while time.monotonic() < frozen_by and health()["window-1"]["responsive"]:
        time.sleep(0.2)
    check(health()["window-1"]["responsive"] is False, "window 1 is reported frozen")

    # 3. Phase 1: the incident and every window at risk.
    first = recover({"window_id": "window-1"})
    token = first.get("incident")
    at_risk = {w["window_id"]: w["url"] for w in first.get("at_risk", [])}
    check(isinstance(token, str) and len(token) >= 32, f"phase 1 returns an incident token ({token!r})")
    check(at_risk == {"window-1": f"{origin}/main", sib: f"{origin}/sib", solo: f"{other}/solo"},
          f"phase 1 lists windows 1, 2 and 3 with their URLs as at risk ({at_risk})")
    check(first.get("window_id") == "window-1" and first.get("unresponsive_ms", 0) >= 2000
          and 1_000 <= first.get("expires_in_ms", 0) <= 600_000, f"phase 1 says which window, how long, and when the token expires ({first})")
    check(ev(solo, "window.__state") == "solo state" and len(zb.page.list()["pages"]) == 3,
          "phase 1 ended nothing")

    # 4. Refusals end nothing.
    everyone = sorted(at_risk)
    code, reason = error_of(lambda: recover({"window_id": "window-1", "incident": "0" * 32, "acknowledge": everyone}))
    check((code, reason) == (-32602, "incident_unknown"), f"phase 2 with a wrong token: incident_unknown ({code}, {reason})")
    code, reason = error_of(lambda: recover({"window_id": "window-1", "incident": token, "acknowledge": ["window-1", sib]}))
    check((code, reason) == (-32602, "acknowledge_mismatch"), f"phase 2 without window 3 acknowledged: acknowledge_mismatch ({code}, {reason})")
    code, reason = error_of(lambda: recover({"window_id": "window-1", "incident": token, "acknowledge": everyone + ["window-9"]}))
    check((code, reason) == (-32602, "acknowledge_mismatch"), f"phase 2 with an extra window: acknowledge_mismatch ({code}, {reason})")
    check(ev(solo, "window.__state") == "solo state" and health()["window-1"]["responsive"] is False,
          "the refusals ended nothing")

    # 5. Confirmed.
    recovered_at = time.monotonic()
    second = recover({"window_id": "window-1", "incident": token, "acknowledge": list(reversed(everyone))})
    took = time.monotonic() - recovered_at
    result = {w["window_id"]: w for w in second.get("recovered", [])}
    check(took < 15, f"phase 2 returns promptly ({took:.1f} s)")
    for wid, url in (("window-1", f"{origin}/main"), (sib, f"{origin}/sib")):
        w = result.get(wid, {})
        check(w.get("ended") is True and w.get("reloaded") is True and w.get("url") == url,
              f"{wid} was ended and reloaded from {url} ({w})")
    w3 = result.get(solo, {})
    check(w3.get("ended") is False and w3.get("reloaded") is False, f"{solo}, in a process of its own, was not ended ({w3})")
    check(ev(solo, "window.__state") == "solo state", "window 3 keeps its page state")
    after = web_processes(proc.pid)
    solo_process = processes - (processes - after)
    check(len(processes - after) == 1 and len(solo_process) == 1,
          f"the frozen web process is gone; window 3's still runs (before {processes}, after {after})")

    # 6. The commands held by the frozen page get one reply each.
    end = time.monotonic() + 10
    while len(replies) < 2 and time.monotonic() < end:
        time.sleep(0.1)
    for name in ("click", "queued"):
        got = replies.get(name)
        check(got is not None and got[0] == -32012 and got[2] < CLICK_DEADLINE_MS / 1000,
              f"the {name} command on window 1 ended with -32012 cancelled before its deadline ({got})")

    # 7. Fresh pages, healthy, usable.
    check(wait_title("window-1", "main") == "main" and wait_title(sib, "sib") == "sib", "windows 1 and 2 show their pages again")
    check(ev("window-1", "typeof window.__state") == "undefined" and ev(sib, "typeof window.__state") == "undefined",
          "windows 1 and 2 are fresh pages (their old JavaScript state is gone)")
    pages = health()
    check(all(p["responsive"] and p["unresponsive_ms"] == 0 and "crashed" not in p for p in pages.values()),
          f"page.health: every window responsive, nothing crashed ({pages})")
    clicked = zb.call("dom.click", {"selector": "css=#ok", "options": {"input": "native", "timeout_ms": 10_000}})
    check(clicked.get("ok") is True and wait_title("window-1", "clicked", 5) == "clicked",
          f"a native click works in window 1 after recovery ({clicked})")
    code, reason = error_of(lambda: recover({"window_id": "window-1", "incident": token, "acknowledge": everyone}))
    check((code, reason) == (-32602, "incident_unknown"), f"the used token is refused ({code}, {reason})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    args = parser.parse_args()

    binary = Path(args.binary)
    if not require_file(binary, "binary"):
        return SKIP_EXIT
    if shutil.which("Xvfb") is None or shutil.which("xauth") is None:
        eprint("SKIP: needs Xvfb and xauth (the browser must run on its own display)")
        return SKIP_EXIT

    failures: list[str] = []

    def check(ok: bool, label: str) -> None:
        print(f"{'ok  ' if ok else 'FAIL'} {label}", flush=True)
        if not ok:
            failures.append(label)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f"http://127.0.0.1:{server.server_address[1]}"
    other = f"http://localhost:{server.server_address[1]}"  # another site: another web process
    try:
        run(binary, origin, other, check)
    finally:
        server.shutdown()
        server.server_close()

    if failures:
        print("FAIL\tpage-recover")
        return 1
    print("PASS\tpage-recover")
    return 0


if __name__ == "__main__":
    sys.exit(main())
