"""zb-net-relay (chat-drawer plan rev 16.2, §3c.2 and §3c.8b): TCP on a private loopback,
relayed to netd's Unix sockets. One standard-library file with two modes:

    relay.py --egress DIR -- HELPER...    the outer relay: 127.0.0.1:3128 -> DIR/proxy.sock
    relay.py --bridges DIR -- HOOK...     the inner relay of one sealed hook:
                                          127.0.0.1:51091 -> DIR/port-51091.sock
                                          127.0.0.1:31337 -> DIR/port-31337.sock
    relay.py --bridges DIR --ports P1,P2,... -- HOOK...
                                          the same for the backend's bridge ports
                                          (MS0): 127.0.0.1:Pn -> DIR/port-Pn.sock

--ports is 1 to PORTS_MAX distinct ports (1-65535) in plain decimal, comma-separated.

The outer relay is the agent sandbox's command (python3 -I -m zb_agent_host.relay); the
inner one runs from the read-only runtime copy, always as `/usr/bin/python3 -I -S
<runtime>/bin/zb-net-relay` (BRIDGE_RELAY_FILE is this file, the one source of truth).

In order it binds its listeners, blocks the forwarded signals, forks and execs the
command (no thread ever exists), then in the parent forwards those signals, lets go of
fds 0 and 1 and of every other descriptor it inherited, and relays in one selectors
loop until the command exits. It exits with the command's status, or 128+n for signal
n. It reaps only its own child: anything left behind dies with the PID namespace when
bwrap's reaper (PID 1) exits. It never reads, copies or logs fd 3 (the chat helper's
token socket) or fd 4 (the login helper's token pipe, S6b1), and logs no content.
"""

import errno
import os
import selectors
import signal
import socket
import sys

BRIDGE_RELAY_FILE = os.path.abspath(__file__)

EXIT_USAGE = 2
EXIT_EXEC_FAILED = 1  # what bwrap itself returns when it cannot exec an unsealed hook
FORWARDED = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT, signal.SIGUSR1, signal.SIGUSR2)
EGRESS = {3128: "proxy.sock"}
BRIDGES = {51091: "port-51091.sock", 31337: "port-31337.sock"}
PORTS_MAX = 8
PAIRS_MAX = {"egress": 64, "bridges": 16}
BUFFER_MAX = 65536
UNIX_CONNECT_TIMEOUT_S = 1.0


def fail(text, code=EXIT_USAGE):
    os.write(2, f"zb-net-relay: {text}\n".encode())
    return code


def parse(argv):
    """(mode, DIR, command, ports or None), or None for a bad argv."""
    if len(argv) < 4 or argv[0] not in ("--egress", "--bridges"):
        return None
    mode, directory, rest = argv[0][2:], argv[1], argv[2:]
    ports = None
    if mode == "bridges" and rest[:1] == ["--ports"] and len(rest) > 1:
        ports = parse_ports(rest[1])
        if ports is None:
            return None
        rest = rest[2:]
    if rest[:1] != ["--"] or not rest[1:]:
        return None
    return mode, directory, rest[1:], ports


def parse_ports(text):
    """The ports of `--ports P1,P2,...`, or None: 1-PORTS_MAX distinct ports 1-65535,
    ASCII digits with no sign, space or leading zero."""
    items = text.split(",")
    if not 1 <= len(items) <= PORTS_MAX:
        return None
    ports = []
    for item in items:
        if not item or not item.isascii() or not item.isdigit() or item[0] == "0":
            return None
        port = int(item)
        if port > 65535 or port in ports:
            return None
        ports.append(port)
    return ports


class Pair:
    """One relayed connection: per-direction buffers, half-close passed on."""

    def __init__(self, relay, a, b):
        self.relay = relay
        self.peer = {a: b, b: a}
        self.pending = {a: bytearray(), b: bytearray()}  # bytes waiting to be written to the key
        self.read_open = {a, b}
        self.write_shut = set()
        for sock in (a, b):
            sock.setblocking(False)
            relay.selector.register(sock, selectors.EVENT_READ, self)

    def events(self, sock):
        mask = 0
        if sock in self.read_open and len(self.pending[self.peer[sock]]) < BUFFER_MAX:
            mask |= selectors.EVENT_READ
        if self.pending[sock]:
            mask |= selectors.EVENT_WRITE
        return mask

    def update(self, sock):
        mask = self.events(sock)
        try:
            if mask:
                self.relay.selector.modify(sock, mask, self)
            else:
                self.relay.selector.unregister(sock)
        except KeyError:
            if mask:
                self.relay.selector.register(sock, mask, self)

    def handle(self, sock, mask):
        peer = self.peer[sock]
        room = BUFFER_MAX - len(self.pending[peer])
        if mask & selectors.EVENT_READ and room > 0:
            try:
                data = sock.recv(room)  # never past the cap (recv(0) would look like EOF)
            except (BlockingIOError, InterruptedError):
                data = None
            except OSError:
                data = b""
            if data:
                self.pending[peer] += data
            elif data == b"":
                self.read_open.discard(sock)
                if not self.pending[peer]:
                    self.shut(peer)
        if mask & selectors.EVENT_WRITE and self.pending[sock]:
            try:
                sent = sock.send(self.pending[sock])
                del self.pending[sock][:sent]
            except (BlockingIOError, InterruptedError):
                pass
            except OSError:
                self.close()
                return
            if not self.pending[sock] and self.peer[sock] not in self.read_open:
                self.shut(sock)
        if not self.read_open and not any(self.pending.values()):
            self.close()
            return
        for s in (sock, peer):
            if s.fileno() >= 0:
                self.update(s)

    def shut(self, sock):
        if sock not in self.write_shut:
            self.write_shut.add(sock)
            try:
                sock.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def close(self):
        for sock in self.peer:
            try:
                self.relay.selector.unregister(sock)
            except (KeyError, ValueError):
                pass
            sock.close()
        self.relay.pairs.discard(self)


