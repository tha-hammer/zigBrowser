#!/usr/bin/env python3
"""Chat drawer S3.1 and S3.7: `zigBrowser --agent-setup` provisions the agent
home from a SAI source, and selects the token route on the installed CLI
(thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md).

Every case runs the real binary with HOME pointing at a decoy user home whose
`.claude/` and `src/decoy-repo/` are watched by inotify: setup must cause no
event there. The SAI source is the fixture tree, copied with its
`@SOURCE_HOME@` placeholders set to that HOME.

- provision: the D6 layout with 0700 modes; CLAUDE.md copied with the HOME
  prefix rewritten; settings sanitized; every hook kept and wrapped in
  `zb-hook-run --`; credentials, transcripts, history, todos and MEMORY
  contents left behind; the runtime written; `token-route.json` says R1 for
  the bundled CLI after the real probe
- idempotent: a second run leaves `.claude` as it was
- refusals (exit 2, the home unchanged): an absolute hook outside the agent
  home; a hook script symlinked outside its item; a hook script in the
  scratchpad; shell syntax in a hook command. Paths in copied text (a
  `.md`, a hook script, a JSON file) are copied and do not refuse (plan rev
  15.6, the user's decision)
- an e2e-only CLI that ignores the token descriptor: exit 2, "no safe token
  route", nothing written
- inertness: the CLI seam without --e2e-protocol is refused on stderr, never
  reaches the setup helper's argv or environment, and never runs
- R3: --agent-token-route env writes R3 and prints the risk line
- kill (plan rev 15.5): the browser is SIGKILLed while setup is paused at
  `swap:before` or `swap:after` (ZIGBROWSER_AGENT_SETUP_PAUSE, e2e only):
  `current` names one whole build, the old or the new; the seeded state
  keeps its content and inodes; the helper is gone; a plain rerun publishes
  and leaves one build. A first install killed at `swap:before` has no
  `current`, and its rerun completes. An old-layout home refuses.
- descendants (RoseCat 5347): the browser is SIGKILLed while the route
  probe's CLI and a process it started are running: the helper, the CLI and
  its child are all gone within 2 s

Exit 1 (never 77) when the helper venv is missing."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
import time
from pathlib import Path

from agent_common import REPO, Checks, Inotify, host_python, run_main

FIXTURE = REPO / "tests" / "fixtures" / "agent" / "sai_source"
NO_ROUTE = "zigBrowser: agent-setup: no safe token route for this Claude CLI"
IGNORED = "zigBrowser: ZIGBROWSER_AGENT_CLAUDE_CLI ignored without --e2e-protocol"


def digest(root: Path) -> str:
    h = hashlib.sha256()
    if not root.exists():
        return "absent"
    for path in sorted(root.rglob("*")):
        st = path.lstat()
        h.update(f"{path.relative_to(root)}:{stat.S_IMODE(st.st_mode)}".encode())
        if path.is_file() and not path.is_symlink():
            h.update(path.read_bytes())
    return h.hexdigest()


class World:
    """A decoy HOME, a SAI source, a PATH with a fake `bun`, and a data dir."""

    def __init__(self, tmp: Path, name: str) -> None:
        self.root = Path(tempfile.mkdtemp(prefix=f"{name}-", dir=tmp))
        self.home = self.root / "home"
        (self.home / ".claude" / "hooks").mkdir(parents=True)
        (self.home / ".claude" / "CLAUDE.md").write_text("ZB-DECOY-USER-MARKER\n")
        (self.home / ".claude" / "settings.json").write_text('{"hooks": {}}\n')
        (self.home / ".claude" / "hooks" / "decoy.sh").write_text("#!/bin/sh\n")
        (self.home / "src" / "decoy-repo").mkdir(parents=True)
        (self.home / "src" / "decoy-repo" / "README").write_text("decoy\n")
        self.source = self.root / "sai"
        shutil.copytree(FIXTURE, self.source, symlinks=True)
        for path in self.source.rglob("*"):
            if path.is_file() and not path.is_symlink() and b"@SOURCE_HOME@" in path.read_bytes():
                path.write_bytes(path.read_bytes().replace(b"@SOURCE_HOME@", str(self.home).encode()))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "bun").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "bun").chmod(0o755)
        self.data = self.root / "data"
        self.agent = self.data / "zigbrowser" / "agent-home"

    def env(self, extra: dict[str, str] | None = None) -> dict[str, str]:
        env = {"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.home), "XDG_DATA_HOME": str(self.data),
               "LANG": "C.UTF-8", "ZB_AGENT_HOST_PYTHON": PYTHON, "ZB_AGENT_HOST_DIR": str(REPO / "agent" / "host")}
        env.update(extra or {})
        return env

    def settings(self) -> dict:
        return json.loads((self.source / "settings.json").read_text())

    def write_settings(self, settings: dict) -> None:
        (self.source / "settings.json").write_text(json.dumps(settings))


def run_setup(binary: Path, world: World, args: list[str] = (), extra: dict[str, str] | None = None,
              watch_helper: bool = False, drop: tuple[str, ...] = (), timeout: float = 180):
    """Runs --agent-setup; with `watch_helper`, also samples the setup
    helper's argv and environment while it runs."""
    oracle = Inotify(world.home / ".claude", world.home / "src" / "decoy-repo")
    proc = subprocess.Popen([str(binary.resolve()), "--agent-setup", "--sai-source", str(world.source), *args],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
                            env={k: v for k, v in world.env(extra).items() if k not in drop})
    seen: list[tuple[list[str], list[str]]] = []
    if watch_helper:
        deadline = time.monotonic() + 120
        while proc.poll() is None and time.monotonic() < deadline:
            for pid in os.listdir("/proc"):
                if not pid.isdigit():
                    continue
                try:
                    argv = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
                    if b"zb_agent_host" in argv and b"setup" in argv:
                        names = [e.split(b"=", 1)[0].decode() for e in Path(f"/proc/{pid}/environ").read_bytes().split(b"\0") if e]
                        seen.append(([a.decode() for a in argv if a], names))
                except OSError:
                    continue
            time.sleep(0.05)
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        out, err = "", "TIMEOUT"
    finally:
        reap(proc)
    events = oracle.events()
    oracle.close()
    return proc.returncode, out, err, events, seen


