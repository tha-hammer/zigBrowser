"""`login` (chat-drawer plan S6, D7b; rev 16.18): the one-shot sign-in helper.

    python -m zb_agent_host login --home H [--e2e-claude-cli CLI]   (fd 4: the token)

It runs `claude setup-token` on a pty, with HOME and CLAUDE_CONFIG_DIR set to
the agent home, as the real CLI (2.1.301, captured in
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
import json
import os
import re
import select
import signal
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
# state always is). The Enter goes once the CLI's masked echo shows it took the code in and
# its output has been quiet for QUIET_S (it may take a code in several reads, and the Enter
# must never share a read with the code's remainder; rev 16.20.28, RoseCat 6493), or after
# ENTER_FALLBACK_S when no echo comes (a code too short for ECHO). Never after an ending.
ENTER_FALLBACK_S = 1.0
QUIET_S = 0.15
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


def relay_proxy():
    """The chat helper's HTTPS_PROXY (options.RELAY_PROXY), from the same backend
    endpoint; read here directly so the login helper does not import the SDK."""
    ep = sandbox.egress_endpoint()
    return f"http://{ep.host}:{ep.port}"


def cli_env(home):
    proxy = relay_proxy()
    return {
        "HOME": home,
        "CLAUDE_CONFIG_DIR": os.path.join(home, ".claude"),
        "PATH": "/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "TERM": "xterm-256color",
        "BROWSER": "/bin/true",
        # The sandbox's only way out is the outer relay (rev 16.18.9).
        "HTTPS_PROXY": proxy,
        "HTTP_PROXY": proxy,
        "NO_PROXY": "127.0.0.1,localhost",
    }


class Login:
    def __init__(self, home, cli, out, token_fd, timeout_s=TIMEOUT_S, exchange_s=EXCHANGE_S):
        self.home, self.cli, self.out, self.token_fd = home, cli, out, token_fd
        self.deadline = time.monotonic() + timeout_s
        self.exchange_s = exchange_s
        self.exchange_by = None  # set when a code is typed; cleared when the CLI asks again
        self.typed_at = 0  # the screen offset when the code was written
        self.enter_by = None  # a code was typed and its Enter is still to be written, by then
        self.last_out = 0.0  # when the CLI last printed something
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

    # ---- the CLI on a pty -------------------------------------------------
    def spawn(self):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, COLUMNS, 0, 0))
        self.proc = subprocess.Popen([self.cli, "setup-token"], stdin=slave, stdout=slave, stderr=slave,
                                     env=cli_env(self.home), cwd=self.home, start_new_session=True,
                                     close_fds=True)
        os.close(slave)

    def kill(self):
        if self.proc and self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if self.proc:
            self.proc.wait()

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
                        enter_by, echoed, quiet_at = self.enter_by, self.echo_at is not None, self.last_out + QUIET_S
                        # The echo came and the CLI is quiet: it took all of the code in. Or no
                        # echo came in time: the Enter anyway. Either way, its own write.
                        due = enter_by is not None and (now >= enter_by or (echoed and now >= quiet_at))
                        if due:
                            self.enter()
                    if due:
                        continue
                    if enter_by is not None:
                        wait = max(0.0, min(wait, enter_by - now, quiet_at - now if echoed else wait))
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
                    self.last_out = time.monotonic()
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
            self.enter_by = time.monotonic() + ENTER_FALLBACK_S
            os.write(self.master, code.encode("ascii"))

    def enter(self):
        """The typed code's Enter, as its own write (called with the lock held). One
        linearization with every ending (RoseCat 6493): under end_lock, which claim() holds to
        end the sign-in, so once an ending is claimed no Enter reaches the CLI (it could submit
        a code the user cancelled), and an Enter already written came before the ending."""
        with self.end_lock:
            if self.enter_by is None:
                return
            self.enter_by = None
            if not self.ended.is_set():
                os.write(self.master, b"\r")

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
    return Login(args.home, cli, Emitter(), TOKEN_FD).run(sys.stdin)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
