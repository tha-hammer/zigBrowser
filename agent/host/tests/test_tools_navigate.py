"""S8 decision 16, part 3 red (chat-drawer plan; S8c's helper side): the helper offers
`navigate` and `reload`, and gives them time for their card.

- The MCP server `zigbrowser` lists S7.5's six read tools, hover and scroll (S8e part 1,
  test_tools_hover_scroll.py), plus `navigate` (exactly
  `{url: non-empty string}`) and `reload` (exactly `{}`), both `additionalProperties: false`,
  so the CLI refuses a model's `window_id`, `navigate_approval`, mode or any other field before
  the browser sees it (the broker refuses them too, d3655a8). `allowed_tools` is those ten.
- Each forwards exactly the model's args as one `tool_call` (`mcp__zigbrowser__navigate` /
  `..._reload`); the helper adds nothing.
- Deadlines (plan rev 16.20.37, "gated calls get their own deadline budget"): a read tool keeps
  the tool deadline (`TOOL_DEADLINE_S`, 120 s, the `ready` frame's value, or the e2e seam's
  shorter one); a gated call waits that plus the card's time (`CARD_S`, 120 s), so a 120 s
  card can expire in the browser and its answer still reach the model:
  `GATED_DEADLINE_S` = 240 s, and the CLI's `MCP_TOOL_TIMEOUT` is 250 s (10 s more, as before).
  The broker's own gated budget is B + 120 s = 235 s (agent_broker.zig), inside 240 s.

Pure Python: the real Bridge, options and cli_env, frames written to memory by the real
Emitter. Run the module alone, as the gate does. Unregistered until its green."""

import asyncio
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from test_bridge import Out, answer, error_text, started  # noqa: E402
from test_tools import ACT, TOOLS as READ  # noqa: E402

from zb_agent_host import options  # noqa: E402
from zb_agent_host.bridge import Bridge  # noqa: E402

NAVIGATE = {"type": "object", "properties": {"url": {"type": "string", "minLength": 1}}, "required": ["url"],
            "additionalProperties": False}
RELOAD = {"type": "object", "properties": {}, "required": [], "additionalProperties": False}
CLICK = {"type": "object", "properties": {
    "selector": {"type": "string", "minLength": 1},
}, "required": ["selector"], "additionalProperties": False}
TYPE_TEXT = {"type": "object", "properties": {
    "selector": {"type": "string", "minLength": 1},
    "text": {"type": "string", "minLength": 1},
}, "required": ["selector", "text"], "additionalProperties": False}
GATED = {"click": CLICK, "type_text": TYPE_TEXT, "navigate": NAVIGATE, "reload": RELOAD}
NAMES = sorted(f"mcp__zigbrowser__{n}" for n in [*READ, *ACT, *GATED])


def bridge(out=None, deadline_s=5.0, **kw):
    return Bridge((out or Out()).emitter, "s-1-1", deadline_s, prompt=lambda: 7, **kw)


def without_descriptions(schema):
    """The schema with each property's free-text description dropped (the model's help text)."""
    props = {k: {f: v for f, v in p.items() if f != "description"} for k, p in schema["properties"].items()}
    return {**schema, "properties": props}


class ListTest(unittest.TestCase):
    def test_the_server_lists_the_six_read_tools_hover_scroll_navigate_and_reload(self):
        tools = {t.name: t for t in bridge().tools()}
        self.assertEqual(sorted(tools), sorted([*READ, *ACT, *GATED]))
        for name, schema in READ.items():
            self.assertEqual(tools[name].input_schema, schema, name)
        for name, schema in GATED.items():
            self.assertEqual(without_descriptions(tools[name].input_schema), schema, name)
            self.assertTrue(tools[name].description, name)

    def test_allowed_tools_are_exactly_the_ten_names(self):
        self.assertEqual(sorted(bridge().allowed_tools()), NAMES)

    def test_no_schema_names_the_selector_the_mode_or_a_window(self):
        for t in bridge().tools():
            if t.name in GATED:
                for field in ("window_id", "navigate_approval", "mode", "drawer_showing", "typed_prompt",
                              "approved"):
                    self.assertNotIn(field, t.input_schema["properties"], (t.name, field))
                self.assertIs(t.input_schema["additionalProperties"], False, t.name)


