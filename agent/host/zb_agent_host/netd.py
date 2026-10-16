"""zb-agent-netd (chat-drawer plan rev 16.2, §3c.2-§3c.5): the agent's only network.

The browser starts it before the helper, outside the agent sandbox:

    python -I -m zb_agent_host.netd --sockdir DIR --bwrap BWRAP [--net-manifest PATH]
        [--test-allow NAME=PORT] [--test-bridge 51091=PORT] [--test-bridge 31337=PORT]
        [--test-resolve NAME=ADDR[,ADDR...]] [--test-record-connects] [--test-ready-delay MS]

PATH is the backend's network manifest, the agent home's runtime/net.json (MS0;
BlueBeaver 5755, JadeBeacon 5762): its `egress.allow` replaces the built-in
api.anthropic.com and its `ports` replace the bridges 51091 and 31337 (an empty
`ports` means no bridges at all: the sign-in's runtime/net-login.json, rev 16.18.1). netd reads
it here, before bwrap, and hands the sandboxed side the checked values; a missing
file, or one with neither key, means the built-in values, and any other fault exits 2
before anything exists.

It creates DIR (one mkdir 0700 under a 0700 parent of ours), then runs bwrap as its only
child and waits: it stays the PID the browser spawned (with its PDEATHSIG), and bwrap's
--die-with-parent ties netd to it. bwrap gives netd the host network but no
filesystem beyond /usr, its own code, the resolver inputs and DIR (§3c.2b). Inside,
it creates

    DIR/egress/proxy.sock            CONNECT api.anthropic.com:443 (or the manifest's
                                     hosts), and nothing else
    DIR/bridges/port-51091.sock      host 127.0.0.1:51091, fixed (or one per manifest port)
    DIR/bridges/port-31337.sock      host 127.0.0.1:31337, fixed

and prints exactly "netd ready". It stops when its stdin reaches EOF (bwrap forwards no
signal): inside, it unlinks its sockets and removes egress/ and bridges/; DIR is the
sandbox's mount point there, so the waiting parent removes the then-empty DIR and exits
with bwrap's status. A signal to the spawned PID is death without cleanup, as a crash.

The --test-* options are honoured as given: the app passes them only under
--e2e-protocol (§3c.4, §3c.5). --test-ready-delay MS (1-4000) holds the ready line
that long after the sockets exist, so a test can act while the browser still waits
for the network (RoseCat 5830). Standard library only."""

import ipaddress
import json
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
MANIFEST_MAX = 65536
NETWORK_LIST_MAX = 8  # hosts in egress.allow, and bridge ports
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
SPLICE_BUFFER = 65536
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

def splice(a, b, idle=IDLE_TIMEOUT_S, first=b""):
    """Relay bytes both ways until both directions end, or until no byte has
    moved for `idle` seconds in either direction. Never blocks on a peer that
    stops reading: sockets are nonblocking, each direction holds at most
    SPLICE_BUFFER bytes, and a full buffer stops reading from the other side.
    EOF on one side is passed on as shutdown(SHUT_WR) once its bytes are out.
    `first` is queued for `b` before anything else (a checked ClientHello)."""
    peer = {a: b, b: a}
    pending = {a: bytearray(), b: bytearray(first)}  # bytes still to write to the key
    reading = {a, b}
    by_fd = {a.fileno(): a, b.fileno(): b}
    last = time.monotonic()
    try:
        for sock in (a, b):
            sock.setblocking(False)
        while reading or pending[a] or pending[b]:
            remaining = idle - (time.monotonic() - last)
            if remaining <= 0:
                return
            poller = select.poll()
            for sock in (a, b):
                mask = 0
                if sock in reading and len(pending[peer[sock]]) < SPLICE_BUFFER:
                    mask |= select.POLLIN
                if pending[sock]:
                    mask |= select.POLLOUT
                if mask:
                    poller.register(sock.fileno(), mask)
            moved = False
            for fd, event in poller.poll(min(1000.0, remaining * 1000.0)):
                sock = by_fd[fd]
                other = peer[sock]
                room = SPLICE_BUFFER - len(pending[other])
                if event & (select.POLLIN | select.POLLHUP | select.POLLERR) and sock in reading and room > 0:
                    try:
                        data = sock.recv(room)  # never past the cap (recv(0) would look like EOF)
                    except (BlockingIOError, InterruptedError):
                        data = None
                    except OSError:
                        data = b""
                    if data:
                        pending[other] += data
                        moved = True
                    elif data == b"":
                        reading.discard(sock)
                        moved = True
                        if not pending[other]:
                            _shut(other)
                if event & select.POLLOUT and pending[sock]:
                    try:
                        sent = sock.send(pending[sock])
                    except (BlockingIOError, InterruptedError):
                        sent = 0
                    except OSError:
                        return
                    if sent:
                        del pending[sock][:sent]
                        moved = True
                    if not pending[sock] and other not in reading:
                        _shut(sock)
                elif event & (select.POLLERR | select.POLLNVAL) and sock not in reading:
                    return
            if moved:
                last = time.monotonic()
    finally:
        a.close()
        b.close()


