"""`zigBrowser --agent-setup` (plan D6, D11; S3.1, S3.7): provisions the agent
home from a SAI source and selects the token route on the installed CLI.

    python -m zb_agent_host setup --home H --sai-source S --source-home U
        --source-path PATH --python PY [--route r1|env] [--e2e-claude-cli CLI]

Everything is built in a staging directory beside the home, and checked,
before anything is installed: a refused source leaves the home exactly as it
was. A first install is one rename; a later one swaps `.claude` and `runtime`
atomically (renameat2 RENAME_EXCHANGE) and keeps the agent's own state
directories, workspace, scratchpad and secrets.

The source is only ever read. Never copied: credentials, transcripts,
history, todos, shell snapshots, the user's MEMORY/ (the agent starts empty).
"""

import argparse
import asyncio
import ctypes
import datetime
import hashlib
import json
import os
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import hook_run, options, sandbox, token
from . import provision as runtime_provision
from .files import atomic_write, write_all

# settings.json keys removed at any depth (D6), and the widening permissions.
REMOVED_KEYS = ("mcpServers", "enabledMcpjsonServers", "enableAllProjectMcpServers", "enabledPlugins",
                "extraKnownMarketplaces", "statusLine", "skipDangerousModePermissionPrompt", "apiKeyHelper", "env")
WIDENING_PERMISSIONS = ("allow", "defaultMode")
# The top-level SAI items copied into .claude; nothing else is.
COPY_ALLOWLIST = ("CLAUDE.md", "settings.json", "SAI", "hooks", "commands", "skills", "agents")
SKIPPED_NAMES = (".git", "__pycache__")
# Absolute paths a copied text file may keep (S3.1); the source HOME is rewritten.
ALLOWED_ROOTS = ("/usr", "/bin", "/lib", "/etc", "/opt", "/proc/self")
# An absolute path of two or more components: not part of a URL, `~/x`, `$X/y`,
# a `${x}/y` or `$(x)/y` concatenation, or a relative path.
PATH_RE = re.compile(r"(?<![\w:/.~$@})-])(?:/[A-Za-z0-9._@+-]+){2,}")
PROBE_TIMEOUT_S = 30
LAYOUT_VERSION = 1


class SetupError(Exception):
    pass


# --- settings ------------------------------------------------------------------

def sanitize_settings(node):
    """`node` without REMOVED_KEYS at any depth, and without widening permissions."""
    if isinstance(node, list):
        return [sanitize_settings(v) for v in node]
    if not isinstance(node, dict):
        return node
    clean = {}
    for key, value in node.items():
        if key in REMOVED_KEYS:
            continue
        value = sanitize_settings(value)
        if key == "permissions" and isinstance(value, dict):
            value = {k: v for k, v in value.items() if k not in WIDENING_PERMISSIONS}
        clean[key] = value
    return clean


def rewrite_text(text, source_home, agent_home, rel, strict=True):
    """The source HOME prefix becomes the agent home. With `strict`, any other
    absolute path outside ALLOWED_ROOTS and the agent home refuses setup with
    `outside path in <rel>:<line>`."""
    def under(path, root):
        return path == root or path.startswith(root + "/")

    out = []
    for lineno, line in enumerate(text.splitlines(keepends=True), 1):
        def fix(match):
            path = match.group(0)
            if under(path, source_home):
                return agent_home + path[len(source_home):]
            if not strict or under(path, agent_home) or any(under(path, root) for root in ALLOWED_ROOTS):
                return path
            raise SetupError(f"outside path in {rel}:{lineno}")
        out.append(PATH_RE.sub(fix, line))
    return "".join(out)


def check_hooks(settings, home_root, staging_root, source_path):
    """Every hook is a command whose first token is a bare command found on the
    source PATH (its directory is returned, for runtime/path.json) or a path,
    and whose every path-like token resolves inside the agent home, symlinks
    resolved in the staged tree (D6; hygiene, not the boundary: D12 is)."""
    home_root, staging_root = str(home_root), str(staging_root)
    real_staging = os.path.realpath(staging_root)
    dirs = set()
    for event, entries in (settings.get("hooks") or {}).items():
        for index, entry in enumerate(entries):
            for hook in entry.get("hooks", []):
                command = hook.get("command")
                if hook.get("type") != "command" or not isinstance(command, str) or not command.strip():
                    raise SetupError(f"hook cannot be wrapped: {event}/{index}")
                tokens = shlex.split(command)
                first = tokens[0]
                if "/" not in first and not first.startswith("~"):
                    found = shutil.which(first, path=source_path)
                    if found is None:
                        raise SetupError(f"hook command not found: {event}/{index}")
                    dirs.add(os.path.dirname(found))
                    tokens = tokens[1:]
                for tok in tokens:
                    if "/" in tok or tok.startswith("~"):
                        if not _inside_home(tok, home_root, staging_root, real_staging):
                            raise SetupError(f"hook path outside agent home: {event}/{index}")
    return sorted(dirs)


