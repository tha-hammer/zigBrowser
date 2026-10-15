"""`zigBrowser --agent-setup` (plan D6, D11; S3.1, S3.7): provisions the agent
home from a SAI source and selects the token route on the installed CLI.

    python -m zb_agent_host setup --home H --sai-source S --source-home U
        --source-path PATH --python PY [--e2e-claude-cli CLI]

The home layout (plan rev 15.4): setup never mutates live state in place.
Everything setup produces (`.claude/`, `runtime/`) is built complete in
`.dist-tmp-*`, checked, fsynced and renamed to `dist-<n>/`, then published by
one atomic swap of the `current` symlink. `.claude` and `runtime` are fixed
links into `current`. The agent's state (`state/<STATE_DIRS>`, `workspace/`,
`scratchpad/`, `secrets/`) lives outside every build; setup only creates it
when absent. A refused source leaves the home exactly as it was; a crash
leaves the old or the new `current`, never a mix.

The source is only ever read. Never copied: credentials, transcripts,
history, todos, shell snapshots, the user's MEMORY/ (the agent starts empty).
"""

import argparse
import asyncio
import datetime
import hashlib
import json
import os
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import hook_run, options, sandbox, token
from . import provision as runtime_provision
from .files import atomic_write, write_all

# settings.json keys removed at any depth (D6), and the widening permissions.
REMOVED_KEYS = ("mcpServers", "enabledMcpjsonServers", "enableAllProjectMcpServers", "enabledPlugins",
                "extraKnownMarketplaces", "statusLine", "skipDangerousModePermissionPrompt", "apiKeyHelper", "env")
WIDENING_PERMISSIONS = ("allow", "defaultMode")
# The top-level SAI items copied into .claude; nothing else is. These two are
# files, the rest directories (RoseCat 5445: a mismatch refuses).
FILE_ITEMS = ("CLAUDE.md", "settings.json")
COPY_ALLOWLIST = ("CLAUDE.md", "settings.json", "SAI", "hooks", "commands", "skills", "agents")
# Dependency trees, version control and build output are copied byte for
# byte: no rewrite (plan rev 15.6). Skills keep working in the sandbox.
DEPENDENCY_DIRS = (
    "node_modules", ".venv", "venv", "site-packages",                      # dependency trees
    ".git",                                                              # version control
    "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox",  # caches
    ".cache", ".zig-cache", "zig-cache", ".gradle", "coverage", ".nyc_output",
    "dist", "build", "out", "target", "zig-out", ".next", ".turbo",     # build output
)
# An absolute path in copied text: not part of a URL, `~/x`, `$X/y`, a
# `${x}/y` or `$(x)/y` concatenation, or a relative path. Only the source
# HOME prefix is rewritten; nothing in copied text refuses setup (rev 15.6,
# the user's decision: only hook command lines are checked, by check_hooks).
PATH_RE = re.compile(r"(?<![\w:/.~$@})-])(?:/[A-Za-z0-9._@+-]+)+")
PROBE_TIMEOUT_S = 30
LAYOUT_VERSION = 2
# Published builds, and the leftovers of interrupted runs (never state).
DIST_RE = re.compile(r"dist-([1-9][0-9]*)")
GARBAGE_PREFIXES = ("dist-", ".dist-tmp-", ".current.tmp-")
FIXED_LINKS = ((".claude", "current/.claude"), ("runtime", "current/runtime"))
# State (plan rev 15.5): never in a build; setup only creates what is absent.
STATE_DIR_PATHS = ("workspace", "scratchpad", "scratchpad/tmp", "secrets", "state", "state/backups",
                   *(f"state/{name}" for name in sandbox.STATE_DIRS))
STATE_FILE = "state/.claude.json"
PAUSE_CUTS = ("swap:before", "swap:after")
PAUSE_S = 30


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


