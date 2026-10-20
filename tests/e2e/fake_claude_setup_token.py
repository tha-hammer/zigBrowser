#!/usr/bin/python3 -IS
"""A stand-in for `claude setup-token` (chat-drawer plan S6; the CLI boundary).

It replays the real CLI's output as the orchestrator captured it from Claude
Code v2.1.301 (tests/fixtures/agent/setup_token_transcript.json), with the
placeholders filled: a fresh state and code challenge each run, a fixed fake
client id, and the token. fake_claude_setup_token_test.py checks the two match
line for line, placeholders aside.

What it copies from the real CLI (2.1.301's own source, read, not run):
- the redirect is the manual code page https://platform.claude.com/oauth/code/callback;
  nothing listens on any port;
- the code is read at the prompt "Paste code here if prompted >" only when stdin
  and stdout are terminals (here: anything else exits 2, so a helper that does
  not give it a pty fails loudly);
- a pasted line is trimmed and split on '#' into code and state; a line without
  both parts, or with another sign-in's state, gets the CLI's own sentence and
  the prompt again; input is not echoed, a '*' per character is.

Its files live in $HOME/scratchpad/.zb-fake-setup-token/ when $HOME/scratchpad is a
directory (inside the helper's sandbox only the agent home's scratchpad is writable;
plan rev 16.18.3), else in $HOME/.zb-fake-setup-token/:
- `codes.log`: every line it reads at the prompt (the "received-code log" the S6
  tests read);
- `state`: this run's state, written before the prompt (the S6b1 e2e pastes it);
- `token`: when it exists, the token it prints, else CANARY;
- `mode` (rev 16.18.9, S6b1 part B's finding): when it exists, what follows a right
  code, as the real CLI behaves (an offline probe of 2.1.294; the helper strips the
  CLI's environment, so this is a file, not a variable):
  - `oauth-error`: the real CLI's "OAuth error: getaddrinfo EAI_AGAIN
    platform.claude.com" and "Press Enter to retry.", then it waits; each line it reads
    prints them again;
  - `silent`: nothing; it waits;
  - `needs-proxy`: without HTTPS_PROXY, as `oauth-error` (the real CLI resolves the
    host itself, and the sandbox has no network); with it, one
    `CONNECT zb-proxy-probe.invalid:443` through that proxy (the login netd refuses
    and censuses it: nothing goes further), then success.
Standard library only: it runs inside the helper's sandbox, which has /usr only.
"""

import os
import secrets
import socket
import sys
import termios
from urllib.parse import urlsplit

CANARY = "sk-ant-oat01-ZBCANARY-login-0123456789abcdef"
CLIENT_ID = "00000000-0000-4000-8000-00000000fa6e"
AUTHORIZE = "https://claude.com/cai/oauth/authorize"
REDIRECT = "https://platform.claude.com/oauth/code/callback"
# The capture's two <REDACTED> runs are prose the CLI prints between them.
INTRO = "<intro>(1-year)<subscription>.Claudesubscriptionrequired."

INVALID = "Invalid code. Please make sure the full code was copied."
FOREIGN = "That code is not from this sign-in. Paste the code shown after opening the address above."
# The real CLI's lines after a failed exchange (2.1.294, probed offline; rev 16.18.9).
OAUTH_ERROR = "OAuth error: getaddrinfo EAI_AGAIN platform.claude.com"
RETRY = "Press Enter to retry."
PROBE = "zb-proxy-probe.invalid:443"