class ServerListTest(unittest.IsolatedAsyncioTestCase):
    async def test_the_mcp_servers_own_list_has_the_gated_schemas(self):
        listed = await bridge().server()["instance"].get_request_handler("tools/list").handler(None, None)
        got = {t.name: t.input_schema for t in listed.tools}
        self.assertEqual(sorted(got), sorted([*READ, *ACT, *GATED]))
        for name, schema in GATED.items():
            self.assertEqual(without_descriptions(got[name]), schema, name)


class ForwardTest(unittest.IsolatedAsyncioTestCase):
    async def test_navigate_and_reload_forward_exactly_the_models_args(self):
        out = Out()
        b = bridge(out)
        tools = {t.name: t for t in b.tools()}
        for name, args in (("click", {"selector": "css=#send"}),
                           ("type_text", {"selector": "css=#message", "text": "hello"}),
                           ("navigate", {"url": "https://example.com/next"}), ("reload", {})):
            task = asyncio.ensure_future(tools[name].handler(args))
            for _ in range(200):
                await asyncio.sleep(0)
                if any(c["tool"] == f"mcp__zigbrowser__{name}" for c in out.calls()):
                    break
            frame = [c for c in out.calls() if c["tool"] == f"mcp__zigbrowser__{name}"][-1]
            self.assertEqual((frame["prompt_id"], frame["args"]), (7, args), name)
            b.resolve(answer(frame))
            self.assertEqual(await asyncio.wait_for(task, 5), {"content": [{"type": "text", "text": "Hello from page 1"}]})


class DeadlineTest(unittest.TestCase):
    def test_the_constants(self):
        self.assertEqual(options.TOOL_DEADLINE_S, 120)
        self.assertEqual(options.CARD_S, 120)
        self.assertEqual(options.GATED_DEADLINE_S, options.TOOL_DEADLINE_S + options.CARD_S)
        self.assertEqual(options.MCP_TOOL_TIMEOUT_MS, (options.GATED_DEADLINE_S + 10) * 1000)
        self.assertEqual(options.MCP_TOOL_TIMEOUT_MS, 250_000)

    def test_the_clis_timeout_is_the_gated_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = options.cli_env(options.AgentHome(tmp), {})
        self.assertEqual(env["MCP_TOOL_TIMEOUT"], "250000")

    def test_the_bridge_takes_the_card_time_by_default(self):
        self.assertEqual(bridge().card_s, options.CARD_S)


class GatedDeadlineTest(unittest.IsolatedAsyncioTestCase):
    async def test_a_read_call_ends_at_the_tool_deadline(self):
        out = Out()
        b = bridge(out, deadline_s=0.2, card_s=0.6)
        started_at = time.monotonic()
        task, calls = await started(b, out, "get_text", {"selector": "css=#x"})
        self.assertEqual(len(calls), 1)
        result = await asyncio.wait_for(task, 5)
        took = time.monotonic() - started_at
        self.assertEqual(error_text(result), (True, "The browser did not answer in time."))
        self.assertLess(took, 0.6, took)

    async def test_a_gated_call_waits_the_tool_deadline_plus_the_card(self):
        for name, args in (("click", {"selector": "css=#send"}),
                           ("type_text", {"selector": "css=#message", "text": "hello"}),
                           ("navigate", {"url": "https://example.com/"}), ("reload", {})):
            out = Out()
            b = bridge(out, deadline_s=0.2, card_s=0.6)
            started_at = time.monotonic()
            task, calls = await started(b, out, name, args)
            self.assertEqual(len(calls), 1, name)
            await asyncio.sleep(0.5)  # past the read deadline, inside deadline + card
            self.assertFalse(task.done(), f"{name} ended at the read deadline")
            result = await asyncio.wait_for(task, 5)
            took = time.monotonic() - started_at
            self.assertEqual(error_text(result), (True, "The browser did not answer in time."), name)
            self.assertGreaterEqual(took, 0.8, (name, took))
            self.assertLess(took, 1.5, (name, took))

    async def test_a_gated_answer_inside_the_card_time_reaches_the_model(self):
        out = Out()
        b = bridge(out, deadline_s=0.2, card_s=0.6)
        task, calls = await started(b, out, "navigate", {"url": "https://example.com/"})
        await asyncio.sleep(0.4)  # the card was approved late, but within its time
        b.resolve(answer(calls[0], ok=False, error="The navigation was not approved in time."))
        self.assertEqual(error_text(await asyncio.wait_for(task, 5)), (True, "The navigation was not approved in time."))


if __name__ == "__main__":
    unittest.main()