def reap(proc: subprocess.Popen) -> None:
    """The setup run's whole process group ends here: TERM, then KILL, then
    reaped, so a timed-out run leaves no helper or CLI behind (RoseCat d7527bb)."""
    import signal
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            break
        try:
            proc.wait(timeout=5)
            break
        except subprocess.TimeoutExpired:
            continue
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()


def bundled_cli() -> str:
    done = subprocess.run([PYTHON, "-c", "import claude_agent_sdk, os; print(os.path.join(os.path.dirname(claude_agent_sdk.__file__), '_bundled', 'claude'))"],
                          capture_output=True, text=True, check=True)
    return done.stdout.strip()


def case_provision(binary: Path, tmp: Path, check: Checks) -> None:
    w = World(tmp, "provision")
    code, _out, err, events, _ = run_setup(binary, w)
    if not check(code == 0, f"provision: exit 0 (exit {code}; {err.strip()[-400:]!r})"):
        return
    check(events == [], f"provision: no event in the decoy home's .claude or repo ({events[:5]})")
    root = w.agent
    for sub in (".", ".claude", "workspace", "scratchpad", "secrets", "runtime"):
        check(stat.S_IMODE((root / sub).stat().st_mode) == 0o700, f"provision: {sub} is 0700")
    claude_md = (root / ".claude" / "CLAUDE.md").read_text()
    check("ZB-AGENT-SAI-MARKER" in claude_md and f"{root}/.claude/SAI/README.md" in claude_md and str(w.home) not in claude_md,
          "provision: CLAUDE.md copied, the source HOME rewritten to the agent home")
    settings = json.loads((root / ".claude" / "settings.json").read_text())
    text = json.dumps(settings)
    removed = ("mcpServers", "enabledMcpjsonServers", "enableAllProjectMcpServers", "enabledPlugins", "extraKnownMarketplaces",
               "statusLine", "skipDangerousModePermissionPrompt", "apiKeyHelper", '"env"', "bypassPermissions", '"allow"')
    check(not any(k in text for k in removed), "provision: settings.json has none of the removed keys")
    commands = [h["command"] for entries in settings["hooks"].values() for e in entries for h in e["hooks"]]
    prefix = f"{root}/runtime/bin/zb-hook-run -- "
    check(len(commands) == 3 and all(c.startswith(prefix) for c in commands), f"provision: every hook kept and wrapped ({commands})")
    check(any("~/.claude/hooks/X.hook.ts" in c for c in commands), "provision: ~/.claude paths kept as they are")
    for gone in (".credentials.json", "history.jsonl", "projects/p1", "todos/t.json", "MEMORY/notes.md"):
        check(not (root / ".claude" / gone).exists(), f"provision: {gone} not copied")
    check(str(w.bin) in json.loads((root / "runtime" / "path.json").read_text()), "provision: bun's directory is in runtime/path.json")
    route = json.loads((root / "runtime" / "token-route.json").read_text())
    check(route["route"] == "R1" and route["cli_path"] == bundled_cli() and route["cli_version"] not in ("", "unknown"),
          f"provision: the real probe selected R1 for the bundled CLI ({route})")
    before = digest(root / ".claude")
    code2, _o, err2, events2, _ = run_setup(binary, w)
    check(code2 == 0 and digest(root / ".claude") == before and events2 == [],
          f"idempotent: a second run leaves .claude as it was (exit {code2}; {err2.strip()[-200:]!r})")


