"""`login` (chat-drawer plan S6, D7b; rev 16.18): the one-shot sign-in helper.

    python -m zb_agent_host login --home H [--e2e-claude-cli CLI]   (fd 4: the token)

It runs `claude setup-token` on a pty, with HOME set to the agent home and
CLAUDE_CONFIG_DIR set to a fresh private directory below scratchpad/tmp, as the real CLI (2.1.301, captured in
tests/fixtures/agent/setup_token_transcript.json) needs: it reads the sign-in
code at "Paste code here if prompted >" only from a terminal, as
`<code>#<state>`.

stdin carries app frames: `start`, `code` (`<code>#<state>`, from the auth
window's captured callback or the Secrets window's paste entry) and `cancel`.
stdout carries `auth_url` (once), `need_code` (each time the CLI prompts),
`done` and `error`. The token goes only to fd 4, in one write, then fd 4 is
closed; it is never on stdout, stderr or in a frame. The helper exits after
`done`, `error` or `cancel`, or after 10 minutes.

Rev 16.18.9 (S6b1 part B's finding): the CLI gets the backend's relay proxy, its
only way out of the sandbox (without it the real CLI resolves platform.claude.com
itself and fails). Once a code is typed, the CLI's "OAuth error" or "Press Enter to
retry" ends the sign-in at once with `error exchange`, and a CLI that within
EXCHANGE_S has neither printed the token nor asked again ends it with `error
timeout`. None of the CLI's text goes into a frame.

The pty is 4096 columns wide, so the CLI's renderer does not wrap the URL;
CSI and OSC sequences (an OSC 8 link around the URL included) are dropped
before anything is parsed. BROWSER is /bin/true: the CLI never opens a browser
itself (the app's auth window does). The pty output is kept in one bytearray
and zeroed before the helper exits; the token is written to fd 4 from a view
of it, not a copy. Python's own intermediate copies (escape removal) cannot be
zeroed, so the token lives in this process's memory until it exits: the helper
is one-shot, and exits right after `done`."""

import argparse
import errno
import json
import os
import re
import select
import secrets
import signal
import shutil
import stat
import struct
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qsl, urlsplit

from . import sandbox
from .frames import Emitter

if sys.platform != "win32":  # POSIX-only (WS7.5, bead zigBrowser-2p3): the module still imports on Windows
    import fcntl
    import pty
    import termios

TOKEN_FD = 4
TIMEOUT_S = 600
EXCHANGE_S = 60  # after a typed code: the token, or the prompt again (rev 16.18.9)
# The Enter after a typed code is its own write (rev 16.20.27, Part B's second finding): the
# real CLI 2.1.294 reads its terminal raw, and one read holding the Enter and more than about
# 64 other bytes is a paste whose Enter does not submit (a real code with its 43-character
# state always is). So the code is typed in pieces of at most CHUNK bytes, and each next piece,
# and at last the Enter, is written only once the masked echo accounts for all that was typed
# but at most CHUNK bytes: the CLI echoes a '*' only for a character it has read, so the stars
# on the screen since the code was typed never exceed what it read, and the bytes it has not
# read are at most (typed - stars). The Enter's read then holds at most CHUNK other bytes,
# however the CLI stalls (rev 16.20.29, RoseCat 6499: quiet time was no proof). The real CLI
# 2.1.294 (probed offline) shows the last six characters in clear and a '*' for each one before
# them, so its stars are the typed count less six, inside CHUNK. A step whose echo does not
# account for it within STEP_S fails closed, with no Enter. Never a step after an ending (rev
# 16.20.28).
CHUNK = 16
STEP_S = 5.0
COLUMNS = 4096
MAX_CODE = 512
MAX_URL = 4096
MAX_FRAME = 4096
MAX_SCREEN = 256 * 1024

# The authorize URLs the CLI may print (2.1.301's CLAUDE_AI_AUTHORIZE_URL and
# CONSOLE_AUTHORIZE_URL), and its exact parameter names (the capture).
AUTHORIZE = {("claude.com", "/cai/oauth/authorize"), ("platform.claude.com", "/oauth/authorize")}
PARAMS = ["code", "client_id", "response_type", "redirect_uri", "scope", "code_challenge",
          "code_challenge_method", "state"]
