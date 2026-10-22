"""S8e part 1 red (chat-drawer plan D9 and S8 decision 12; S8c's helper side): the helper offers
`hover` and `scroll`, the two act-on-page tools that need no card.

- The MCP server `zigbrowser` lists S7.5's six read tools, `hover` (exactly `{selector}`) and
  `scroll` (`{selector}` or `{x?, y?}`, integers in [-100000, 100000]), then decision 16's
  `navigate` and `reload`; every schema is `additionalProperties: false`, so the CLI refuses a
  model's `options` (native input would move the user's own pointer), `window_id`, `strict`,
  `timeout_ms` or `approved` before the browser sees them (the broker refuses them too,
  tests/agent_broker_hover_test.zig). `allowed_tools` is those ten.
- Each forwards exactly the model's args as one `tool_call`; the helper adds nothing.
- Neither waits for a card: each keeps the read deadline (`TOOL_DEADLINE_S`), never the gated
  one (deadline + `CARD_S`).

Pure Python: the real Bridge and frames written to memory by the real Emitter. Run the module
alone, as the gate does. Unregistered until its green."""

import asyncio
import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from test_bridge import Out, answer, error_text, started  # noqa: E402
from test_tools import TOOLS as READ  # noqa: E402
from test_tools_navigate import GATED, without_descriptions  # noqa: E402

from zb_agent_host.bridge import Bridge  # noqa: E402

OFFSET = {"type": "integer", "minimum": -100000, "maximum": 100000}
HOVER = {"type": "object", "properties": {"selector": {"type": "string", "minLength": 1}}, "required": ["selector"],
         "additionalProperties": False}
SCROLL = {"type": "object", "properties": {"selector": {"type": "string", "minLength": 1}, "x": OFFSET, "y": OFFSET},
          "required": [], "additionalProperties": False}
ACT = {"hover": HOVER, "scroll": SCROLL}
ORDER = [*READ, *ACT, *GATED]
NAMES = sorted(f"mcp__zigbrowser__{n}" for n in ORDER)


def bridge(out=None, deadline_s=5.0, **kw):
    return Bridge((out or Out()).emitter, "s-1-1", deadline_s, prompt=lambda: 7, **kw)


class ListTest(unittest.TestCase):
    def test_the_server_lists_read_then_hover_and_scroll_then_the_gated_tools(self):
        self.assertEqual([t.name for t in bridge().tools()], ORDER)

    def test_hover_and_scrolls_exact_schemas(self):
        tools = {t.name: t for t in bridge().tools()}
        for name, schema in ACT.items():
            self.assertEqual(without_descriptions(tools[name].input_schema), schema, name)
            self.assertTrue(tools[name].description, name)
            selector = tools[name].input_schema["properties"]["selector"]
            self.assertIn("css=", selector.get("description", ""), name)

    def test_allowed_tools_are_exactly_the_ten_names(self):
        self.assertEqual(sorted(bridge().allowed_tools()), NAMES)

    def test_no_schema_names_options_a_window_or_a_grant(self):
        tools = {t.name: t for t in bridge().tools()}
        for name in ACT:
            for field in ("options", "input", "humanize", "strict", "timeout_ms", "window_id", "approved", "grant",
                          "force", "trial"):
                self.assertNotIn(field, tools[name].input_schema["properties"], (name, field))
            self.assertIs(tools[name].input_schema["additionalProperties"], False, name)


class ServerListTest(unittest.IsolatedAsyncioTestCase):
    async def test_the_mcp_servers_own_list_has_the_act_schemas(self):
        listed = await bridge().server()["instance"].get_request_handler("tools/list").handler(None, None)
        got = {t.name: t.input_schema for t in listed.tools}
        self.assertEqual(sorted(got), sorted(ORDER))
        for name, schema in ACT.items():
            self.assertEqual(without_descriptions(got[name]), schema, name)


class ForwardTest(unittest.IsolatedAsyncioTestCase):
    async def test_hover_and_scroll_forward_exactly_the_models_args(self):
        out = Out()
        b = bridge(out)
        tools = {t.name: t for t in b.tools()}
        for name, args in (("hover", {"selector": "css=#menu"}), ("scroll", {"selector": "css=#bottom"}),
                           ("scroll", {"y": 900}), ("scroll", {"x": -5, "y": 0})):
            task = asyncio.ensure_future(tools[name].handler(args))
            for _ in range(200):
                await asyncio.sleep(0)
                if any(c["tool"] == f"mcp__zigbrowser__{name}" and c["args"] == args for c in out.calls()):
                    break
            frame = [c for c in out.calls() if c["tool"] == f"mcp__zigbrowser__{name}"][-1]
            self.assertEqual((frame["prompt_id"], frame["args"]), (7, args), name)
            b.resolve(answer(frame))
            self.assertEqual(await asyncio.wait_for(task, 5), {"content": [{"type": "text", "text": "Hello from page 1"}]})


class DeadlineTest(unittest.IsolatedAsyncioTestCase):
    async def test_hover_and_scroll_end_at_the_read_deadline_not_the_gated_one(self):
        for name, args in (("hover", {"selector": "css=#menu"}), ("scroll", {"y": 900})):
            out = Out()
            b = bridge(out, deadline_s=0.2, card_s=0.6)
            self.assertIn(name, [t.name for t in b.tools()])  # the call below must be the offered tool's
            started_at = time.monotonic()
            task, calls = await started(b, out, name, args)
            self.assertEqual(len(calls), 1, name)
            result = await asyncio.wait_for(task, 5)
            took = time.monotonic() - started_at
            self.assertEqual(error_text(result), (True, "The browser did not answer in time."), name)
            self.assertLess(took, 0.6, (name, took))


if __name__ == "__main__":
    unittest.main()
