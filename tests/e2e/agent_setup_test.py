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
  home; an outside path in a `.md`, a `.ts` hook and a JSON file; a hook
  script symlinked outside
- an e2e-only CLI that ignores the token descriptor: exit 2, "no safe token
  route", nothing written
- inertness: the CLI seam without --e2e-protocol is refused on stderr, never
  reaches the setup helper's argv or environment, and never runs
- R3: --agent-token-route env writes R3 and prints the risk line

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
              watch_helper: bool = False):
    """Runs --agent-setup; with `watch_helper`, also samples the setup
    helper's argv and environment while it runs."""
    oracle = Inotify(world.home / ".claude", world.home / "src" / "decoy-repo")
    proc = subprocess.Popen([str(binary.resolve()), "--agent-setup", "--sai-source", str(world.source), *args],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=world.env(extra))
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
    out, err = proc.communicate(timeout=180)
    events = oracle.events()
    oracle.close()
    return proc.returncode, out, err, events, seen


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
    check(events == [], f"{label}: no event in the decoy trees")


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
    refused(binary, tmp, check, "outside path in .md", append("commands/hello.md", "Also /srv/elsewhere/notes.\n"),
            "zigBrowser: agent-setup: outside path in commands/hello.md:3")
    refused(binary, tmp, check, "outside path in .ts hook", append("hooks/X.hook.ts", 'const log = "/var/log/x.log";\n'),
            "zigBrowser: agent-setup: outside path in hooks/X.hook.ts:5")
    refused(binary, tmp, check, "outside path in JSON", json_file, "zigBrowser: agent-setup: outside path in skills/demo/meta.json:2")
    refused(binary, tmp, check, "hook symlinked outside", symlinked, "zigBrowser: agent-setup: outside path in hooks/X.hook.ts")


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


def main() -> int:
    return run_main(__doc__, {"provision": case_provision, "refusals": case_refusals, "cli": case_cli_seam})


if __name__ == "__main__":
    PYTHON = host_python()
    raise SystemExit(main())