REDIRECT = "https://platform.claude.com/oauth/code/callback"
# The captured fixed values (RoseCat 5967): anything else is not the CLI's URL.
FIXED = {"code": "true", "response_type": "code", "redirect_uri": REDIRECT, "scope": "user:inference",
         "code_challenge_method": "S256"}
CLIENT_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
S256_CHALLENGE = re.compile(r"[A-Za-z0-9_-]{43}")  # base64url of a SHA-256, unpadded

ESCAPE = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[ -/]*[0-~]|\x1b")
CONTROL = re.compile(rb"[\x00-\x09\x0b-\x1f\x7f]")
URL = re.compile(rb"https://[\x21-\x7e]+")
PROMPT = b"Pastecodehereifprompted>"
SUCCESS = b"Long-livedauthenticationtokencreatedsuccessfully"
# The real CLI after a failed exchange (2.1.294, probed offline): "OAuth error: <why>",
# then "Press Enter to retry." while it waits. Matched with spaces removed.
EXCHANGE_FAILED = (b"OAutherror", b"PressEntertoretry")
# The CLI's masked echo of the typed code: it prints a '*' per character as it reads it
# (2.1.294 probed offline: the stars, then the code's last characters). What follows the
# first such run after the code was written is the CLI's answer to it (rev 16.18.13).
ECHO = re.compile(rb"\*{8,}")
TOKEN = re.compile(rb"(?<![A-Za-z0-9_-])sk-ant-oat01-[A-Za-z0-9_-]{22,499}(?=\n)")
CODE = re.compile(r"[\x21-\x22\x24-\x7e]+#[\x21-\x22\x24-\x7e]+")


def authorize_url(text):
    """The authorize URL if `text` is exactly one the CLI prints, else None."""
    if len(text) > MAX_URL:
        return None
    # Visible ASCII only, the whole URL (rev 16.18.14, RoseCat 6261), as the app checks it:
    # so MAX_URL counts bytes, and no NUL, control byte, space, DEL or non-ASCII gets through.
    if any(not "\x21" <= ch <= "\x7e" for ch in text):
        return None
    url = urlsplit(text)
    if url.scheme != "https" or (url.netloc, url.path) not in AUTHORIZE or url.fragment:
        return None
    # Names written plainly, as the CLI writes them (rev 16.18.12): parse_qsl would decode
    # `st%61te` into `state`; the app (agent_auth.authorizeUrl) refuses it, and so does this.
    if any("%" in piece.split("=", 1)[0] or "+" in piece.split("=", 1)[0] for piece in url.query.split("&")):
        return None
    params = parse_qsl(url.query, keep_blank_values=True)
    if sorted(name for name, _ in params) != sorted(PARAMS):  # each name exactly once
        return None
    values = dict(params)
    if any(values[name] != value for name, value in FIXED.items()):
        return None
    if not CLIENT_ID.fullmatch(values["client_id"]) or not S256_CHALLENGE.fullmatch(values["code_challenge"]):
        return None
    if not values["state"]:
        return None
    return text


def valid_code(code):
    return isinstance(code, str) and 3 <= len(code) <= MAX_CODE and CODE.fullmatch(code) is not None


def cli_env(home, proxy, config_dir=None):
    """The setup-token CLI's environment; `proxy` is the helper's (sandbox.helper_proxy: the macOS spec's direct port,
    else sandbox.linux_helper_proxy, the Linux relay's listener)."""
    # The CLI's temp files and its own per-uid temp dir (claude-<uid>) go to the home's scratchpad tmp, the macOS
    # sign-in profile's only write root (options.AgentHome.tmp's layout; options itself imports the SDK). Unset,
    # both fall back to /tmp, which Seatbelt denies (24f8d49: mkdir /tmp/claude-501 EPERM; RoseCat 0c476b8).
    tmp = os.path.join(home, "scratchpad", "tmp")
    return {
        "HOME": home,
        "CLAUDE_CONFIG_DIR": config_dir if config_dir is not None else os.path.join(home, ".claude"),
        # setup-token is a one-shot minting process.  Keep both its ordinary and secure-storage state in the
        # private directory that kill() removes, and use the CLI's minimal mode so it never consults Keychain.
        "CLAUDE_SECURESTORAGE_CONFIG_DIR": config_dir if config_dir is not None else os.path.join(home, ".claude"),
        "CLAUDE_CODE_SIMPLE": "1",
        "TMPDIR": tmp,
        "CLAUDE_CODE_TMPDIR": tmp,
        "PATH": "/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "TERM": "xterm-256color",
        "BROWSER": "/bin/true",
        # The sandbox's only way out is the outer relay (rev 16.18.9).
        "HTTPS_PROXY": proxy,
        "HTTP_PROXY": proxy,
        "NO_PROXY": "127.0.0.1,localhost",
    }


