"""MS6.3's hard gate (plan MS6.3; BlueBeaver 7514, 7523; the orchestrator's calls on 7514): the REAL pinned CLI
consumes the exact token from the production fd-3 channel, under the generated CLI profile, on a Mac. Under the
STAGED pinned runtime:
  a fake Messages API: production's own route_probe._ProbeServer, in this case process OUTSIDE Seatbelt, on
  127.0.0.1:<P> (it records the bearer of the first /v1/messages and streams a short reply)
  -> /bin/sh places one socketpair end, holding only the token, on fd 3 and closes the original
  -> sandbox_macos.MacSeatbeltBackend(P).launch(home): sandbox-exec with the generated CLI profile (egress only to
     127.0.0.1:P plus the canonical bridges; writes only to the home's scratchpad)
  -> python -m zb_agent_host contract-config (the helper reads fd 3 and hands the token through its FifoHandoff to the
     zb-claude wrapper, written for h.cli as setup.stage writes it) -> the real CLI, whose token arrives on fd 3.
The home is pre-created exactly as setup.stage lays it out, under the REAL path of this case's scratch: the profile's
write root is the scratchpad's spelling, Seatbelt compares resolved paths, and macOS's /tmp is a symlink to
private/tmp (11b3ac4 on both Macs: every write, the token-fifo inside the scratchpad included, was denied; RoseCat
7627). Each row checks its scratchpad is its own real path. Any other write the chain makes outside the scratchpad
is left to fail visibly under the profile (measured evidence, not hidden).
Rows:
 1. positive: the exact generated profile denies a read of ~/.ssh/id_canary, then the real CLI starts, answers,
    and sends exactly "Bearer <canary>" from fd 3;
 2. decoy: that profile again denies ~/.ssh/id_canary, then the real CLI sends the different token on fd 3: it
    follows fd 3, not a cached credential, an environment variable or a keychain item;
 3. no channel: no fd 3 -> rc != 0 and no request at all (the canary never reaches the server).
In rows 1 and 2, WHILE the CLI's request is being served, production's census (proc_darwin.cli_env_census over this
process's descendants, outside Seatbelt) must say "ok", and the row records only that fixed reason (RoseCat 7986: a
census outside CENSUS_REASONS, or one that raises, is recorded as "invalid", never echoed): at least one descendant
runs the CLI, every one's environment reads, holds the exact ANTHROPIC_BASE_URL of this row's server, and holds the
row's token nowhere.
After EVERY row: the server's port is free on 127.0.0.1 and ::1, and no process of ours runs the CLI or is a python
naming the row's home (waited out to the row's horizon, never signalled; the inspection fails closed).
Self-contained (the orchestrator, 7514 (c)): the helpers below are this case's own copies of the R1 case's reviewed
ones, so this file's digest covers all of its logic.
Tokens never reach a label: only verdicts, rc and sanitized output tails.
Kill safety: this case makes no signal call. Its runs and ps go through the guarded h.spawn_group (its own group,
bounded, the owned-group stop)."""
import json
import os
import re
import socket
import stat
import sys
import time

NAME = "ms6.3-fd3-cli"
PROMPT = "hi"
CANARY = "sk-ant-oat01-ZBCANARY" + "q7x2" * 10  # fixed test tokens: 16-512 printable, never real credentials
DECOY = "sk-ant-oat01-ZBDECOY" + "m3k9" * 10
SSH_CANARY = b"zb-ms6-private-ssh\n"
PLACE_FD3 = 'fd=$1; shift; [ "$fd" -eq 3 ] || eval "exec 3<&$fd $fd<&-"; exec "$@"'  # already 3: kept as is
RUN_TIMEOUT_S = 120
CHAIN_GRACE_S = 15  # a finished row's chain is gone within this
CHAIN_HORIZON_S = RUN_TIMEOUT_S + 30  # from the row's start: its group was stopped at RUN_TIMEOUT_S at the latest
DIAG_MAX = 600  # characters of each output stream shown when a row fails
_REDACT = [re.compile(p) for p in (
    r"sk-ant-\S+",
    r"(?i)bearer\s+\S+",
    r"(?i)(?:token|authorization|secret|key)\w*\s*[=:]\s*\S+",
    r"[0-9A-Fa-f]{6,}",
    r"[A-Za-z0-9+_=-]{24,}",  # any long base64-ish run (an encoded token)
)]
_PS_ROW = re.compile(r"([0-9]+)\s+(-?[0-9]+)\s+(\S+)")  # pid, uid (macOS shows nobody as -2), stat


