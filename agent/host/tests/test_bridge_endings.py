"""S7.0.5 (chat-drawer plan section 10, S7, rev 16.20.32; RoseCat 6513): every way a prompt
or its session ends ends the prompt's waiting browser calls, each exactly once with "the
prompt ended", and forgets their ids before `session_ended` is written: the turn's result, a
session failure (the client is renewed), `end_session` (the window closed), `shutdown` and the
end of stdin (the real `Chat.run`). Forced orderings: result versus end in each order,
timeout versus result, and a late result for an ended prompt's call against the next prompt.

The real Bridge, Session and Chat with a stand-in SDK client whose turn makes the browser
call from a task of its own, as the SDK runs an MCP handler. Run the module alone, as the gate
does."""

import asyncio
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from claude_agent_sdk import ResultMessage  # noqa: E402
from test_bridge import Out, answer, bridge, error_text, started  # noqa: E402

from zb_agent_host import chat  # noqa: E402

ENDED = (True, "the prompt ended")


def result_message():
    return ResultMessage(subtype="success", duration_ms=1, duration_api_ms=1, is_error=False, num_turns=1,
                         session_id="sdk-1")


class Watch:
    """Out's stream, noting what each session's Bridge still waits for when its session_ended
    is written."""

    def __init__(self, out):
        self.out, self.sessions, self.at_end = out, {}, {}
        write = out.stream.write

        def watched(text):
            for line in text.splitlines():
                if '"session_ended"' in line:
                    sid = json.loads(line)["session"]
                    self.at_end[sid] = sorted(self.sessions[sid].bridge.waiting())
            return write(text)

        out.stream.write = watched


class Turn:
    """A stand-in client: its turn makes one browser call (its own task), then ends with a result
    on `finish()`, or fails on `fail()`; it never ends by itself."""

    def __init__(self, out, session_box):
        self.out, self.box = out, session_box
        self.end, self.failing = asyncio.Event(), False
        self.call = None
        self.calls = []

    def finish(self):
        self.end.set()

    def fail(self):
        self.failing = True
        self.end.set()

    async def connect(self):
        pass

    async def disconnect(self):
        pass

    async def query(self, text):
        pass

    async def receive_response(self):
        self.call, made = await started(self.box["session"].bridge, self.out)
        self.calls += made
        await self.end.wait()
        if self.failing:
            raise RuntimeError("the SDK's reader failed")
        yield result_message()


def host(out, tmp):
    """A Chat with its scans stubbed (S5.7's own suites cover them) and our Out."""
    c = chat.Chat(types.SimpleNamespace(scratchpad=Path(tmp), claude_dir=tmp), "token")
    c.out = out.emitter

    async def scrubbed(*_args):
        pass

    c.scrubbed = scrubbed
    return c


class Session:
    """A real chat.Session in `c`, with the stand-in client and no route."""

    def __init__(self, c, out, sid="s-1-1"):
        self.box = {}
        self.client = Turn(out, self.box)
        with mock.patch.object(chat.Session, "_new_client", lambda s: None):
            s = chat.Session(c, sid)
        s.client, s.route = self.client, types.SimpleNamespace(close=lambda: None)
        s.renew = self.renew
        self.box["session"] = s
        self.session = s
        c.sessions[sid] = s
        self.renewed = 0

    async def renew(self):
        self.renewed += 1

    async def prompt(self, c, prompt_id=7):
        await c.handle({"type": "prompt", "session": self.session.id, "prompt_id": prompt_id, "text": "hi"})
        for _ in range(200):
            await asyncio.sleep(0)
            if self.client.call is not None:
                return
        raise AssertionError("the turn made no browser call")


class EndingTest(unittest.IsolatedAsyncioTestCase):
    async def ended(self, s, out):
        result = await asyncio.wait_for(s.client.call, 5)
        self.assertEqual(error_text(result), ENDED)
        return result

    async def test_the_turns_result_ends_its_call(self):
        out = Out()
        c = host(out, self.enterContext(tempfile.TemporaryDirectory()))
        s = Session(c, out)
        await s.prompt(c)
        s.client.finish()
        await self.ended(s, out)
        self.assertEqual([f["type"] for f in out.frames()], ["tool_call", "result"])
        self.assertEqual(s.session.bridge.waiting(), [])

    async def test_a_session_failure_ends_its_call(self):
        out = Out()
        c = host(out, self.enterContext(tempfile.TemporaryDirectory()))
        s = Session(c, out)
        await s.prompt(c)
        s.client.fail()
        await self.ended(s, out)
        self.assertEqual(s.renewed, 1)
        self.assertEqual([(f["type"], f.get("code"), f.get("prompt_id")) for f in out.frames()],
                         [("tool_call", None, 7), ("error", "sdk", 7)])

    async def test_end_session_ends_its_call_before_session_ended(self):
        out = Out()
        c = host(out, self.enterContext(tempfile.TemporaryDirectory()))
        s = Session(c, out)
        watch = Watch(out)
        watch.sessions["s-1-1"] = s.session
        await s.prompt(c)
        await c.handle({"type": "end_session", "session": "s-1-1"})
        await self.ended(s, out)
        self.assertEqual(watch.at_end, {"s-1-1": []}, "its id was forgotten before session_ended")
        self.assertEqual([f["type"] for f in out.frames()], ["tool_call", "session_ended"])

    async def test_result_then_end_and_end_then_result(self):
        for order in ("result first", "end first"):
            with self.subTest(order):
                out = Out()
                c = host(out, self.enterContext(tempfile.TemporaryDirectory()))
                s = Session(c, out)
                watch = Watch(out)
                watch.sessions["s-1-1"] = s.session
                await s.prompt(c)
                if order == "result first":
                    s.client.finish()
                    await asyncio.sleep(0.05)
                await c.handle({"type": "end_session", "session": "s-1-1"})
                s.client.finish()  # too late for "end first": the turn was cancelled
                await self.ended(s, out)
                kinds = [f["type"] for f in out.frames()]
                self.assertEqual(kinds, ["tool_call", "result", "session_ended"] if order == "result first"
                                 else ["tool_call", "session_ended"])
                self.assertEqual(watch.at_end, {"s-1-1": []})