# The trust anchor: the one owner, besides the effective uid, a directory above the home may have (RoseCat 7753).
TRUST_ANCHOR_UID = 0


def open_home(home, euid):
    """An O_DIRECTORY fd of the home, reached from / one component at a time through held fds, never following a
    link. Every directory on the way is owned by the trust anchor (root) or by us, and writable by no one else
    unless it is sticky (like /tmp), where only an entry's owner may rename it; its next entry is then checked as
    root's or ours in turn, the home itself as ours alone. So no other uid can rename or replace anything on the
    home's path (RoseCat 7753). Each component opened must be the one lstat saw first."""
    path = os.fspath(home)
    names = [n for n in path.split("/") if n]
    if not os.path.isabs(path) or any(n in (".", "..") for n in names):
        raise OSError(errno.EINVAL, "the sign-in's home is not an absolute, plain path")
    trusted = (TRUST_ANCHOR_UID, euid)
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for name in names:
            here, seen = os.fstat(fd), os.lstat(name, dir_fd=fd)
            if here.st_uid not in trusted or (here.st_mode & 0o022 and not here.st_mode & stat.S_ISVTX):
                raise OSError(errno.EPERM, f"a directory above the sign-in's home is not safe ({name})")
            if not stat.S_ISDIR(seen.st_mode):
                raise OSError(errno.ENOTDIR, f"the sign-in's home path is not plain directories ({name})")
            nxt = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = nxt
            if not os.path.samestat(os.fstat(fd), seen):
                raise OSError(errno.EPERM, f"the sign-in's home path changed while it was walked ({name})")
        st = os.fstat(fd)
        if st.st_uid != euid or st.st_mode & 0o022:
            raise OSError(errno.EPERM, "the sign-in's home is not ours alone")
        return fd
    except BaseException:
        os.close(fd)
        raise


class PrivateTmp:
    """The checked home, scratchpad and tmp, each held open (so its inode cannot be reused) with the path the CLI
    is given. recheck(), right before the launch, refuses when a path no longer names its checked directory."""

    def __init__(self):
        self.held = []  # (path, fd)
        self.config = None  # (name below tmp, path, held fd)

    def make_login_config(self):
        """Create and hold one unpredictable private directory below the checked tmp."""
        tmp_path, tmp_fd = self.held[-1]
        for _ in range(100):
            name = ".zb-login-config-" + secrets.token_hex(12)
            try:
                os.mkdir(name, 0o700, dir_fd=tmp_fd)
                break
            except FileExistsError:
                continue
        else:
            raise OSError(errno.EEXIST, "could not create a unique sign-in config directory")
        path = os.path.join(tmp_path, name)
        seen = os.lstat(name, dir_fd=tmp_fd)
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=tmp_fd)
        st = os.fstat(fd)
        if not os.path.samestat(st, seen) or st.st_uid != os.geteuid() or stat.S_IMODE(st.st_mode) != 0o700:
            os.close(fd)
            os.rmdir(name, dir_fd=tmp_fd)
            raise OSError(errno.EPERM, "the sign-in config directory is not private")
        self.held.append((path, fd))
        self.config = (name, path, fd)
        return path

    def remove_login_config(self):
        """Remove only the exact directory made above, after the CLI has exited."""
        if self.config is None:
            return
        name, _path, fd = self.config
        tmp_fd = self.held[-2][1]
        try:
            seen = os.lstat(name, dir_fd=tmp_fd)
        except FileNotFoundError:
            self.config = None
            return
        if not os.path.samestat(seen, os.fstat(fd)) or not stat.S_ISDIR(seen.st_mode):
            raise OSError(errno.EPERM, "the sign-in config directory changed before cleanup")
        shutil.rmtree(name, dir_fd=tmp_fd)
        self.config = None

    def recheck(self):
        for path, fd in self.held:
            if not os.path.samestat(os.lstat(path), os.fstat(fd)):
                raise OSError(errno.EPERM, f"the sign-in's {os.path.basename(path)} changed after it was checked")

    def close(self):
        try:
            self.remove_login_config()
        finally:
            held, self.held = self.held, []
            for _, fd in held:
                os.close(fd)