def rewrite_text(text, source_home, agent_home):
    """Every absolute path under the source HOME is moved to the agent home;
    nothing else changes. `source_home` must be an absolute directory other
    than `/` (RoseCat 5328: an empty one rewrote every path)."""
    if not os.path.isabs(source_home) or source_home.rstrip("/") == "":
        raise SetupError("the source HOME is not an absolute directory")

    def fix(match):
        path = match.group(0)
        if path == source_home or path.startswith(source_home + "/"):
            return agent_home + path[len(source_home):]
        return path
    return PATH_RE.sub(fix, text)


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
                tokens = hook_tokens(command, f"{event}/{index}")
                reason = hook_grammar_refusal(tokens, command)
                if reason:
                    raise SetupError(f"hook command {reason}: {event}/{index}")
                first = tokens[0]
                if "/" not in first and not first.startswith("~"):
                    found = shutil.which(first, path=source_path)
                    if found is None:
                        raise SetupError(f"hook command not found: {event}/{index}")
                    dirs.add(os.path.dirname(found))
                    tokens = tokens[1:]
                for part in (p for tok in tokens for p in path_parts(tok)):
                    if not _inside_home(part, home_root, staging_root, real_staging):
                        raise SetupError(f"hook path outside agent home: {event}/{index}")
                    if not _in_copy(part, home_root, staging_root):
                        raise SetupError(f"hook path is not in the copied SAI: {event}/{index}")
    return sorted(dirs)


def _in_copy(part, home_root, staging_root):
    """Whether a hook's path names an existing file or directory of the copy
    setup publishes (.claude or runtime). Never the workspace, scratchpad,
    state or secrets, whose bytes the agent can change after setup checked
    them (RoseCat 5444), and never a missing path or a relative one (those
    resolve against the writable workspace)."""
    if not (part == "~" or part.startswith("~/") or part.startswith("/")):
        return False
    path = os.path.normpath(home_root + part[1:] if part.startswith("~") else part)
    rel = os.path.relpath(path, home_root)
    if rel.split("/", 1)[0] not in (".claude", "runtime"):
        return False
    staged = os.path.realpath(os.path.join(staging_root, rel))
    copy_roots = [os.path.realpath(os.path.join(staging_root, top)) for top in (".claude", "runtime")]
    inside = any(staged == r or staged.startswith(r + "/") for r in copy_roots)
    return inside and os.path.exists(staged)


# The hook command forms setup understands (RoseCat 5416, 5431): a script
# path, or one of these launchers followed by options and then a script path.
# Anything that could carry code or paths opaquely refuses.
LAUNCHERS = ("bun", "node", "deno", "python3", "python", "sh", "bash")
EVAL_FLAGS = ("-c", "-lc", "-ic", "-e", "--eval", "-p", "--print", "-m", "-")


# A hook command is a shell string: only words of these characters, one space
# apart, so no shell syntax (`;`, `&&`, `|`, `$(…)`, backticks, redirection,
# quoting, variables, newlines) can hide in it (RoseCat 5438).
HOOK_COMMAND_RE = re.compile(r"[A-Za-z0-9_./~=:@%+,-]+( [A-Za-z0-9_./~=:@%+,-]+)*")


def hook_grammar_refusal(tokens, command=None):
    """Why a hook command is outside the supported grammar (None: it is not)."""
    if command is not None and not HOOK_COMMAND_RE.fullmatch(command):
        return "has shell syntax"
    if not tokens:
        return "is empty"
    for tok in tokens:
        if any(ch.isspace() for ch in tok):
            return "has an embedded command or text with spaces"
        if tok.startswith("~") and not (tok == "~" or tok.startswith("~/")):
            return "names another user's home"
        if "://" in tok and tok.split("://", 1)[0].lower() not in ("http", "https"):
            return "has a non-http URL"
    first = tokens[0]
    if "/" in first or first.startswith("~"):
        return None
    if first not in LAUNCHERS:
        return f"launcher is not supported ({first})"
    for tok in tokens[1:]:
        if tok.split("=", 1)[0] in EVAL_FLAGS or (tok[:1] == "-" and tok[1:2] in "celpm" and tok[1:2] != "-"):
            return "evaluates code given on the command line"  # also -eCODE, -pCODE, -cCODE
        if not tok.startswith("-"):
            return None if ("/" in tok or tok.startswith("~")) else "runs no script path"
    return "runs no script path"


