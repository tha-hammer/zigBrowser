"""MS5.1 on a Mac (macOS plan): setup inherits the S3a corrections (da5eb70; RoseCat 833767e), not today's defects.
Under the STAGED pinned runtime the staged python3.12 imports the staged zb_agent_host, and the real setup.provision
(the token route off: no CLI is run, no sandbox is entered) builds an agent home from three SAI sources this case
writes under the real path of its scratch (macOS /tmp is a link to private/tmp; 8413992), each into its own home:
- chain: CLAUDE.md -> hop/CLAUDE.md with hop -> a directory outside (a link in a parent component). Setup warns
  "skipped CLAUDE.md: its link is a chain", and the target's canary is in no file of the home;
- alias: skills/alias and skills/zzz-alias -> real (internal aliases before and after the real name) and
  skills/real/loop -> .. (a real cycle). Setup ends within 30 s, all three names hold the payload, and it warns
  "a link cycle";
- quote: a Stop hook whose command is `python3 "unterminated` (a malformed quote). Setup refuses with SetupError
  "hook command has shell syntax" (never a parser crash) and leaves no agent home.
Kill safety: this case starts no process and sends no signal (provision runs no CLI with the route off). It reads
no other case file. Linux proof with fakes: tests/e2e/ms5_1_hard_gate_case_test.py. PENDING its kill-safety review
(tests/mac/hard_gate_pending/): on approval it moves into tests/mac/hard_gate/ with its MANIFEST.json entry."""
import contextlib
import io
import json
import os
import stat
import sys
import time

NAME = "ms5.1-s3a-links"
CANARY = b"ZB-MS51-CHAIN-CANARY"


def _source(root):
    """A fresh SAI source (~/.claude with settings.json {}) under `root`; returns (source_home, source)."""
    source_home = os.path.join(root, "user")
    source = os.path.join(source_home, ".claude")
    os.makedirs(source, 0o700)
    with open(os.path.join(source, "settings.json"), "w") as f:
        f.write("{}\n")
    return source_home, source


def _provision(setup, options, h, root, source_home, source):
    """(home, error repr or None, stderr text, seconds) of one real provision into root/data/zigbrowser/agent-home."""
    home = options.AgentHome(os.path.join(root, "data", "zigbrowser", "agent-home"))
    err, error = io.StringIO(), None
    started = time.monotonic()
    try:
        with contextlib.redirect_stderr(err):
            setup.provision(home=home, source=source, source_home=source_home, source_path="/usr/bin:/bin",
                            python=h.python, select_token_route=False, cli=h.cli)
    except Exception as exc:  # noqa: BLE001 - the row decides what it expects
        error = exc
    return home, error, err.getvalue(), time.monotonic() - started


def _has_canary(root):
    """Whether any regular file under `root` (walked without following links, read O_NOFOLLOW) holds the canary;
    an unreadable one or another kind of entry counts as holding it (fail closed)."""
    for top, _dirs, files in os.walk(root, followlinks=False, onerror=lambda e: (_ for _ in ()).throw(e)):
        for name in files:
            path = os.path.join(top, name)
            st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode):
                continue
            if not stat.S_ISREG(st.st_mode):
                return True
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                with os.fdopen(fd, "rb") as f:
                    if CANARY in f.read():
                        return True
            except OSError:
                return True
    return False


def run(h):
    prefix = h.prefix
    if not h.check(bool(prefix) and os.path.isdir(os.path.join(prefix or "", "zb_agent_host")),
                   f"the staged agent-host is present (ZB_HG_PREFIX={prefix!r})"):
        return
    if not h.check(bool(h.python) and os.path.realpath(sys.executable) == os.path.realpath(h.python),
                   f"this case runs under the staged interpreter ({sys.executable} vs {h.python})"):
        return
    sys.path.insert(0, prefix)
    from zb_agent_host import options, setup  # the staged tree's own modules
    scratch = os.path.realpath(h.scratch)

    root = os.path.join(scratch, "chain")
    source_home, source = _source(root)
    outside = os.path.join(root, "outside")
    os.mkdir(outside, 0o700)
    with open(os.path.join(outside, "CLAUDE.md"), "wb") as f:
        f.write(CANARY + b"\n")
    os.symlink(outside, os.path.join(root, "hop"))
    os.symlink(os.path.join(root, "hop", "CLAUDE.md"), os.path.join(source, "CLAUDE.md"))
    home, error, err, _ = _provision(setup, options, h, root, source_home, source)
    if h.check(error is None, f"chain: setup provisions the home ({error!r}; stderr tail {err[-200:]!r})"):
        h.check("skipped CLAUDE.md: its link is a chain" in err,
                f"chain: skipped CLAUDE.md as a chain with setup's warning ({err[-200:]!r})")
        h.check(not _has_canary(str(home.root)), "chain: the canary is nowhere in the home")

    root = os.path.join(scratch, "alias")
    source_home, source = _source(root)
    real = os.path.join(source, "skills", "real")
    os.makedirs(real, 0o700)
    with open(os.path.join(real, "payload.txt"), "w") as f:
        f.write("payload\n")
    for alias in ("alias", "zzz-alias"):
        os.symlink("real", os.path.join(source, "skills", alias))
    os.symlink("..", os.path.join(real, "loop"))
    home, error, err, took = _provision(setup, options, h, root, source_home, source)
    if h.check(error is None, f"alias: setup provisions the home ({error!r}; stderr tail {err[-200:]!r})"):
        held = []
        for name in ("real", "alias", "zzz-alias"):
            try:
                with open(os.path.join(str(home.root), ".claude", "skills", name, "payload.txt")) as f:
                    held.append(f.read() == "payload\n")
            except OSError:
                held.append(False)
        h.check(all(held), f"alias: both names hold the payload, beside the real one ({held})")
        h.check("a link cycle" in err and took < 30, f"alias: the cycle is bounded and warned ({took:.1f} s)")

    root = os.path.join(scratch, "quote")
    source_home, source = _source(root)
    with open(os.path.join(source, "settings.json"), "w") as f:
        json.dump({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": 'python3 "unterminated'}]}]}}, f)
    home, error, err, _ = _provision(setup, options, h, root, source_home, source)
    h.check(isinstance(error, setup.SetupError) and "hook command has shell syntax" in str(error),
            f"quote: setup refuses the malformed quote ({error!r})")
    h.check(not os.path.lexists(str(home.root)), "quote: no agent home is left behind")