def b64url(n):
    return secrets.token_urlsafe(n)[: (n * 4 + 2) // 3]


def authorize_url(challenge, state):
    return (
        f"{AUTHORIZE}?code=true&client_id={CLIENT_ID}&response_type=code"
        f"&redirect_uri={REDIRECT}&scope=user:inference&code_challenge={challenge}"
        f"&code_challenge_method=S256&state={state}"
    )


def fake_dir():
    home = os.environ.get("HOME", "/nonexistent")
    scratch = os.path.join(home, "scratchpad")
    return os.path.join(scratch if os.path.isdir(scratch) else home, ".zb-fake-setup-token")


def write_state(state):
    os.makedirs(fake_dir(), mode=0o700, exist_ok=True)
    with open(os.path.join(fake_dir(), "state"), "w", encoding="ascii") as f:
        f.write(state + "\n")


def token():
    try:
        with open(os.path.join(fake_dir(), "token"), encoding="ascii") as f:
            return f.read().strip()
    except OSError:
        return CANARY


def log_code(line):
    os.makedirs(fake_dir(), mode=0o700, exist_ok=True)
    with open(os.path.join(fake_dir(), "codes.log"), "a", encoding="utf-8") as f:
        f.write(line + "\n")


def mode():
    try:
        with open(os.path.join(fake_dir(), "mode"), encoding="ascii") as f:
            return f.read().strip()
    except OSError:
        return ""


def through_proxy():
    """One CONNECT to PROBE through $HTTPS_PROXY; True when the proxy answered at all."""
    proxy = os.environ.get("HTTPS_PROXY")
    if not proxy:
        return False
    url = urlsplit(proxy)
    try:
        with socket.create_connection((url.hostname, url.port or 80), timeout=10) as s:
            s.sendall(f"CONNECT {PROBE} HTTP/1.1\r\nHost: {PROBE}\r\n\r\n".encode("ascii"))
            return s.recv(64).startswith(b"HTTP/1.")
    except OSError:
        return False


def fail_and_wait():
    """The real CLI after a failed exchange: two lines, then each Enter retries and fails again."""
    while True:
        out(OAUTH_ERROR)
        out(RETRY)
        if sys.stdin.readline() == "":
            return 1


def out(text=""):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def prompt():
    out("Pastecodehereifprompted>")
    out("\x1b\x0f\x1b\x1b\x1b\x1b\x0f\x1b\x1b\x1b")


def read_masked():
    """One line from the terminal with echo off; echoes a '*' per character."""
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    new = termios.tcgetattr(fd)
    new[3] &= ~termios.ECHO
    termios.tcsetattr(fd, termios.TCSANOW, new)
    try:
        line = sys.stdin.readline()
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, old)
    if not line:
        return None
    line = line.rstrip("\r\n")
    out("*" * len(line))
    return line


def main(argv):
    if argv != ["setup-token"]:
        print("usage: fake_claude_setup_token.py setup-token", file=sys.stderr)
        return 2
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        print("fake setup-token: stdin and stdout must be a terminal", file=sys.stderr)
        return 2
    state = b64url(32)
    out("\x1b7\x1b8\x1b\x1b\x1bWelcometoClaudeCodev2.1.301")
    out(INTRO)
    out("\x1b·Openingbrowsertosignin…")
    out("Browser didn't open? Use the url below to sign in (c to copy)")
    out(authorize_url(b64url(32), state))
    write_state(state)
    prompt()
    while True:
        line = read_masked()
        if line is None:
            return 1
        line = line.strip()
        if not line:
            prompt()
            continue
        log_code(line)
        parts = line.split("#")
        if len(parts) < 2 or not parts[0] or not parts[1]:
            out(INVALID)
            prompt()
            continue
        if parts[1] != state:
            out(FOREIGN)
            prompt()
            continue
        break
    how = mode()
    if how == "oauth-error" or (how == "needs-proxy" and not through_proxy()):
        return fail_and_wait()
    if how == "silent":
        while sys.stdin.readline() != "":
            pass
        return 1
    out("✓ Long-lived authentication token created successfully!")
    out("Your OAuth token (valid for 1 year):")
    out(token())
    out("Storethistokensecurely.Youwon'tbeabletoseeitagain.")
    out("Usethistokenbysetting:exportCLAUDE_CODE_OAUTH_TOKEN=<token>")
    out("\x1b\x1b\x1b\x0f\x1b7\x1b8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
