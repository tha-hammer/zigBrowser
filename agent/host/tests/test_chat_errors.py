"""S5a (chat-drawer plan S5.3, rev 16.14): chat turns an API error into a plain `error`
frame, which ends the prompt in place of its `result`. The real bundled CLI reports a 401, 429 or 529 as an AssistantMessage whose
`error` is authentication_failed, rate_limit or server_error, with a text that echoes the
server's own error message; that text is never emitted. Under the test base URL (only
with --e2e-protocol) the CLI does not retry, and production keeps its retries.

These drive `python -m zb_agent_host chat` (test_chat's Helper) and the real CLI against
the fake Messages API; run the module alone, as the gate does."""

import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_chat  # noqa: E402 - its Helper, provisioned home and the fake API
from test_chat import FakeAnthropicApi, Helper, provisioned  # noqa: E402
from zb_agent_host import chat, options, sandbox  # noqa: E402

SERVER_CANARY = "zb-server-error-canary-unit"
API_ERRORS = {401: "authentication_error", 429: "rate_limit_error", 529: "overloaded_error"}


class ApiErrorTest(unittest.TestCase):
    def run_prompt(self, status):
        box = provisioned(self)
        body = {"type": "error", "error": {"type": API_ERRORS[status], "message": SERVER_CANARY}}
        with FakeAnthropicApi(responder=lambda entry, index: {"status": status, "body": body}) as api:
            h = Helper(self, box.home)
            self.assertEqual(h.frame()["type"], "ready")
            h.send("hello", agent_home=str(box.home.root), workspace=str(box.home.workspace),
                   scratchpad=str(box.home.scratchpad), route="R1", e2e={"test_base_url": api.base_url})
            h.send("open_session", session="s-1-1", window_id="window-1")
            h.until("session_opened")
            started = time.monotonic()
            h.send("prompt", session="s-1-1", text="hi")
            _, frames = h.until("error", timeout=90)
            elapsed = time.monotonic() - started
            frames += h.rest(3.0)
            h.send("shutdown")
            h.proc.wait(timeout=30)
            return frames, len(api.messages_requests()), elapsed

    def assert_plain(self, frames, code):
        errors = [f for f in frames if f["type"] == "error"]
        self.assertEqual([(f["code"], f["session"]) for f in errors], [(code, "s-1-1")], frames)
        texts = [f.get("text", "") for f in frames] + [f.get("message", "") for f in frames]
        self.assertFalse([t for t in texts if SERVER_CANARY in t or "API Error" in t], frames)
        self.assertEqual([f for f in frames if f["type"] in ("assistant_message", "assistant_delta")], [], frames)
        # One ending frame per prompt: the error stands in for the result.
        self.assertEqual([f for f in frames if f["type"] == "result"], [], frames)

    def test_a_401_is_an_auth_error_frame_without_the_server_text(self):
        frames, _, _ = self.run_prompt(401)
        self.assert_plain(frames, "auth")

    def test_a_429_is_overloaded_and_not_retried_under_the_test_base_url(self):
        frames, requests, elapsed = self.run_prompt(429)
        self.assert_plain(frames, "overloaded")
        self.assertEqual(requests, 1)
        self.assertLess(elapsed, 30)

    def test_a_529_is_overloaded_and_not_retried_under_the_test_base_url(self):
        frames, requests, _ = self.run_prompt(529)
        self.assert_plain(frames, "overloaded")
        self.assertEqual(requests, 1)


class RetrySettingTest(unittest.TestCase):
    """The no-retry setting exists only with the test base URL (hello's e2e object)."""

    def env(self, e2e):
        box = provisioned(self)
        opts = chat.session_options(box.home, route_env={}, cli_path=None, e2e=e2e, test_ca=None,
                                    proxy=sandbox.linux_helper_proxy())
        return opts.env

    def test_production_keeps_the_cli_retries(self):
        self.assertNotIn("CLAUDE_CODE_MAX_RETRIES", self.env(None))
        self.assertNotIn("CLAUDE_CODE_MAX_RETRIES", self.env({}))

    def test_the_test_base_url_turns_retries_off(self):
        self.assertEqual(self.env({"test_base_url": "https://fake.zb.invalid"})["CLAUDE_CODE_MAX_RETRIES"], "0")


class InterruptTest(unittest.TestCase):
    """S5.2 (observed with the real CLI): an interrupt ends the running prompt with an
    error_during_execution result, and the next prompt in the same session runs. The
    setup is test_chat's held first prompt (its own tests stay in test_chat)."""

    setUp = test_chat.PromptLifecycleTest.setUp
    held = test_chat.PromptLifecycleTest.held

    def test_interrupt_ends_the_prompt_and_the_session_goes_on(self):
        self.h.send("interrupt", session="s-1-1")
        result, _ = self.h.until("result", timeout=30)
        self.assertEqual((result["subtype"], result["is_error"]), ("error_during_execution", True))
        self.release.set()
        self.h.send("prompt", session="s-1-1", text="second")
        result, frames = self.h.until("result", timeout=60)
        self.assertEqual(result["subtype"], "success")
        self.assertIn("assistant_message", [f["type"] for f in frames])
        self.assertEqual(len(self.api.messages_requests()), 2)


if __name__ == "__main__":
    unittest.main()
