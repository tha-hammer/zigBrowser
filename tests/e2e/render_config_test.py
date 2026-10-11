#!/usr/bin/env python3
"""Startup rendering config reaches WebKit's web process (src/render_config.zig).

Each case starts the browser on its own Xvfb display, waits for its
WebKitWebProcess and reads that process's environment:

- no flag (the built-in default, case J): WEBKIT_DMABUF_RENDERER_FORCE_SHM=1
  reaches the web process, no Mesa EGL override, no rendering line on stderr
- the user's own WEBKIT_DMABUF_RENDERER_FORCE_SHM=0: the user's value stays
- --renderer default (opt-out): no renderer variable, and stderr states the
  effective choice
- --hardware-acceleration never (opt-out): stderr states it; the renderer
  stays shm (the policy itself is checked live in src/webkit.zig)
- --renderer mesa-egl: __EGL_VENDOR_LIBRARY_FILENAMES names Mesa's vendor
  file and FORCE_SHM is not set (skipped when that file is not installed)
- --screenshot: the same default reaches the screenshot's web process and
  the PNG is written; the same opt-out flags work there

Never uses the caller's DISPLAY. Exit 77 (skip) without the binary,
Xvfb or xauth."""

from __future__ import annotations

import argparse
import http.server
import os
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from slice2_common import SKIP_EXIT, eprint, isolate_profile_env, require_file, stop_browser, xsession_prefix

SHM = "WEBKIT_DMABUF_RENDERER_FORCE_SHM"
EGL = "__EGL_VENDOR_LIBRARY_FILENAMES"
MESA = "/usr/share/glvnd/egl_vendor.d/50_mesa.json"


def web_process_env(pid: int) -> dict[str, str] | None:
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
                if not Path(f"/proc/{child}/comm").read_text().strip().startswith("WebKitWebProces"):
                    continue
                raw = Path(f"/proc/{child}/environ").read_bytes()
            except OSError:
                continue
            pairs = (item.split(b"=", 1) for item in raw.split(b"\0") if b"=" in item)
            return {k.decode(errors="replace"): v.decode(errors="replace") for k, v in pairs}
    return None


def run_case(binary: Path, args: list[str], tmp: Path, extra_env: dict[str, str], timeout: float, exits: bool = False):
    """Starts the browser with `args`, returns (web process env or None,
    stderr lines, exit code). `exits`: the run ends by itself (a
    screenshot); otherwise it is stopped once the environment is read."""
    env = isolate_profile_env(dict(os.environ))
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "ZIGBROWSER_SOCKET", SHM, EGL):
        env.pop(name, None)
    env.update(extra_env)
    proc = subprocess.Popen(
        xsession_prefix(True) + [str(binary)] + args,
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env,
    )
    lines: list[str] = []
    reader = threading.Thread(target=lambda: lines.extend(proc.stderr), daemon=True)  # type: ignore[arg-type]
    reader.start()
    found = None
    rc = None
    try:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and proc.poll() is None:
            found = web_process_env(proc.pid)
            if found is not None:
                break
            time.sleep(0.02)
        if exits:
            rc = proc.wait(timeout=max(1.0, deadline - time.monotonic()))
        else:
            time.sleep(0.3)
    except subprocess.TimeoutExpired:
        pass
    finally:
        if proc.poll() is None:
            rc = stop_browser(proc)
        reader.join(timeout=5)
    return found, [line.rstrip("\n") for line in lines], rc


