"""The token's two hops: app -> helper (fd 3, read once) and helper -> CLI (route R1, the only one).

R1 (default): the helper writes the token once into a FIFO with a random name in
a directory others cannot list (0300); the CLI is started through the wrapper
`zb-claude`, which reads the FIFO, unlinks it, and hands the token to the CLI on
fd 3 as a socket (CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3). The CLI reads a
socket descriptor directly and closes it; a pipe or FIFO it would reopen through
/proc/self/fd/3, which blocks for a FIFO whose writer has gone. No process
environment holds the token. R3 (the token in the CLI's environment) was removed
(chat-drawer plan rev 16, §3c.1).
"""

import os
import secrets
import stat
import threading

from .files import atomic_write

MIN_TOKEN = 16
MAX_TOKEN = 512


def check_shape(value):
    if not MIN_TOKEN <= len(value) <= MAX_TOKEN or not all(33 <= ord(c) <= 126 for c in value):
        raise ValueError("token must be one line of 16-512 printable non-space characters")
    return value


def read_token(fd):
    """Reads the token from `fd` to end of stream, closes it, and checks its shape."""
    chunks = []
    size = 0
    try:
        while True:
            chunk = os.read(fd, MAX_TOKEN + 2 - size)
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
            if size > MAX_TOKEN + 1:
                break
    finally:
        os.close(fd)
    data = b"".join(chunks)
    if data.endswith(b"\n"):
        data = data[:-1]
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        raise ValueError("token must be ASCII") from None
    return check_shape(text)


class FifoHandoff:
    """One session's R1 FIFO: created with a random 128-bit name, written once, never reused."""

    def __init__(self, directory, value):
        self.directory = str(directory)
        os.makedirs(self.directory, mode=0o300, exist_ok=True)
        os.chmod(self.directory, 0o300)
        self.path = os.path.join(self.directory, secrets.token_hex(16))
        os.mkfifo(self.path, 0o600)
        self._value = value.encode()
        self._thread = threading.Thread(target=self._write, daemon=True)
        self._thread.start()

    def _write(self):
        try:
            fd = os.open(self.path, os.O_WRONLY | os.O_CLOEXEC)  # waits for the wrapper
        except OSError:
            return
        try:
            os.write(fd, self._value + b"\n")
        finally:
            os.close(fd)
            self._value = b""

    def env(self):
        return {"ZB_TOKEN_FIFO": self.path}

    def close(self):
        """Drops the FIFO. If the wrapper never opened it, our own read end releases the writer."""
        if self._thread.is_alive():
            try:
                fd = os.open(self.path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
            except OSError:
                fd = None
            self._thread.join(1.0)
            if fd is not None:
                os.close(fd)
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass
        self._value = b""


WRAPPER = '''#!{python} -I
# zb-claude (written by --agent-setup): route R1. Reads this session's token FIFO,
# unlinks it, and starts the Claude CLI with the token on fd 3 as a socket.
import os, socket, sys
CLI = {cli!r}
path = os.environ.pop("ZB_TOKEN_FIFO", "")
if not path:
    sys.exit("zb-claude: no token FIFO")
fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
os.unlink(path)
data = b""
while len(data) <= {limit}:
    chunk = os.read(fd, {limit} + 2 - len(data))
    if not chunk:
        break
    data += chunk
os.close(fd)
if not data or len(data) > {limit} + 1:
    sys.exit("zb-claude: bad token")
ours, theirs = socket.socketpair()
ours.sendall(data)
ours.close()
del data
fd3 = theirs.detach()
if fd3 != 3:
    os.dup2(fd3, 3)
    os.close(fd3)
os.set_inheritable(3, True)
os.environ["CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR"] = "3"
os.execv(CLI, [CLI] + sys.argv[1:])
'''


def write_wrapper(path, cli, python="/usr/bin/python3"):
    return atomic_write(path, WRAPPER.format(python=python, cli=str(cli), limit=MAX_TOKEN), 0o700)


def bundled_cli():
    import claude_agent_sdk
    path = os.path.join(os.path.dirname(claude_agent_sdk.__file__), "_bundled", "claude")
    if not os.access(path, os.X_OK) or not stat.S_ISREG(os.stat(path).st_mode):
        raise FileNotFoundError(path)
    return path
