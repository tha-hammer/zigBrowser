"""S8e part 2 red (chat-drawer plan D9 and S8 decision 12; S8c's helper side): the helper offers the
seven LinkedIn and Instagram dry-run previews, which need no card.

- The MCP server `zigbrowser` lists S7.5's six read tools, hover and scroll, the seven previews
  (`linkedin_connect_preview` `{profileUrl, note?}`, `linkedin_follow_preview` `{profileUrl}`,
  `linkedin_like_preview` `{postUrl}`, `linkedin_comment_preview` `{postUrl, text}`,
  `instagram_follow_preview` `{profileUrl}`, `instagram_like_preview` `{postUrl}`,
  `instagram_comment_preview` `{postUrl, text}`; every value a non-empty string), then
  decision 16's navigate and reload: 17 tools, all `additionalProperties: false`.
  `allowed_tools` is those 17.
- No preview schema names `options`, `dry_run`, `expect`, `timeout_ms`, `window_id`,
  `compose_url`, `approved` or `grant`: the model can never turn a preview into a real run
  or choose the page (the broker adds `options.dry_run` itself; tests/agent_broker_preview_test.zig).
  Through the server's own tools/call path, as the CLI reaches it, each such shape, a missing
  required key, an empty or non-string value is refused ("Input validation error") with no
  tool_call frame; the accepted shapes forward exactly.
- The previews keep the read deadline (`TOOL_DEADLINE_S`), never the gated one.
- The X previews (x_post_preview, x_schedule_post_preview) are not in this part: x.post's
  `compose_url` must never reach the model, and X has no fixture-origin seam yet.

Pure Python: the real Bridge and frames written to memory by the real Emitter. Run the module
alone, as the gate does. Unregistered until its green."""

import asyncio
import sys
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from test_bridge import Out, answer, error_text, started  # noqa: E402
from test_tools import TOOLS as READ  # noqa: E402
from test_tools_hover_scroll import ACT  # noqa: E402
from test_tools_navigate import GATED, without_descriptions  # noqa: E402

from zb_agent_host.bridge import Bridge  # noqa: E402

TEXT = {"type": "string", "minLength": 1}


def preview(required, optional=()):
    return {"type": "object", "properties": {k: TEXT for k in (*required, *optional)}, "required": list(required),
            "additionalProperties": False}


PREVIEWS = {
    "linkedin_connect_preview": preview(["profileUrl"], ["note"]),
    "linkedin_follow_preview": preview(["profileUrl"]),
    "linkedin_like_preview": preview(["postUrl"]),
    "linkedin_comment_preview": preview(["postUrl", "text"]),
    "instagram_follow_preview": preview(["profileUrl"]),
    "instagram_like_preview": preview(["postUrl"]),
    "instagram_comment_preview": preview(["postUrl", "text"]),
}
ORDER = [*READ, *ACT, *PREVIEWS, *GATED]
NAMES = sorted(f"mcp__zigbrowser__{n}" for n in ORDER)
FORBIDDEN = ("options", "dry_run", "expect", "timeout_ms", "window_id", "compose_url", "approved", "grant")
POST = "https://www.linkedin.com/feed/update/urn:li:activity:1/"
GOOD = {
    "linkedin_connect_preview": [{"profileUrl": "https://www.linkedin.com/in/sam/"},
                                 {"profileUrl": "https://www.linkedin.com/in/sam/", "note": "Hi Sam"}],
    "linkedin_follow_preview": [{"profileUrl": "https://www.linkedin.com/in/sam/"}],
    "linkedin_like_preview": [{"postUrl": POST}],
    "linkedin_comment_preview": [{"postUrl": POST, "text": "Great post"}],
    "instagram_follow_preview": [{"profileUrl": "https://www.instagram.com/sam.example/"}],
    "instagram_like_preview": [{"postUrl": "https://www.instagram.com/p/C0ffee/"}],
    "instagram_comment_preview": [{"postUrl": "https://www.instagram.com/p/C0ffee/", "text": "So good"}],
}


def bridge(out=None, deadline_s=5.0, **kw):
    return Bridge((out or Out()).emitter, "s-1-1", deadline_s, prompt=lambda: 7, **kw)


