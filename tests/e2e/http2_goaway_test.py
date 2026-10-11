#!/usr/bin/env python3
"""Real-binary E2E: an HTTP/2 response followed by GOAWAY(NO_ERROR) must not fail the page's fetch.

libsoup 3.6.5 (WebKitGTK 2.52.6) marks a stream that already completed as
"interrupted" when the server's GOAWAY(NO_ERROR) arrives in the same read, and
the page's fetch() rejects with "TypeError: Load failed". Live effect: X login's
anti-fraud call to edge.prelude.dev failed. zigBrowser therefore sets
SOUP_FORCE_HTTP1=1 at startup, unless the user exported SOUP_FORCE_HTTP1
(kept as is) or ZIGBROWSER_HTTP2=1 (opt-out).

Everything is local. A standard-library TLS server on 127.0.0.1 answers each
HTTP/2 stream completely and sends GOAWAY in the same write; over HTTP/1.1 it
answers normally. Its self-signed certificate is trusted only inside the
browser processes this test starts: a tiny LD_PRELOAD library (built here with
gcc) replaces GnuTLS's system trust store with that one certificate.
The ZIGBROWSER_HTTP2=1 run is the control: it must reproduce the failure,
otherwise the passing runs prove nothing.

Every browser runs on its own Xvfb display (never the user's DISPLAY).
"""

from __future__ import annotations

import argparse
import os
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from slice2_common import SKIP_EXIT, eprint, isolate_profile_env, require_file, stop_browser, xsession_prefix

PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
DATA, HEADERS, SETTINGS, PING, GOAWAY = 0x0, 0x1, 0x4, 0x6, 0x7
BODY = b'{"ok":true}'

TRUST_PRELOAD_C = r"""
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
typedef struct gnutls_x509_trust_list_st *trust_list_t;
typedef int (*add_file_fn)(trust_list_t, const char *, const char *, int, unsigned int, unsigned int);
/* GIO's TLS module loads GnuTLS privately, so RTLD_NEXT cannot see it: ask for the loaded copy. */
int gnutls_x509_trust_list_add_system_trust(trust_list_t list, unsigned int tl_flags, unsigned int tl_vflags) {
  void *gnutls = dlopen("libgnutls.so.30", RTLD_NOW | RTLD_NOLOAD);
  add_file_fn add = gnutls == NULL ? NULL : (add_file_fn)dlsym(gnutls, "gnutls_x509_trust_list_add_trust_file");
  const char *ca = getenv("ZB_TEST_CA_FILE");
  return (ca != NULL && add != NULL) ? add(list, ca, NULL, 1 /* PEM */, tl_flags, tl_vflags) : -1;
}
"""


def frame(ftype: int, flags: int, stream: int, payload: bytes = b"") -> bytes:
    return struct.pack(">I", len(payload))[1:] + bytes([ftype, flags]) + struct.pack(">I", stream) + payload


def read_exact(conn: ssl.SSLSocket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def hpack_literal(index: int, value: bytes) -> bytes:
    """Literal header field without indexing, static-table name, raw value (< 127 bytes)."""
    prefix = bytes([index]) if index < 15 else bytes([0x0F, index - 15])
    return prefix + bytes([len(value)]) + value


class GoawayServer:
    """TLS on 127.0.0.1: HTTP/2 streams get HEADERS + DATA(END_STREAM) + GOAWAY(NO_ERROR) in one write."""

    def __init__(self, cert: Path, key: Path) -> None:
        self.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ctx.load_cert_chain(str(cert), str(key))
        self.ctx.set_alpn_protocols(["h2", "http/1.1"])
        self.sock = socket.create_server(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]
        self.lock = threading.Lock()
        self.answered: list[str] = []  # "h2" or "http/1.1", one per answered request
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self) -> None:
        while True:
            try:
                raw, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(raw,), daemon=True).start()

    def _handle(self, raw: socket.socket) -> None:
        try:
            with self.ctx.wrap_socket(raw, server_side=True) as conn:
                conn.settimeout(10)
                proto = self._serve_h2(conn) if conn.selected_alpn_protocol() == "h2" else self._serve_h1(conn)
                if proto:
                    with self.lock:
                        self.answered.append(proto)
        except (OSError, ssl.SSLError, EOFError):
            pass

    def _serve_h2(self, conn: ssl.SSLSocket) -> str | None:
        if read_exact(conn, len(PREFACE)) != PREFACE:
            return None
        conn.sendall(frame(SETTINGS, 0, 0))
        while True:
            head = read_exact(conn, 9)
            length, ftype, flags = int.from_bytes(head[:3], "big"), head[3], head[4]
            stream = struct.unpack(">I", head[5:9])[0] & 0x7FFFFFFF
            payload = read_exact(conn, length)
            if ftype == SETTINGS and not flags & 0x1:
                conn.sendall(frame(SETTINGS, 0x1, 0))
            elif ftype == PING and not flags & 0x1:
                conn.sendall(frame(PING, 0x1, 0, payload))
            elif ftype == HEADERS:
                # :status 200 (static 8), content-type (31), content-length (28).
                block = b"\x88" + hpack_literal(31, b"application/json") + hpack_literal(28, str(len(BODY)).encode())
                conn.sendall(
                    frame(HEADERS, 0x4, stream, block)
                    + frame(DATA, 0x1, stream, BODY)
                    + frame(GOAWAY, 0, 0, struct.pack(">II", stream, 0))
                )
                return "h2"

    def _serve_h1(self, conn: ssl.SSLSocket) -> str | None:
        req = b""
        while b"\r\n\r\n" not in req:
            chunk = conn.recv(4096)
            if not chunk:
                return None
            req += chunk
        conn.sendall(
            b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
            % len(BODY)
            + BODY
        )
        return "http/1.1"

    def answered_since(self, start: int) -> list[str]:
        with self.lock:
            return self.answered[start:]

    def count(self) -> int:
        with self.lock:
            return len(self.answered)

    def close(self) -> None:
        self.sock.close()


