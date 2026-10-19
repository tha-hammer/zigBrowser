#!/usr/bin/env python3
"""MS1.2 executing-arch readback probe (plan rev 6; BlackRobin 5971).

Launches the browser with its automation socket, mints a telemetry trace, and reads the
running app's `build.exec_arch` span attribute — the arch of the slice the loader actually
chose. `tests/mac/gate.sh` runs this on each Mac and passes the value to
`mac_universal_test.py --reported-arch`, which (with `sysctl.proc_translated == 0`) rules out
an x86 process under Rosetta on the Apple-Silicon host. `lipo -archs`/`--version` alone cannot
prove this — the value must come from the running process.

Wire protocol (see sdk/python/src/zigbrowser/client.py): a Unix stream socket at
`$ZIGBROWSER_SOCKET`, 4-byte big-endian length prefix + JSON-RPC 2.0, with the per-session
token from `<socket>.token` attached as the top-level `auth` field. `telemetry.query` needs a
specific `trace_id` and there is no "newest trace" selector, so we mint one by issuing a command
that deliberately fails (a `dom.click` on an absent selector → `element_not_found`, whose error
`data.trace_id` we then query). The root span (index 0) carries `build.exec_arch`.

Stdlib only (the Mac gate runs it with plain python3). On ANY failure it writes nothing and
exits nonzero, so the gate's `--reported-arch` stays absent and MS1.2 fails closed — never a
skip-to-green. Keep it short: it opens one browser window on the logged-in screen.
"""
import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("automation socket closed mid-frame")
        buf += chunk
    return buf


def _call(sock, token, method, params, call_id):
    req = {"jsonrpc": "2.0", "method": method, "params": params, "id": call_id}
    if token:
        req["auth"] = token
    body = json.dumps(req).encode()
    sock.sendall(struct.pack(">I", len(body)) + body)
    length = struct.unpack(">I", _recv_exact(sock, 4))[0]
    return json.loads(_recv_exact(sock, length))


def _wait_for(path, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return True
        time.sleep(0.1)
    return False


def read_exec_arch(sock_path, timeout):
    """Returns the running app's build.exec_arch, or raises on any failure."""
    token_path = sock_path + ".token"
    if not _wait_for(sock_path, timeout) or not _wait_for(token_path, timeout):
        raise RuntimeError(f"automation socket/token did not appear at {sock_path}")
    with open(token_path, encoding="ascii") as fh:
        token = fh.read().strip()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(sock_path)
    try:
        # Mint a trace with a command that fails at execution (not a protocol error, which
        # carries no trace_id): a dom.click on an absent selector -> element_not_found.
        resp = _call(sock, token, "dom.click",
                     {"selector": "css=#__zb_exec_arch_probe_absent__", "options": {"timeout_ms": 500}}, 1)
        err = resp.get("error") or {}
        trace_id = (err.get("data") or {}).get("trace_id")
        if not trace_id:
            raise RuntimeError(f"probe command did not mint a trace_id; response={resp}")
        q = _call(sock, token, "telemetry.query", {"trace_id": trace_id}, 2)
        spans = (q.get("result") or {}).get("spans") or []
        if not spans:
            raise RuntimeError(f"telemetry.query returned no spans for trace {trace_id}")
        root = spans[0]
        if root.get("name") != "automation.command":
            raise RuntimeError(f"first span is not the root: {root.get('name')!r}")
        arch = (root.get("attributes") or {}).get("build.exec_arch")
        if not arch:
            raise RuntimeError("root span carries no build.exec_arch attribute "
                               "(telemetry.zig not wired, or an old build)")
        return arch
    finally:
        sock.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", required=True, help="the built browser binary")
    ap.add_argument("--out", required=True, help="file to write the reported arch into (only on success)")
    ap.add_argument("--url", default="about:blank", help="page to load before the probe command")
    ap.add_argument("--timeout", type=float, default=30.0)
    args = ap.parse_args()

    # Never leave a stale value: the gate's fail-closed depends on the file being absent on failure.
    try:
        os.unlink(args.out)
    except FileNotFoundError:
        pass

    tmp = tempfile.mkdtemp(prefix="zb-exec-arch-")
    sock_path = os.path.join(tmp, "automation.sock")
    env = dict(os.environ)
    env["ZIGBROWSER_SOCKET"] = sock_path
    proc = subprocess.Popen([args.browser, args.url, "--automation-api"], env=env)
    try:
        arch = read_exec_arch(sock_path, args.timeout)
    except Exception as exc:  # noqa: BLE001 - any failure is fail-closed (write nothing)
        print(f"exec_arch_probe: FAIL ({exc})", file=sys.stderr)
        return 2
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        for name in ("automation.sock", "automation.sock.token"):
            try:
                os.unlink(os.path.join(tmp, name))
            except OSError:
                pass
        try:
            os.rmdir(tmp)
        except OSError:
            pass

    with open(args.out, "w", encoding="ascii") as fh:
        fh.write(arch + "\n")
    print(f"exec_arch_probe: build.exec_arch={arch}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
