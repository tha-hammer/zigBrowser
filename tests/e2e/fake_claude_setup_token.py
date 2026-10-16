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

Every line it reads at the prompt is appended to $HOME/.zb-fake-setup-token/codes.log
(the "received-code log" the S6 tests read). The token it prints is the content of
$HOME/.zb-fake-setup-token/token when that file exists, else CANARY.
Standard library only: it runs inside the helper's sandbox, which has /usr only.
"""

import os
import secrets
import sys
import termios

CANARY = "sk-ant-oat01-ZBCANARY-login-0123456789abcdef"
CLIENT_ID = "00000000-0000-4000-8000-00000000fa6e"
AUTHORIZE = "https://claude.com/cai/oauth/authorize"
REDIRECT = "https://platform.claude.com/oauth/code/callback"
# The capture's two <REDACTED> runs are prose the CLI prints between them.
INTRO = "<intro>(1-year)<subscription>.Claudesubscriptionrequired."

INVALID = "Invalid code. Please make sure the full code was copied."
FOREIGN = "That code is not from this sign-in. Paste the code shown after opening the address above."


def b64url(n):
    return secrets.token_urlsafe(n)[: (n * 4 + 2) // 3]


def authorize_url(challenge, state):
    return (
        f"{AUTHORIZE}?code=true&client_id={CLIENT_ID}&response_type=code"
        f"&redirect_uri={REDIRECT}&scope=user:inference&code_challenge={challenge}"
        f"&code_challenge_method=S256&state={state}"
    )


def fake_dir():
    return os.path.join(os.environ.get("HOME", "/nonexistent"), ".zb-fake-setup-token")


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
    out("✓ Long-lived authentication token created successfully!")
    out("Your OAuth token (valid for 1 year):")
    out(token())
    out("Storethistokensecurely.Youwon'tbeabletoseeitagain.")
    out("Usethistokenbysetting:exportCLAUDE_CODE_OAUTH_TOKEN=<token>")
    out("\x1b\x1b\x1b\x0f\x1b7\x1b8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
