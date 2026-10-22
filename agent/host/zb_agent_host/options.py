"""The single builder of the helper's environment and of every ClaudeAgentOptions.

The SDK merges `ClaudeAgentOptions.env` over the helper's own environment, so the
helper first reduces its own environment to HELPER_ENV_NAMES (helper_environ),
then every CLI gets exactly that plus CLI_ENV_FIXED and the route's variables.
"""

from dataclasses import dataclass
from pathlib import Path

from claude_agent_sdk import ClaudeAgentOptions

from . import sandbox  # stdlib-only; the backend owns the egress endpoint (one source of truth)

# Everything the helper process keeps; anything else it inherited is dropped.
HELPER_ENV_NAMES = (
    "PATH", "LANG", "LC_ALL", "HOME", "CLAUDE_CONFIG_DIR", "TMPDIR",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK",
)
# Copied from the launching environment; the rest of HELPER_ENV_NAMES is set here.
INHERITED_ENV_NAMES = ("PATH", "LANG", "LC_ALL")

# The CLI's only way out (plan rev 16 §3c.2): the outer relay's listener inside the
# helper sandbox's own network namespace. IPv4 only, so no ::1 in NO_PROXY.
def relay_proxy_url():
    """The CLI's HTTPS_PROXY, from the backend's egress endpoint — not a hard-coded
    literal, so a different backend-supplied endpoint changes the CLI's proxy
    (rev 16.2 §3c; MS0). Stays ``http://127.0.0.1:3128`` on Linux."""
    ep = sandbox.egress_endpoint()
    return f"http://{ep.host}:{ep.port}"


RELAY_PROXY = relay_proxy_url()

# The helper's wait for one in-process tool call (the `ready` frame's tool_deadline_s); a
# navigate or reload also waits for its card (S8 decision 16, plan rev 16.20.56). The CLI's
# own bound is 10 s past the longest of them.
TOOL_DEADLINE_S = 120
CARD_S = 120
GATED_DEADLINE_S = TOOL_DEADLINE_S + CARD_S
MCP_TOOL_TIMEOUT_MS = (GATED_DEADLINE_S + 10) * 1000


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


def cli_env(home, route_env, base_url=None, proxy=None, mcp_tool_timeout_ms=MCP_TOOL_TIMEOUT_MS, ca_file=None,
            max_retries=None):
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
    if ca_file:
        env["NODE_EXTRA_CA_CERTS"] = ca_file  # the e2e fake's CA (§3c.4); the CLI's environment only
    if max_retries is not None:
        # Only chat under the e2e test base URL sets it (S5a, rev 16.14): the CLI retries
        # a 429 or 529 ten times, about 185 s, which no e2e of the plain message can wait.
        env["CLAUDE_CODE_MAX_RETRIES"] = str(max_retries)
    return env


def build(home, *, route_env, cli_path=None, base_url=None, proxy=None, mcp_servers=None,
          allowed_tools=(), can_use_tool=None, mcp_tool_timeout_ms=MCP_TOOL_TIMEOUT_MS,
          stderr=None, extra_args=None, ca_file=None, max_retries=None):
    return ClaudeAgentOptions(
        setting_sources=["user"],
        cwd=str(home.workspace),
        tools=[],
        permission_mode="default",
        env=cli_env(home, route_env, base_url, proxy, mcp_tool_timeout_ms, ca_file, max_retries),
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