def _inside_home(tok, home_root, staging_root, real_staging):
    if tok == "~" or tok.startswith("~/"):
        path = home_root + tok[1:]
    elif tok.startswith("/"):
        path = tok
    else:
        path = os.path.join(home_root, "workspace", tok)
    path = os.path.normpath(path)
    if not path.startswith(home_root + "/"):
        return False
    staged = os.path.realpath(os.path.join(staging_root, os.path.relpath(path, home_root)))
    return staged == real_staging or staged.startswith(real_staging + "/")


# --- copying -------------------------------------------------------------------

def copy_sai(source, claude, source_home, agent_home):
    """The allowlisted items of `source` into `claude`: text rewritten, modes
    0700 (executable) or 0600, symlinks followed only inside their own item."""
    source = Path(source)
    for name in COPY_ALLOWLIST:
        item = source / name
        if not item.exists():
            continue
        real = Path(os.path.realpath(item))
        if real.is_dir():
            _copy_tree(real, real, claude / name, name, source_home, agent_home, set())
        else:
            _copy_file(real, claude / name, name, source_home, agent_home)


def _copy_tree(root, directory, target, rel, source_home, agent_home, seen):
    seen.add(str(directory))
    target.mkdir(mode=0o700, exist_ok=True)
    os.chmod(target, 0o700)
    for entry in sorted(os.scandir(directory), key=lambda e: e.name):
        if entry.name in SKIPPED_NAMES:
            continue
        path, entry_rel = Path(entry.path), f"{rel}/{entry.name}"
        if entry.is_symlink():
            resolved = Path(os.path.realpath(path))
            if not (resolved == root or str(resolved).startswith(str(root) + "/")):
                raise SetupError(f"outside path in {entry_rel}")
            path = resolved
        if path.is_dir():
            if str(path) not in seen:
                _copy_tree(root, path, target / entry.name, entry_rel, source_home, agent_home, seen)
        elif path.is_file():
            _copy_file(path, target / entry.name, entry_rel, source_home, agent_home)


def _copy_file(path, target, rel, source_home, agent_home):
    """settings.json is only rewritten here: its paths are checked after its
    hooks are (stage), so a hook path gets the hook-specific refusal."""
    data = path.read_bytes()
    if b"\0" not in data:
        try:
            text = data.decode("utf-8")
            data = rewrite_text(text, source_home, agent_home, rel, strict=rel != "settings.json").encode("utf-8")
        except UnicodeDecodeError:
            pass
    mode = 0o700 if os.access(path, os.X_OK) else 0o600
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, mode)
    try:
        write_all(fd, data)
    finally:
        os.close(fd)


# --- staging, runtime, install ------------------------------------------------

def manifest(claude):
    """SHA-256 of every file in .claude except the writable state directories."""
    out = {}
    for path in sorted(Path(claude).rglob("*")):
        rel = path.relative_to(claude)
        if rel.parts[0] in sandbox.STATE_DIRS or not path.is_file():
            continue
        out[str(rel)] = hashlib.sha256(path.read_bytes()).hexdigest()
    return out