def refused(binary: Path, tmp: Path, check: Checks, label: str, mutate, want: str) -> None:
    w = World(tmp, "".join(ch if ch.isalnum() else "-" for ch in label))
    code0, _o, err0, _e, _s = run_setup(binary, w)
    if not check(code0 == 0, f"{label}: the clean source provisions first ({err0.strip()[-200:]!r})"):
        return
    before = digest(w.agent)
    mutate(w)
    code, _out, err, events, _ = run_setup(binary, w)
    check(code == 2 and want in err, f"{label}: exit 2 with {want!r} (exit {code}; {err.strip()[-300:]!r})")
    check(digest(w.agent) == before, f"{label}: the agent home is unchanged")
    check(events == [], f"{label}: no event in the decoy trees ({events[:6]})")


def case_refusals(binary: Path, tmp: Path, check: Checks) -> None:
    def evil_hook(w: World) -> None:
        s = w.settings()
        s["hooks"]["Stop"][0]["hooks"].append({"type": "command", "command": "/home/u/evil.sh"})
        w.write_settings(s)

    def append(rel: str, line: str):
        def mutate(w: World) -> None:
            with open(w.source / rel, "a") as f:
                f.write(line)
        return mutate

    def json_file(w: World) -> None:
        (w.source / "skills" / "demo" / "meta.json").write_text('{\n  "data": "/srv/data/file"\n}\n')

    def symlinked(w: World) -> None:
        outside = w.root / "outside.ts"
        outside.write_text("// outside\n")
        (w.source / "hooks" / "X.hook.ts").unlink()
        (w.source / "hooks" / "X.hook.ts").symlink_to(outside)

    refused(binary, tmp, check, "absolute hook", evil_hook, "zigBrowser: agent-setup: hook path outside agent home: Stop/0")
    refused(binary, tmp, check, "hook symlinked outside", symlinked,
            "zigBrowser: agent-setup: hook script links outside its item: hooks/X.hook.ts")

    def writable_hook(w: World) -> None:  # RoseCat 5444: bytes the agent could change later
        s = w.settings()
        s["hooks"]["Stop"][0]["hooks"].append({"type": "command", "command": "bun ~/scratchpad/run.ts"})
        w.write_settings(s)

    refused(binary, tmp, check, "hook in the scratchpad", writable_hook,
            "zigBrowser: agent-setup: hook path is not in the copied SAI: Stop/0")

    def shell_hook(w: World) -> None:  # RoseCat 5438: no shell syntax reaches a hook
        s = w.settings()
        marker = w.root / "shell-marker"
        s["hooks"]["Stop"][0]["hooks"].append({"type": "command", "command": f"bun ~/.claude/hooks/X.hook.ts; touch {marker}"})
        w.write_settings(s)

    refused(binary, tmp, check, "shell syntax in a hook", shell_hook,
            "zigBrowser: agent-setup: hook command has shell syntax: Stop/0")

    def unterminated_quote(w: World) -> None:  # RoseCat 833767e: exit 2, not a parser crash (exit 1)
        s = w.settings()
        s["hooks"]["Stop"][0]["hooks"].append({"type": "command", "command": 'python3 "unterminated'})
        w.write_settings(s)

    refused(binary, tmp, check, "unterminated quote in a hook", unterminated_quote,
            "zigBrowser: agent-setup: hook command has shell syntax: Stop/0")

    # Plan rev 15.6 (the user's decision): only hook command lines refuse;
    # a path in copied text, hook scripts included, is copied as it is.
    w = World(tmp, "text-paths")
    for mutate in (append("commands/hello.md", "Also /srv/elsewhere/notes.\n"),
                   append("hooks/X.hook.ts", 'const log = "/var/log/x.log";\n'), json_file):
        mutate(w)
    code, _o, err, events, _ = run_setup(binary, w)
    copied = {rel: (w.agent / ".claude" / rel).read_text() if code == 0 else ""
              for rel in ("commands/hello.md", "hooks/X.hook.ts", "skills/demo/meta.json")}
    check(code == 0 and "/srv/elsewhere/notes" in copied["commands/hello.md"]
          and "/var/log/x.log" in copied["hooks/X.hook.ts"] and "/srv/data/file" in copied["skills/demo/meta.json"],
          f"text paths: paths in a .md, a hook script and a JSON file are copied, setup succeeds ({code}; {err.strip()[-200:]!r})")
    check(events == [], "text paths: no event in the decoy trees")


