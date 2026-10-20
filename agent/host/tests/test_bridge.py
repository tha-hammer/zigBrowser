"""S7.0 (chat-drawer plan section 10, S7, rev 16.20.30): the Bridge's binding. A browser tool
call names the session's running prompt (`tool_call.prompt_id`, which the app's validator
requires since S5d); with no prompt running nothing is sent; `Chat` hands the app's
`tool_result` to the waiting call by `id` alone, and nothing else changes anything; a
prompt's end ends its calls; a call with no answer ends at the tool deadline, which a
`hello.e2e.tool_deadline_s` seam can shorten for the sessions opened after it.

Pure Python: the real Bridge, Session and Chat, with a stand-in SDK client and frames
written to memory by the real Emitter. Run the module alone, as the gate does."""

import asyncio
import io
import json
import random
import re
import sys
import tempfile
import threading
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from claude_agent_sdk import ResultMessage  # noqa: E402

from zb_agent_host import chat  # noqa: E402
from zb_agent_host.bridge import Bridge  # noqa: E402
from zb_agent_host.frames import Emitter  # noqa: E402

UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
MAX_PROMPT_ID = 2**53 - 1
TEXT = [{"type": "text", "text": "Hello from page 1"}]


class Out:
    """The real Emitter, writing to memory."""

    def __init__(self):
        self.stream = io.StringIO()
        self.emitter = Emitter(self.stream)

    def frames(self):
        return [json.loads(line) for line in self.stream.getvalue().splitlines()]

    def calls(self):
        return [f for f in self.frames() if f["type"] == "tool_call"]


def bridge(out, prompt, deadline_s=5.0, session="s-1-1"):
    return Bridge(out.emitter, session, deadline_s, prompt=prompt)


async def started(b, out, name="get_text", args=None):
    """A call in flight, and the tool_call frames written so far."""
    before = len(out.calls())
    task = asyncio.ensure_future(b.call(name, {"selector": "#greeting"} if args is None else args))
    for _ in range(200):
        await asyncio.sleep(0)
        if len(out.calls()) > before or task.done():
            break
    return task, out.calls()[before:]


def answer(frame, ok=True, **fields):
    reply = {"type": "tool_result", "session": frame["session"], "id": frame["id"], "ok": ok}
    reply.update({"content": TEXT} if ok else {"error": "the page has a dialog open"})
    reply.update(fields)
    return reply


def error_text(result):
    return result.get("is_error"), " ".join(c.get("text", "") for c in result.get("content", []))


class BindingTest(unittest.IsolatedAsyncioTestCase):
    async def test_a_tool_call_carries_the_running_prompts_id(self):
        out = Out()
        b = bridge(out, lambda: 7)
        task, calls = await started(b, out, "get_text", {"selector": "#greeting"})
        self.assertEqual(len(calls), 1, out.frames())
        frame = calls[0]
        self.assertEqual({k: frame[k] for k in ("type", "session", "prompt_id", "tool", "args")},
                         {"type": "tool_call", "session": "s-1-1", "prompt_id": 7,
                          "tool": "mcp__zigbrowser__get_text", "args": {"selector": "#greeting"}})
        self.assertRegex(frame["id"], UUID)
        self.assertEqual(set(frame), {"v", "seq", "type", "session", "prompt_id", "id", "tool", "args"})
        b.resolve(answer(frame))
        self.assertEqual(await asyncio.wait_for(task, 5), {"content": TEXT})

    async def test_every_running_id_is_the_one_sent(self):
        """Invariant (seeded): for every running prompt id, the call names exactly it."""
        rng = random.Random(7_0_1)
        ids = [1, MAX_PROMPT_ID] + [rng.randint(1, MAX_PROMPT_ID) for _ in range(198)]
        out = Out()
        running = {"id": None}
        b = bridge(out, lambda: running["id"])
        for prompt_id in ids:
            running["id"] = prompt_id
            task, calls = await started(b, out)
            self.assertEqual([c["prompt_id"] for c in calls], [prompt_id])
            b.resolve(answer(calls[0]))
            await asyncio.wait_for(task, 5)


