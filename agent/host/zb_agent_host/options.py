"""The single builder of the helper's environment and of every ClaudeAgentOptions.

The SDK merges `ClaudeAgentOptions.env` over the helper's own environment, so the
helper first reduces its own environment to HELPER_ENV_NAMES (helper_environ),
then every CLI gets exactly that plus CLI_ENV_FIXED and the route's variables.
"""

from dataclasses import dataclass
from pathlib import Path

from claude_agent_sdk import ClaudeAgentOptions

# Everything the helper process keeps; anything else it inherited is dropped.
HELPER_ENV_NAMES = (
    "PATH", "LANG", "LC_ALL", "HOME", "CLAUDE_CONFIG_DIR", "TMPDIR",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK",
)
# Copied from the launching environment; the rest of HELPER_ENV_NAMES is set here.
INHERITED_ENV_NAMES = ("PATH", "LANG", "LC_ALL")

# Bounds the CLI's wait for one in-process tool call; the helper answers 10 s earlier.
MCP_TOOL_TIMEOUT_MS = 130_000
TOOL_DEADLINE_S = (MCP_TOOL_TIMEOUT_MS - 10_000) / 1000


@dataclass(frozen=True)
class AgentHome:
    root: Path

    def __post_init__(self):
        object.__setattr__(self, "root", Path(self.root))

    @property
    def claude_dir(self):
        return self.root / ".claude"

    @property
    def workspace(self):
        return self.root / "workspace"

    @property
    def scratchpad(self):
        return self.root / "scratchpad"

    @property
    def runtime(self):
        return self.root / "runtime"

    @property
    def state(self):
        """The agent's writable state, outside every published build (plan
        rev 15.4): the sandbox binds state/<name> at .claude/<name>."""
        return self.root / "state"

    @property
    def tmp(self):
        return self.scratchpad / "tmp"


def home_env(home):
    """HOME and the config dir point into the agent home, so no ~/ path reaches the user's."""
    return {
        "HOME": str(home.root),
        "CLAUDE_CONFIG_DIR": str(home.claude_dir),
        "TMPDIR": str(home.tmp),
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    }


def helper_environ(home, inherited):
    env = {name: inherited[name] for name in INHERITED_ENV_NAMES if name in inherited}
    env.setdefault("PATH", "/usr/bin:/bin")
    env.update(home_env(home))
    # The SDK's `cli -v` probe would run the R1 wrapper without a token FIFO.
    env["CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK"] = "1"
    return env


def cli_env(home, route_env, base_url=None, proxy=None, mcp_tool_timeout_ms=MCP_TOOL_TIMEOUT_MS):
    fixed = {**home_env(home), "DISABLE_AUTOUPDATER": "1", "MCP_TOOL_TIMEOUT": str(mcp_tool_timeout_ms)}
    clash = sorted(set(route_env) & set(fixed))
    if clash:
        raise ValueError(f"route may not set {', '.join(clash)}")
    env = dict(fixed)
    env.update(route_env)
    if base_url:
        env["ANTHROPIC_BASE_URL"] = base_url
    if proxy:
        env.update({"HTTPS_PROXY": proxy, "HTTP_PROXY": proxy, "NO_PROXY": "127.0.0.1,localhost"})
    return env


def build(home, *, route_env, cli_path=None, base_url=None, proxy=None, mcp_servers=None,
          allowed_tools=(), can_use_tool=None, mcp_tool_timeout_ms=MCP_TOOL_TIMEOUT_MS,
          stderr=None, extra_args=None):
    return ClaudeAgentOptions(
        setting_sources=["user"],
        cwd=str(home.workspace),
        tools=[],
        permission_mode="default",
        env=cli_env(home, route_env, base_url, proxy, mcp_tool_timeout_ms),
        cli_path=cli_path,
        mcp_servers=dict(mcp_servers or {}),
        allowed_tools=list(allowed_tools),
        can_use_tool=can_use_tool,
        include_partial_messages=True,
        stderr=stderr,
        # Only the in-process zigbrowser server may exist: MCP servers planted in
        # any settings or .claude.json are ignored.
        extra_args={"strict-mcp-config": None, **(extra_args or {})},
    )


def cli_version():
    from claude_agent_sdk._cli_version import __cli_version__
    return __cli_version__