class ListTest(unittest.TestCase):
    def test_the_server_lists_read_act_previews_then_gated(self):
        self.assertEqual([t.name for t in bridge().tools()], ORDER)

    def test_the_previews_exact_schemas(self):
        tools = {t.name: t for t in bridge().tools()}
        for name, schema in PREVIEWS.items():
            self.assertEqual(without_descriptions(tools[name].input_schema), schema, name)
            self.assertTrue(tools[name].description, name)
            self.assertIn("dry run", tools[name].description.lower(), name)

    def test_allowed_tools_are_exactly_the_seventeen_names(self):
        self.assertEqual(sorted(bridge().allowed_tools()), NAMES)

    def test_no_preview_names_a_run_option_a_page_a_window_or_a_grant(self):
        tools = {t.name: t for t in bridge().tools()}
        for name in PREVIEWS:
            for field in FORBIDDEN:
                self.assertNotIn(field, tools[name].input_schema["properties"], (name, field))
            self.assertIs(tools[name].input_schema["additionalProperties"], False, name)

    def test_no_x_preview_and_no_story_preview(self):
        names = {t.name for t in bridge().tools()}
        for name in ("x_post_preview", "x_schedule_post_preview", "instagram_story_view_preview"):
            self.assertNotIn(name, names)


class ServerListTest(unittest.IsolatedAsyncioTestCase):
    async def test_the_mcp_servers_own_list_has_the_preview_schemas(self):
        listed = await bridge().server()["instance"].get_request_handler("tools/list").handler(None, None)
        got = {t.name: t.input_schema for t in listed.tools}
        self.assertEqual(sorted(got), sorted(ORDER))
        for name, schema in PREVIEWS.items():
            self.assertEqual(without_descriptions(got[name]), schema, name)


class ServerCallTest(unittest.IsolatedAsyncioTestCase):
    """The server's own tools/call path, as the CLI reaches it."""

    async def call(self, b, name, args):
        handler = b.server()["instance"].get_request_handler("tools/call").handler
        try:
            return await asyncio.wait_for(handler(None, SimpleNamespace(name=name, arguments=args)), 2)
        except TimeoutError:
            self.fail(f"{name} {args} was not refused: it went on to the browser and waited for its answer")

    async def test_a_preview_refuses_every_run_option_and_bad_shape_before_any_call(self):
        out = Out()
        b = bridge(out)
        names = [t.name for t in b.tools()]
        for name, goods in GOOD.items():
            self.assertIn(name, names)
            good = goods[0]
            bad = [{}, {k: "" for k in good}, {k: 7 for k in good}]
            bad += [{**good, field: value} for field, value in
                    (("options", {"dry_run": False}), ("dry_run", False), ("expect", {}), ("timeout_ms", 1000),
                     ("window_id", "window-1"), ("compose_url", "https://example.com/"), ("approved", True),
                     ("grant", "G-123"), ("extra", "x"))]
            if len(good) > 1:
                bad += [{k: v for k, v in good.items() if k != key} for key in good]
            for args in bad:
                result = await self.call(b, name, args)
                text = "".join(getattr(c, "text", "") for c in result.content)
                self.assertTrue(result.is_error, (name, args, text))
                self.assertIn("Input validation error", text, (name, args))
        self.assertEqual(out.calls(), [], "a refused shape reached the browser")

    async def test_the_accepted_shapes_reach_the_browser_exactly(self):
        for name, goods in GOOD.items():
            for args in goods:
                out = Out()
                b = bridge(out)
                task = asyncio.ensure_future(self.call(b, name, args))
                for _ in range(200):
                    await asyncio.sleep(0)
                    if out.calls():
                        break
                calls = out.calls()
                self.assertEqual([(c["tool"], c["prompt_id"], c["args"]) for c in calls],
                                 [(f"mcp__zigbrowser__{name}", 7, args)], args)
                b.resolve(answer(calls[0]))
                self.assertFalse((await task).is_error, args)


class DeadlineTest(unittest.IsolatedAsyncioTestCase):
    async def test_a_preview_ends_at_the_read_deadline_not_the_gated_one(self):
        for name in ("linkedin_like_preview", "instagram_comment_preview"):
            out = Out()
            b = bridge(out, deadline_s=0.2, card_s=0.6)
            self.assertIn(name, [t.name for t in b.tools()])
            started_at = time.monotonic()
            task, calls = await started(b, out, name, GOOD[name][0])
            self.assertEqual(len(calls), 1, name)
            result = await asyncio.wait_for(task, 5)
            took = time.monotonic() - started_at
            self.assertEqual(error_text(result), (True, "The browser did not answer in time."), name)
            self.assertLess(took, 0.6, (name, took))


if __name__ == "__main__":
    unittest.main()