def _turn_completed(out):
    """The helper's stdout holds a result frame that succeeded: one NDJSON line, UTF-8, that is a JSON object with type
    "result", subtype "success" and is_error false. The helper writes compact frames (frames.encode), so the bytes
    are never matched as text (11eaceb on both Macs, BlueBeaver 7832)."""
    for line in out.splitlines():
        try:
            frame = json.loads(line.decode("utf-8") if isinstance(line, bytes) else line)
        except ValueError:  # malformed JSON, or not UTF-8 (UnicodeDecodeError is a ValueError)
            continue
        if (isinstance(frame, dict) and frame.get("type") == "result" and frame.get("subtype") == "success"
                and frame.get("is_error") is False):
            return True
    return False


def _sanitize(text):
    """Output made safe to print: every redaction runs BEFORE the text is bounded to its last DIAG_MAX characters,
    so no cut can expose a token; control characters become "?"."""
    if text is None:
        return ""
    if isinstance(text, bytes):
        text = text.decode("utf-8", "replace")
    for rx in _REDACT:
        text = rx.sub("<redacted>", text)
    text = "".join(c if c == "\n" or c.isprintable() else "?" for c in text)
    return text[-DIAG_MAX:]


def _port_free(port):
    """No live socket holds `port` on 127.0.0.1 or ::1 (SO_REUSEADDR only so a served connection's TIME_WAIT does not
    count)."""
    for family, host in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        s = socket.socket(family, socket.SOCK_STREAM)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if family == socket.AF_INET6:
                s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            s.bind((host, port))
        except OSError:
            return False
        finally:
            s.close()
    return True


def _chain_alive(h, proc_darwin, cli, markers):
    """(inspected, alive, unreadable) over OUR processes (ps through the guarded h.spawn_group). Alive: a process
    running `cli`, or a python whose argv names one of `markers`. Fails closed: a failed ps is inspected=False, and
    any read that fails while the pid has not vanished is unreadable. Zombies run nothing and are skipped."""
    code, out, _ = h.spawn_group(["/bin/ps", "-axo", "pid=,uid=,stat="], env={"PATH": "/usr/bin:/bin"}, timeout=20)
    if code != 0:
        return False, [], []
    alive, unreadable = [], []
    for line in out.decode(errors="replace").splitlines():
        m = _PS_ROW.fullmatch(line.strip())
        if m is None:
            return False, [], [line]
        pid, uid, stat = int(m.group(1)), int(m.group(2)), m.group(3)
        if uid != os.getuid() or pid == os.getpid() or stat.startswith("Z"):
            continue
        try:
            exe = proc_darwin.path(pid)
        except OSError as e:
            unreadable.append((pid, f"path: {e}"))
            continue
        if exe is None:
            continue  # vanished (ESRCH)
        if exe == cli:
            alive.append((pid, exe))
            continue
        if not os.path.basename(exe).lower().startswith("python"):
            continue
        try:
            _raw, argv, _env = proc_darwin.environ_of(pid)
        except OSError as e:
            try:
                gone = proc_darwin.path(pid) is None
            except OSError:
                gone = False
            if not gone:
                unreadable.append((pid, f"procargs: {e}"))
            continue
        if any(os.fsencode(m) in a for a in argv for m in markers):
            alive.append((pid, exe))
    return True, alive, unreadable


def _clean(scan):
    inspected, alive, unreadable = scan
    return inspected and not alive and not unreadable


