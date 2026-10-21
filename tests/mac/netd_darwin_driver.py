"""Both-Mac half of macOS netd (BlueBeaver 6971): runs netd.py natively (sys.platform == "darwin") with the system
python3 and checks, against a private fake upstream on 127.0.0.1:
 1. the only stdout line is exactly `netd ready 127.0.0.1:<port>`;
 2. lsof shows netd holding exactly one listening TCP socket, 127.0.0.1:<port>;
 3. CONNECT to the allowed test name is 200 and its ClientHello reaches the fake byte for byte;
 4. CONNECT to any other name is 403 and netd makes no upstream attempt for it;
 5. EOF on stdin exits 0 within 5 s and the port then refuses connections.
Run by tests/mac/ms6_netd_darwin_gate.sh with netd.py next to this file."""
import os
import re
import socket
import ssl
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FAKE = "fake.zb.invalid"
failures = []


def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        failures.append(what)


def client_hello(name):
    ctx = ssl.create_default_context()
    incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
    obj = ctx.wrap_bio(incoming, outgoing, server_hostname=name)
    try:
        obj.do_handshake()
    except ssl.SSLWantReadError:
        pass
    return outgoing.read()


def head(sock):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    return data


def main():
    fake = socket.create_server(("127.0.0.1", 0))
    received = bytearray()

    def serve():
        conn, _ = fake.accept()
        with conn:
            conn.settimeout(10)
            try:
                while chunk := conn.recv(65536):
                    received.extend(chunk)
            except OSError:
                pass
    threading.Thread(target=serve, daemon=True).start()

    env = {"PATH": "/usr/bin:/bin", "LANG": "C"}
    netd = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "netd.py"), "--test-record-connects",
                             "--test-allow", f"{FAKE}={fake.getsockname()[1]}"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
    err = []
    threading.Thread(target=lambda: err.extend(netd.stderr), daemon=True).start()
    try:
        line = netd.stdout.readline().rstrip("\n")
        m = re.fullmatch(r"netd ready 127\.0\.0\.1:([1-9][0-9]{0,4})", line)
        check(m is not None and int(m.group(1)) <= 65535, f"ready line is exact ({line!r})")
        if m is None:
            return 1
        port = int(m.group(1))
        lsof = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(netd.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"],
                              capture_output=True, text=True).stdout
        names = [l[1:] for l in lsof.splitlines() if l.startswith("n")]
        check(names == [f"127.0.0.1:{port}"], f"exactly one listener, on 127.0.0.1 ({names})")

        s = socket.create_connection(("127.0.0.1", port), timeout=10)
        s.sendall(f"CONNECT {FAKE}:443 HTTP/1.1\r\nHost: {FAKE}:443\r\n\r\n".encode())
        check(head(s).startswith(b"HTTP/1.1 200 "), "allowed name: 200")
        hello = client_hello(FAKE)
        s.sendall(hello)
        s.shutdown(socket.SHUT_WR)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and bytes(received) != hello:
            time.sleep(0.05)
        check(bytes(received) == hello, "allowed name: the ClientHello reached the upstream byte for byte")
        s.close()

        s = socket.create_connection(("127.0.0.1", port), timeout=10)
        s.sendall(b"CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        check(head(s).startswith(b"HTTP/1.1 403 "), "another name: 403")
        s.close()
        time.sleep(0.3)
        attempts = [l for l in err if "netd test-connect" in l]
        check(len(attempts) == 1 and "127.0.0.1" in attempts[0], f"only the allowed name was dialled ({attempts})")

        netd.stdin.close()
        try:
            code = netd.wait(timeout=5)
        except subprocess.TimeoutExpired:
            code = None
        check(code == 0, f"EOF on stdin exits 0 ({code})")
        try:
            socket.create_connection(("127.0.0.1", port), timeout=3).close()
            check(False, "the port refuses connections after exit")
        except ConnectionRefusedError:
            check(True, "the port refuses connections after exit")
    finally:
        if netd.poll() is None:
            netd.kill()
        netd.wait()
        fake.close()
    if failures:
        print(f"FAIL\tms6-netd-darwin\t{len(failures)} failure(s)")
        return 1
    print("PASS\tms6-netd-darwin\t5 cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