def path_parts(tok):
    """The path-like pieces of one hook command word: the word itself, or
    each side of an `=` (`--preload=/x/pre.ts`: RoseCat 5416, an embedded path
    is checked like any other)."""
    return [p for p in tok.split("=") if ("/" in p or p.startswith("~")) and "://" not in p]


def hook_tokens(command, where):
    """The words of a hook command, refused before any shell-style parsing
    when it is outside the closed grammar's characters (RoseCat 833767e: an
    unterminated quote must be a setup refusal, exit 2, not a parser crash)."""
    if not isinstance(command, str) or not HOOK_COMMAND_RE.fullmatch(command):
        raise SetupError(f"hook command has shell syntax: {where}")
    return command.split(" ")


def check_hook_links(settings, home_root):
    """A hook that names a file setup skipped (a link outside its item) would
    not run as written: that refuses setup (rev 15.6)."""
    home_root = str(home_root)
    for event, entries in (settings.get("hooks") or {}).items():
        for index, entry in enumerate(entries):
            for hook in entry.get("hooks", []):
                command = hook.get("command")
                if hook.get("type") != "command" or not isinstance(command, str) or not command.strip():
                    continue  # check_hooks refuses it with its own reason
                tokens = hook_tokens(command, f"{event}/{index}")
                for part in (p for tok in tokens for p in path_parts(tok)):
                    path = home_root + part[1:] if part == "~" or part.startswith("~/") else part
                    if not os.path.isabs(path):
                        continue
                    rel = os.path.relpath(os.path.normpath(path), home_root)
                    shown = rel[len(".claude/"):] if rel.startswith(".claude/") else rel
                    # The skipped link itself, or anything below it (RoseCat 5416).
                    ancestors = [shown] + [str(a) for a in Path(shown).parents if str(a) != "."]
                    if any(a in _SKIPPED_LINKS for a in ancestors):
                        raise SetupError(f"hook script links outside its item: {shown}")


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
    """The allowlisted items of `source` into `claude`: the source HOME
    rewritten in text (nothing in copied text refuses setup; rev 15.6),
    dependency trees byte for byte, modes 0700 (executable) or 0600, symlinks
    followed only inside their own item (others are skipped)."""
    source = Path(source)
    _SKIPPED_LINKS.clear()
    for name, real in top_level_items(source, agent_home):
        if real is None:
            _SKIPPED_LINKS.add(name)
            print(f"zigBrowser: agent-setup: skipped {name}: its link is a chain or not this user's", file=sys.stderr)
        elif real.is_dir():
            _copy_tree(real, real, claude / name, name, source_home, agent_home, frozenset())
        else:
            _copy_file(real, claude / name, source_home, agent_home)


def top_level_items(source, agent_home):
    """(name, its real root or None to skip) for each allowlisted item that
    exists (RoseCat 5428, 5438). An item that is a link is followed once,
    never through a chain, to a real file or directory of this user: the user
    chose it by choosing the SAI source (each is logged). Every root must be
    disjoint from the agent home (RoseCat 5439: else the copy would read its
    own output). Anything that is not a regular file or a directory refuses
    setup: a FIFO would block it."""
    home = os.path.realpath(agent_home)
    check_disjoint("the SAI source", os.path.realpath(source), home)
    out = []
    for name in COPY_ALLOWLIST:
        item = source / name
        if not os.path.lexists(item):
            continue
        if os.path.islink(item):
            target = _link_target(item)
            if target is not None:
                check_disjoint(name, os.path.realpath(target), home)
                print(f"zigBrowser: agent-setup: {name} comes from {target}", file=sys.stderr)
            out.append((name, Path(target) if target is not None else None))
            continue
        st = os.lstat(item)
        if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)):
            raise SetupError(f"{name} in the SAI source is not a regular file or a directory")
        out.append((name, Path(os.path.realpath(item))))
    for name, real in out:
        if real is not None and real.is_dir() != (name not in FILE_ITEMS):
            want = "a regular file" if name in FILE_ITEMS else "a directory"
            raise SetupError(f"{name} in the SAI source is not {want}")
    return out


