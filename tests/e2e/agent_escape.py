"""Escape attempts for setup's own executions (chat-drawer plan rev 16.1, §3c.7;
S3n2), shared by agent/host/tests/test_provision.py and agent_setup_test.py.

attempter_cli() writes a stand-in Claude CLI that first tries to reach every
decoy it is given (TCP addresses, abstract Unix socket names) and to open every
canary file, ignoring every error, and then either execs the real CLI with the
same arguments, descriptors and environment (so a real R1 probe still passes) or
prints a fake version. It reports nothing itself: the oracle is on the host
side, a TcpDecoy's accept count and an inotify watch on the canaries.
Standard library only (it runs as /usr/bin/python3 -I inside the sandbox)."""

from __future__ import annotations

import socket
import subprocess
import threading
from pathlib import Path

ATTEMPTER = '''#!/usr/bin/python3 -I
import os, socket, sys
for host, port in {tcp!r}:
    try:
        socket.create_connection((host, port), timeout=1).close()
    except OSError:
        pass
for name in {abstract!r}:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(1)
    try:
        s.connect("\\0" + name)
    except OSError:
        pass
    finally:
        s.close()
for path in {files!r}:
    try:
        open(path, "rb").close()
    except OSError:
        pass
if {real!r}:
    os.execv({real!r}, [{real!r}] + sys.argv[1:])
print("0.0.0 (escape attempter)")
'''


def attempter_cli(path: Path, tcp=(), abstract=(), files=(), real: str | None = None) -> Path:
    path.write_text(ATTEMPTER.format(tcp=[tuple(t) for t in tcp], abstract=list(abstract),
                                     files=[str(f) for f in files], real=real))
    path.chmod(0o755)
    return path


class TcpDecoy:
    """A listener that counts the connections it accepts."""

    def __init__(self, host: str = "127.0.0.1"):
        self.sock = socket.create_server((host, 0))
        self.address = (host, self.sock.getsockname()[1])
        self.accepted = 0
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self) -> None:
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            self.accepted += 1
            conn.close()

    def close(self) -> None:
        self.sock.close()


class AbstractDecoy(TcpDecoy):
    """The same, on an abstract Unix socket name (only inside a disposable netns:
    abstract names belong to the network namespace)."""

    def __init__(self, name: str):  # noqa: D107 - no TCP base setup
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind("\0" + name)
        self.sock.listen(16)
        self.address = name
        self.accepted = 0
        threading.Thread(target=self._serve, daemon=True).start()


def host_lan_address() -> str | None:
    """The host's first global IPv4 address (its LAN side), or None."""
    done = subprocess.run(["/usr/bin/ip", "-4", "-o", "addr", "show", "scope", "global"],
                          capture_output=True, text=True, timeout=10)
    for line in done.stdout.splitlines():
        fields = line.split()
        if "inet" in fields:
            return fields[fields.index("inet") + 1].split("/")[0]
    return None
