#!/usr/bin/env python3
"""--media-source on|off and ZIGBROWSER_MEDIA_SOURCE reach every window
(src/media_config.zig).

WebKitGTK 2.54.0's Media Source Extensions can deadlock a web process's
main thread in a seek flush (review: "Instagram media deadlock
investigation"); `off` turns MSE off for every window. WebKitGTK 2.54.0
ignores its own "enable-mediasource" setting, so this checks what pages
see, not the setting. Each case starts its own browser on its own Xvfb
display with the automation API. Window 1 opens a same-origin popup and a
cross-origin noopener popup (its own web process); every window reports
`typeof MediaSource`, whether `window.MediaSource` exists, `typeof
ManagedMediaSource`, and `typeof MediaSource` in an about:blank iframe it
makes:

- no flag, no variable: the default `on`; MSE defined everywhere; no
  media-source line on stderr
- --media-source off: undefined everywhere; stderr states it
- --media-source on: defined everywhere
- ZIGBROWSER_MEDIA_SOURCE=off: undefined everywhere
- ZIGBROWSER_MEDIA_SOURCE=off with --media-source on: the flag wins
- ZIGBROWSER_MEDIA_SOURCE=bogus: stderr warns; the default stays
- --screenshot ... --media-source off: the screenshot's page sees it too

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

ENV = "ZIGBROWSER_MEDIA_SOURCE"
# The window itself, and an about:blank iframe the page makes (a page could
# otherwise take MediaSource from there).
PROBE = ("typeof MediaSource + ',' + ('MediaSource' in window) + ',' + typeof ManagedMediaSource + ',' + "
         "(() => { const f = document.createElement('iframe'); document.body.appendChild(f); "
         "const t = typeof f.contentWindow.MediaSource; f.remove(); return t; })()")
DEFINED = "function,true,function,function"
UNDEFINED = "undefined,false,undefined,undefined"


class Pages(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - http.server API
        name = self.path.strip("/").split("?")[0] or "main"
        # The screenshot case reads the probe from the title (--print-title).
        body = (f"<!doctype html><title>{name}</title><p>{name}</p>"
                f"<script>if (location.search === '?title') document.title = 'ms=' + ({PROBE});</script>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args) -> None:
        pass


def clean_env(extra: dict[str, str]) -> dict[str, str]:
    env = isolate_profile_env(dict(os.environ))
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "ZIGBROWSER_SOCKET", ENV):
        env.pop(name, None)
    env.update(extra)
    return env


def windows_case(binary: Path, origin: str, other: str, label: str, args: list[str],
                 extra_env: dict[str, str], want: str, want_stderr: list[str], check) -> None:
    with tempfile.TemporaryDirectory(prefix="zb-media-source-e2e-") as tmp_name:
        tmp = Path(tmp_name)
        env = clean_env(extra_env)
        socket_path = tmp / "automation.sock"
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        stderr: list[str] = []
        proc = subprocess.Popen(
            xsession_prefix(True) + [str(binary.resolve()), f"{origin}/main", "--automation-api",
                                     "--profile-dir", str(tmp / "profile")] + args,
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
                def ev(window: str, expression: str):
                    return zb.call("page.evaluate", {"expression": expression, "window_id": window})["result"]

                def pages() -> dict[str, dict]:
                    return {p["window_id"]: p for p in zb.page.list()["pages"]}

                check(ev("window-1", "document.title") == "main", f"{label}: window 1 loaded")
                ev("window-1", f"(window.open('{origin}/popup'), window.open('{other}/solo', '_blank', 'noopener'), 1)")
                found: dict[str, str] = {}
                deadline = time.monotonic() + 15
                while len(found) < 2 and time.monotonic() < deadline:
                    for wid, page in pages().items():
                        for path in ("/popup", "/solo"):
                            if page.get("url", "").endswith(path):
                                found[path] = wid
                    time.sleep(0.05)
                check(len(found) == 2, f"{label}: both popups opened ({pages()})")
                for name, wid in [("window 1", "window-1")] + [(f"popup {p}", w) for p, w in sorted(found.items())]:
                    got = None
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        try:
                            got = ev(wid, PROBE)
                            break
                        except Exception as exc:  # noqa: BLE001 - still loading
                            got = f"error {exc}"
                            time.sleep(0.1)
                    check(got == want, f"{label}: {name} ({wid}) sees MediaSource as {want!r} (got {got!r})")
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            check(False, f"{label}: error={exc!r}")
        finally:
            stop_browser(proc)
        time.sleep(0.2)
        lines = [line.rstrip("\n") for line in stderr if line.startswith(("zigBrowser: media-source", f"zigBrowser: {ENV}"))]
        check(lines == want_stderr, f"{label}: stderr media-source lines {want_stderr} (got {lines})")
        if lines != want_stderr:
            eprint("browser stderr (last 30 lines):\n" + "".join(stderr[-30:]))


def screenshot_case(binary: Path, origin: str, check) -> None:
    with tempfile.TemporaryDirectory(prefix="zb-media-source-e2e-") as tmp_name:
        out = Path(tmp_name) / "shot.png"
        for flag, want in ((["--media-source", "off"], UNDEFINED), ([], DEFINED)):
            label = f"screenshot {' '.join(flag) or '(default)'}"
            try:
                done = subprocess.run(
                    xsession_prefix(True) + [str(binary.resolve()), "--screenshot", str(out), f"{origin}/shot?title",
                                             "--print-title"] + flag,
                    capture_output=True, text=True, env=clean_env({}), timeout=60,
                )
            except subprocess.TimeoutExpired:
                check(False, f"{label}: timed out")
                continue
            titles = [line.split("\t", 1)[1] for line in done.stdout.splitlines() if line.startswith("TITLE\tms=")]
            check(done.returncode == 0 and titles == [f"ms={want}"],
                  f"{label}: exit 0 and the page sees MediaSource as {want!r} (exit {done.returncode}, titles {titles}, "
                  f"stderr {done.stderr.strip()[-300:]!r})")


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
    off_line = ["zigBrowser: media-source=off"]
    try:
        windows_case(binary, origin, other, "default", [], {}, DEFINED, [], check)
        windows_case(binary, origin, other, "--media-source off", ["--media-source", "off"], {}, UNDEFINED, off_line, check)
        windows_case(binary, origin, other, "--media-source on", ["--media-source", "on"], {}, DEFINED, [], check)
        windows_case(binary, origin, other, f"{ENV}=off", [], {ENV: "off"}, UNDEFINED, off_line, check)
        windows_case(binary, origin, other, f"{ENV}=off, --media-source on", ["--media-source", "on"], {ENV: "off"},
                     DEFINED, [], check)
        windows_case(binary, origin, other, f"{ENV}=bogus", [], {ENV: "bogus"}, DEFINED,
                     [f"zigBrowser: {ENV}=bogus is not on or off; using on"], check)
        screenshot_case(binary, origin, check)
    finally:
        server.shutdown()
        server.server_close()

    if failures:
        print("FAIL\tmedia-source")
        return 1
    print("PASS\tmedia-source")
    return 0


if __name__ == "__main__":
    sys.exit(main())