def check_disjoint(label, path, home):
    """`path` may be neither the agent home, nor inside it, nor contain it."""
    if path == home or path.startswith(home + "/") or home.startswith(path.rstrip("/") + "/"):
        raise SetupError(f"{label} overlaps the agent home: {path}")


def _link_target(link):
    """The absolute target of `link` when it is a real file or directory of
    this user, not another link; else None."""
    target = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(link)), os.readlink(link)))
    try:
        st = os.lstat(target)
    except OSError:
        return None
    if stat.S_ISLNK(st.st_mode) or st.st_uid != os.getuid():
        return None
    # No link in a parent component either (RoseCat 833767e): `hop/CLAUDE.md`
    # with `hop -> /outside` is a chain of two links.
    if os.path.realpath(target) != target:
        return None
    if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)):
        raise SetupError(f"{os.path.basename(link)} in the SAI source is not a regular file or a directory")
    return target


def _copy_tree(root, directory, target, rel, source_home, agent_home, ancestors, verbatim=False):
    """`ancestors`: the real directories on the current recursion path only.
    A link back to one of them is a cycle (skipped with a warning); a link to
    any other directory of the item is an alias and is copied under its own
    name too, so nothing vanishes silently (RoseCat 833767e)."""
    ancestors = ancestors | {str(directory)}
    target.mkdir(mode=0o700, exist_ok=True)
    os.chmod(target, 0o700)
    for entry in sorted(os.scandir(directory), key=lambda e: e.name):
        path, entry_rel = Path(entry.path), f"{rel}/{entry.name}"
        if entry.is_symlink():
            resolved = Path(os.path.realpath(path))
            if not (resolved == root or str(resolved).startswith(str(root) + "/")):
                # Never followed: it could name any file of the user's. Skipped,
                # not refused (rev 15.6); a hook that names it refuses.
                _SKIPPED_LINKS.add(entry_rel)
                print(f"zigBrowser: agent-setup: skipped {entry_rel}: it links outside {rel.split('/')[0]}",
                      file=sys.stderr)
                continue
            path = resolved
        try:
            mode = os.stat(path, follow_symlinks=False).st_mode  # never opened: a FIFO would block
        except FileNotFoundError:
            print(f"zigBrowser: agent-setup: skipped {entry_rel}: a broken link", file=sys.stderr)
            continue
        if stat.S_ISDIR(mode):
            if str(path) in ancestors:
                print(f"zigBrowser: agent-setup: skipped {entry_rel}: a link cycle", file=sys.stderr)
                continue
            _copy_tree(root, path, target / entry.name, entry_rel, source_home, agent_home, ancestors,
                       verbatim or entry.name in DEPENDENCY_DIRS)
        elif stat.S_ISREG(mode):
            _copy_file(path, target / entry.name, source_home, agent_home, verbatim)
        else:
            # Copy everything means nothing vanishes silently (RoseCat 5445).
            raise SetupError(f"{entry_rel} in the SAI source is not a regular file or a directory")


_SKIPPED_LINKS = set()  # copied-tree paths (rel to .claude) not copied: links outside their item