class HoldServer:
    """Plain HTTP on 127.0.0.1. /hold?run=N answers only after /release?run=N (or 20 s), so the
    page's load event, and with it the title the browser prints, waits for the fetch to settle."""

    def __init__(self) -> None:
        events: dict[str, threading.Event] = {}
        lock = threading.Lock()

        def event_for(run: str) -> threading.Event:
            with lock:
                return events.setdefault(run, threading.Event())

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                path, _, query = self.path.partition("?")
                run = query.partition("run=")[2]
                if path == "/hold":
                    event_for(run).wait(20)
                elif path == "/release":
                    event_for(run).set()
                self.send_response(204)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *args: object) -> None:
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


def write_page(work: Path, run: str, h2_port: int, hold_port: int) -> str:
    page = work / f"fetch-{run}.html"
    page.write_text(
        f"""<!doctype html><title>fetching</title>
<script>
fetch("https://localhost:{h2_port}/v1/signals", {{mode: "no-cors"}})
  .then(r => r.text().then(() => "ok " + r.type), e => "fail " + e)
  .then(r => {{ document.title = r; new Image().src = "http://127.0.0.1:{hold_port}/release?run={run}"; }});
</script>
<img src="http://127.0.0.1:{hold_port}/hold?run={run}">
""",
        encoding="utf-8",
    )
    return page.resolve().as_uri()


def descendants(pid: int) -> list[int]:
    parents: dict[int, int] = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            stat = Path(f"/proc/{entry}/stat").read_text()
        except OSError:
            continue
        parents[int(entry)] = int(stat.rsplit(")", 1)[1].split()[1])
    found, frontier = [], [pid]
    while frontier:
        parent = frontier.pop()
        for child, ppid in parents.items():
            if ppid == parent:
                found.append(child)
                frontier.append(child)
    return found


def network_process_env(pid: int) -> dict[str, str] | None:
    for child in descendants(pid):
        try:
            argv0 = Path(f"/proc/{child}/cmdline").read_bytes().split(b"\0", 1)[0]
            if not argv0.endswith(b"WebKitNetworkProcess"):
                continue
            raw = Path(f"/proc/{child}/environ").read_bytes()
        except OSError:
            continue
        pairs = (item.split(b"=", 1) for item in raw.split(b"\0") if b"=" in item)
        return {k.decode(errors="replace"): v.decode(errors="replace") for k, v in pairs}
    return None


