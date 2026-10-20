"""S5c-1 (chat-drawer plan S5.6, rev 16.20.11 and 16.20.12; RoseCat ae39e2a, e2cb1b0): the
helper's forward cap is terminal. The 256 KiB bound is the whole shown text, the 19-byte
marker included, so a reply's content is capped at CONTENT_MAX (262,125 bytes). Once one
code point of a reply does not fit in what remains of it, no later delta of that prompt is
sent, even a smaller one, and `reply_capped` is sent once. So the deltas are exactly the
reply's longest UTF-8 prefix that fits, which may stop 1 to 3 bytes short of CONTENT_MAX,
and the app learns of the cap without counting bytes. Rev 16.20.13 (RoseCat 5aea621):
`reply_capped` echoes the prompt's `prompt_id`, and a bubble never shrinks when its reply
completes, so no `assistant_message` follows the cap, and none is sent for a streamed
message whose frame would have to be cut.

These drive `python -m zb_agent_host chat` (test_chat's Helper) and the real CLI against
the fake Messages API; run the module alone, as the gate does."""

import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_chat import FakeAnthropicApi, provisioned  # noqa: E402
from test_chat_flood import MARKER, MESSAGE_MAX, RawHelper, utf8_prefix  # noqa: E402

TRUNCATED = "\n" + MARKER
CONTENT_MAX = MESSAGE_MAX - len(TRUNCATED.encode())  # 262,125
WIDE = "界"  # 3 bytes of UTF-8


class CapTest(unittest.TestCase):
    def start(self, turn, after="after the capped one"):
        box = provisioned(self)
        api = FakeAnthropicApi(turns=[turn, {"text": after}]).start()
        self.addCleanup(api.stop)
        h = RawHelper(self, box.home)
        self.assertEqual(h.frame()["type"], "ready")
        h.send("hello", agent_home=str(box.home.root), workspace=str(box.home.workspace),
               scratchpad=str(box.home.scratchpad), route="R1", e2e={"test_base_url": api.base_url})
        h.send("open_session", session="s-1-1", window_id="window-1")
        h.until("session_opened")
        h.send("prompt", session="s-1-1", prompt_id=1, text="go")
        return h

    def assert_capped(self, frames, want):
        """The prompt's deltas are exactly `want`, and one `reply_capped` for prompt 1
        follows the last; no delta or message of the prompt follows it."""
        kinds = [f["type"] for f in frames]
        streamed = "".join(f["text"] for f in frames if f["type"] == "assistant_delta")
        self.assertEqual(len(streamed.encode()), len(want.encode()), "the forwarded bytes")
        self.assertEqual(streamed, want, (streamed[-8:], want[-8:]))
        self.assertEqual(kinds.count("reply_capped"), 1, kinds[-6:])
        capped = kinds.index("reply_capped")
        self.assertEqual([f for f in frames if f["type"] == "reply_capped"],
                         [{"v": 1, "seq": frames[capped]["seq"], "type": "reply_capped", "session": "s-1-1",
                           "prompt_id": 1}])
        self.assertEqual([k for k in kinds[capped + 1:] if k in ("assistant_delta", "assistant_message")], [],
                         "nothing of the reply's text follows reply_capped")

    def answered_again(self, h, text="after the capped one"):
        h.send("prompt", session="s-1-1", prompt_id=2, text="again")
        _, after = h.until("result", timeout=90)
        self.assertIn(text, [f.get("text") for f in after if f["type"] == "assistant_message"])
        self.assertNotIn("reply_capped", [f["type"] for f in after], "a new prompt is not capped")

    def test_a_code_point_that_does_not_fit_ends_forwarding_for_the_reply(self):
        """RoseCat ae39e2a's repro, one delta per flush: `a`x(CONTENT_MAX-1) leaves 1 byte,
        which a 3-byte character does not fit; the later `x` (1 byte) must not take it."""
        head = "a" * (CONTENT_MAX - 1)
        h = self.start({"deltas": [head, WIDE, "x"], "gap_ms": 300})
        _, frames = h.until("result", timeout=180)
        self.assert_capped(frames, head)
        self.answered_again(h)
        h.send("shutdown")
        h.proc.wait(timeout=30)

    def test_an_endless_multibyte_reply_stops_short_of_the_bound_and_is_capped(self):
        """1,022-byte pieces of 3-byte characters: the longest prefix that fits CONTENT_MAX
        is 262,124 bytes, so a cap signal that waits for the bound to be reached would
        never come."""
        piece = WIDE * 340 + "  "
        h = self.start({"endless": piece})  # the fake's default pace
        want = utf8_prefix(piece * (CONTENT_MAX // len(piece.encode()) + 2), CONTENT_MAX)
        self.assertEqual(len(want.encode()), CONTENT_MAX - 1)
        frames, deadline = [], time.monotonic() + 60
        while "reply_capped" not in [f["type"] for f in frames] and time.monotonic() < deadline:
            frames += h.rest(quiet=0.5)
        frames += h.rest(quiet=1.0)  # nothing more of this reply may follow
        h.send("interrupt", session="s-1-1")
        while not any(f["type"] in ("result", "error") for f in frames):
            frames.append(h.frame(60))
        self.assert_capped(frames, want)
        self.answered_again(h)
        h.send("shutdown")
        h.proc.wait(timeout=30)

    def test_a_streamed_message_whose_frame_would_be_cut_is_not_sent(self):
        """200,000 characters under the cap whose JSON escapes double them: every one goes
        out as deltas, and no shorter assistant_message replaces them (rev 16.20.13)."""
        text = '"\\' * 100_000
        h = self.start({"text": text}, after="after the escaped one")
        _, frames = h.until("result", timeout=180)
        self.assertEqual("".join(f["text"] for f in frames if f["type"] == "assistant_delta"), text)
        kinds = [f["type"] for f in frames]
        self.assertNotIn("assistant_message", kinds, kinds[-4:])
        self.assertNotIn("reply_capped", kinds)
        self.answered_again(h, "after the escaped one")
        h.send("shutdown")
        h.proc.wait(timeout=30)


if __name__ == "__main__":
    unittest.main()