class NoPromptTest(unittest.IsolatedAsyncioTestCase):
    async def test_with_no_prompt_running_no_frame_is_sent(self):
        out = Out()
        b = bridge(out, lambda: None)
        task, calls = await started(b, out)
        result = await asyncio.wait_for(task, 5)
        self.assertEqual(calls, [])
        self.assertEqual(out.frames(), [], "the app would reject a tool_call with no running prompt")
        self.assertEqual(error_text(result), (True, "no prompt is running"))


class RouteTest(unittest.IsolatedAsyncioTestCase):
    def chat_with(self, out, **bridges):
        c = chat.Chat.__new__(chat.Chat)
        c.out = out.emitter
        c.sessions = {sid.replace("_", "-"): types.SimpleNamespace(bridge=b) for sid, b in bridges.items()}
        return c

    async def test_chat_hands_a_tool_result_to_its_sessions_bridge(self):
        out = Out()
        mine = bridge(out, lambda: 7)
        c = self.chat_with(out, s_1_1=mine, s_2_1=bridge(out, lambda: 3, session="s-2-1"))
        task, calls = await started(mine, out)
        self.assertTrue(await c.handle(answer(calls[0])))
        self.assertEqual(await asyncio.wait_for(task, 5), {"content": TEXT})
        task, calls = await started(mine, out)
        await c.handle(answer(calls[0], ok=False))
        self.assertEqual(error_text(await asyncio.wait_for(task, 5)), (True, "the page has a dialog open"))
        self.assertEqual([f["type"] for f in out.frames()], ["tool_call", "tool_call"], "nothing else is sent")

    async def test_unknown_repeated_and_foreign_results_change_nothing(self):
        out = Out()
        mine, other = bridge(out, lambda: 7), bridge(out, lambda: 3, session="s-2-1")
        c = self.chat_with(out, s_1_1=mine, s_2_1=other)
        task, calls = await started(mine, out)
        frame = calls[0]
        for stray in (dict(answer(frame), id="00000000-0000-4000-8000-000000000000"),  # unknown id
                      dict(answer(frame), session="s-2-1"),  # pending in another session
                      dict(answer(frame), session="s-9-9")):  # a session that is not open
            self.assertTrue(await c.handle(stray))
            await asyncio.sleep(0.05)
            self.assertFalse(task.done(), f"{stray} answered the call")
        self.assertEqual(len(out.frames()), 1, "a stray tool_result sends nothing")
        await c.handle(answer(frame))
        self.assertEqual(await asyncio.wait_for(task, 5), {"content": TEXT})
        self.assertTrue(await c.handle(answer(frame)))  # repeated: nothing to answer
        self.assertEqual(len(out.frames()), 1)

    async def test_the_bridge_reads_no_stdin_of_its_own(self):
        """One stdin reader, Chat's pump (RoseCat 6527): the Bridge touches no stdin attribute,
        registers no event-loop reader and starts no thread."""

        class StdinSpy:
            def __init__(self):
                self.touched = []

            def __getattr__(self, name):  # read, readline, fileno, buffer, ...
                self.touched.append(name)
                raise AttributeError(name)

            def __iter__(self):
                self.touched.append("__iter__")
                return iter(())

        out, spy = Out(), StdinSpy()
        loop = asyncio.get_running_loop()
        before = {t.ident for t in threading.enumerate()}
        with mock.patch("sys.stdin", spy), \
                mock.patch.object(loop, "add_reader", side_effect=lambda *a: spy.touched.append("add_reader")):
            b = bridge(out, lambda: 7)
            task, calls = await started(b, out)
            b.resolve(answer(calls[0]))
            await asyncio.wait_for(task, 5)
            await asyncio.sleep(0.05)  # a reader thread would have iterated by now
        self.assertEqual(spy.touched, [], "one stdin reader: Chat's pump")
        self.assertEqual({t.ident for t in threading.enumerate()} - before, set())


