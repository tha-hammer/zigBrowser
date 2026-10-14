"""zb-agent-netd (chat-drawer plan rev 16.2, §3c.2-§3c.5): the agent's only network.

The browser starts it before the helper, outside the agent sandbox:

    python -I -m zb_agent_host.netd --sockdir DIR --bwrap BWRAP
        [--test-allow NAME=PORT] [--test-bridge 51091=PORT] [--test-bridge 31337=PORT]
        [--test-resolve NAME=ADDR[,ADDR...]] [--test-record-connects]

It creates DIR (one mkdir 0700 under a 0700 parent of ours), then runs bwrap as its only
child and waits: it stays the PID the browser spawned (with its PDEATHSIG), and bwrap's
--die-with-parent ties netd to it. bwrap gives netd the host network but no
filesystem beyond /usr, its own code, the resolver inputs and DIR (§3c.2b). Inside,
it creates

    DIR/egress/proxy.sock            CONNECT api.anthropic.com:443, and nothing else
    DIR/bridges/port-51091.sock      host 127.0.0.1:51091, fixed
    DIR/bridges/port-31337.sock      host 127.0.0.1:31337, fixed

and prints exactly "netd ready". It stops when its stdin reaches EOF (bwrap forwards no
signal): inside, it unlinks its sockets and removes egress/ and bridges/; DIR is the
sandbox's mount point there, so the waiting parent removes the then-empty DIR and exits
with bwrap's status. A signal to the spawned PID is death without cleanup, as a crash.

The --test-* options are honoured as given: the app passes them only under
--e2e-protocol (§3c.4, §3c.5). Standard library only."""

import ipaddress
import os
import re
import select
import signal
import socket
import stat
import sys
import threading
import time

EXIT_NO_SANDBOX = 3
EXIT_USAGE = 2

API_HOST = "api.anthropic.com"
BRIDGE_PORTS = (51091, 31337)
SUN_PATH_MAX = 107
USR_LINKS = (("usr/bin", "/bin"), ("usr/sbin", "/sbin"), ("usr/lib", "/lib"), ("usr/lib64", "/lib64"))
RESOLVER_FILES = ("/etc/resolv.conf", "/etc/nsswitch.conf", "/etc/hosts", "/etc/host.conf", "/etc/gai.conf")

LINE_MAX = 1024
HEADER_LINES_MAX = 32
HEADER_BYTES_MAX = 8192
HEADER_TIMEOUT_S = 10.0
CONNECT_TIMEOUT_S = 10.0
HELLO_TIMEOUT_S = 10.0
HELLO_MAX = 16384
IDLE_TIMEOUT_S = 300.0
TUNNELS_MAX = 16
BRIDGE_CONNECTIONS_MAX = 32
BRIDGE_CONNECT_TIMEOUT_S = 1.0
LOG_HOST_MAX = 64

MALFORMED = b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
REFUSED = b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
BUSY = b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
ESTABLISHED = b"HTTP/1.1 200 Connection Established\r\n\r\n"