def stage(home, source, source_home, source_path, python, cli, staging):
    """A complete agent home in `staging`, laid out for `home`."""
    root = str(home.root)
    claude, runtime = staging / ".claude", staging / "runtime"
    for sub in (".claude", "workspace", "scratchpad", "scratchpad/tmp", "secrets", "runtime", "runtime/bin"):
        (staging / sub).mkdir(mode=0o700, parents=True, exist_ok=True)
    copy_sai(source, claude, str(source_home), root)
    (claude / "MEMORY").mkdir(mode=0o700, exist_ok=True)
    settings_path = claude / "settings.json"
    settings = sanitize_settings(json.loads(settings_path.read_text())) if settings_path.exists() else {}
    dirs = check_hooks(settings, root, staging, source_path)
    runtime_provision.wrap_hooks(settings, f"{shlex.quote(root + '/runtime/bin/zb-hook-run')} -- ")
    if settings_path.exists():
        settings_path.unlink()
    final = json.dumps(settings, indent=2) + "\n"
    rewrite_text(final, str(source_home), root, "settings.json")
    atomic_write(settings_path, final, 0o600)
    atomic_write(claude / ".claude.json", "{}\n", 0o600)

    bad = hook_run.refused_names(runtime_provision.HOOK_ENV_NAMES)
    if bad:
        raise SetupError(f"refused hook environment names: {', '.join(bad)}")
    token.write_wrapper(runtime / "bin" / "zb-claude", cli)
    atomic_write(runtime / "bin" / "zb-hook-run", Path(hook_run.__file__).read_text(), 0o700)
    atomic_write(runtime / "hook-env.json", json.dumps(list(runtime_provision.HOOK_ENV_NAMES)), 0o600)
    atomic_write(runtime / "writable.json", json.dumps(list(sandbox.STATE_DIRS)), 0o600)
    atomic_write(runtime / "path.json", json.dumps(dirs), 0o600)
    atomic_write(runtime / "host.json", json.dumps({"python": str(python)}), 0o600)
    shutil.copytree(Path(__file__).resolve().parent, runtime / "host" / "zb_agent_host",
                    ignore=shutil.ignore_patterns("__pycache__"))
    atomic_write(runtime / "config-manifest.json", json.dumps(manifest(claude), indent=1), 0o600)
    atomic_write(staging / ".zb-agent-home", json.dumps({"layout": LAYOUT_VERSION}), 0o600)


_RENAME_EXCHANGE = 2
_libc = ctypes.CDLL(None, use_errno=True)
_libc.syscall.restype = ctypes.c_long


def exchange(a, b):
    """Atomically swaps two paths (renameat2 RENAME_EXCHANGE, syscall 316)."""
    at_fdcwd = ctypes.c_long(-100)
    rc = _libc.syscall(ctypes.c_long(316), at_fdcwd, os.fsencode(str(a)), at_fdcwd, os.fsencode(str(b)),
                       ctypes.c_ulong(_RENAME_EXCHANGE))
    if rc != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err), str(a))


def install(home, staging):
    """First install: one rename (or, when the browser already made the home
    to hold its owner lock in it, one rename per staged entry, the marker
    last). Later: the agent's state directories move into the staged
    .claude, then .claude and runtime are swapped atomically."""
    root = home.root
    if not root.exists():
        os.rename(staging, root)
        return
    if not (root / ".zb-agent-home").exists():
        for entry in sorted(staging.iterdir(), key=lambda p: p.name == ".zb-agent-home"):
            os.rename(entry, root / entry.name)
        os.chmod(root, 0o700)
        staging.rmdir()
        return
    for name in sandbox.STATE_DIRS:
        old = root / ".claude" / name
        if old.is_dir():
            new = staging / ".claude" / name
            if new.exists():
                shutil.rmtree(new)
            os.rename(old, new)
    for name in (".claude", "runtime"):
        exchange(staging / name, root / name)
    for name in ("workspace", "scratchpad", "scratchpad/tmp", "secrets"):
        (root / name).mkdir(mode=0o700, exist_ok=True)
    os.replace(staging / ".zb-agent-home", root / ".zb-agent-home")
    shutil.rmtree(staging)


def provision(home, source, source_home, source_path, python, route, cli=None, probe=None):
    """Stages, checks, selects the token route (when `route` is given) and
    installs. Raises SetupError, leaving the home unchanged."""
    root = home.root
    root.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".agent-home.staging-", dir=root.parent))
    try:
        os.chmod(staging, 0o700)
        cli = cli or token.bundled_cli()
        stage(home, source, source_home, source_path, python, cli, staging)
        if route is not None:
            select_route(staging / "runtime", route, cli, probe or probe_r1)
        install(home, staging)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


# --- the token route (D11, S3.7) ---------------------------------------------

RISK_LINE = ("zigBrowser: agent-setup: token route env (R3): any process in the agent sandbox, hooks included, "
             "can read the Claude CLI's environment as the same user")


