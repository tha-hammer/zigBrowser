"""S7.0.7 (chat-drawer plan section 10, S7, rev 16.20.32; RoseCat 6513): the Bridge checks the
app's `tool_result` against section 3's grammar exactly. `ok` true has exactly `content`, text
and image blocks (image/png or image/jpeg, valid base64), returned in order with each image as
an MCP image block; `ok` false has exactly one non-empty `error` of at most 4 KiB; the line is
at most 1 MiB (as the helper encodes it). Anything else ends the call "the browser sent a bad
result", forgets its id and emits one helper-wide `error protocol`; none of it reaches the
model.

Pure Python: the real Bridge and Emitter. Run the module alone, as the gate does."""

import asyncio
import base64
import copy
import json
import sys
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from test_bridge import Out, answer, bridge, error_text, started  # noqa: E402

from zb_agent_host.frames import encode  # noqa: E402
from zb_agent_host import chat  # noqa: E402

PNG = base64.b64encode(b"\x89PNG\r\n\x1a\n" + bytes(range(64))).decode()
JPEG = base64.b64encode(b"\xff\xd8\xff\xe0" + bytes(range(64))).decode()
LIMIT = 1 << 20
BAD = "the browser sent a bad result"


def result(frame, **fields):
    reply = {"type": "tool_result", "session": frame["session"], "id": frame["id"]}
    reply.update(fields)
    return reply


class GoodTest(unittest.IsolatedAsyncioTestCase):
    async def test_text_and_images_come_back_in_order(self):
        out = Out()
        b = bridge(out, lambda: 7)
        task, calls = await started(b, out)
        b.resolve(result(calls[0], ok=True, content=[
            {"type": "text", "text": "before"},
            {"type": "image", "mime": "image/png", "data_b64": PNG},
            {"type": "text", "text": "between"},
            {"type": "image", "mime": "image/jpeg", "data_b64": JPEG}]))
        self.assertEqual(await asyncio.wait_for(task, 5), {"content": [
            {"type": "text", "text": "before"},
            {"type": "image", "data": PNG, "mimeType": "image/png"},
            {"type": "text", "text": "between"},
            {"type": "image", "data": JPEG, "mimeType": "image/jpeg"}]})
        self.assertEqual([f["type"] for f in out.frames()], ["tool_call"])

    async def test_the_frames_envelope_is_accepted(self):
        """The app writes every frame with the shared envelope {"v":1,"seq":n} (plan D7b)."""
        out = Out()
        b = bridge(out, lambda: 7)
        task, calls = await started(b, out)
        b.resolve(result(calls[0], v=1, seq=41, ok=True, content=[{"type": "text", "text": "framed"}]))
        self.assertEqual(await asyncio.wait_for(task, 5), {"content": [{"type": "text", "text": "framed"}]})

    async def test_an_error_of_4_kib_is_returned_as_is(self):
        out = Out()
        b = bridge(out, lambda: 7)
        task, calls = await started(b, out)
        b.resolve(result(calls[0], ok=False, error="e" * 4096))
        self.assertEqual(error_text(await asyncio.wait_for(task, 5)), (True, "e" * 4096))

    async def test_a_line_of_exactly_1_mib_is_accepted(self):
        out = Out()
        b = bridge(out, lambda: 7)
        task, calls = await started(b, out)
        frame = result(calls[0], ok=True, content=[{"type": "text", "text": ""}])
        frame["content"][0]["text"] = "x" * (LIMIT - len(encode(frame).encode()))
        self.assertEqual(len(encode(frame).encode()), LIMIT)
        b.resolve(frame)
        returned = await asyncio.wait_for(task, 5)
        self.assertNotIn("is_error", returned)
        self.assertEqual(len(returned["content"][0]["text"]), len(frame["content"][0]["text"]))