class Relay:
    def __init__(self, mode, directory, ports=None):
        self.mode = mode
        names = EGRESS if mode == "egress" else BRIDGES
        if ports is not None:
            names = {port: f"port-{port}.sock" for port in ports}
        self.targets = {port: os.path.join(directory, name) for port, name in names.items()}
        self.selector = selectors.DefaultSelector()
        self.pairs = set()
        self.listeners = {}

    def bind(self):
        for port, path in self.targets.items():
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("127.0.0.1", port))
            sock.listen(16)
            self.listeners[sock] = path

    def accept(self, listener):
        try:
            client, _ = listener.accept()
        except (BlockingIOError, InterruptedError, OSError):
            return
        if len(self.pairs) >= PAIRS_MAX[self.mode]:
            client.close()
            return
        target = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        target.settimeout(UNIX_CONNECT_TIMEOUT_S)
        try:
            target.connect(self.listeners[listener])
        except OSError:
            client.close()  # target down: the client sees EOF at once
            target.close()
            return
        self.pairs.add(Pair(self, client, target))

    def run(self, child, pidfd):
        for sock in self.listeners:
            sock.setblocking(False)
            self.selector.register(sock, selectors.EVENT_READ, "listen")
        self.selector.register(pidfd, selectors.EVENT_READ, "child")
        while True:
            for key, mask in self.selector.select():
                if key.data == "child":
                    status = _wait(child)
                    self.shutdown()
                    return status
                if key.data == "listen":
                    self.accept(key.fileobj)
                else:
                    key.data.handle(key.fileobj, mask)

    def shutdown(self):
        for sock in self.listeners:
            sock.close()
        for pair in list(self.pairs):
            pair.close()


def _wait(child):
    while True:
        try:
            _, status = os.waitpid(child, 0)
            break
        except InterruptedError:
            continue
    code = os.waitstatus_to_exitcode(status)
    return 128 - code if code < 0 else code


def _close_inherited(keep):
    """Close every descriptor >= 3 except `keep`."""
    keep = sorted(fd for fd in set(keep) if fd >= 3)
    low = 3
    for fd in keep:
        if low < fd:
            os.closerange(low, fd)
        low = fd + 1
    os.closerange(low, os.sysconf("SC_OPEN_MAX"))


def main(argv):
    parsed = parse(argv)
    if parsed is None:
        return fail("usage: zb-net-relay --egress DIR | --bridges DIR [--ports P1,P2,...] -- COMMAND...")
    mode, directory, command, ports = parsed
    relay = Relay(mode, directory, ports)
    try:
        relay.bind()
    except OSError as exc:
        return fail(f"cannot bind: {exc.strerror}")
    listener_fds = [sock.fileno() for sock in relay.listeners] + [relay.selector.fileno()]
    # A hook gets only fds 0-2; the helper gets 0-4: fd 3 is the chat helper's token socket
    # (§3c.2), fd 4 the login helper's token pipe (S6b1, rev 16.18.3). Each is open only
    # for its own helper.
    _close_inherited(listener_fds + ([3, 4] if mode == "egress" else []))
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, FORWARDED)
    child = os.fork()
    if child == 0:
        try:
            for sock in relay.listeners:
                sock.close()
            for sig in FORWARDED:
                signal.signal(sig, signal.SIG_DFL)
            signal.pthread_sigmask(signal.SIG_SETMASK, previous)
            os.execvp(command[0], command)
        except OSError as exc:
            os.write(2, f"zb-net-relay: cannot run {command[0]}: {exc.strerror}\n".encode())
        finally:
            os._exit(EXIT_EXEC_FAILED)
    for sig in FORWARDED:
        signal.signal(sig, lambda signum, _frame: _forward(child, signum))
    signal.pthread_sigmask(signal.SIG_SETMASK, previous)
    null = os.open(os.devnull, os.O_RDWR)
    os.dup2(null, 0)
    os.dup2(null, 1)
    os.close(null)
    pidfd = os.pidfd_open(child)
    _close_inherited(listener_fds + [pidfd])  # the outer relay's own copies of fds 3 and 4 go here
    return relay.run(child, pidfd)


def _forward(child, signum):
    try:
        os.kill(child, signum)
    except OSError as exc:
        if exc.errno != errno.ESRCH:
            raise


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
