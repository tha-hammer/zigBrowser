"""The hook network probe (chat-drawer plan rev 16.2, §3c.8b; S3n2, S3.8, S3.9,
S4.4, S7.6). A hook runs it as

    /usr/bin/python3 -I -S hook_net_probe.py <out.json> <nonce>

and it records, without raising, what the hook's network can reach:
- each bridge (127.0.0.1:51091 and :31337): it sends `bridge-<port>-<nonce>`,
  half-closes, and keeps the decoy's whole reply;
- the egress routes a hook must not have: a raw `CONNECT fake.zb.invalid:443`
  and a CONNECT followed by a real ClientHello, both through 127.0.0.1:3128,
  and the same CONNECT and ClientHello over /run/zb-net/egress/proxy.sock;
- every path named proxy.sock in its whole view (except /proc and /sys);
- DNS (getaddrinfo of api.anthropic.com) and a direct connect to a public IP;
- the names in its own environment (names only, never values).
Standard library only: the hook's view has /usr, not the helper's venv."""

import json
import os
import socket
import ssl
import sys

FAKE = "fake.zb.invalid"
EGRESS_SOCK = "/run/zb-net/egress/proxy.sock"
BRIDGES = (51091, 31337)
TIMEOUT = 3


def errname(exc):
    code = getattr(exc, "errno", None)
    return os.strerror(code) if isinstance(code, int) else type(exc).__name__


def bridge(port, nonce):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT) as s:
            s.sendall(f"bridge-{port}-{nonce}".encode())
            s.shutdown(socket.SHUT_WR)
            reply = b""
            while chunk := s.recv(4096):
                reply += chunk
        return {"ok": True, "reply": reply.decode("utf-8", "replace")}
    except OSError as exc:
        return {"ok": False, "error": errname(exc)}


def client_hello(server_name):
    ctx = ssl.create_default_context()
    outgoing = ssl.MemoryBIO()
    obj = ctx.wrap_bio(ssl.MemoryBIO(), outgoing, server_hostname=server_name)
    try:
        obj.do_handshake()
    except ssl.SSLWantReadError:
        pass
    return outgoing.read()


def connect_attempt(make_socket, with_hello):
    """CONNECT fake.zb.invalid:443; with_hello sends a ClientHello after a 200."""
    try:
        with make_socket() as s:
            s.settimeout(TIMEOUT)
            s.sendall(f"CONNECT {FAKE}:443 HTTP/1.1\r\nHost: {FAKE}:443\r\n\r\n".encode())
            head = b""
            while b"\r\n\r\n" not in head:
                chunk = s.recv(4096)
                if not chunk:
                    break
                head += chunk
            status = head.split(b" ", 2)[1].decode() if head.startswith(b"HTTP/1.1 ") else None
            if with_hello and status == "200":
                s.sendall(client_hello(FAKE))
                s.shutdown(socket.SHUT_WR)
                try:
                    while s.recv(4096):
                        pass
                except OSError:
                    pass
        return {"ok": True, "status": status}
    except OSError as exc:
        return {"ok": False, "error": errname(exc)}


def tcp_3128():
    return socket.create_connection(("127.0.0.1", 3128), timeout=TIMEOUT)


def unix_egress():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(TIMEOUT)
        s.connect(EGRESS_SOCK)
    except OSError:
        s.close()
        raise
    return s


def proxy_socks_in_view():
    found, todo = [], ["/"]
    while todo:
        top = todo.pop()
        try:
            entries = list(os.scandir(top))
        except OSError:
            continue
        for entry in entries:
            if entry.path in ("/proc", "/sys"):
                continue
            if entry.name == "proxy.sock":
                found.append(entry.path)
            try:
                if entry.is_dir(follow_symlinks=False):
                    todo.append(entry.path)
            except OSError:
                pass
    return sorted(found)


def dns():
    try:
        return {"ok": True, "addresses": sorted({a[4][0] for a in socket.getaddrinfo("api.anthropic.com", 443)})}
    except OSError as exc:
        return {"ok": False, "error": errname(exc)}


def public_ip():
    try:
        with socket.create_connection(("1.1.1.1", 443), timeout=TIMEOUT):
            return {"ok": True}
    except OSError as exc:
        return {"ok": False, "error": errname(exc)}


def main(out, nonce):
    result = {
        "nonce": nonce,
        "bridges": {str(port): bridge(port, nonce) for port in BRIDGES},
        "tcp_3128_connect": connect_attempt(tcp_3128, with_hello=False),
        "tcp_3128_tls": connect_attempt(tcp_3128, with_hello=True),
        "egress_sock": connect_attempt(unix_egress, with_hello=True),
        "proxy_socks": proxy_socks_in_view(),
        "dns": dns(),
        "public_ip": public_ip(),
        "env_names": sorted(os.environ),
        "netns": os.readlink("/proc/self/ns/net"),
    }
    with open(out, "w") as f:
        json.dump(result, f)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