def _shut(sock):
    try:
        sock.shutdown(socket.SHUT_WR)
    except OSError:
        pass


# ---------------------------------------------------------------- the service

class Netd:
    def __init__(self, sockdir, allow, bridges, resolve, record_connects, hosts=(API_HOST,)):
        self.sockdir = sockdir
        self.allowed = {*hosts, *allow}
        self.test_allow = allow  # name -> 127.0.0.1 port; skips vetting (the e2e seam)
        self.bridges = bridges  # sandbox port -> host port, one socket each
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
        client.settimeout(HEADER_TIMEOUT_S)  # every reply below is bounded too
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
            client.settimeout(HEADER_TIMEOUT_S)
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
            splice(client, upstream, first=early)
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
        for name in ("egress", "bridges") if self.bridges else ("egress",):
            os.mkdir(os.path.join(self.sockdir, name), 0o700)
        os.umask(0o177)  # sockets are born 0600: there is no window with a wider mode
        self.listen(os.path.join(self.sockdir, "egress", "proxy.sock"), self.egress)
        for port, host_port in self.bridges.items():
            self.listen(os.path.join(self.sockdir, "bridges", f"port-{port}.sock"), self.bridge, host_port)

    def stop(self):
        """Unlink exactly what start() made, by directory fd, and nothing else."""
        self.stopping.set()
        for sock, _ in self.listeners:
            sock.close()
        root = os.open(self.sockdir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for sub, names in (("egress", ("proxy.sock",)),
                               ("bridges", tuple(f"port-{p}.sock" for p in self.bridges))):
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
    opts = {"sockdir": None, "bwrap": None, "manifest": None, "ready_delay": None, "allow": [], "bridge": [], "resolve": [],
            "host": [], "port": [], "record": False, "serve": False, "no_bridges": False}
    single = {"--sockdir": "sockdir", "--bwrap": "bwrap", "--net-manifest": "manifest",
              "--test-ready-delay": "ready_delay"}
    # --allow-host and --bridge-port carry the checked manifest to the sandboxed side.
    multi = {"--test-allow": "allow", "--test-bridge": "bridge", "--test-resolve": "resolve",
             "--allow-host": "host", "--bridge-port": "port"}
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
        elif arg == "--no-bridges":  # a manifest's empty `ports`, carried to the sandboxed side
            opts["no_bridges"] = True
            i += 1
        else:
            raise ValueError(f"unknown argument {arg!r}")
    if not opts["sockdir"]:
        raise ValueError("--sockdir is required")
    if opts["serve"] and opts["manifest"] is not None:
        raise ValueError("--net-manifest is read before the sandbox")
    if not opts["serve"] and (opts["host"] or opts["port"] or opts["no_bridges"]):
        raise ValueError("--allow-host, --bridge-port and --no-bridges belong to the sandboxed side")
    if opts["no_bridges"] and opts["port"]:
        raise ValueError("--no-bridges takes no --bridge-port")
    if opts["manifest"] is not None and not os.path.isabs(opts["manifest"]):
        raise ValueError("--net-manifest needs an absolute path")
    if opts["ready_delay"] is not None:
        text = opts["ready_delay"]
        if not (text.isascii() and text.isdigit() and text[0] != "0" and int(text) <= 4000):
            raise ValueError(f"--test-ready-delay needs 1-4000 ms: {text!r}")
        opts["ready_delay"] = int(text)
    allow = _pairs(opts["allow"], "--test-allow", _port)
    for name in allow:
        if not valid_dns_name(name):
            raise ValueError(f"--test-allow name is not a DNS name: {name!r}")
    resolve = _pairs(opts["resolve"], "--test-resolve", lambda v: [a for a in v.split(",") if a])
    return opts, allow, resolve


def network(opts):
    """(hosts, ports, from_manifest): the egress allow-list and the bridge ports, from
    the manifest (outer side), from --allow-host/--bridge-port (sandboxed side), or
    the built-in values."""
    if opts["serve"]:
        hosts = tuple(opts["host"]) or (API_HOST,)
        ports = () if opts["no_bridges"] else tuple(_port(p) for p in opts["port"]) or BRIDGE_PORTS
        check_network(hosts, ports, no_ports=opts["no_bridges"])
        return hosts, ports, False
    if opts["manifest"] is not None:
        loaded = load_manifest(opts["manifest"])
        if loaded is not None:
            return (*loaded, True)
    return (API_HOST,), BRIDGE_PORTS, False


def check_network(hosts, ports, no_ports=False):
    """1-8 distinct DNS names and 1-8 distinct ports (1-65535), or no ports at all
    when `no_ports` (a manifest's empty list). Fixed words only: the values may come
    from a file."""
    if not all(isinstance(h, str) and valid_dns_name(h) for h in hosts) or \
            not 1 <= len(hosts) <= NETWORK_LIST_MAX or len(set(hosts)) != len(hosts):
        raise ValueError("network manifest refused (egress.allow)")
    if not all(type(p) is int and 0 < p < 65536 for p in ports) or \
            not (0 if no_ports else 1) <= len(ports) <= NETWORK_LIST_MAX or len(set(ports)) != len(ports):
        raise ValueError("network manifest refused (ports)")


def load_manifest(path):
    """The backend's network manifest at `path` as (hosts, ports), or None when no file
    has that name or it has neither `egress` nor `ports` (written before they existed). It must be a regular file of ours, not group- or world-writable, at
    most MANIFEST_MAX bytes of UTF-8 JSON; it is opened without following a link and
    without blocking (a FIFO is refused, never waited on). Raises ValueError with fixed
    words: no byte of the file reaches a log."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except FileNotFoundError:
        return None
    except OSError:
        raise ValueError("network manifest refused (unreadable or a link)") from None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ValueError("network manifest refused (not a regular file)")
        if st.st_uid != os.getuid() or st.st_mode & 0o022:
            raise ValueError("network manifest refused (owner or mode)")
        data = b""
        while len(data) <= MANIFEST_MAX:
            chunk = os.read(fd, MANIFEST_MAX + 1 - len(data))
            if not chunk:
                break
            data += chunk
    finally:
        os.close(fd)
    if len(data) > MANIFEST_MAX:
        raise ValueError("network manifest refused (too large)")
    try:
        doc = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise ValueError("network manifest refused (not JSON)") from None
    if not isinstance(doc, dict):
        raise ValueError("network manifest refused (not an object)")
    if "egress" not in doc and "ports" not in doc:
        return None  # a manifest from before these keys (bridges_dir only): the built-in values
    egress = doc.get("egress")
    hosts = egress.get("allow") if isinstance(egress, dict) else None
    ports = doc.get("ports")
    if not isinstance(hosts, list):
        raise ValueError("network manifest refused (egress.allow)")
    if not isinstance(ports, list):
        raise ValueError("network manifest refused (ports)")
    check_network(hosts, ports, no_ports=not ports)
    return tuple(hosts), tuple(ports)


def bridge_targets(ports, test_bridges):
    """Sandbox port -> host port: each bridge goes to its own port, unless the e2e seam
    redirects one of them."""
    bridges = {port: port for port in ports}
    for key, value in _pairs(test_bridges, "--test-bridge", _port).items():
        if key not in {str(p) for p in ports}:
            raise ValueError(f"--test-bridge names an unknown bridge: {key!r}")
        bridges[int(key)] = value
    return bridges


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


def serve(sockdir, allow, bridges, resolve, record, hosts, ready_delay=None):
    netd = Netd(sockdir, allow, bridges, resolve, record, hosts)
    netd.start()
    if ready_delay:
        time.sleep(ready_delay / 1000)  # the e2e hold: the sockets exist, the line waits
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
        opts, allow, resolve = parse_args(argv)
        hosts, ports, from_manifest = network(opts)  # the manifest is read here, before anything exists
        bridges = bridge_targets(ports, opts["bridge"])
    except ValueError as exc:
        log(f"netd: {exc}")
        return EXIT_USAGE
    sockdir = opts["sockdir"]
    os.closerange(3, os.sysconf("SC_OPEN_MAX"))  # nothing the browser leaked goes further
    if opts["serve"]:
        return serve(sockdir, allow, bridges, resolve, opts["record"], hosts, opts["ready_delay"])
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
            serve_argv = _serve_args(argv)
            if from_manifest:
                for host in hosts:
                    serve_argv += ["--allow-host", host]
                for port in ports:
                    serve_argv += ["--bridge-port", str(port)]
                if not ports:
                    serve_argv.append("--no-bridges")
            os.execv(bwrap, sandbox_argv(bwrap, sockdir, serve_argv))
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
    """argv without --bwrap BWRAP (the sandboxed side has no bwrap) and without
    --net-manifest PATH (it has no agent home; it gets the checked values instead)."""
    out, skip = [], False
    for arg in argv:
        if skip:
            skip = False
            continue
        if arg in ("--bwrap", "--net-manifest"):
            skip = True
            continue
        out.append(arg)
    return out


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