def _read_regular(path):
    """The bytes of `path`, read through one descriptor that is checked to be
    a regular file: no link is followed and a FIFO never blocks, so a swap
    after classification cannot change what is read (RoseCat 833767e SHOULD)."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError as exc:
        raise SetupError(f"{path} changed while setup read it") from exc
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise SetupError(f"{path} changed while setup read it")
        chunks = []
        while chunk := os.read(fd, 1 << 20):
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def _copy_file(path, target, source_home, agent_home, verbatim=False):
    """Text gets the source-HOME rewrite only; nothing refuses here."""
    data = _read_regular(path)
    if not verbatim and b"\0" not in data:
        try:
            text = data.decode("utf-8")
            data = rewrite_text(text, source_home, agent_home).encode("utf-8")
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


def runtime_lock(package_dir):
    """The installed runtime's lock hash (runtime.json beside the package,
    written by tools/install_agent_runtime.sh); None for a checkout."""
    try:
        return json.loads((Path(package_dir) / "runtime.json").read_text())["lock_sha256"]
    except (OSError, ValueError, KeyError, TypeError):
        return None


def stage(home, source, source_home, source_path, python, cli, staging, package_dir):
    """A complete build in `staging`: `.claude/` and `runtime/`, laid out for
    `home` (they are published at home/.claude and home/runtime)."""
    root = str(home.root)
    claude, runtime = staging / ".claude", staging / "runtime"
    for sub in (".claude", "runtime", "runtime/bin"):
        (staging / sub).mkdir(mode=0o700, parents=True, exist_ok=True)
    copy_sai(source, claude, str(source_home), root)
    # Mount points: the sandbox binds state/<name> over these (D12).
    for name in ("backups", *sandbox.STATE_DIRS):
        (claude / name).mkdir(mode=0o700, exist_ok=True)
    settings_path = claude / "settings.json"
    settings = sanitize_settings(json.loads(settings_path.read_text())) if settings_path.exists() else {}
    check_hook_links(settings, root)  # first: the more specific reason
    dirs = check_hooks(settings, root, staging, source_path)
    runtime_provision.wrap_hooks(settings, f"{shlex.quote(root + '/runtime/bin/zb-hook-run')} -- ")
    if settings_path.exists():
        settings_path.unlink()
    final = json.dumps(settings, indent=2) + "\n"
    atomic_write(settings_path, final, 0o600)
    # The mount point of state/.claude.json; `{}` so the CLI can read it even unmounted.
    atomic_write(claude / ".claude.json", "{}\n", 0o600)

    bad = hook_run.refused_names(runtime_provision.HOOK_ENV_NAMES)
    if bad:
        raise SetupError(f"refused hook environment names: {', '.join(bad)}")
    token.write_wrapper(runtime / "bin" / "zb-claude", cli)
    atomic_write(runtime / "bin" / "zb-hook-run", Path(hook_run.__file__).read_text(), 0o700)
    atomic_write(runtime / "hook-env.json", json.dumps(list(runtime_provision.HOOK_ENV_NAMES)), 0o600)
    atomic_write(runtime / "writable.json", json.dumps(list(sandbox.STATE_DIRS)), 0o600)
    atomic_write(runtime / "path.json", json.dumps(dirs), 0o600)
    atomic_write(runtime / "host.json", json.dumps({"python": str(python), "runtime_lock": runtime_lock(package_dir)}), 0o600)
    shutil.copytree(Path(package_dir) / "zb_agent_host", runtime / "host" / "zb_agent_host",
                    ignore=shutil.ignore_patterns("__pycache__"))
    atomic_write(runtime / "config-manifest.json", json.dumps(manifest(claude), indent=1), 0o600)
    atomic_write(staging / ".zb-agent-home", json.dumps({"layout": LAYOUT_VERSION}), 0o600)


def fsync_tree(top):
    """Every file and directory under `top`, and `top`, to disk."""
    for dirpath, dirnames, filenames in os.walk(top, topdown=False):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        fsync_dir(dirpath)


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _owned(st, kind, mode=None):
    return kind(st.st_mode) and st.st_uid == os.getuid() and (mode is None or stat.S_IMODE(st.st_mode) == mode)


def _valid_garbage(name, st):
    """Whether `name` (an entry of the home with a garbage prefix) is exactly
    something setup made: then it may be deleted, unless it is live."""
    if DIST_RE.fullmatch(name) or name.startswith(".dist-tmp-") and len(name) > len(".dist-tmp-"):
        return _owned(st, stat.S_ISDIR, 0o700)
    if name.startswith(".current.tmp-") and len(name) > len(".current.tmp-"):
        return _owned(st, stat.S_ISLNK)
    return False


def check_layout(root):
    """Refuses, before anything is built: an old-layout home (S3a before rev
    15.4: a real `.claude` directory); fixed links, `current` or state that
    are something else; and any entry with a build prefix that setup did not
    make (rev 15.5: garbage is deleted only once validated). No link is
    followed. Returns the live build's name, or None."""
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        def lstat(name):
            try:
                return os.stat(name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                return None

        claude = lstat(".claude")
        if claude is not None and not stat.S_ISLNK(claude.st_mode):
            raise SetupError(f"{root} has the old layout; move it aside and run again")
        for name, target in FIXED_LINKS:
            st = lstat(name)
            if st is not None and (not stat.S_ISLNK(st.st_mode) or os.readlink(name, dir_fd=fd) != target):
                raise SetupError(f"{root / name} is not the link setup made")
        live = None
        st = lstat("current")
        if st is not None:
            live = os.readlink("current", dir_fd=fd) if stat.S_ISLNK(st.st_mode) else ""
            live_st = lstat(live) if DIST_RE.fullmatch(live) else None
            if live_st is None or not _owned(live_st, stat.S_ISDIR, 0o700):
                raise SetupError(f"{root / 'current'} does not name a build setup made")
        for name in os.listdir(fd):
            if name.startswith(GARBAGE_PREFIXES) and not _valid_garbage(name, lstat(name)):
                raise SetupError(f"{root / name} is not something setup made; remove it and run again")
        # Existing state is never changed, so a wrong mode refuses (RoseCat 5431).
        if not _owned(os.fstat(fd), stat.S_ISDIR, 0o700):
            raise SetupError(f"{root} is not a mode-0700 directory of this user")
        for name in STATE_DIR_PATHS:
            st = lstat(name)
            if st is not None and not _owned(st, stat.S_ISDIR, 0o700):
                raise SetupError(f"{root / name} is not a mode-0700 directory of this user")
        st = lstat(STATE_FILE)
        if st is not None and not _owned(st, stat.S_ISREG, 0o600):
            raise SetupError(f"{root / STATE_FILE} is not a mode-0600 file of this user")
        return live
    finally:
        os.close(fd)


def ensure_home(root):
    """The state and the fixed links, each made only when absent, one at a
    time. Setup never writes into, moves or deletes state."""
    for name in STATE_DIR_PATHS:
        try:
            (root / name).mkdir(mode=0o700)
        except FileExistsError:
            pass
    try:
        fd = os.open(root / STATE_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except FileExistsError:
        pass
    else:
        try:
            write_all(fd, b"{}\n")
            os.fsync(fd)
        finally:
            os.close(fd)
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        for name, target in FIXED_LINKS:
            try:
                os.symlink(target, name, dir_fd=fd)
            except FileExistsError:
                pass
            # Whoever made it, it must now be exactly the link setup makes (rev 15.5).
            st = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if not stat.S_ISLNK(st.st_mode) or os.readlink(name, dir_fd=fd) != target:
                raise SetupError(f"{root / name} is not the link setup made")
    finally:
        os.close(fd)
    fsync_dir(root / "state")
    fsync_dir(root)


def pause(cut):
    """The e2e-only kill seam (--e2e-pause-at): announce the cut, then wait
    to be killed; never continue past it."""
    if cut != _PAUSE_AT:
        return
    print(f"SETUP\tpaused\t{cut}", flush=True)
    time.sleep(PAUSE_S)
    os._exit(1)


_PAUSE_AT = None


def publish(root, build):
    """`build` becomes dist-<n>, then `current` points at it: one atomic swap."""
    numbers = [int(m.group(1)) for p in root.iterdir() if (m := DIST_RE.fullmatch(p.name))]
    dist = root / f"dist-{max(numbers, default=0) + 1}"
    os.rename(build, dist)
    fsync_dir(root)
    pause("swap:before")
    link = root / f".current.tmp-{secrets.token_hex(8)}"
    os.symlink(dist.name, link)
    os.rename(link, root / "current")
    fsync_dir(root)
    pause("swap:after")


def collect_garbage(root):
    """Every validated build but the live one, and leftovers of interrupted
    runs: never state, never a link's target. fd-relative and no-follow.
    Best-effort: a failure is reported and setup still succeeds."""
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        live = os.readlink("current", dir_fd=fd)
        for name in sorted(os.listdir(fd)):
            if name == live or not name.startswith(GARBAGE_PREFIXES):
                continue
            try:
                st = os.stat(name, dir_fd=fd, follow_symlinks=False)
                if not _valid_garbage(name, st):
                    raise OSError(f"{name} changed")
                if stat.S_ISDIR(st.st_mode):
                    shutil.rmtree(name, dir_fd=fd)
                else:
                    os.unlink(name, dir_fd=fd)
            except OSError:
                print(f"zigBrowser: agent-setup: old build left at {root / name}", file=sys.stderr)
    finally:
        os.close(fd)


PACKAGE_DIR = Path(__file__).resolve().parent.parent


def provision(home, source, source_home, source_path, python, select_token_route=True, cli=None, probe=None,
              package_dir=PACKAGE_DIR):
    """Builds and checks a complete dist, selects the token route (R1, unless
    `select_token_route` is false), then publishes it. Raises SetupError, leaving the home
    as it was."""
    root = home.root
    if not os.path.isabs(str(source_home)) or str(source_home).rstrip("/") == "":
        raise SetupError("the source HOME is not an absolute directory")
    root.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    made_root = not root.exists()
    root.mkdir(mode=0o700, exist_ok=True)
    build = None
    try:
        check_layout(root)
        build = Path(tempfile.mkdtemp(prefix=".dist-tmp-", dir=root))
        os.chmod(build, 0o700)
        cli = cli or token.bundled_cli()
        stage(home, source, source_home, source_path, python, cli, build, package_dir)
        if select_token_route:
            select_route(build / "runtime", cli, probe or probe_r1)
        fsync_tree(build)
    except BaseException:
        if build is not None:
            shutil.rmtree(build, ignore_errors=True)
        if made_root:
            shutil.rmtree(root, ignore_errors=True)
        raise
    ensure_home(root)
    publish(root, build)
    collect_garbage(root)


# --- the token route (D11, S3.7) ---------------------------------------------

def contained(argv):
    """`argv` in its own PID namespace that dies with this process (RoseCat
    5347): the setup helper dies with the browser (PDEATHSIG), bwrap with the
    helper (--die-with-parent), and with bwrap's first child the kernel kills
    every process in the namespace, whatever the CLI started."""
    return [sandbox.BWRAP, "--unshare-pid", "--die-with-parent", "--dev-bind", "/", "/", "--proc", "/proc",
            "--", *map(str, argv)]


def cli_version(cli):
    try:
        done = subprocess.run(contained([cli, "--version"]), capture_output=True, text=True, timeout=20,
                              env={"PATH": "/usr/bin:/bin", "HOME": tempfile.gettempdir()})
        return (done.stdout.strip().split() or ["unknown"])[0]
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def select_route(runtime, cli, probe):
    """R1 when the installed CLI takes the token from the wrapper's descriptor;
    else refuse. There is no other route: R3, the token in the CLI's
    environment, was removed (plan rev 16, §3c.1)."""
    if not probe(runtime / "bin" / "zb-claude", cli):
        raise SetupError("no safe token route for this Claude CLI")
    record = {"route": "R1", "cli_path": str(cli), "cli_version": cli_version(cli),
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
        # The SDK starts the CLI through this launcher, so the CLI and all it
        # starts live in a PID namespace that dies with this helper.
        launcher = scratch / "zb-claude-contained"
        launcher.write_text("#!/bin/sh\nexec " + " ".join(map(shlex.quote, contained([wrapper]))) + ' "$@"\n')
        launcher.chmod(0o700)
        opts = options.build(home, route_env=handoff.env(), cli_path=str(launcher), base_url=server.url)

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
    parser.add_argument("--e2e-claude-cli")
    parser.add_argument("--e2e-pause-at", choices=PAUSE_CUTS)
    args = parser.parse_args(argv)
    global _PAUSE_AT
    _PAUSE_AT = args.e2e_pause_at
    try:
        provision(options.AgentHome(args.home), Path(args.sai_source), args.source_home.rstrip("/"),
                  args.source_path, args.python, cli=args.e2e_claude_cli)
    except SetupError as exc:
        print(f"zigBrowser: agent-setup: {exc}", file=sys.stderr)
        return 2
    except (OSError, ValueError) as exc:
        print(f"zigBrowser: agent-setup: {exc}", file=sys.stderr)
        return 1
    return 0