def cli_version(cli):
    try:
        done = subprocess.run([cli, "--version"], capture_output=True, text=True, timeout=20,
                              env={"PATH": "/usr/bin:/bin", "HOME": tempfile.gettempdir()})
        return (done.stdout.strip().split() or ["unknown"])[0]
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def select_route(runtime, route, cli, probe):
    """R1 when the installed CLI takes the token from the wrapper's descriptor;
    R3 only when explicitly asked; else refuse."""
    if route == "env":
        print(RISK_LINE, file=sys.stderr)
        chosen = "R3"
    elif probe(runtime / "bin" / "zb-claude", cli):
        chosen = "R1"
    else:
        raise SetupError("no safe token route for this Claude CLI")
    record = {"route": chosen, "cli_path": str(cli), "cli_version": cli_version(cli),
              "probed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}
    atomic_write(runtime / "token-route.json", json.dumps(record), 0o600)


def _stream(text):
    message = {"id": "msg_probe", "type": "message", "role": "assistant", "model": "probe", "content": [],
               "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}
    yield "message_start", {"type": "message_start", "message": message}
    yield "content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}
    yield "content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}}
    yield "content_block_stop", {"type": "content_block_stop", "index": 0}
    yield "message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                            "usage": {"output_tokens": 1}}
    yield "message_stop", {"type": "message_stop"}


def _descendants_running(exe):
    """PIDs of our descendants whose executable is `exe`."""
    me, found = os.getpid(), []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            if os.path.realpath(f"/proc/{entry}/exe") != exe:
                continue
        except OSError:
            continue
        pid = int(entry)
        while pid > 1:
            try:
                with open(f"/proc/{pid}/stat") as f:
                    pid = int(f.read().rsplit(")", 1)[1].split()[1])
            except (OSError, ValueError, IndexError):
                break
            if pid == me:
                found.append(int(entry))
                break
    return found


class _ProbeServer:
    """A one-shot loopback Messages API: records the bearer it receives and
    whether any running CLI process holds the probe token in its environment."""

    def __init__(self, probe_token, cli):
        self.bearer = None
        self.cli_env_clean = None
        server = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):  # noqa: N802 - http.server API
                length = int(self.headers.get("content-length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}")
                if self.path.split("?", 1)[0] == "/v1/messages" and server.bearer is None:
                    server.bearer = self.headers.get("authorization", "")
                    environs = []
                    for pid in _descendants_running(os.path.realpath(cli)):
                        try:
                            with open(f"/proc/{pid}/environ", "rb") as f:
                                environs.append(f.read())
                        except OSError:
                            pass
                    server.cli_env_clean = bool(environs) and all(probe_token.encode() not in e for e in environs)
                if not body.get("stream"):
                    self._reply(200, "application/json", json.dumps({"type": "message", "content": []}).encode())
                    return
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.send_header("connection", "close")
                self.end_headers()
                for name, data in _stream("ok"):
                    self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
                self.close_connection = True

            def _reply(self, code, ctype, data):
                self.send_response(code)
                self.send_header("content-type", ctype)
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def probe_r1(wrapper, cli):
    """One turn through the real wrapper, FIFO and socket hand-off, with a
    random probe token, against the loopback probe server. Runs with a
    throwaway HOME and config (no SAI, no hooks). True when the server saw
    `Bearer <probe>` and no CLI environment held it."""
    from claude_agent_sdk import query

    probe_token = "zb-probe-" + secrets.token_hex(24)
    server = _ProbeServer(probe_token, cli)
    scratch = Path(tempfile.mkdtemp(prefix="zb-route-probe-"))
    try:
        home = options.AgentHome(scratch / "home")
        for sub in (home.claude_dir, home.workspace, home.tmp):
            sub.mkdir(mode=0o700, parents=True, exist_ok=True)
        handoff = token.FifoHandoff(scratch / "zb-token", probe_token)
        opts = options.build(home, route_env=handoff.env(), cli_path=str(wrapper), base_url=server.url)

        async def turn():
            async for _ in query(prompt="probe", options=opts):
                pass

        try:
            asyncio.run(asyncio.wait_for(turn(), PROBE_TIMEOUT_S))
        except BaseException as exc:  # noqa: BLE001 - the verdict is what the server saw
            if isinstance(exc, KeyboardInterrupt):
                raise
        finally:
            handoff.close()
        return server.bearer == f"Bearer {probe_token}" and server.cli_env_clean is True
    finally:
        server.close()
        shutil.rmtree(scratch, ignore_errors=True)


def main(argv):
    parser = argparse.ArgumentParser(prog="zb_agent_host setup")
    parser.add_argument("--home", required=True)
    parser.add_argument("--sai-source", required=True)
    parser.add_argument("--source-home", required=True)
    parser.add_argument("--source-path", required=True)
    parser.add_argument("--python", required=True)
    parser.add_argument("--route", choices=("r1", "env"), default="r1")
    parser.add_argument("--e2e-claude-cli")
    args = parser.parse_args(argv)
    try:
        provision(options.AgentHome(args.home), Path(args.sai_source), args.source_home.rstrip("/"),
                  args.source_path, args.python, args.route, cli=args.e2e_claude_cli)
    except SetupError as exc:
        print(f"zigBrowser: agent-setup: {exc}", file=sys.stderr)
        return 2
    except (OSError, ValueError) as exc:
        print(f"zigBrowser: agent-setup: {exc}", file=sys.stderr)
        return 1
    return 0