def ensure_private_tmp(home):
    """Makes sure <home>/scratchpad and <home>/scratchpad/tmp (cli_env's TMPDIR) are real directories of the
    effective uid, mode 0700, before the CLI starts (setup.ensure_home's layout), and returns them held
    (PrivateTmp). The home is reached through a checked chain from / (open_home). The two are walked through held
    directory fds, never following a link: a missing component is made 0700; any other existing state (a link, a
    file, a FIFO, a wider mode, another owner) raises OSError and is left as it is (RoseCat 7739). Nothing is ever
    repaired: the object opened must be the very one lstat saw first, and it is accepted only as it is, so a
    directory swapped in between mkdir and open is refused unchanged (RoseCat 7746).

    Trust boundary (RoseCat 7746/7753): the CLI resolves TMPDIR and CLAUDE_CODE_TMPDIR by path for its whole run,
    so no fd could bind them. The chain check is what makes that safe: after it, only root or our own uid can
    rename anything on those paths. The caller rechecks them right before the launch."""
    euid = os.geteuid()
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    held = PrivateTmp()
    try:
        path, fd = os.fspath(home), open_home(home, euid)
        held.held.append((path, fd))
        for name in ("scratchpad", "tmp"):
            try:
                os.mkdir(name, 0o700, dir_fd=fd)  # 0700 under any umask that leaves the owner's bits alone
            except FileExistsError:
                pass
            seen = os.lstat(name, dir_fd=fd)  # never opens a FIFO or follows a link
            if not stat.S_ISDIR(seen.st_mode):
                raise OSError(errno.ENOTDIR, f"the sign-in's {name} is not a directory")
            path, fd = os.path.join(path, name), os.open(name, flags, dir_fd=fd)
            held.held.append((path, fd))
            st = os.fstat(fd)
            if not os.path.samestat(st, seen):
                raise OSError(errno.EPERM, f"the sign-in's {name} changed while it was opened")
            if st.st_uid != euid or stat.S_IMODE(st.st_mode) != 0o700:
                raise OSError(errno.EPERM, f"the sign-in's {name} is not a private directory")
        held.recheck()
        return held
    except BaseException:
        held.close()
        raise


