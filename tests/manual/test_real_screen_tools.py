"""S7b's real-screen `tools` case (tests/manual/real_screen_check.py --case tools): the
fake API's three steps, and the judgement of the screenshot the model got. Pure, no display.
Run alone, as the gate does."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import real_screen_check as rsc  # noqa: E402


def request(messages):
    return {"body": {"messages": messages}}


def tool_result_turn(text, tool_id="toolu_fake_0"):
    return {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tool_id, "content": [{"type": "text", "text": text}]}]}


class ToolsTurnTest(unittest.TestCase):
    """S7b's real-screen `tools` case: the fake API's three steps."""

    def test_a_prompt_gets_get_text_on_the_header(self):
        turn = rsc.tools_turn(request([{"role": "user", "content": "tools"}]))
        self.assertEqual(turn, {"tool_use": {"name": "mcp__zigbrowser__get_text", "input": {"selector": "css=header"}}})

    def test_after_get_text_a_screenshot_then_the_final_text(self):
        one = request([{"role": "user", "content": "tools"}, {"role": "assistant", "content": []}, tool_result_turn("x")])
        self.assertEqual(rsc.tools_turn(one), {"tool_use": {"name": "mcp__zigbrowser__screenshot", "input": {}}})
        two = request([*one["body"]["messages"], {"role": "assistant", "content": []}, tool_result_turn("y", "toolu_fake_1")])
        self.assertEqual(rsc.tools_turn(two), {"text": rsc.TOOLS_DONE})

    def test_another_prompt_is_not_scripted(self):
        self.assertIsNone(rsc.tools_turn(request([{"role": "user", "content": "something else"}])))


class LatestResultsTest(unittest.TestCase):
    def test_the_newest_request_holds_every_tool_result_once(self):
        """Each request carries the earlier tool results again: they are read from the newest
        request (the most of them), never stacked from every request."""
        first = request([{"role": "user", "content": "tools"}, tool_result_turn("x")])
        second = request([{"role": "user", "content": "tools"}, tool_result_turn("x"), tool_result_turn("y", "toolu_fake_1")])
        blocks = rsc.latest_tool_results([first, second])
        self.assertEqual([b["tool_use_id"] for b in blocks], ["toolu_fake_0", "toolu_fake_1"])
        self.assertEqual(rsc.latest_tool_results([]), [])


class ToolImageTest(unittest.TestCase):
    """A screenshot the model got is the page: it decodes, it shows the fixture's blue (it is
    this page) and its white text and lines (the page's content was drawn, not just a fill)."""

    def test_the_page_passes(self):
        ok, _ = rsc.judge_tool_image({"format": "png", "width": 1024, "height": 461, "dominant": 0.93,
                                      "page_blue": 0.93, "white": 0.04})
        self.assertTrue(ok)

    def test_blank_black_a_fill_or_not_the_page_fails(self):
        for stats in ({"format": None, "width": 0, "height": 0, "dominant": 1.0, "page_blue": 0.0, "white": 0.0},
                      {"format": "png", "width": 1024, "height": 461, "dominant": 1.0, "page_blue": 1.0, "white": 0.0},
                      {"format": "png", "width": 1024, "height": 461, "dominant": 1.0, "page_blue": 0.0, "white": 0.0},
                      {"format": "jpeg", "width": 1024, "height": 461, "dominant": 0.6, "page_blue": 0.01, "white": 0.4}):
            ok, detail = rsc.judge_tool_image(stats)
            self.assertFalse(ok, stats)
            self.assertTrue(detail)


if __name__ == "__main__":
    unittest.main()