class RunEndingTest(unittest.IsolatedAsyncioTestCase):
    """The real Chat.run, its stdin a pipe the test writes."""

    async def run_until(self, last_frames):
        out = Out()
        c = host(out, self.enterContext(tempfile.TemporaryDirectory()))
        read, write = os.pipe()
        stdin = os.fdopen(read, "r")
        self.addCleanup(stdin.close)
        box = {}
        with mock.patch.object(chat.Session, "_new_client", lambda s: box.update(session=s) or None), \
                mock.patch.object(chat.redact, "Scrubber") as scrubber, mock.patch("sys.stdin", stdin):
            scrubber.return_value.run = lambda on_failure: None
            scrubber.return_value.request = lambda kind, tag=None: None
            original = chat.Session.__init__

            def init(session, chat_, sid):
                original(session, chat_, sid)
                session.client, session.route = Turn(out, {"session": session}), types.SimpleNamespace(close=lambda: None)
                box["client"] = session.client
                box["session"] = session

            with mock.patch.object(chat.Session, "__init__", init):
                runner = asyncio.ensure_future(c.run())
                os.write(write, b'{"type":"hello","e2e":null}\n{"type":"open_session","session":"s-1-1","window_id":"window-1"}\n'
                         b'{"type":"prompt","session":"s-1-1","prompt_id":7,"text":"hi"}\n')
                for _ in range(500):
                    await asyncio.sleep(0.01)
                    if box.get("client") is not None and box["client"].call is not None:
                        break
                self.assertIsNotNone(box["client"].call, "the turn made its browser call")
                watch = Watch(out)
                watch.sessions["s-1-1"] = box["session"]
                if last_frames:
                    os.write(write, last_frames)
                os.close(write)  # then the end of stdin
                await asyncio.wait_for(runner, 10)
        result = await asyncio.wait_for(box["client"].call, 5)
        return out, watch, result

    async def test_the_end_of_stdin_ends_the_call_before_session_ended(self):
        out, watch, result = await self.run_until(b"")
        self.assertEqual(error_text(result), ENDED)
        self.assertEqual(watch.at_end, {"s-1-1": []})
        self.assertEqual([f["type"] for f in out.frames()], ["ready", "session_opened", "tool_call", "session_ended"])

    async def test_shutdown_ends_the_call_before_session_ended(self):
        out, watch, result = await self.run_until(b'{"type":"shutdown"}\n')
        self.assertEqual(error_text(result), ENDED)
        self.assertEqual(watch.at_end, {"s-1-1": []})


class OrderTest(unittest.IsolatedAsyncioTestCase):
    async def test_a_result_before_the_deadline_is_the_answer_and_after_it_nothing(self):
        out = Out()
        b = bridge(out, lambda: 7, deadline_s=0.3)
        task, calls = await started(b, out)
        await asyncio.sleep(0.1)
        b.resolve(answer(calls[0]))
        self.assertEqual(await asyncio.wait_for(task, 5), {"content": answer(calls[0])["content"]})
        task, calls = await started(b, out)
        result = await asyncio.wait_for(task, 5)
        b.resolve(answer(calls[0]))
        self.assertEqual(error_text(result), (True, "The browser did not answer in time."))
        self.assertEqual(b.waiting(), [])

    async def test_a_late_result_for_an_ended_prompt_never_reaches_the_next(self):
        out = Out()
        running = {"id": 7}
        b = bridge(out, lambda: running["id"])
        old, old_calls = await started(b, out)
        b.prompt_ended()
        running["id"] = 8
        self.assertEqual(error_text(await asyncio.wait_for(old, 5)), ENDED)
        new, new_calls = await started(b, out)
        self.assertEqual(new_calls[0]["prompt_id"], 8)
        b.resolve(answer(old_calls[0]))
        await asyncio.sleep(0.05)
        self.assertFalse(new.done(), "prompt 7's late result answered prompt 8's call")
        self.assertEqual(b.waiting(), [new_calls[0]["id"]])
        b.resolve(answer(new_calls[0], content=[{"type": "text", "text": "eight"}]))
        self.assertEqual(await asyncio.wait_for(new, 5), {"content": [{"type": "text", "text": "eight"}]})


if __name__ == "__main__":
    unittest.main()
