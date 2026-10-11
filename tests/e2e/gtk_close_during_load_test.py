#!/usr/bin/env python3
"""GTK E2E: closing a window during an in-flight load cancels and exits cleanly."""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import http.server
import os
import signal
import socket
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
    protocol_rows,
    require_file,
    stop_browser,
)


class HangingResponseHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802
        server: HangingHttpServer = self.server  # type: ignore[assignment]
        server.request_started.set()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(b"<!doctype html><html><head><title>Partial Load")
            self.wfile.flush()
            while not server.stop_response.is_set():
                try:
                    self.wfile.write(b" ")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, OSError):
                    server.client_disconnected.set()
                    return
                time.sleep(0.1)
        finally:
            server.handler_done.set()

    def log_message(self, _format: str, *_args) -> None:
        return


class HangingHttpServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), HangingResponseHandler)
        self.request_started = threading.Event()
        self.client_disconnected = threading.Event()
        self.handler_done = threading.Event()
        self.stop_response = threading.Event()


class XClientMessageEvent(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int),
        ("serial", ctypes.c_ulong),
        ("send_event", ctypes.c_int),
        ("display", ctypes.c_void_p),
        ("window", ctypes.c_ulong),
        ("message_type", ctypes.c_ulong),
        ("format", ctypes.c_int),
        ("data", ctypes.c_long * 5),
    ]


class XEvent(ctypes.Union):
    _fields_ = [("xclient", XClientMessageEvent), ("pad", ctypes.c_long * 24)]


class XWindowAttributes(ctypes.Structure):
    _fields_ = [
        ("x", ctypes.c_int),
        ("y", ctypes.c_int),
        ("width", ctypes.c_int),
        ("height", ctypes.c_int),
        ("border_width", ctypes.c_int),
        ("depth", ctypes.c_int),
        ("visual", ctypes.c_void_p),
        ("root", ctypes.c_ulong),
        ("class", ctypes.c_int),
        ("bit_gravity", ctypes.c_int),
        ("win_gravity", ctypes.c_int),
        ("backing_store", ctypes.c_int),
        ("backing_planes", ctypes.c_ulong),
        ("backing_pixel", ctypes.c_ulong),
        ("save_under", ctypes.c_int),
        ("colormap", ctypes.c_ulong),
        ("map_installed", ctypes.c_int),
        ("map_state", ctypes.c_int),
        ("all_event_masks", ctypes.c_long),
        ("your_event_mask", ctypes.c_long),
        ("do_not_propagate_mask", ctypes.c_long),
        ("override_redirect", ctypes.c_int),
        ("screen", ctypes.c_void_p),
    ]