class PromptEndTest(unittest.IsolatedAsyncioTestCase):
    async def test_a_prompts_end_answers_its_pending_call(self):
        out = Out()
        b = bridge(out, lambda: 7)
        task, calls = await started(b, out)
        b.prompt_ended()
        self.assertEqual(error_text(await asyncio.wait_for(task, 5)), (True, "the prompt ended"))
        b.resolve(answer(calls[0]))  # late: changes nothing
        self.assertEqual(len(out.frames()), 1)

    async def test_the_session_labels_calls_with_its_prompt_and_ends_them_with_it(self):
        """The real Session and Chat._prompt, a stand-in client whose turn makes two calls:
        one answered, one left pending when the turn's result comes."""
        out = Out()
        results = {}

        class Client:
            async def query(self, text):
                results["query"] = text

            async def receive_response(self):
                task, calls = await started(session.bridge, out)
                session.bridge.resolve(answer(calls[0]))
                results["answered"] = await asyncio.wait_for(task, 5)
                results["pending"], _ = await started(session.bridge, out)
                yield ResultMessage(subtype="success", duration_ms=1, duration_api_ms=1, is_error=False,
                                    num_turns=1, session_id="sdk-1")

        async def scrubbed(*_args):
            pass

        host = types.SimpleNamespace(out=out.emitter, tool_deadline_s=5.0, scrubbed=scrubbed,
                                     error=lambda *a, **k: out.emitter.emit("error", code=a[0]))
        with mock.patch.object(chat.Session, "_new_client", lambda self: setattr(self, "client", Client())):
            session = chat.Session(host, "s-1-1")
        self.assertIsNone(session.running_prompt)
        await chat.Chat._prompt(host, session, "hi", 7)
        self.assertEqual(results["answered"], {"content": TEXT})
        self.assertEqual([c["prompt_id"] for c in out.calls()], [7, 7])
        self.assertEqual(error_text(await asyncio.wait_for(results["pending"], 5)), (True, "the prompt ended"))
        self.assertIsNone(session.running_prompt, "cleared after the prompt's ending frame")
        task, calls = await started(session.bridge, out)
        self.assertEqual((calls, error_text(await asyncio.wait_for(task, 5))), ([], (True, "no prompt is running")))
        self.assertEqual([f["type"] for f in out.frames()], ["tool_call", "tool_call", "result"])


class DeadlineTest(unittest.IsolatedAsyncioTestCase):
    async def test_no_answer_ends_at_the_deadline(self):
        out = Out()
        b = bridge(out, lambda: 7, deadline_s=0.2)
        task, calls = await started(b, out)
        result = await asyncio.wait_for(task, 5)
        self.assertEqual(error_text(result), (True, "The browser did not answer in time."))
        b.resolve(answer(calls[0]))  # too late: changes nothing
        self.assertEqual(len(out.frames()), 1)

    def chat(self, tmp):
        c = chat.Chat(types.SimpleNamespace(scratchpad=Path(tmp)), "token")
        c.out = (out := Out()).emitter
        return c, out

    async def test_hello_sets_the_deadline_for_sessions_opened_after_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            c, out = self.chat(tmp)
            self.assertEqual(c.tool_deadline_s, chat.TOOL_DEADLINE_S)
            await c.handle({"type": "hello", "e2e": {"tool_deadline_s": 1}})
            self.assertEqual((c.tool_deadline_s, out.frames()), (1, []))
            with mock.patch.object(chat.Session, "_new_client", lambda self: None):
                session = chat.Session(c, "s-1-1")
            self.assertEqual(session.bridge.deadline_s, 1)

    async def test_a_bad_deadline_is_a_protocol_error_and_the_default_stays(self):
        for bad in (0, chat.TOOL_DEADLINE_S + 1, "5", 1.5, True, -3):
            with self.subTest(bad=bad), tempfile.TemporaryDirectory() as tmp:
                c, out = self.chat(tmp)
                await c.handle({"type": "hello", "e2e": {"tool_deadline_s": bad}})
                self.assertEqual(c.tool_deadline_s, chat.TOOL_DEADLINE_S)
                self.assertEqual([(f["type"], f["code"], f["session"]) for f in out.frames()],
                                 [("error", "protocol", None)])

    async def test_no_seam_keeps_the_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            c, out = self.chat(tmp)
            await c.handle({"type": "hello", "e2e": None})
            await c.handle({"type": "hello", "e2e": {"test_base_url": "https://fake.zb.invalid"}})
            self.assertEqual((c.tool_deadline_s, out.frames()), (chat.TOOL_DEADLINE_S, []))


if __name__ == "__main__":
    unittest.main()