def _chain_release(scan, started_at, clock=time.monotonic, sleep=time.sleep):
    """(faults, survivors, last): scans once a second until a clean, empty scan or the end (the row's horizon, and
    never before a full CHAIN_GRACE_S from now). `faults` keeps every uninspected or unreadable scan (sticky);
    `survivors` is what was alive once the grace had passed; `last` is the final scan. Nothing is ever signalled."""
    faults, survivors = [], None
    grace = clock() + CHAIN_GRACE_S
    end = max(grace, started_at + CHAIN_HORIZON_S)
    while True:
        result = scan()
        inspected, alive, unreadable = result
        if not inspected or unreadable:
            faults.append(result)
        now = clock()
        if _clean(result) or now >= end:
            return faults, (survivors if survivors is not None else ([] if now < grace else list(alive))), result
        if survivors is None and now >= grace:
            survivors = list(alive)
        sleep(1)


def _home_layout(options, root):
    """Exactly the agent home setup.stage lays out."""
    home = options.AgentHome(root)
    for d in (home.claude_dir, home.workspace, home.scratchpad, home.tmp, home.runtime / "bin", home.state):
        os.makedirs(d, 0o700, exist_ok=True)
    return home


def _unlock_token_fifo_dir(home):
    """The helper's FifoHandoff leaves <scratchpad>/token-fifo empty at 0300 by design; the driver must still be
    able to remove this case's scratch (24f8d49 left /tmp/zb-hardgate-run-* on both Macs). Only a real directory,
    never a symlink, and only inside this case's own home."""
    path = home.scratchpad / "token-fifo"
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISDIR(st.st_mode):
        os.chmod(path, 0o700)


def _with_census(server, proc_darwin, cli, tok, seen):
    """Hooks the server's handler: on the first /v1/messages, BEFORE it is answered (the CLI is waiting on it, so it
    is alive), production's census runs over this process's descendants, and its fixed reason is recorded."""
    base = server.httpd.RequestHandlerClass
    canary = b"ANTHROPIC_BASE_URL=" + server.url.encode()

    class Census(base):
        def do_POST(self):  # noqa: N802 - http.server API
            if self.path.split("?", 1)[0] == "/v1/messages" and not seen:
                try:
                    reason = proc_darwin.cli_env_census(cli, os.getpid(), tok.encode(), canary)
                except Exception:  # noqa: BLE001 - its text may hold a pid, a path or the token: never recorded
                    reason = None
                seen.append(reason if isinstance(reason, str) and reason in proc_darwin.CENSUS_REASONS else "invalid")
            super().do_POST()

    server.httpd.RequestHandlerClass = Census