class Login:
    def __init__(self, home, cli, out, token_fd, timeout_s=TIMEOUT_S, exchange_s=EXCHANGE_S, proxy=None):
        self.home, self.cli, self.out, self.token_fd = home, cli, out, token_fd
        self.proxy = proxy if proxy is not None else sandbox.helper_proxy()
        self.deadline = time.monotonic() + timeout_s
        self.exchange_s = exchange_s
        self.exchange_by = None  # set when a code is typed; cleared when the CLI asks again
        self.typed_at = 0  # the screen offset when the code was written
        self.enter_by = None  # a step of typing the code is pending; the echo must account for it by then
        self.typing = b""  # the code's bytes still to be typed, before its Enter
        self.typed = 0  # the code's bytes written so far
        self.echo_at = None  # the end of the CLI's masked echo of it: its answer starts here
        self.screen = bytearray()  # the pty output, escapes removed; zeroed at the end
        self.prompts = 0  # prompts seen
        self.answered = 0  # prompts a code was written to
        self.code = None  # the first code waiting for the next prompt; later ones are dropped
        self.sent_url = False
        self.lock = threading.Lock()
        self.ended = threading.Event()
        # One ending: `done`, `error` and `cancel` race for this claim (RoseCat 5967). It is
        # separate from `lock`, which scan() holds while it may end the sign-in.
        self.end_lock = threading.Lock()
        self.outcome = None
        self.proc = None
        self.master = -1
        self.private_tmp = None

    # ---- the CLI on a pty -------------------------------------------------
    def spawn(self):
        held = ensure_private_tmp(self.home)  # before anything starts: an invalid temp dir launches nothing
        try:
            config_dir = held.make_login_config()
            env = cli_env(self.home, self.proxy, config_dir)
            self.master, slave = pty.openpty()
            try:
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, COLUMNS, 0, 0))
                held.recheck()  # right before the launch (RoseCat 7746/7768): still the checked directories
                self.proc = subprocess.Popen([self.cli, "setup-token"], stdin=slave, stdout=slave, stderr=slave,
                                             env=env, cwd=self.home, start_new_session=True, close_fds=True)
            except BaseException:
                os.close(self.master)
                self.master = -1
                raise
            finally:
                os.close(slave)
            self.private_tmp, held = held, None
        finally:
            if held is not None:
                held.close()

    def kill(self):
        if self.proc and self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if self.proc:
            self.proc.wait()
        if self.private_tmp is not None:
            held, self.private_tmp = self.private_tmp, None
            held.close()

    def read_pty(self):
        chunk = bytearray(16384)
        try:
            while not self.ended.is_set():
                now = time.monotonic()
                left = self.deadline - now
                if left <= 0:
                    return self.end("error", code="timeout", message="sign-in timed out")
                exchange_by = self.exchange_by
                if exchange_by is not None and now >= exchange_by:
                    return self.end("error", code="timeout", message="the Claude CLI did not finish the sign-in")
                wait = min(left, 0.5)
                if self.enter_by is not None:
                    with self.lock:
                        enter_by = self.enter_by
                        # The echo accounts for all but at most CHUNK of the typed bytes: the next step.
                        grew = enter_by is not None and self.screen[self.typed_at:].count(b"*") >= self.typed - CHUNK
                        if grew:
                            self.enter()
                    if grew:
                        continue
                    if enter_by is not None and now >= enter_by:
                        return self.end("error", code="cli", message="the Claude CLI did not take the code in")
                    if enter_by is not None:
                        wait = max(0.0, min(wait, enter_by - now))
                if not select.select([self.master], [], [], wait)[0]:
                    continue
                try:
                    n = os.readv(self.master, [chunk])
                except OSError:
                    n = 0
                if n == 0:
                    with self.lock:
                        printed = SUCCESS in bytes(self.screen).replace(b" ", b"")
                    if printed:
                        return self.end("error", code="shape", message="the Claude CLI printed no setup token")
                    return self.end("error", code="cli", message="the Claude CLI ended before the token")
                with self.lock:
                    self.screen += CONTROL.sub(b"", ESCAPE.sub(b"", bytes(memoryview(chunk)[:n])).replace(b"\r", b""))
                    if len(self.screen) > MAX_SCREEN:
                        return self.end("error", code="cli", message="the Claude CLI printed too much")
                    self.scan()
        finally:
            chunk[:] = bytes(len(chunk))

    def scan(self):
        """Act on what the screen now shows (called with the lock held)."""
        if not self.sent_url:
            for m in URL.finditer(self.screen):
                url = authorize_url(m.group().decode("ascii"))
                if url:
                    self.sent_url = True
                    self.out.emit("auth_url", url=url)
                    break
        squeezed = bytes(self.screen).replace(b" ", b"")
        prompts = squeezed.count(PROMPT)
        while self.prompts < prompts:
            self.prompts += 1
            if not self.sent_url:
                return self.end("error", code="cli", message="the Claude CLI printed no sign-in address")
            self.exchange_by = None  # it asked again: the user's time, not the exchange's
            self.out.emit("need_code")
        self.answer()
        at = self.screen.find(b"successfully!")
        if SUCCESS in squeezed and at >= 0:
            m = TOKEN.search(self.screen, at)
            if m:
                return self.hand_off(*m.span())
        if self.exchange_by is not None and self.echo_at is None:
            echo = ECHO.search(self.screen, self.typed_at)
            if echo:
                self.echo_at = echo.end()
        if self.exchange_by is not None and self.echo_at is not None:
            reply = bytes(self.screen[self.echo_at:]).replace(b" ", b"")
            if any(word in reply for word in EXCHANGE_FAILED):
                return self.end("error", code="exchange", message="the Claude CLI could not exchange the code")

    def answer(self):
        if self.code is not None and self.answered < self.prompts:
            code, self.code = self.code, None
            self.answered = self.prompts
            self.typed_at = len(self.screen)
            self.echo_at = None
            self.exchange_by = time.monotonic() + self.exchange_s
            self.typing = code.encode("ascii")
            self.typed = 0
            self.enter_by = time.monotonic() + STEP_S
            self.enter()  # its first piece

    def enter(self):
        """The next step of typing the code: its next piece, or, when all of it is typed, its
        Enter, alone (called with the lock held). One linearization with every ending (RoseCat
        6493): under end_lock, which claim() holds to end the sign-in, so once an ending is
        claimed no step reaches the CLI (an Enter could submit a code the user cancelled), and
        a step already written came before the ending."""
        with self.end_lock:
            if self.enter_by is None:
                return
            if self.ended.is_set():
                self.enter_by, self.typing = None, b""
                return
            if self.typing:
                piece, self.typing = self.typing[:CHUNK], self.typing[CHUNK:]
            else:
                piece = b"\r"
            if piece != b"\r":
                self.typed += len(piece)
            self.enter_by = time.monotonic() + STEP_S if piece != b"\r" else None
            os.write(self.master, piece)

    def claim(self):
        """True for exactly one caller: the one whose ending is the sign-in's."""
        with self.end_lock:
            if self.ended.is_set():
                return False
            self.ended.set()
            return True

    def hand_off(self, start, end):
        """The token to fd 4, only if `done` wins the ending: a cancel or an error that
        won it first means fd 4 gets nothing."""
        if not self.claim():
            return
        token = memoryview(self.screen)[start:end]
        try:
            written = os.write(self.token_fd, token)
        except OSError:  # the app closed its end: still exactly one ending
            written = -1
        finally:
            token.release()
        os.close(self.token_fd)
        self.token_fd = -1
        if written != end - start:
            return self.emit_end("error", code="cli", message="the token could not be handed over")
        self.emit_end("done")

    def end(self, type_, **fields):
        if self.claim():
            self.emit_end(type_, **fields)

    def emit_end(self, type_, **fields):
        self.outcome = type_
        self.out.emit(type_, **fields)

    # ---- app frames -------------------------------------------------------
    def read_frames(self, stream):
        for line in stream:
            if self.ended.is_set():
                return
            if len(line) > MAX_FRAME:
                return self.end("error", code="protocol", message="frame too long")
            try:
                frame = json.loads(line)
            except ValueError:
                return self.end("error", code="protocol", message="frame is not JSON")
            kind = frame.get("type") if isinstance(frame, dict) else None
            if kind == "cancel":
                return self.end("error", code="cancelled", message="sign-in cancelled")
            if kind == "code":
                if not valid_code(frame.get("code")):
                    return self.end("error", code="protocol", message="code refused")
                with self.lock:
                    if self.code is None:  # the first code to arrive is used (D7b)
                        self.code = frame["code"]
                    self.answer()
                continue
            return self.end("error", code="protocol", message="unexpected frame")
        self.end("error", code="cancelled", message="sign-in cancelled")

    def run(self, stream):
        first = stream.readline()
        try:
            frame = json.loads(first) if len(first) <= MAX_FRAME else None
        except ValueError:
            frame = None
        if not isinstance(frame, dict) or frame.get("type") != "start":
            self.end("error", code="protocol", message="expected start")
            return 2
        try:
            self.spawn()
        except OSError:
            self.end("error", code="cli", message="the Claude CLI could not start")
            return 1
        threading.Thread(target=self.read_frames, args=(stream,), daemon=True).start()
        try:
            self.read_pty()
            self.ended.wait()
        finally:
            self.kill()
            with self.lock:
                self.screen[:] = bytes(len(self.screen))
            os.close(self.master)
            if self.token_fd >= 0:
                os.close(self.token_fd)
        return 0 if self.outcome == "done" else 1


def main(argv):
    parser = argparse.ArgumentParser(prog="zb_agent_host login")
    parser.add_argument("--home", required=True)
    parser.add_argument("--e2e-claude-cli")
    parser.add_argument("--egress-port", type=sandbox.loopback_port)  # a relay-less backend's direct port (macOS)
    args = parser.parse_args(argv)
    if args.e2e_claude_cli:
        cli = args.e2e_claude_cli
    else:
        from .token import bundled_cli
        cli = bundled_cli()
    try:
        os.fstat(TOKEN_FD)
    except OSError:
        print("zb_agent_host login: no fd 4", file=sys.stderr)
        return 2
    return Login(args.home, cli, Emitter(), TOKEN_FD, proxy=sandbox.helper_proxy(args.egress_port)).run(sys.stdin)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