class X11Client:
    ClientMessage = 33
    SubstructureRedirectMask = 1 << 20
    SubstructureNotifyMask = 1 << 19

    def __init__(self, display_name: str | None) -> None:
        lib_name = ctypes.util.find_library("X11")
        if lib_name is None:
            raise RuntimeError("libX11 not found")
        self.x11 = ctypes.CDLL(lib_name)
        self._configure_prototypes()
        encoded = display_name.encode() if display_name else None
        self.display = self.x11.XOpenDisplay(encoded)
        if not self.display:
            raise RuntimeError(f"cannot open X display {display_name!r}")
        self.root = self.x11.XDefaultRootWindow(self.display)
        self.atom_wm_delete = self.intern("WM_DELETE_WINDOW")
        self.atom_wm_protocols = self.intern("WM_PROTOCOLS")
        self.atom_net_wm_pid = self.intern("_NET_WM_PID")
        self.atom_wm_name = self.intern("WM_NAME")

    def close(self) -> None:
        if self.display:
            self.x11.XCloseDisplay(self.display)
            self.display = None

    def _configure_prototypes(self) -> None:
        self.x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x11.XOpenDisplay.restype = ctypes.c_void_p
        self.x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        self.x11.XDefaultRootWindow.restype = ctypes.c_ulong
        self.x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        self.x11.XInternAtom.restype = ctypes.c_ulong
        self.x11.XQueryTree.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)),
            ctypes.POINTER(ctypes.c_uint),
        ]
        self.x11.XQueryTree.restype = ctypes.c_int
        self.x11.XFree.argtypes = [ctypes.c_void_p]
        self.x11.XGetWindowProperty.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_long,
            ctypes.c_long,
            ctypes.c_int,
            ctypes.c_ulong,
            ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte)),
        ]
        self.x11.XGetWindowProperty.restype = ctypes.c_int
        self.x11.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.POINTER(XEvent)]
        self.x11.XSendEvent.restype = ctypes.c_int
        self.x11.XFlush.argtypes = [ctypes.c_void_p]
        self.x11.XGetWindowAttributes.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.POINTER(XWindowAttributes),
        ]
        self.x11.XGetWindowAttributes.restype = ctypes.c_int

    def intern(self, name: str) -> int:
        return int(self.x11.XInternAtom(self.display, name.encode(), 0))

    def children(self, window: int) -> list[int]:
        root = ctypes.c_ulong()
        parent = ctypes.c_ulong()
        children = ctypes.POINTER(ctypes.c_ulong)()
        count = ctypes.c_uint()
        ok = self.x11.XQueryTree(self.display, window, ctypes.byref(root), ctypes.byref(parent), ctypes.byref(children), ctypes.byref(count))
        if ok == 0:
            return []
        try:
            return [int(children[i]) for i in range(count.value)]
        finally:
            if children:
                self.x11.XFree(children)

    def get_property_bytes(self, window: int, atom: int, max_items: int = 1024) -> bytes | None:
        actual_type = ctypes.c_ulong()
        actual_format = ctypes.c_int()
        nitems = ctypes.c_ulong()
        bytes_after = ctypes.c_ulong()
        prop = ctypes.POINTER(ctypes.c_ubyte)()
        status = self.x11.XGetWindowProperty(
            self.display,
            window,
            atom,
            0,
            max_items,
            0,
            0,
            ctypes.byref(actual_type),
            ctypes.byref(actual_format),
            ctypes.byref(nitems),
            ctypes.byref(bytes_after),
            ctypes.byref(prop),
        )
        if status != 0 or not prop or nitems.value == 0:
            return None
        try:
            byte_len = nitems.value * max(actual_format.value // 8, 1)
            return ctypes.string_at(prop, byte_len)
        finally:
            self.x11.XFree(prop)

    def window_pid(self, window: int) -> int | None:
        raw = self.get_property_bytes(window, self.atom_net_wm_pid, 1)
        if not raw or len(raw) < 4:
            return None
        return int.from_bytes(raw[:4], byteorder="little", signed=False)

    def window_name(self, window: int) -> str:
        raw = self.get_property_bytes(window, self.atom_wm_name, 256)
        if not raw:
            return ""
        return raw.split(b"\0", 1)[0].decode("utf-8", errors="replace")

    def window_attributes(self, window: int) -> XWindowAttributes | None:
        attrs = XWindowAttributes()
        ok = self.x11.XGetWindowAttributes(self.display, window, ctypes.byref(attrs))
        return attrs if ok != 0 else None

    def walk_windows(self) -> list[int]:
        found: list[int] = []
        stack = [self.root]
        while stack:
            window = stack.pop()
            kids = self.children(window)
            found.extend(kids)
            stack.extend(kids)
        return found

    def find_browser_window(self, pid: int, timeout_sec: float) -> int | None:
        deadline = time.monotonic() + timeout_sec
        while time.monotonic() < deadline:
            candidates: list[tuple[int, int]] = []
            for window in self.walk_windows():
                if self.window_pid(window) != pid and self.window_name(window) != "zigBrowser":
                    continue
                attrs = self.window_attributes(window)
                if attrs is None or attrs.map_state == 0:
                    continue
                area = int(attrs.width) * int(attrs.height)
                candidates.append((area, window))
            if candidates:
                candidates.sort(reverse=True)
                return candidates[0][1]
            time.sleep(0.05)
        return None

    def send_wm_delete(self, window: int) -> bool:
        event = XEvent()
        event.xclient.type = self.ClientMessage
        event.xclient.serial = 0
        event.xclient.send_event = 1
        event.xclient.display = self.display
        event.xclient.window = window
        event.xclient.message_type = self.atom_wm_protocols
        event.xclient.format = 32
        event.xclient.data[0] = self.atom_wm_delete
        event.xclient.data[1] = 0
        ok = self.x11.XSendEvent(
            self.display,
            window,
            0,
            0,
            ctypes.byref(event),
        )
        self.x11.XFlush(self.display)
        return ok != 0


def wait_for_exit(proc: subprocess.Popen[str], timeout_sec: float) -> bool:
    try:
        proc.wait(timeout=timeout_sec)
        return True
    except subprocess.TimeoutExpired:
        return False


def print_context(label: str, proc: subprocess.Popen[str], stdout_lines: list[str], stderr_lines: list[str], extra: str = "") -> None:
    print(f"FAIL\t{label}")
    eprint(f"return={proc.returncode} {extra}".strip())
    eprint("stdout:\n" + "\n".join(stdout_lines))
    eprint("stderr:\n" + "\n".join(stderr_lines))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=15.0)
    parser.add_argument("--close-deadline-sec", type=float, default=3.0)
    parser.add_argument("--window-timeout-sec", type=float, default=5.0)
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

    server = HangingHttpServer()
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    host, port = server.server_address
    uri = f"http://{host}:{port}/slow"

    proc: subprocess.Popen[str] | None = None
    x11: X11Client | None = None
    try:
        cmd = prefix + [str(browser), uri, "--e2e-protocol"]
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        assert proc.stdout is not None
        assert proc.stderr is not None

        stdout_lines: list[str] = []
        stderr_lines: list[str] = []
        out_thread = threading.Thread(target=lambda: [stdout_lines.append(line.rstrip("\n")) for line in proc.stdout], daemon=True)
        err_thread = threading.Thread(target=lambda: [stderr_lines.append(line.rstrip("\n")) for line in proc.stderr], daemon=True)
        out_thread.start()
        err_thread.start()

        if not server.request_started.wait(timeout=args.timeout_sec):
            print_context("server-request-not-started", proc, stdout_lines, stderr_lines)
            return 1

        tracked_children = child_pids_linux(proc.pid)
        try:
            x11 = X11Client(env.get("DISPLAY"))
        except RuntimeError as err:
            eprint(f"SKIP: {err}")
            return SKIP_EXIT

        window = x11.find_browser_window(proc.pid, args.window_timeout_sec)
        if window is None:
            print_context("browser-window-not-found", proc, stdout_lines, stderr_lines)
            return 1

        close_at = time.monotonic()
        if not x11.send_wm_delete(window):
            print_context("wm-delete-send-failed", proc, stdout_lines, stderr_lines)
            return 1

        exited = wait_for_exit(proc, args.close_deadline_sec)
        exit_elapsed = time.monotonic() - close_at
        out_thread.join(timeout=1)
        err_thread.join(timeout=1)
        tracked_children.update(child_pids_linux(proc.pid))

        ok_exit = exited and proc.returncode == 130
        ok_deadline = exited and exit_elapsed <= args.close_deadline_sec
        ok_cancel = server.client_disconnected.wait(timeout=1.0)
        ok_no_success = not protocol_rows(stdout_lines, "NAV")
        ok_children, alive = assert_children_exit(tracked_children, 4.0)

        if ok_exit and ok_deadline and ok_cancel and ok_no_success and ok_children:
            print("PASS\tgtk-close-during-load-cancels")
            return 0

        extra = (
            f"elapsed={exit_elapsed:.3f}s cancel_seen={ok_cancel} "
            f"nav_rows={protocol_rows(stdout_lines, 'NAV')} alive_children={alive}"
        )
        print_context("gtk-close-during-load-clean-cancel", proc, stdout_lines, stderr_lines, extra)
        return 1
    finally:
        server.stop_response.set()
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=1)
        if x11 is not None:
            x11.close()
        if proc is not None:
            if proc.poll() is None:
                proc.send_signal(signal.SIGTERM)
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
            stop_browser(proc, grace_sec=0)


if __name__ == "__main__":
    raise SystemExit(main())