_LABEL = re.compile(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?")
_CONNECT = re.compile(r"CONNECT ([^ ]+):([0-9]+) HTTP/1\.1")


def log(text):
    sys.stderr.write(f"zigBrowser: agent: {text}\n")
    sys.stderr.flush()


class Refused(Exception):
    """The request is not allowed (403), or malformed (400); `host` and `port` are for
    the one log line."""

    def __init__(self, host="?", port="?", malformed=False):
        super().__init__(host)
        self.host = host
        self.port = port
        self.response = MALFORMED if malformed else REFUSED


# ---------------------------------------------------------------- request parsing

def valid_dns_name(host):
    """A lowercase ASCII DNS name: no trailing dot, no IDNA label, not an IP literal."""
    if not host or len(host) > 253 or host.endswith("."):
        return False
    labels = host.split(".")
    if any(not _LABEL.fullmatch(label) or label.startswith("xn--") for label in labels):
        return False
    try:
        ipaddress.ip_address(host)
        return False
    except ValueError:
        pass
    return not labels[-1].isdigit()


def parse_head(head, allowed):
    """`head` is the request line plus headers, without the blank line. Returns the
    allowlisted host, or raises Refused. Header lines are counted and never kept."""
    lines = head.split(b"\r\n")
    if len(lines[0]) > LINE_MAX:
        raise Refused(malformed=True)
    if len(lines) - 1 > HEADER_LINES_MAX or len(head) - len(lines[0]) > HEADER_BYTES_MAX:
        raise Refused(malformed=True)
    try:
        line = lines[0].decode("ascii")
    except UnicodeDecodeError:
        raise Refused(malformed=True)
    match = _CONNECT.fullmatch(line)
    if match is None:
        target = line.split(" ")[1] if line.count(" ") >= 2 else "?"
        host, _, port = target.rpartition(":")
        raise Refused(host or target, port or "?", malformed=True)
    host, port = match.group(1), match.group(2)
    if port != "443" or "@" in host or not valid_dns_name(host) or host not in allowed:
        raise Refused(host, port)
    return host


def sanitize(text):
    cleaned = "".join(ch for ch in str(text) if ch.isprintable() and ch not in "\r\n\t")
    return cleaned[:LOG_HOST_MAX]


# ---------------------------------------------------------------- address vetting

def _embedded_v4(address):
    if address.ipv4_mapped is not None:
        return address.ipv4_mapped
    if address in ipaddress.ip_network("64:ff9b::/96"):
        return ipaddress.IPv4Address(int(address) & 0xFFFFFFFF)
    if address.sixtofour is not None:
        return address.sixtofour
    return None


def vetted(addresses):
    """Every resolved address must be global (§3c.3), or none is used."""
    out = []
    for text in addresses:
        try:
            address = ipaddress.ip_address(text)
        except ValueError:
            return []
        if address.version == 6:
            inner = _embedded_v4(address)
            if inner is not None and not inner.is_global:
                return []
        if not address.is_global or address in ipaddress.ip_network("100.64.0.0/10") \
                or address in ipaddress.ip_network("198.18.0.0/15"):
            return []
        if text not in out:
            out.append(text)
    return out


# ---------------------------------------------------------------- TLS ClientHello

def client_hello_sni(record):
    """The server_name of a complete TLS handshake record holding a ClientHello, or
    None when it is not one (or has no host_name SNI)."""
    try:
        if record[0] != 0x16 or record[5] != 0x01:
            return None
        body = record[9:5 + int.from_bytes(record[3:5], "big")]
        i = 2 + 32
        i += 1 + body[i]
        i += 2 + int.from_bytes(body[i:i + 2], "big")
        i += 1 + body[i]
        end = i + 2 + int.from_bytes(body[i:i + 2], "big")
        i += 2
        while i + 4 <= end:
            kind = int.from_bytes(body[i:i + 2], "big")
            size = int.from_bytes(body[i + 2:i + 4], "big")
            data = body[i + 4:i + 4 + size]
            if kind == 0:
                j = 2
                while j + 3 <= len(data):
                    name_type, length = data[j], int.from_bytes(data[j + 1:j + 3], "big")
                    if name_type == 0:
                        return data[j + 3:j + 3 + length].decode("ascii")
                    j += 3 + length
                return None
            i += 4 + size
    except (IndexError, UnicodeDecodeError):
        return None
    return None


def read_record(sock, buffered, deadline):
    """Read until `buffered` holds one whole TLS record (or fail). Returns the bytes read
    so far, all of which are forwarded later."""
    data = bytearray(buffered)
    while True:
        if len(data) >= 1 and data[0] != 0x16:
            return None, bytes(data)
        if len(data) >= 5:
            need = 5 + int.from_bytes(data[3:5], "big")
            if need > HELLO_MAX + 5:
                return None, bytes(data)
            if len(data) >= need:
                return bytes(data[:need]), bytes(data)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None, bytes(data)
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(HELLO_MAX + 5 - len(data))
        except OSError:
            return None, bytes(data)
        if not chunk:
            return None, bytes(data)
        data += chunk


# ---------------------------------------------------------------- splicing

def splice(a, b, idle=IDLE_TIMEOUT_S):
    """Relay bytes both ways until both directions end or nothing moves for `idle`
    seconds. EOF on one side is passed on as shutdown(SHUT_WR)."""
    poller = select.poll()
    open_reads = {a.fileno(): (a, b), b.fileno(): (b, a)}
    for fd in open_reads:
        poller.register(fd, select.POLLIN)
    last = time.monotonic()
    try:
        while open_reads:
            events = poller.poll(1000)
            if not events:
                if time.monotonic() - last > idle:
                    return
                continue
            last = time.monotonic()
            for fd, _ in events:
                if fd not in open_reads:
                    continue
                src, dst = open_reads[fd]
                try:
                    data = src.recv(65536)
                except OSError:
                    data = b""
                if data:
                    try:
                        dst.sendall(data)
                        continue
                    except OSError:
                        return
                poller.unregister(fd)
                del open_reads[fd]
                try:
                    dst.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
    finally:
        a.close()
        b.close()


# ---------------------------------------------------------------- the service

class Netd:
    def __init__(self, sockdir, allow, bridges, resolve, record_connects):
        self.sockdir = sockdir
        self.allowed = {API_HOST, *allow}
        self.test_allow = allow  # name -> 127.0.0.1 port; skips vetting (the e2e seam)
        self.bridges = bridges  # sandbox port -> host port
        self.resolve_seam = resolve
        self.record_connects = record_connects
        self.tunnels = threading.BoundedSemaphore(TUNNELS_MAX)
        self.bridge_slots = threading.BoundedSemaphore(BRIDGE_CONNECTIONS_MAX)
        self.logged = set()
        self.log_lock = threading.Lock()
        self.listeners = []
        self.stopping = threading.Event()

    def refused(self, host, port):
        key = (sanitize(host), sanitize(port))
        with self.log_lock:
            if key in self.logged:
                return
            self.logged.add(key)
        log(f"network refused {key[0]}:{key[1]}")

    def addresses(self, host):
        if host in self.test_allow:
            return [("127.0.0.1", self.test_allow[host])]
        if host in self.resolve_seam:
            found = self.resolve_seam[host]
        else:
            try:
                infos = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
            except OSError:
                return []
            found = [info[4][0] for info in infos]
        return [(address, 443) for address in vetted(found)]

    def connect(self, targets):
        deadline = time.monotonic() + CONNECT_TIMEOUT_S
        for address, port in targets:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            if self.record_connects:
                log(f"netd test-connect {address} {port}")
            try:
                return socket.create_connection((address, port), timeout=remaining)
            except OSError:
                continue
        return None

    def egress(self, client):
        if not self.tunnels.acquire(blocking=False):
            try:
                client.sendall(BUSY)
            finally:
                client.close()
            return
        upstream = None
        try:
            head, rest = self.read_head(client)
            if head is None:
                return
            try:
                host = parse_head(head, self.allowed)
            except Refused as refusal:
                self.refused(refusal.host, refusal.port)
                client.sendall(refusal.response)
                return
            targets = self.addresses(host)
            if not targets:
                self.refused(host, 443)
                client.sendall(REFUSED)
                return
            client.sendall(ESTABLISHED)
            record, early = read_record(client, rest, time.monotonic() + HELLO_TIMEOUT_S)
            if record is None or client_hello_sni(record) != host:
                self.refused(host, 443)
                return
            upstream = self.connect(targets)
            if upstream is None:
                return
            upstream.settimeout(None)
            upstream.sendall(early)
            client.settimeout(None)
            splice(client, upstream)
            client = upstream = None
        except OSError:
            pass
        finally:
            for sock in (client, upstream):
                if sock is not None:
                    sock.close()
            self.tunnels.release()

    def read_head(self, client):
        deadline = time.monotonic() + HEADER_TIMEOUT_S
        data = b""
        limit = LINE_MAX + HEADER_BYTES_MAX + 4
        while b"\r\n\r\n" not in data:
            if len(data) > limit or (b"\r\n" not in data and len(data) > LINE_MAX):
                self.refused("?", "?")
                client.sendall(MALFORMED)
                return None, b""
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None, b""
            client.settimeout(remaining)
            try:
                chunk = client.recv(4096)
            except OSError:
                return None, b""
            if not chunk:
                return None, b""
            data += chunk
        head, _, rest = data.partition(b"\r\n\r\n")
        return head, rest

    def bridge(self, client, host_port):
        """A fixed bridge: no input chooses its target."""
        if not self.bridge_slots.acquire(blocking=False):
            client.close()
            return
        try:
            try:
                upstream = socket.create_connection(("127.0.0.1", host_port), timeout=BRIDGE_CONNECT_TIMEOUT_S)
            except OSError:
                client.close()
                return
            upstream.settimeout(None)
            splice(client, upstream)
        finally:
            self.bridge_slots.release()

    def listen(self, path, handler, *extra):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(path)
        sock.listen(64)
        self.listeners.append((sock, path))

        def accept_loop():
            while not self.stopping.is_set():
                try:
                    client, _ = sock.accept()
                except OSError:
                    return
                threading.Thread(target=handler, args=(client, *extra), daemon=True).start()
        threading.Thread(target=accept_loop, daemon=True).start()

    def start(self):
        os.umask(0o077)
        for name in ("egress", "bridges"):
            os.mkdir(os.path.join(self.sockdir, name), 0o700)
        os.umask(0o177)  # sockets are born 0600: there is no window with a wider mode
        self.listen(os.path.join(self.sockdir, "egress", "proxy.sock"), self.egress)
        for port in BRIDGE_PORTS:
            self.listen(os.path.join(self.sockdir, "bridges", f"port-{port}.sock"), self.bridge,
                        self.bridges[port])

    def stop(self):
        """Unlink exactly what start() made, by directory fd, and nothing else."""
        self.stopping.set()
        for sock, _ in self.listeners:
            sock.close()
        root = os.open(self.sockdir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for sub, names in (("egress", ("proxy.sock",)),
                               ("bridges", tuple(f"port-{p}.sock" for p in BRIDGE_PORTS))):
                try:
                    fd = os.open(sub, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root)
                except OSError:
                    continue
                try:
                    for name in names:
                        try:
                            if stat.S_ISSOCK(os.lstat(name, dir_fd=fd).st_mode):
                                os.unlink(name, dir_fd=fd)
                        except OSError:
                            pass
                finally:
                    os.close(fd)
                try:
                    os.rmdir(sub, dir_fd=root)
                except OSError:
                    pass
        finally:
            os.close(root)


# ---------------------------------------------------------------- command line

def _pairs(values, what, value_kind):
    out = {}
    for item in values:
        name, sep, value = item.partition("=")
        if not sep or not name or not value:
            raise ValueError(f"{what} needs NAME=VALUE: {item!r}")
        out[name] = value_kind(value)
    return out


def _port(text):
    port = int(text)
    if not 0 < port < 65536:
        raise ValueError(f"bad port {text!r}")
    return port


def parse_args(argv):
    opts = {"sockdir": None, "bwrap": None, "allow": [], "bridge": [], "resolve": [],
            "record": False, "serve": False}
    single = {"--sockdir": "sockdir", "--bwrap": "bwrap"}
    multi = {"--test-allow": "allow", "--test-bridge": "bridge", "--test-resolve": "resolve"}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in single or arg in multi:
            if i + 1 >= len(argv):
                raise ValueError(f"{arg} needs a value")
            if arg in single:
                opts[single[arg]] = argv[i + 1]
            else:
                opts[multi[arg]].append(argv[i + 1])
            i += 2
        elif arg == "--test-record-connects":
            opts["record"] = True
            i += 1
        elif arg == "--serve":
            opts["serve"] = True
            i += 1
        else:
            raise ValueError(f"unknown argument {arg!r}")
    if not opts["sockdir"]:
        raise ValueError("--sockdir is required")
    allow = _pairs(opts["allow"], "--test-allow", _port)
    for name in allow:
        if not valid_dns_name(name):
            raise ValueError(f"--test-allow name is not a DNS name: {name!r}")
    bridges = {port: port for port in BRIDGE_PORTS}
    for key, value in _pairs(opts["bridge"], "--test-bridge", _port).items():
        if key not in {str(p) for p in BRIDGE_PORTS}:
            raise ValueError(f"--test-bridge names an unknown bridge: {key!r}")
        bridges[int(key)] = value
    resolve = _pairs(opts["resolve"], "--test-resolve", lambda v: [a for a in v.split(",") if a])
    return opts, allow, bridges, resolve


def check_sockdir(sockdir):
    """DIR must be new, absolute, under a real 0700 directory of ours, and short enough."""
    if not os.path.isabs(sockdir) or os.path.normpath(sockdir) != sockdir or sockdir == "/":
        raise ValueError(f"socket directory must be an absolute, normalized path: {sockdir!r}")
    longest = os.path.join(sockdir, "bridges", f"port-{BRIDGE_PORTS[0]}.sock")
    if len(longest.encode()) > SUN_PATH_MAX:
        raise ValueError(f"socket directory too long: {longest!r} exceeds {SUN_PATH_MAX} bytes")
    parent = os.path.dirname(sockdir)
    st = os.lstat(parent)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
        raise ValueError(f"{parent} must be a real directory of ours with mode 0700")


def make_sockdir(sockdir):
    os.mkdir(sockdir, 0o700)  # fails if anything (a link included) already has the name
    fd = os.open(sockdir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fchmod(fd, 0o700)
        st = os.fstat(fd)
        if st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
            raise ValueError(f"{sockdir} is not a 0700 directory of ours")
    finally:
        os.close(fd)


def sandbox_argv(bwrap, sockdir, serve_argv):
    """netd's own bwrap (§3c.2b): host network, no filesystem beyond what it needs."""
    package_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    argv = [bwrap, "--unshare-all", "--share-net", "--die-with-parent", "--new-session",
            "--clearenv", "--setenv", "PATH", "/usr/bin", "--setenv", "LANG", "C.UTF-8",
            # The private /tmp first: the binds below may live under the host's /tmp.
            "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp",
            "--ro-bind", "/usr", "/usr"]
    for target, link in USR_LINKS:
        argv += ["--symlink", target, link]
    argv += ["--ro-bind", package_dir, package_dir]
    executable = os.path.realpath(sys.executable)
    if not executable.startswith("/usr/") and not executable.startswith(package_dir + "/"):
        argv += ["--ro-bind", executable, executable]
    for path in RESOLVER_FILES:
        if os.path.islink(path):
            target = os.path.realpath(path)
            if os.path.exists(target):
                argv += ["--ro-bind", target, path]
        elif os.path.exists(path):
            argv += ["--ro-bind", path, path]
    argv += ["--bind", sockdir, sockdir,
             "--", executable, "-I", "-S", os.path.abspath(__file__), "--serve", *serve_argv]
    return argv


def serve(sockdir, allow, bridges, resolve, record):
    netd = Netd(sockdir, allow, bridges, resolve, record)
    netd.start()
    done = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: done.set())
    signal.signal(signal.SIGINT, lambda *_: done.set())

    def stdin_watch():
        try:
            while os.read(0, 4096):
                pass
        except OSError:
            pass
        done.set()
    threading.Thread(target=stdin_watch, daemon=True).start()
    sys.stdout.write("netd ready\n")
    sys.stdout.flush()
    while not done.wait(0.5):
        pass
    netd.stop()
    return 0


def main(argv):
    try:
        opts, allow, bridges, resolve = parse_args(argv)
    except ValueError as exc:
        log(f"netd: {exc}")
        return EXIT_USAGE
    sockdir = opts["sockdir"]
    os.closerange(3, os.sysconf("SC_OPEN_MAX"))  # nothing the browser leaked goes further
    if opts["serve"]:
        return serve(sockdir, allow, bridges, resolve, opts["record"])
    bwrap = opts["bwrap"] or "/usr/bin/bwrap"
    if not os.access(bwrap, os.X_OK):
        log("network unavailable (bwrap)")
        return EXIT_NO_SANDBOX
    try:
        check_sockdir(sockdir)
        make_sockdir(sockdir)
    except (OSError, ValueError) as exc:
        log(f"netd: {exc}")
        return EXIT_USAGE
    child = os.fork()
    if child == 0:
        try:
            os.execv(bwrap, sandbox_argv(bwrap, sockdir, _serve_args(argv)))
        finally:
            os._exit(EXIT_NO_SANDBOX)
    while True:
        try:
            _, status = os.waitpid(child, 0)
            break
        except InterruptedError:
            continue
    try:
        os.rmdir(sockdir)  # only when serve emptied it; never anything else
    except OSError:
        pass
    code = os.waitstatus_to_exitcode(status)
    return 128 - code if code < 0 else code


def _serve_args(argv):
    """argv without --bwrap BWRAP (the sandboxed side has no bwrap)."""
    out, skip = [], False
    for arg in argv:
        if skip:
            skip = False
            continue
        if arg == "--bwrap":
            skip = True
            continue
        out.append(arg)
    return out


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