def run(h):
    prefix = h.prefix
    if not h.check(bool(prefix) and os.path.isdir(os.path.join(prefix or "", "zb_agent_host")),
                   f"the staged agent-host is present (ZB_HG_PREFIX={prefix!r})"):
        return
    if not h.check(bool(h.cli), f"the pinned CLI is staged (ZB_HG_CLI={h.cli!r})"):
        return
    sys.path.insert(0, prefix)
    from zb_agent_host import options, proc_darwin, route_probe, sandbox_macos, token  # the staged tree's own
    cli = os.path.realpath(h.cli)
    root = os.path.realpath(h.scratch)  # never the /tmp spelling: the profile's write root must be a real path

    def one(label, tok):
        """One contract-config turn with `tok` on fd 3 (None: no fd 3).

        The same generated profile first tries a fixed read from this row's synthetic ~/.ssh, then launches the
        real CLI. Only the fixed verdict leaves this function; the canary bytes and Seatbelt diagnostic do not.
        Returns (rc, out, err, bearer, census, sensitive_read, port, home).
        """
        home = _home_layout(options, os.path.join(root, f"home-{label.replace(' ', '-')}"))
        h.check(str(home.scratchpad) == os.path.realpath(home.scratchpad),
                f"{label}: the home's scratchpad is its own real path")
        ssh_dir = home.root / ".ssh"
        os.makedirs(ssh_dir, 0o700, exist_ok=True)
        sensitive_path = ssh_dir / "id_canary"
        with open(sensitive_path, "wb") as f:
            f.write(SSH_CANARY)
        token.write_wrapper(home.runtime / "bin" / "zb-claude", h.cli)  # as setup.stage writes it
        server = route_probe._ProbeServer(CANARY, h.cli)
        port = int(server.url.rsplit(":", 1)[1])
        census = []
        _with_census(server, proc_darwin, cli, tok or CANARY, census)
        theirs = None
        try:
            command = [h.python, "-m", "zb_agent_host", "contract-config", "--home", str(home.root),
                       "--base-url", server.url, "--fifo-dir", str(home.scratchpad / "token-fifo"),
                       "--prompt", PROMPT]
            pass_fds, head = (), []
            if tok is not None:
                ours, theirs = socket.socketpair()
                try:
                    ours.sendall(tok.encode())
                finally:
                    ours.close()  # read_token reads to end of stream
                pass_fds, head = (theirs.fileno(),), ["/bin/sh", "-c", PLACE_FD3, "sh", str(theirs.fileno())]
            env = {"PATH": "/usr/bin:/bin", "PYTHONPATH": prefix, "PYTHONDONTWRITEBYTECODE": "1"}
            with sandbox_macos.MacSeatbeltBackend(port).launch(home) as spec:
                read_rc, read_out, _read_err = h.spawn_group(
                    list(spec.argv) + ["/bin/cat", str(sensitive_path)], env={"HOME": str(home.root)}, timeout=20)
                sensitive_read = ("allowed" if read_rc == 0 and read_out == SSH_CANARY
                                  else "denied" if read_rc not in (0, None) and not read_out else "invalid")
                rc, out, err = h.spawn_group(head + list(spec.argv) + command, env=env, pass_fds=pass_fds,
                                             timeout=RUN_TIMEOUT_S)
            return rc, out, err, server.bearer, census, sensitive_read, port, home
        finally:
            if theirs is not None:
                theirs.close()
            server.close()
            _unlock_token_fifo_dir(home)

    def diag(rc, out, err):
        return f"rc={rc}; stdout {_sanitize(out)!r}; stderr {_sanitize(err)!r}"

    def released(label, port, home, started):
        h.check(_port_free(port), f"{label}: afterwards port {port} is free on 127.0.0.1 and ::1")
        faults, survivors, last = _chain_release(lambda: _chain_alive(h, proc_darwin, cli, [str(home.root)]), started)
        h.check(faults == [] and survivors == [] and _clean(last),
                f"{label}: no process of ours runs the CLI or names the row's home afterwards "
                f"(faults={len(faults)}, survivors={survivors}, last={last})")

    for label, tok in (("positive", CANARY), ("decoy", DECOY)):
        started = time.monotonic()
        rc, out, err, bearer, census, sensitive_read, port, home = one(label, tok)
        h.check(sensitive_read == "denied", f"{label}: the real CLI's generated profile denies ~/.ssh/id_canary "
                                             f"(verdict={sensitive_read})")
        h.check(rc == 0 and _turn_completed(out), f"{label}: the helper's turn completes ({diag(rc, out, err)})")
        h.check(bearer == "Bearer " + tok, f"{label}: the CLI's bearer is exactly the token on fd 3 "
                                           f"(bearer={'none' if bearer is None else 'other'})")
        h.check(census == ["ok"], f"{label}: during the request the CLI's environment holds this row's base URL and "
                                  f"not the token (census={census})")
        released(label, port, home, started)

    started = time.monotonic()
    rc, out, err, bearer, census, _sensitive_read, port, home = one("no channel", None)
    h.check(rc not in (0, None), f"no channel: the helper fails without fd 3 ({diag(rc, out, err)})")
    h.check(bearer is None and census == [], "no channel: no request reached the server, the canary never left")
    released("no channel", port, home, started)