def fake_cli(dir_: Path, name: str, body: str) -> Path:
    path = dir_ / name
    path.write_text("#!/usr/bin/python3 -I\n" + body)
    path.chmod(0o755)
    return path


def case_cli_seam(binary: Path, tmp: Path, check: Checks) -> None:
    # A CLI that ignores CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR: it calls the
    # API with no bearer, then exits.
    w = World(tmp, "no-route")
    cli = fake_cli(w.root, "fake-claude", (
        "import os, sys, urllib.request\n"
        "if '--version' in sys.argv: print('0.0.0 (fake)'); sys.exit(0)\n"
        "req = urllib.request.Request(os.environ['ANTHROPIC_BASE_URL'] + '/v1/messages', data=b'{}', method='POST')\n"
        "try: urllib.request.urlopen(req, timeout=5)\n"
        "except Exception: pass\n"
        "sys.exit(1)\n"))
    code, _out, err, _ev, _ = run_setup(binary, w, ["--e2e-protocol"], {"ZIGBROWSER_AGENT_CLAUDE_CLI": str(cli)})
    check(code == 2 and NO_ROUTE in err, f"no route: an e2e CLI ignoring the token descriptor -> exit 2 ({code}; {err.strip()[-300:]!r})")
    check(not (w.agent / ".claude").exists() and not (w.agent / "runtime").exists(), "no route: nothing is written")

    # Inertness: the same seam without --e2e-protocol.
    w = World(tmp, "inert")
    marker = w.root / "marker"
    cli = fake_cli(w.root, "marker-claude", f"open({str(marker)!r}, 'w').write('ran')\n")
    code, _out, err, _ev, seen = run_setup(binary, w, [], {"ZIGBROWSER_AGENT_CLAUDE_CLI": str(cli)}, watch_helper=True)
    check(code == 0 and IGNORED in err, f"inert: setup runs and stderr says the seam is ignored ({code}; {err.strip()[-300:]!r})")
    check(bool(seen), f"inert: the setup helper was sampled while it ran ({len(seen)} samples)")
    check(all("--e2e-claude-cli" not in argv and str(cli) not in argv for argv, _ in seen), "inert: no --e2e-claude-cli in the helper's argv")
    check(all("ZIGBROWSER_AGENT_CLAUDE_CLI" not in names for _, names in seen), "inert: the variable is not in the helper's environment")
    check(not marker.exists(), "inert: the seam's program never ran")
    route = json.loads((w.agent / "runtime" / "token-route.json").read_text()) if (w.agent / "runtime" / "token-route.json").exists() else {}
    check(route.get("cli_path") == bundled_cli() and route.get("route") == "R1", f"inert: token-route.json names the bundled CLI ({route})")
    expected = {"PATH", "HOME", "CLAUDE_CONFIG_DIR", "TMPDIR", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "PYTHONPATH",
                "PYTHONDONTWRITEBYTECODE", "LANG"}
    check(bool(seen) and set(seen[0][1]) == expected, f"inert: the helper's environment is exactly the allowlist ({seen[0][1] if seen else None})")

    # R3 on request.
    w = World(tmp, "r3")
    code, _out, err, _ev, _ = run_setup(binary, w, ["--agent-token-route", "env"])
    route = json.loads((w.agent / "runtime" / "token-route.json").read_text()) if code == 0 else {}
    check(code == 0 and route.get("route") == "R3" and "token route env (R3)" in err,
          f"R3: --agent-token-route env writes R3 and prints the risk line ({code}; {route})")


