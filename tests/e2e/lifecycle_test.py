#!/usr/bin/env python3
"""Slice 3/4 M7 GTK E2E: SIGINT cancels in-flight load and exits 130 within 3 seconds."""

from __future__ import annotations

import argparse
import http.server
import signal
import subprocess
import threading
import time
from pathlib import Path

from slice2_common import (
    SKIP_EXIT,
    assert_children_exit,
    child_pids_linux,
    detect_runner,
    eprint,
    require_file,
    stop_browser,
)


class HangHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        time.sleep(self.server.delay_sec)  # type: ignore[attr-defined]

    def log_message(self, _format: str, *_args) -> None:
        return


class ThreadingHttpServer(http.server.ThreadingHTTPServer):
    daemon_threads = True


def start_server(delay_sec: float) -> tuple[ThreadingHttpServer, threading.Thread, str]:
    server = ThreadingHttpServer(("127.0.0.1", 0), HangHandler)
    server.delay_sec = delay_sec  # type: ignore[attr-defined]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    return server, thread, f"http://{host}:{port}/hang"


def read_lines(stream, sink: list[str]) -> None:
    try:
        for line in stream:
            sink.append(line.rstrip("\n"))
    finally:
        stream.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=15.0)
    parser.add_argument("--sigint-deadline-sec", type=float, default=3.0)
    parser.add_argument("--server-delay-sec", type=float, default=60.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    if not require_file(browser, "binary"):
        return SKIP_EXIT

    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    server, thread, hang_uri = start_server(args.server_delay_sec)
    try:
        cmd = prefix + [str(browser), hang_uri, "--e2e-protocol"]
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        assert proc.stdout is not None
        assert proc.stderr is not None

        stdout_lines: list[str] = []
        stderr_lines: list[str] = []
        out_thread = threading.Thread(target=read_lines, args=(proc.stdout, stdout_lines), daemon=True)
        err_thread = threading.Thread(target=read_lines, args=(proc.stderr, stderr_lines), daemon=True)
        out_thread.start()
        err_thread.start()

        tracked_children: set[int] = set()
        start_at = time.monotonic()
        sigint_at: float | None = None
        exit_at: float | None = None

        while time.monotonic() - start_at < args.timeout_sec:
            if proc.poll() is not None:
                exit_at = time.monotonic()
                break

            tracked_children.update(child_pids_linux(proc.pid))

            if sigint_at is None and time.monotonic() - start_at >= 0.5:
                proc.send_signal(signal.SIGINT)
                sigint_at = time.monotonic()

            time.sleep(0.05)

        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=8)
            except subprocess.TimeoutExpired:
                pass
        stop_browser(proc, grace_sec=0)

        if exit_at is None:
            exit_at = time.monotonic()

        out_thread.join(timeout=1)
        err_thread.join(timeout=1)

        if sigint_at is None:
            print("FAIL\tsigint-not-sent")
            eprint("stdout:\n" + "\n".join(stdout_lines))
            eprint("stderr:\n" + "\n".join(stderr_lines))
            return 1

        elapsed = exit_at - sigint_at
        ok_deadline = elapsed <= args.sigint_deadline_sec
        ok_exit = proc.returncode == 130
        ok_children, alive = assert_children_exit(tracked_children, 4.0)

        if ok_exit and ok_deadline and ok_children:
            print("PASS\tsigint-exit-130-within-3s")
            return 0

        print("FAIL\tsigint-clean-quit-or-deadline")
        eprint(f"return={proc.returncode} elapsed_after_sigint={elapsed:.3f}s")
        if not ok_children:
            eprint(f"alive_children={alive}")
        eprint("stdout:\n" + "\n".join(stdout_lines))
        eprint("stderr:\n" + "\n".join(stderr_lines))
        return 1
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)


if __name__ == "__main__":
    raise SystemExit(main())
