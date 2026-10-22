"""Runtime provisioning used by the P0 contracts (a subset of --agent-setup, D6).

It writes runtime/bin/zb-claude (route R1), runtime/bin/zb-hook-run and
runtime/hook-env.json, and rewrites every hook command in .claude/settings.json
as `<agent-home>/runtime/bin/zb-hook-run -- <command>`.
"""

import argparse
import json
import sys

from . import hook_run, options, relay, token
from .files import atomic_write

# The variables the bundled CLI sets for hooks (P0 census, CLI 2.1.294), minus
# hook_run.REFUSED, plus the plan's PATH, HOME, LANG, LC_ALL, TMPDIR and TERM.
# CLAUDE_CODE_TMPDIR (cli_env, MS6.3): the CLI forwards it to hooks; it equals TMPDIR, which they already get.
HOOK_ENV_NAMES = (
    "PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "TERM", "PWD",
    "AI_AGENT", "ANTHROPIC_BASE_URL", "CLAUDECODE", "CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK",
    "CLAUDE_AGENT_SDK_VERSION", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
    "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_TMPDIR",
    "CLAUDE_CONFIG_DIR", "CLAUDE_EFFORT", "CLAUDE_ENV_FILE", "CLAUDE_PID", "CLAUDE_PROJECT_DIR",
    "COREPACK_ENABLE_AUTO_PIN", "DISABLE_AUTOUPDATER",
    "MCP_TOOL_TIMEOUT", "NoDefaultCurrentDirectoryInExePath",
)


class ProvisionError(Exception):
    pass


def hook_run_path(home):
    return home.runtime / "bin" / "zb-hook-run"


def wrap_hooks(settings, prefix):
    for event, entries in (settings.get("hooks") or {}).items():
        for index, entry in enumerate(entries):
            for hook in entry.get("hooks", []):
                command = hook.get("command")
                if hook.get("type") != "command" or not isinstance(command, str) or not command.strip():
                    raise ProvisionError(f"hook cannot be wrapped: {event}/{index}")
                if not command.startswith(prefix):
                    hook["command"] = prefix + command
    return settings


def provision_runtime(home, hook_env_names=HOOK_ENV_NAMES):
    bad = hook_run.refused_names(hook_env_names)
    if bad:
        raise ProvisionError(f"refused hook environment names: {', '.join(bad)}")
    bindir = home.runtime / "bin"
    bindir.mkdir(parents=True, exist_ok=True)
    token.write_wrapper(bindir / "zb-claude", token.bundled_cli())
    with open(hook_run.__file__) as f:
        atomic_write(hook_run_path(home), f.read(), 0o700)
    with open(relay.BRIDGE_RELAY_FILE) as f:  # each hook's bridge-only relay (§3c.8b)
        atomic_write(bindir / "zb-net-relay", f.read(), 0o555)
    atomic_write(home.runtime / "hook-env.json", json.dumps(list(hook_env_names)), 0o600)
    settings_path = home.claude_dir / "settings.json"
    if settings_path.exists():
        settings = json.loads(settings_path.read_text())
        wrap_hooks(settings, f"{hook_run_path(home)} -- ")
        atomic_write(settings_path, json.dumps(settings, indent=2), 0o600)


def main(argv):
    parser = argparse.ArgumentParser(prog="zb_agent_host provision-runtime")
    parser.add_argument("--home", required=True)
    args = parser.parse_args(argv)
    try:
        provision_runtime(options.AgentHome(args.home))
    except ProvisionError as exc:
        print(f"zigBrowser: agent-setup: {exc}", file=sys.stderr)
        return 2
    return 0
