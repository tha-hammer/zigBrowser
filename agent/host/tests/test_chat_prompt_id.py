"""S5d (chat-drawer plan section 10, S5d, rev 16.20.16): the helper echoes each prompt's
`prompt_id` on every prompt-scoped frame of its reply: `assistant_delta`,
`assistant_message`, `result`, a session's `error` (an API error, and the `error sdk` after
a renewed client) and `reply_capped`. A helper-wide error carries none.

These drive `python -m zb_agent_host chat` (test_chat's Helper) and the real CLI against
the fake Messages API; run the module alone, as the gate does."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_chat import FakeAnthropicApi, provisioned  # noqa: E402
from test_chat_flood import RawHelper  # noqa: E402

PROMPT_SCOPED = ("assistant_delta", "assistant_message", "tool_call", "result", "error", "reply_capped")


def said(entry):
    users = [m for m in (entry.get("body") or {}).get("messages") or [] if m.get("role") == "user"]
    content = users[-1].get("content") if users else ""
    if isinstance(content, str):
        return content
    # After a failed turn the CLI puts the next prompt into that same user turn (rev 16.16):
    # the last text block is the newest prompt.
    texts = [b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text"]
    return texts[-1] if texts else ""


def respond(entry, index):
    text = said(entry)
    if "refuse" in text:
        return {"status": 401, "body": {"type": "error", "error": {"type": "authentication_error", "message": "no"}}}
    if "flood" in text:
        return {"endless": "x" * 1023 + " ", "every_ms": 0}  # the SDK reader fails: a renew
    if "long" in text:
        return {"text": "y" * 300_000}  # capped
    return {"text": f"reply to {text[-12:]}"}


class PromptIdTest(unittest.TestCase):
    def test_every_frame_of_a_reply_carries_its_prompts_id(self):
        box = provisioned(self)
        with FakeAnthropicApi(responder=respond) as api:
            h = RawHelper(self, box.home)
            self.assertEqual(h.frame()["type"], "ready")
            h.send("hello", agent_home=str(box.home.root), workspace=str(box.home.workspace),
                   scratchpad=str(box.home.scratchpad), route="R1", e2e={"test_base_url": api.base_url})
            h.send("open_session", session="s-1-1", window_id="window-1")
            h.until("session_opened")
            ends = {}
            for prompt_id, text in enumerate(["one", "refuse", "long", "flood", "after"], start=1):
                h.send("prompt", session="s-1-1", prompt_id=prompt_id, text=text)
                frames = []
                while not any(f["type"] in ("result", "error") for f in frames):
                    frames.append(h.frame(180))
                frames += h.rest(quiet=1.0)  # nothing of this prompt may follow its ending frame
                scoped = [f for f in frames if f["type"] in PROMPT_SCOPED]
                self.assertNotEqual(scoped, [], text)
                self.assertEqual({f.get("prompt_id", "missing") for f in scoped}, {prompt_id},
                                 (text, sorted({(f["type"], f.get("prompt_id", "missing")) for f in scoped})))
                ends[text] = [(f["type"], f.get("code")) for f in frames if f["type"] in ("result", "error")]
            self.assertEqual(ends["one"], [("result", None)])
            self.assertEqual(ends["refuse"], [("error", "auth")])
            self.assertEqual(ends["long"], [("result", None)])
            self.assertEqual(ends["flood"], [("error", "sdk")])
            self.assertEqual(ends["after"], [("result", None)])
            h.send("shutdown")
            h.proc.wait(timeout=30)


if __name__ == "__main__":
    unittest.main()