def helpers_for(home: Path) -> list[int]:
    """Live processes running the setup helper for this agent home."""
    pids = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            argv = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
            state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
        except OSError:
            continue
        if b"zb_agent_host" in argv and str(home).encode() in argv and state != "Z":
            pids.append(int(pid))
    return pids


def case_parent_death(binary: Path, tmp: Path, check: Checks) -> None:
    """RoseCat 5330: the browser dies between fork() and PR_SET_PDEATHSIG; the
    setup child must not survive it. The e2e-only spawn delay holds the child
    inside that window."""
    import signal
    for round_ in range(3):
        w = World(tmp, f"parent-death-{round_}")
        proc = subprocess.Popen([str(binary.resolve()), "--agent-setup", "--e2e-protocol", "--sai-source", str(w.source)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                env=w.env({"ZIGBROWSER_AGENT_SPAWN_DELAY_MS": "500"}))
        time.sleep(0.15)
        proc.send_signal(signal.SIGKILL)
        proc.wait()
        # The child leaves its 500 ms window about 0.35 s from now; by 1 s an
        # orphan is running setup, and a correct child has already exited.
        time.sleep(1.0)
        left = helpers_for(w.agent)
        check(left == [], f"parent death {round_}: no setup helper outlives the browser ({left})")
        for pid in left:
            os.kill(pid, signal.SIGKILL)


def case_timeout_teardown(binary: Path, tmp: Path, check: Checks) -> None:
    """A run that times out is torn down with its descendants (d7527bb SHOULD):
    the setup child is held 5 s by the e2e-only spawn delay; the run's 1 s
    timeout must still leave no helper behind."""
    w = World(tmp, "timeout")
    _code, _o, err, _e, _s = run_setup(binary, w, ["--e2e-protocol"], {"ZIGBROWSER_AGENT_SPAWN_DELAY_MS": "5000"},
                                       timeout=1.0)
    time.sleep(6.0)
    check(err == "TIMEOUT" and helpers_for(w.agent) == [], f"timeout: the run timed out and no helper outlived it ({helpers_for(w.agent)})")


def case_bad_home(binary: Path, tmp: Path, check: Checks) -> None:
    """RoseCat 5328 (3): an empty or missing HOME is refused, never rewritten."""
    for label, extra in (("empty HOME", {"HOME": ""}), ("relative HOME", {"HOME": "rel"})):
        w = World(tmp, label.replace(" ", "-"))
        code, _o, err, _e, _s = run_setup(binary, w, [], extra)
        check(code == 2 and "HOME must be an absolute directory" in err and not (w.agent / ".claude").exists(),
              f"{label}: refused with exit 2 and nothing written ({code}; {err.strip()[-200:]!r})")


def case_clean_install(binary: Path, tmp: Path, check: Checks) -> None:
    """RoseCat 5331: the production route, with no developer override. The
    runtime is installed beside a copy of the binary, as `zig build
    agent-runtime` does for the install prefix."""
    prefix = tmp / "prefix"
    done = subprocess.run(["sh", str(REPO / "tools" / "install_agent_runtime.sh"), str(prefix)],
                          capture_output=True, text=True, timeout=900)
    if not check(done.returncode == 0, f"clean install: the runtime installs ({done.stderr.strip()[-300:]!r})"):
        return
    (prefix / "bin").mkdir()
    shutil.copy2(binary, prefix / "bin" / "zigBrowser")
    w = World(tmp, "clean-install")
    overrides = ("ZB_AGENT_HOST_PYTHON", "ZB_AGENT_HOST_DIR")
    code, _o, err, _e, _s = run_setup(prefix / "bin" / "zigBrowser", w, drop=overrides)
    if not check(code == 0, f"clean install: setup succeeds with no override ({code}; {err.strip()[-300:]!r})"):
        return
    runtime = prefix / "lib" / "zigbrowser" / "agent-host"
    host = json.loads((w.agent / "runtime" / "host.json").read_text())
    lock = hashlib.sha256((REPO / "agent" / "host" / "uv.lock").read_bytes()).hexdigest()
    check(host == {"python": str(runtime / "venv" / "bin" / "python"), "runtime_lock": lock},
          f"clean install: host.json names the installed runtime and its lock ({host})")
    route = json.loads((w.agent / "runtime" / "token-route.json").read_text())
    check(route["route"] == "R1", f"clean install: the probe selected R1 through the installed runtime ({route})")
    bare = tmp / "bare"
    (bare / "bin").mkdir(parents=True)
    shutil.copy2(binary, bare / "bin" / "zigBrowser")
    w2 = World(tmp, "no-runtime")
    code, _o, err, _e, _s = run_setup(bare / "bin" / "zigBrowser", w2, drop=overrides)
    want = f"zigBrowser: agent-setup: agent runtime missing at {bare}/lib/zigbrowser/agent-host/venv/bin/python"
    check(code == 1 and want in err, f"no runtime: setup names where the runtime is missing ({code}; {err.strip()[-300:]!r})")


SEEDED = ("state/projects/keep.jsonl", "state/MEMORY/note.md", "workspace/keep.txt")


def seed_state(agent: Path) -> dict[str, tuple[int, bytes]]:
    for rel in SEEDED:
        (agent / rel).write_text(f"seed {rel}\n")
    return state_of(agent)


def state_of(agent: Path) -> dict[str, tuple[int, bytes]]:
    out = {}
    for rel in (*SEEDED, "state/.claude.json"):
        path = agent / rel
        out[rel] = (path.stat().st_ino, path.read_bytes()) if path.exists() else (0, b"")
    return out


def builds(agent: Path) -> list[str]:
    return sorted(p.name for p in agent.iterdir() if p.name.startswith(("dist-", ".dist-tmp-", ".current.tmp-")))


def current(agent: Path) -> str | None:
    return os.readlink(agent / "current") if os.path.islink(agent / "current") else None


def setup_until(binary: Path, w: World, want: str, extra: dict[str, str], timeout: float = 120):
    """Starts --agent-setup --e2e-protocol and reads stdout until the row
    `want`; returns (proc, seen)."""
    proc = subprocess.Popen([str(binary.resolve()), "--agent-setup", "--e2e-protocol", "--sai-source", str(w.source)],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=w.env(extra))
    deadline, seen = time.monotonic() + timeout, False
    while time.monotonic() < deadline and not seen:
        line = proc.stdout.readline()
        if not line:
            break
        seen = line.rstrip("\n") == want
    return proc, seen


def case_kill(binary: Path, tmp: Path, check: Checks) -> None:
    import signal
    for cut in ("swap:before", "swap:after"):
        w = World(tmp, f"kill-{cut.replace(':', '-')}")
        code, _o, err, _e, _s = run_setup(binary, w)
        if not check(code == 0, f"{cut}: the first setup succeeds ({code}; {err.strip()[-200:]!r})"):
            continue
        before = seed_state(w.agent)
        old = current(w.agent)
        proc, seen = setup_until(binary, w, f"SETUP\tpaused\t{cut}", {"ZIGBROWSER_AGENT_SETUP_PAUSE": cut})
        if check(seen, f"{cut}: setup reports the pause"):
            want = old if cut == "swap:before" else "dist-2"
            check(current(w.agent) == want and "dist-2" in builds(w.agent),
                  f"{cut}: before the kill, current is {want} and dist-2 is built ({current(w.agent)}, {builds(w.agent)})")
        proc.send_signal(signal.SIGKILL)
        proc.wait()
        time.sleep(1.0)
        left = helpers_for(w.agent)
        check(left == [], f"{cut}: the paused helper died with the browser ({left})")
        for pid in left:
            os.kill(pid, signal.SIGKILL)
        live = current(w.agent)
        check(live in (old, "dist-2") and (w.agent / live / ".claude" / "settings.json").is_file(),
              f"{cut}: current names one whole build ({live})")
        check(state_of(w.agent) == before, f"{cut}: the state kept its content and inodes")
        code, _o, err, _e, _s = run_setup(binary, w)
        check(code == 0 and builds(w.agent) == [current(w.agent)] and state_of(w.agent) == before,
              f"{cut}: a plain rerun publishes one build and keeps the state ({code}; {builds(w.agent)}; {err.strip()[-200:]!r})")

    w = World(tmp, "kill-first")
    proc, seen = setup_until(binary, w, "SETUP\tpaused\tswap:before", {"ZIGBROWSER_AGENT_SETUP_PAUSE": "swap:before"})
    proc.send_signal(signal.SIGKILL)
    proc.wait()
    time.sleep(1.0)
    check(seen and current(w.agent) is None and helpers_for(w.agent) == [],
          f"first install killed at swap:before: no current, no helper ({current(w.agent)})")
    code, _o, err, _e, _s = run_setup(binary, w)
    check(code == 0 and current(w.agent) == "dist-2" and builds(w.agent) == ["dist-2"]
          and os.readlink(w.agent / ".claude") == "current/.claude",
          f"first install: the rerun completes ({code}; {builds(w.agent)}; {err.strip()[-200:]!r})")

    w = World(tmp, "old-layout")
    (w.agent / ".claude" / "projects").mkdir(parents=True)
    code, _o, err, _e, _s = run_setup(binary, w)
    check(code == 2 and f"{w.agent} has the old layout; move it aside and run again" in err
          and sorted(p.name for p in w.agent.iterdir()) in ([".claude"], [".claude", ".zb-owner.lock"]),
          f"old layout: refused with exit 2 and nothing built ({code}; {err.strip()[-200:]!r})")


def case_descendants(binary: Path, tmp: Path, check: Checks) -> None:
    """RoseCat 5347: the route probe's CLI and whatever it starts die with the
    browser. The fake CLI answers --version, then on the probe starts a child
    and sleeps; both carry a marker in their argv, so the test finds their
    host PIDs (they live in their own PID namespace)."""
    import signal
    w = World(tmp, "descendants")
    tag = f"zb-descendant-{os.getpid()}-{int(time.monotonic() * 1000)}"
    ready = w.root / "ready"
    cli = fake_cli(w.root, "sleepy-claude", (
        "import subprocess, sys, time\n"
        "if '--version' in sys.argv: print('0.0.0 (fake)'); sys.exit(0)\n"
        f"subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)', {tag + '-child'!r}])\n"
        f"open({str(ready)!r}, 'w').write('ok')\n"
        "time.sleep(120)\n"))
    proc = subprocess.Popen([str(binary.resolve()), "--agent-setup", "--e2e-protocol", "--sai-source", str(w.source)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            env=w.env({"ZIGBROWSER_AGENT_CLAUDE_CLI": str(cli)}))

    def running(marker: str) -> list[int]:
        pids = []
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                argv = Path(f"/proc/{pid}/cmdline").read_bytes()
                state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
            except OSError:
                continue
            if marker.encode() in argv and state != "Z":
                pids.append(int(pid))
        return pids

    deadline = time.monotonic() + 120
    while time.monotonic() < deadline and not ready.exists() and proc.poll() is None:
        time.sleep(0.1)
    cli_pids, child_pids = running(str(cli)), running(tag + "-child")
    if not check(ready.exists() and cli_pids and child_pids,
                 f"descendants: the probe's CLI and its child are running ({cli_pids}, {child_pids})"):
        reap(proc)
        return
    proc.send_signal(signal.SIGKILL)
    proc.wait()
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline and (helpers_for(w.agent) or running(str(cli)) or running(tag + "-child")):
        time.sleep(0.1)
    left = {"helper": helpers_for(w.agent), "cli": running(str(cli)), "child": running(tag + "-child")}
    check(not any(left.values()), f"descendants: helper, CLI and child are gone within 2 s of the browser's death ({left})")
    for pid in (p for pids in left.values() for p in pids):
        os.kill(pid, signal.SIGKILL)


def main() -> int:
    return run_main(__doc__, {"provision": case_provision, "refusals": case_refusals, "cli": case_cli_seam,
                              "parent": case_parent_death, "home": case_bad_home, "install": case_clean_install,
                              "timeout": case_timeout_teardown, "kill": case_kill, "descendants": case_descendants})


if __name__ == "__main__":
    PYTHON = host_python()
    raise SystemExit(main())