class FramingTest(unittest.IsolatedAsyncioTestCase):
    """RoseCat 6526: the 1 MiB is the line Chat read, as the app wrote it (here with spaces
    that a compact re-encoding would drop), not the frame re-encoded."""

    async def test_the_limit_is_the_line_as_read(self):
        out = Out()
        b = bridge(out, lambda: 7)
        c = types.SimpleNamespace(sessions={"s-1-1": types.SimpleNamespace(bridge=b)})
        task, calls = await started(b, out)
        frame = result(calls[0], ok=True, content=[{"type": "text", "text": ""}])
        spaced = lambda f: json.dumps(f, separators=(", ", ": "), ensure_ascii=False)  # noqa: E731
        frame["content"][0]["text"] = "x" * (LIMIT + 1 - len(spaced(frame).encode()))
        line = spaced(frame)
        self.assertEqual(len(line.encode()), LIMIT + 1)
        self.assertLessEqual(len(encode(frame).encode()), LIMIT, "compact, it would fit")
        await chat.Chat.handle(c, json.loads(line), size=len(line.encode()))
        self.assertEqual(error_text(await asyncio.wait_for(task, 5)), (True, BAD))


def malformed_cases(frame):
    """(name, the tool_result) for each shape section 3's grammar refuses."""
    good = result(frame, ok=True, content=[{"type": "text", "text": "fine"}])
    failed = result(frame, ok=False, error="no")

    def with_(base, **changes):
        reply = copy.deepcopy(base)
        for key, value in changes.items():
            if value is KeyError:
                del reply[key]
            else:
                reply[key] = value
        return reply

    def block(**fields):
        return with_(good, content=[fields])

    over = result(frame, ok=True, content=[{"type": "text", "text": ""}])
    over["content"][0]["text"] = "x" * (LIMIT + 1 - len(encode(over).encode()))
    return [
        ("an unknown field", with_(good, extra=1)),
        ("an envelope v other than 1", with_(good, v=2, seq=1)),
        ("an envelope seq that is not a positive integer", with_(good, v=1, seq=0)),
        ("no ok", with_(good, ok=KeyError)),
        ("ok a string", with_(good, ok="true")),
        ("ok a number", with_(good, ok=1)),
        ("ok true with an error", with_(good, error="no")),
        ("ok true with no content", with_(good, content=KeyError)),
        ("content not an array", with_(good, content={"type": "text", "text": "x"})),
        ("a block not an object", with_(good, content=["text"])),
        ("an unknown block type", block(type="audio", data_b64=PNG)),
        ("a text block with no text", block(type="text")),
        ("a text block whose text is a number", block(type="text", text=5)),
        ("a text block with an extra field", block(type="text", text="x", mime="text/plain")),
        ("an image of an unknown mime", block(type="image", mime="image/gif", data_b64=PNG)),
        ("an image with bad base64", block(type="image", mime="image/png", data_b64="not*base64!")),
        ("an image with no data", block(type="image", mime="image/png")),
        ("an image with an extra field", block(type="image", mime="image/png", data_b64=PNG, alt="x")),
        ("ok false with content", with_(failed, content=[{"type": "text", "text": "x"}])),
        ("ok false with no error", with_(failed, error=KeyError)),
        ("ok false with an empty error", with_(failed, error="")),
        ("ok false with an error over 4 KiB", with_(failed, error="e" * 4097)),
        ("ok false with an error that is not a string", with_(failed, error=["no"])),
        ("a line of 1 MiB and one byte", over),
    ]


class MalformedTest(unittest.IsolatedAsyncioTestCase):
    async def test_each_malformed_result_ends_its_call_and_reaches_no_model(self):
        probe = {"session": "s-1-1", "id": "00000000-0000-4000-8000-000000000000"}
        for name, _ in malformed_cases(probe):
            with self.subTest(name):
                out = Out()
                b = bridge(out, lambda: 7)
                task, calls = await started(b, out)
                bad = dict(malformed_cases(calls[0]))[name]
                if name == "a line of 1 MiB and one byte":
                    self.assertEqual(len(encode(bad).encode()), LIMIT + 1)
                b.resolve(bad)
                self.assertEqual(error_text(await asyncio.wait_for(task, 5)), (True, BAD))
                self.assertEqual([(f["type"], f.get("session"), f.get("code"), f.get("message"))
                                  for f in out.frames()[1:]], [("error", None, "protocol", "bad tool_result")])
                b.resolve(answer(calls[0]))  # its id is forgotten: changes nothing
                self.assertEqual(len(out.frames()), 2)
                self.assertNotIn(calls[0]["id"], b.waiting())


if __name__ == "__main__":
    unittest.main()
