"""Both-Mac half of macOS netd (BlueBeaver 6971): runs netd.py natively (sys.platform == "darwin") with the system
python3 and checks, against a private fake upstream on 127.0.0.1:
 1. the only stdout line is exactly `netd ready 127.0.0.1:<port>`;
 2. lsof shows netd holding exactly one listening TCP socket, 127.0.0.1:<port>;
 3. CONNECT to the allowed test name is 200 and its ClientHello reaches the fake byte for byte;
 4. CONNECT to any other name is 403 and netd makes no upstream attempt for it;
 5. EOF on stdin exits 0 within 5 s and the port then refuses connections;
 6. netd also holds ::1:<port> (bound, NOT listening; lsof), a second ::1:<port> bind fails with EADDRINUSE even with
    SO_REUSEADDR+SO_REUSEPORT, and after EOF both families are free (RoseCat 7071; bead zigBrowser-v9f);
 7. a ::1:<P> listener planted before `--test-port P` makes netd refuse: exit 2, no ready line.
Run by tests/mac/ms6_netd_darwin_gate.sh with netd.py next to this file."""
import errno
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


def bind_errno(family, addr, reuse=False, reuseaddr_only=False):
    with socket.socket(family, socket.SOCK_STREAM) as s:
        if family == socket.AF_INET6:
            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        if reuse or reuseaddr_only:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if reuse:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        try:
            s.bind(addr)
        except OSError as exc:
            return exc.errno
        return 0


def tcp_sockets(pid):
    """lsof's view of the process's TCP sockets: (name, state or '')."""
    out = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-FnT"],
                         capture_output=True, text=True).stdout
    rows, name = [], None
    for line in out.splitlines():
        if line.startswith("n"):
            name = line[1:]
            rows.append([name, ""])
        elif line.startswith("TST=") and rows:
            rows[-1][1] = line[4:]
    return [tuple(r) for r in rows]


def planted_refusal():
    """A ::1:<P> listener planted first: netd --test-port P must refuse (exit 2, no ready line)."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    planted = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    planted.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    planted.bind(("::1", port))
    planted.listen(1)
    try:
        proc = subprocess.run([sys.executable, "-I", os.path.join(HERE, "netd.py"), "--test-port", str(port)],
                              capture_output=True, text=True, input="", timeout=20,
                              env={"PATH": "/usr/bin:/bin", "LANG": "C"})
        check(proc.returncode == 2 and proc.stdout == "" and "::1" in proc.stderr,
              f"a planted ::1:{port} listener makes netd refuse (rc {proc.returncode}, {proc.stderr.strip()[:120]!r})")
    finally:
        planted.close()


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

        rows = tcp_sockets(netd.pid)
        check(("127.0.0.1:%d" % port, "LISTEN") in rows, f"lsof: the v4 listener ({rows})")
        v6 = [r for r in rows if r[0] == "[::1]:%d" % port]
        check(len(v6) == 1 and v6[0][1] != "LISTEN", f"lsof: ::1:{port} held, not listening ({rows})")
        check(bind_errno(socket.AF_INET6, ("::1", port)) == errno.EADDRINUSE, "a second ::1 bind is EADDRINUSE")
        try:
            socket.create_connection(("::1", port), timeout=2).close()
            v6 = "ok"
        except socket.timeout:
            v6 = "timeout"
        except OSError as exc:
            v6 = f"errno {exc.errno}"
        # macOS drops a SYN at a bound, non-listening socket: the reservation makes [::1]:<port> reach nothing.
        check(v6 == "timeout", f"[::1]:{port} reaches nothing while netd holds it ({v6})")
        check(bind_errno(socket.AF_INET6, ("::1", port), reuse=True) == errno.EADDRINUSE,
              "and so is one with SO_REUSEADDR+SO_REUSEPORT (netd set neither)")
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
        # The v4 port saw real connections, so macOS keeps it in TIME_WAIT: SO_REUSEADDR alone passes TIME_WAIT but
        # never a live listener. ::1 was never connected, so a plain bind must succeed there.
        check((bind_errno(socket.AF_INET, ("127.0.0.1", port), reuseaddr_only=True),
               bind_errno(socket.AF_INET6, ("::1", port))) == (0, 0), "after exit both families are free")
        planted_refusal()
    finally:
        if netd.poll() is None:
            netd.kill()
        netd.wait()
        fake.close()
    if failures:
        print(f"FAIL\tms6-netd-darwin\t{len(failures)} failure(s)")
        return 1
    print("PASS\tms6-netd-darwin\t7 cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())