class SlowPage(http.server.BaseHTTPRequestHandler):
    """Answers after a pause, so a screenshot's web process lives long
    enough to read its environment."""

    def do_GET(self) -> None:  # noqa: N802 - http.server API
        time.sleep(1.5)
        body = b"<!doctype html><title>shot</title><p>screenshot render config</p>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args) -> None:
        pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    args = parser.parse_args()

    binary = Path(args.binary).resolve()
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

    def rendering_lines(lines: list[str]) -> list[str]:
        return [line for line in lines if "zigBrowser: rendering:" in line]

    def shm_of(env: dict[str, str] | None):
        return None if env is None else env.get(SHM, "<unset>")

    with tempfile.TemporaryDirectory(prefix="zb-render-e2e-") as tmp_name:
        tmp = Path(tmp_name)
        page = tmp / "page.html"
        page.write_text("<!doctype html><title>render</title><p>render config</p>", encoding="utf-8")
        uri = page.as_uri()
        counter = iter(range(1000))

        def open_case(flags: list[str], extra_env: dict[str, str]):
            env, lines, _ = run_case(binary, [uri, "--profile-dir", str(tmp / f"profile-{next(counter)}")] + flags,
                                     tmp, extra_env, args.timeout_sec)
            return env, lines

        env, lines = open_case([], {})
        check(env is not None, "default: a web process started")
        check(env is not None and env.get(SHM) == "1", f"default: the web process has {SHM}=1 (got {shm_of(env)!r})")
        check(env is not None and EGL not in env, "default: no Mesa EGL override reaches the web process")
        check(not rendering_lines(lines), f"default: no rendering line on stderr (got {rendering_lines(lines)})")

        env, _ = open_case([], {SHM: "0"})
        check(env is not None and env.get(SHM) == "0", f"default: the user's own {SHM}=0 stays (got {shm_of(env)!r})")

        env, lines = open_case(["--renderer", "default"], {})
        check(env is not None and SHM not in env and EGL not in env,
              f"--renderer default: no renderer variable reaches the web process (got {shm_of(env)!r})")
        check(rendering_lines(lines) == ["zigBrowser: rendering: hardware-acceleration=webkit renderer=default"],
              f"--renderer default: stderr states the effective choice (got {rendering_lines(lines)})")

        env, lines = open_case(["--hardware-acceleration", "never"], {})
        check(env is not None and env.get(SHM) == "1", f"--hardware-acceleration never: the renderer stays shm (got {shm_of(env)!r})")
        check(rendering_lines(lines) == ["zigBrowser: rendering: hardware-acceleration=never renderer=shm"],
              f"--hardware-acceleration never: stderr states it (got {rendering_lines(lines)})")

        if Path(MESA).exists():
            env, lines = open_case(["--renderer", "mesa-egl"], {})
            check(env is not None and env.get(EGL) == MESA, f"mesa-egl: the web process uses Mesa's EGL vendor (got {None if env is None else env.get(EGL)!r})")
            check(env is not None and SHM not in env, f"mesa-egl: {SHM} is not set (got {shm_of(env)!r})")
            check(rendering_lines(lines) == ["zigBrowser: rendering: hardware-acceleration=webkit renderer=mesa-egl"],
                  f"mesa-egl: stderr states it (got {rendering_lines(lines)})")
        else:
            print(f"skip mesa-egl: {MESA} is not installed", flush=True)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SlowPage)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            slow = f"http://127.0.0.1:{server.server_address[1]}/shot"
            for label, flags, want_shm, want_lines in (
                ("screenshot default", [], "1", []),
                ("screenshot opt-out", ["--renderer", "default", "--hardware-acceleration", "never"], "<unset>",
                 ["zigBrowser: rendering: hardware-acceleration=never renderer=default"]),
            ):
                out = tmp / f"shot-{next(counter)}.png"
                env, lines, rc = run_case(binary, ["--screenshot", str(out), slow] + flags, tmp, {}, args.timeout_sec, exits=True)
                check(env is not None and env.get(SHM, "<unset>") == want_shm,
                      f"{label}: the screenshot's web process has {SHM}={want_shm} (got {shm_of(env)!r})")
                check(rendering_lines(lines) == want_lines, f"{label}: rendering lines {want_lines} (got {rendering_lines(lines)})")
                png = out.read_bytes()[:8] if out.exists() else b""
                check(rc == 0 and png == b"\x89PNG\r\n\x1a\n", f"{label}: exit 0 and a PNG (rc={rc}, head={png!r})")
        finally:
            server.shutdown()
            server.server_close()

    if failures:
        print("FAIL\trender-config")
        return 1
    print("PASS\trender-config")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
