#!/usr/bin/env python3
"""Startup rendering config reaches WebKit's web process (src/render_config.zig).

Each case starts the browser on its own Xvfb display, waits for its
WebKitWebProcess and reads that process's environment:

- no flag: neither renderer variable is set (today's default), no
  rendering line on stderr
- --renderer shm: WEBKIT_DMABUF_RENDERER_FORCE_SHM=1, and stderr states
  the effective choice
- --renderer shm with the user's own WEBKIT_DMABUF_RENDERER_FORCE_SHM=0:
  the user's value stays
- --renderer mesa-egl: __EGL_VENDOR_LIBRARY_FILENAMES names Mesa's vendor
  file (skipped when that file is not installed)
- --hardware-acceleration webkit: stderr states it (the policy itself is
  checked live in src/webkit.zig)

Never uses the caller's DISPLAY. Exit 77 (skip) without the binary,
Xvfb or xauth."""

from __future__ import annotations

import argparse
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


def run_case(binary: Path, page: str, tmp: Path, flags: list[str], extra_env: dict[str, str], timeout: float):
    env = isolate_profile_env(dict(os.environ))
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "ZIGBROWSER_SOCKET", SHM, EGL):
        env.pop(name, None)
    env.update(extra_env)
    proc = subprocess.Popen(
        xsession_prefix(True) + [str(binary), page, "--profile-dir", str(tmp / f"profile-{len(list(tmp.iterdir()))}")] + flags,
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env,
    )
    lines: list[str] = []
    threading.Thread(target=lambda: lines.extend(proc.stderr), daemon=True).start()  # type: ignore[arg-type]
    found = None
    try:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and proc.poll() is None:
            found = web_process_env(proc.pid)
            if found is not None:
                break
            time.sleep(0.1)
        time.sleep(0.3)
    finally:
        stop_browser(proc)
    return found, [line.rstrip("\n") for line in lines]


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

    with tempfile.TemporaryDirectory(prefix="zb-render-e2e-") as tmp_name:
        tmp = Path(tmp_name)
        page = tmp / "page.html"
        page.write_text("<!doctype html><title>render</title><p>render config</p>", encoding="utf-8")
        uri = page.as_uri()

        env, lines = run_case(binary, uri, tmp, [], {}, args.timeout_sec)
        check(env is not None, "default: a web process started")
        check(env is not None and SHM not in env and EGL not in env, "default: no renderer variable reaches the web process")
        check(not rendering_lines(lines), f"default: no rendering line on stderr (got {rendering_lines(lines)})")

        env, lines = run_case(binary, uri, tmp, ["--renderer", "shm"], {}, args.timeout_sec)
        check(env is not None and env.get(SHM) == "1", f"shm: the web process has {SHM}=1 (got {None if env is None else env.get(SHM)!r})")
        check(rendering_lines(lines) == ["zigBrowser: rendering: hardware-acceleration=never renderer=shm"],
              f"shm: stderr states the effective choice (got {rendering_lines(lines)})")

        env, _ = run_case(binary, uri, tmp, ["--renderer", "shm"], {SHM: "0"}, args.timeout_sec)
        check(env is not None and env.get(SHM) == "0", f"shm: the user's own {SHM}=0 stays (got {None if env is None else env.get(SHM)!r})")

        if Path(MESA).exists():
            env, _ = run_case(binary, uri, tmp, ["--renderer", "mesa-egl"], {}, args.timeout_sec)
            check(env is not None and env.get(EGL) == MESA, f"mesa-egl: the web process uses Mesa's EGL vendor (got {None if env is None else env.get(EGL)!r})")
        else:
            print(f"skip mesa-egl: {MESA} is not installed", flush=True)

        _, lines = run_case(binary, uri, tmp, ["--hardware-acceleration", "webkit"], {}, args.timeout_sec)
        check(rendering_lines(lines) == ["zigBrowser: rendering: hardware-acceleration=webkit renderer=default"],
              f"webkit policy: stderr states it (got {rendering_lines(lines)})")

    if failures:
        print("FAIL\trender-config")
        return 1
    print("PASS\trender-config")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
