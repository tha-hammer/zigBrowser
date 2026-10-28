"""S7b (chat-drawer plan section 10, S7, rev 16.20.34): the helper's browser tools. A chat
session's MCP server `zigbrowser` lists S7.5's six read tools, each with its exact input
schema, and since S8 decision 16 (rev 16.20.56) navigate and reload, whose schemas
test_tools_navigate.py pins; `allowed_tools` is exactly those eight names; each read handler
forwards its name and args to the Bridge (S7.0); and a session's options install the server,
those names and `deny_all`, as P0's contract does.

Pure Python: the real Bridge and session_options, the Bridge's call replaced by a recorder.
Run the module alone, as the gate does."""

import asyncio
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from test_bridge import Out  # noqa: E402

from zb_agent_host import chat, options, sandbox  # noqa: E402
from zb_agent_host.bridge import Bridge, deny_all  # noqa: E402


def schema(properties, required=()):
    return {"type": "object", "properties": properties, "required": list(required), "additionalProperties": False}


SELECTOR = {"type": "string", "description": "An engine selector: css=..., text=..., as the SDKs send it."}
TOOLS = {
    "window_info": schema({}),
    "query": schema({"selector": SELECTOR}, ["selector"]),
    "get_text": schema({"selector": SELECTOR}, ["selector"]),
    "get_attribute": schema({"selector": SELECTOR, "name": {"type": "string"}}, ["selector", "name"]),
    "wait_for": schema({"selector": SELECTOR,
                        "state": {"type": "string", "enum": ["visible", "hidden", "attached", "detached"]},
                        "timeout_ms": {"type": "integer", "minimum": 0, "maximum": 10000}}, ["selector"]),
    "screenshot": schema({}),
}
ACT = ("hover", "scroll")  # S8 decision 12, no card: test_tools_hover_scroll.py
GATED = ("click", "type_text", "press_key", "navigate", "reload")  # S8 decision 16
NAMES = sorted(f"mcp__zigbrowser__{name}" for name in [*TOOLS, *ACT, *GATED])


def bridge():
    return Bridge(Out().emitter, "s-1-1", 5.0, prompt=lambda: 7)


class ToolListTest(unittest.TestCase):
    def test_the_server_lists_the_six_read_tools_with_their_schemas_hover_scroll_and_the_two_gated(self):
        b = bridge()
        tools = b.tools()
        self.assertEqual(sorted(t.name for t in tools), sorted([*TOOLS, *ACT, *GATED]))
        for t in tools:
            if t.name in TOOLS:
                self.assertEqual(t.input_schema, TOOLS[t.name], t.name)
            self.assertTrue(t.description, t.name)
        server = b.server()
        self.assertEqual((server["type"], server["name"]), ("sdk", "zigbrowser"))

    def test_a_selector_tools_selector_states_the_engine_grammar(self):
        """RoseCat 6575: the model is told the selector syntax the engine takes."""
        for t in bridge().tools():
            selector = t.input_schema["properties"].get("selector")
            if t.name in ("window_info", "screenshot", "navigate", "reload"):
                self.assertIsNone(selector, t.name)
                continue
            self.assertIn("css=", selector.get("description", ""), t.name)
            self.assertIn("text=", selector.get("description", ""), t.name)

    def test_allowed_tools_are_exactly_their_names(self):
        self.assertEqual(sorted(bridge().allowed_tools()), NAMES)

    def test_no_other_act_tool_is_offered(self):
        names = {t.name for t in bridge().tools()}
        for act in ("type", "fill", "press", "select_option", "evaluate", "echo", "cookies_get"):
            self.assertNotIn(act, names)


class ServerListTest(unittest.IsolatedAsyncioTestCase):
    async def test_the_mcp_servers_own_list_is_exactly_the_ten_tools(self):
        """RoseCat 6575: through the server's tools/list path, as the CLI sees it."""
        b = bridge()
        listed = await b.server()["instance"].get_request_handler("tools/list").handler(None, None)
        self.assertEqual(sorted(t.name for t in listed.tools), sorted([*TOOLS, *ACT, *GATED]))
        mine = {t.name: t for t in b.tools()}
        for t in listed.tools:
            if t.name in TOOLS:
                self.assertEqual(t.input_schema, TOOLS[t.name], t.name)
            self.assertEqual(t.description, mine[t.name].description, t.name)
            self.assertTrue(t.description, t.name)


class ForwardTest(unittest.IsolatedAsyncioTestCase):
    async def test_each_handler_forwards_its_name_and_args(self):
        b = bridge()
        seen = []

        async def call(name, args):
            seen.append((name, args))
            return {"content": [{"type": "text", "text": f"answer for {name}"}]}

        b.call = call
        cases = {"window_info": {}, "query": {"selector": "css=li"}, "get_text": {"selector": "css=#greeting"},
                 "get_attribute": {"selector": "css=a", "name": "href"},
                 "wait_for": {"selector": "css=#x", "state": "hidden", "timeout_ms": 250}, "screenshot": {}}
        for t in [t for t in b.tools() if t.name in cases]:
            result = await asyncio.wait_for(t.handler(cases[t.name]), 5)
            self.assertEqual(result, {"content": [{"type": "text", "text": f"answer for {t.name}"}]})
        self.assertEqual(sorted(seen, key=lambda s: s[0]), sorted(cases.items()))


class SessionOptionsTest(unittest.TestCase):
    def test_a_sessions_options_install_the_tools_and_deny_all(self):
        b = bridge()
        with tempfile.TemporaryDirectory() as tmp:
            opts = chat.session_options(options.AgentHome(tmp), route_env={}, cli_path=None, e2e=None, test_ca=None,
                                        proxy=sandbox.linux_helper_proxy(), bridge=b)
        self.assertEqual(list(opts.mcp_servers), ["zigbrowser"])
        self.assertEqual(opts.mcp_servers["zigbrowser"]["name"], "zigbrowser")
        self.assertEqual(sorted(opts.allowed_tools), NAMES)
        self.assertIs(opts.can_use_tool, deny_all)
        self.assertEqual(opts.tools, [], "no built-in tool")


if __name__ == "__main__":
    unittest.main()