def run_open(cmd: list[str], env: dict[str, str], timeout: float) -> tuple[str | None, dict[str, str] | None, str]:
    """Run the browser until it prints the page's final title; return (title, network env, log)."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    lines: list[str] = []
    reader = threading.Thread(target=lambda: lines.extend(proc.stdout), daemon=True)  # type: ignore[arg-type]
    reader.start()
    title, net_env = None, None
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and proc.poll() is None:
        titles = [l.rstrip("\n").split("\t", 1)[1] for l in list(lines) if l.startswith("TITLE\t")]
        final = [t for t in titles if t != "fetching"]
        if final:
            title = final[0]
            net_env = network_process_env(proc.pid)
            break
        time.sleep(0.05)
    for child in reversed(descendants(proc.pid)):
        try:
            os.kill(child, 15)
        except OSError:
            pass
    stop_browser(proc, grace_sec=10)
    reader.join(timeout=2)
    return title, net_env, "".join(lines[-30:])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=40.0)
    args = parser.parse_args()

    if not sys.platform.startswith("linux"):
        eprint("SKIP: the libsoup HTTP/2 workaround is Linux-only")
        return SKIP_EXIT
    binary = Path(args.binary).resolve()
    if not require_file(binary, "zigBrowser binary"):
        return SKIP_EXIT
    tools = {name: shutil.which(name) for name in ("Xvfb", "xauth", "gcc", "openssl")}
    missing = [name for name, path in tools.items() if path is None]
    if missing:
        eprint(f"SKIP: needs {', '.join(missing)} (the browser must run on its own Xvfb display)")
        return SKIP_EXIT

    work = Path(tempfile.mkdtemp(prefix="zb-http2-goaway-"))
    servers: list = []
    try:
        cert, key, preload = work / "cert.pem", work / "key.pem", work / "trust_preload.so"
        subprocess.run(
            [tools["openssl"], "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
             "-nodes", "-days", "2", "-subj", "/CN=localhost",
             "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
             "-keyout", str(key), "-out", str(cert)],
            check=True, capture_output=True,
        )
        (work / "trust_preload.c").write_text(TRUST_PRELOAD_C, encoding="utf-8")
        subprocess.run([tools["gcc"], "-shared", "-fPIC", "-O2", "-o", str(preload), str(work / "trust_preload.c"), "-ldl"],
                       check=True, capture_output=True)

        h2 = GoawayServer(cert, key)
        hold = HoldServer()
        servers = [h2, hold]

        base_env = isolate_profile_env(dict(os.environ))
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "SOUP_FORCE_HTTP1", "ZIGBROWSER_HTTP2", "ZIGBROWSER_SOCKET"):
            base_env.pop(name, None)
        base_env["LD_PRELOAD"] = str(preload)
        base_env["ZB_TEST_CA_FILE"] = str(cert)
        xvfb = xsession_prefix(True)

        failures: list[str] = []

        def check(ok: bool, label: str, detail: str = "") -> None:
            print(f"{'ok  ' if ok else 'FAIL'} {label}", flush=True)
            if not ok:
                failures.append(label)
                if detail:
                    eprint(detail)

        cases = [
            # (run id, extra env, expected title, expected protocol, expected SOUP_FORCE_HTTP1 in the network process)
            ("control", {"ZIGBROWSER_HTTP2": "1"}, "fail TypeError: Load failed", "h2", None),
            ("default", {}, "ok opaque", "http/1.1", "1"),
            ("user-value", {"SOUP_FORCE_HTTP1": "user-set"}, None, None, "user-set"),
        ]
        for run, extra, want_title, want_proto, want_force in cases:
            uri = write_page(work, run, h2.port, hold.port)
            env = dict(base_env, **extra)
            start = h2.count()
            title, net_env, log = run_open(
                xvfb + [str(binary), uri, "--print-title", "--profile-dir", str(work / f"profile-{run}")],
                env, args.timeout_sec)
            answered = h2.answered_since(start)
            if want_title is not None:
                check(title == want_title, f"open/{run}: page fetch gives {want_title!r} (got {title!r})", log)
            else:
                check(title is not None, f"open/{run}: page fetch settles (got {title!r})", log)
            if want_proto is not None:
                check(answered == [want_proto], f"open/{run}: server answered over {want_proto} (got {answered})")
            got_force = None if net_env is None else net_env.get("SOUP_FORCE_HTTP1")
            check(net_env is not None and got_force == want_force,
                  f"open/{run}: network process SOUP_FORCE_HTTP1 is {want_force!r} (got {got_force!r})")

        # The screenshot path starts its own network process: the same default applies there.
        uri = write_page(work, "screenshot", h2.port, hold.port)
        start = h2.count()
        shot = subprocess.run(
            xvfb + [str(binary), "--screenshot", str(work / "shot.png"), uri, "--print-title"],
            env=base_env, capture_output=True, text=True, timeout=args.timeout_sec + 20,
        )
        titles = [l.split("\t", 1)[1] for l in shot.stdout.splitlines() if l.startswith("TITLE\t")]
        check(shot.returncode == 0 and titles == ["ok opaque"],
              f"screenshot/default: page fetch gives 'ok opaque' (rc={shot.returncode}, titles={titles})",
              shot.stderr[-2000:])
        answered = h2.answered_since(start)
        check(answered == ["http/1.1"], f"screenshot/default: server answered over http/1.1 (got {answered})")

        if failures:
            eprint(f"FAIL: {len(failures)} check(s) failed")
            if any(f.startswith("open/control") for f in failures):
                eprint("The control did not reproduce the libsoup GOAWAY failure: if libsoup is fixed, "
                       "reconsider the SOUP_FORCE_HTTP1 default (src/webkit.zig preferHttp1).")
            return 1
        print("PASS: http2 GOAWAY e2e", flush=True)
        return 0
    finally:
        for server in servers:
            server.close()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
