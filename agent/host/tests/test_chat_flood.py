"""S5c-1 (chat-drawer plan S5.6, rev 16.20): the helper sends every streamed character
and keeps each frame inside the app's validator caps, measured as the app measures
them: the line's bytes (at most 256 KiB, src/agent_protocol.zig `max_frame`) and the
text's UTF-8 bytes (a delta at most 16 KiB, a message at most 256 KiB).
- A batch longer than 16 KiB goes out as several deltas, and nothing is lost.
- Non-ASCII and escaped text are sized as encoded, so no frame is refused as oversize.
- A message over its cap is cut at a character boundary and ends with "[output truncated]".

These drive `python -m zb_agent_host chat` (test_chat's Helper) and the real CLI against
the fake Messages API; run the module alone, as the gate does."""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_chat import FakeAnthropicApi, Helper, provisioned  # noqa: E402

MAX_FRAME = 256 * 1024
DELTA_MAX = 16 * 1024
MESSAGE_MAX = 256 * 1024
MARKER = "[output truncated]"


def utf8_prefix(text, limit):
    """The longest prefix of `text` whose UTF-8 is at most `limit` bytes."""
    return text.encode()[:limit].decode("utf-8", "ignore")


class RawHelper(Helper):
    """Keeps every stdout line as it was written, so its size is the app's."""

    def __init__(self, tc, home):
        self.raw = []
        super().__init__(tc, home)

    def _read(self):
        for line in self.proc.stdout:
            self.raw.append(line.rstrip("\n"))
            self.lines.put(line)
        self.lines.put(None)


class FloodTest(unittest.TestCase):
    def reply(self, text):
        """One prompt answered with `text` as a single streamed text block. Returns
        (the prompt's frames, the raw lines of those frames)."""
        box = provisioned(self)
        with FakeAnthropicApi(turns=[{"text": text}]) as api:
            h = RawHelper(self, box.home)
            self.assertEqual(h.frame()["type"], "ready")
            h.send("hello", agent_home=str(box.home.root), workspace=str(box.home.workspace),
                   scratchpad=str(box.home.scratchpad), route="R1", e2e={"test_base_url": api.base_url})
            h.send("open_session", session="s-1-1", window_id="window-1")
            h.until("session_opened")
            start = len(h.raw)
            h.send("prompt", session="s-1-1", text="hi")
            _, frames = h.until("result", timeout=180)
            raw = list(h.raw[start:])
            h.send("shutdown")
            h.proc.wait(timeout=30)
        return frames, raw

    def assert_within_caps(self, frames, raw):
        refused = [len(line.encode()) for line in raw if len(line.encode()) > MAX_FRAME]
        self.assertEqual(refused, [], "every frame line fits the app's 256 KiB line cap")
        deltas = [f["text"] for f in frames if f["type"] == "assistant_delta"]
        self.assertEqual([len(t.encode()) for t in deltas if len(t.encode()) > DELTA_MAX], [],
                         "every delta's text fits 16 KiB of UTF-8")
        messages = [f["text"] for f in frames if f["type"] == "assistant_message"]
        self.assertEqual([len(t.encode()) for t in messages if len(t.encode()) > MESSAGE_MAX], [],
                         "every message's text fits 256 KiB of UTF-8")
        return "".join(deltas), messages

    def test_a_batch_longer_than_16_kib_is_split_and_nothing_is_lost(self):
        text = "abcdefghij" * 10_000
        frames, raw = self.reply(text)
        streamed, messages = self.assert_within_caps(frames, raw)
        self.assertEqual(len(streamed), len(text), "the deltas carry every character")
        self.assertEqual(streamed, text)
        self.assertGreater(len([f for f in frames if f["type"] == "assistant_delta"]), len(text) // DELTA_MAX)
        self.assertEqual(messages, [text])

    def test_non_ascii_text_is_sized_as_utf8_and_reaches_the_app_whole(self):
        text = "界" * 60_000  # 180,000 bytes of UTF-8: under the message cap
        frames, raw = self.reply(text)
        streamed, messages = self.assert_within_caps(frames, raw)
        self.assertEqual(streamed, text)
        self.assertEqual(messages, [text])

    def test_a_message_over_its_cap_is_cut_and_ends_with_the_marker(self):
        # 350,000 bytes. The 3-byte character keeps 16 KiB pieces from adding up to exactly
        # 256 KiB, so a helper that forwards whole pieces past the cap is caught.
        text = "ab\u754c " * 58_334
        frames, raw = self.reply(text)
        streamed, messages = self.assert_within_caps(frames, raw)
        # Rev 16.20.10: a reply's deltas are exactly its longest UTF-8 prefix that fits 256 KiB.
        want = utf8_prefix(text, MESSAGE_MAX)
        self.assertEqual(streamed, want, (len(streamed.encode()), len(want.encode())))
        self.assertEqual(len(messages), 1)
        self.assertTrue(messages[0].endswith(MARKER), messages[0][-60:])
        kept = messages[0][:-len(MARKER)].rstrip("\n")
        self.assertTrue(text.startswith(kept) and len(kept) > MESSAGE_MAX // 2, len(kept))

    def test_escaped_text_is_measured_as_encoded(self):
        text = '"\\' * 100_000  # 200,000 characters that each encode to two bytes
        frames, raw = self.reply(text)
        streamed, messages = self.assert_within_caps(frames, raw)
        self.assertEqual(streamed, text)
        self.assertEqual(len(messages), 1)
        self.assertTrue(messages[0].endswith(MARKER), messages[0][-60:])


def cli_pids(root):
    """The bundled CLI processes among `root`'s descendants."""
    import os
    parents = {}
    for entry in os.listdir("/proc"):
        if entry.isdigit():
            try:
                with open(f"/proc/{entry}/stat") as f:
                    ppid = int(f.read().rsplit(")", 1)[1].split()[1])
            except (OSError, IndexError, ValueError):
                continue
            parents.setdefault(ppid, []).append(int(entry))
    found, todo = [], [root]
    while todo:
        pid = todo.pop()
        for child in parents.get(pid, []):
            try:
                with open(f"/proc/{child}/cmdline", "rb") as f:
                    argv = f.read().split(b"\0")
            except OSError:
                continue
            if argv and argv[0].endswith(b"_bundled/claude"):
                found.append(child)
            todo.append(child)
    return found


class EndlessTest(unittest.TestCase):
    """S5c-1 (rev 16.20.9): an endless reply. The helper forwards at most 256 KiB of a
    reply's deltas (the app shows no more), and a session whose SDK reader failed (the
    CLI's message over the SDK's 1 MiB buffer) gets a fresh CLI, the old one killed, so
    the next prompt in it is answered."""

    def start(self, endless):
        box = provisioned(self)
        api = FakeAnthropicApi(turns=[endless, {"text": "after the endless one"}]).start()
        self.addCleanup(api.stop)
        h = RawHelper(self, box.home)
        self.assertEqual(h.frame()["type"], "ready")
        h.send("hello", agent_home=str(box.home.root), workspace=str(box.home.workspace),
               scratchpad=str(box.home.scratchpad), route="R1", e2e={"test_base_url": api.base_url})
        h.send("open_session", session="s-1-1", window_id="window-1")
        h.until("session_opened")
        h.send("prompt", session="s-1-1", text="go")
        return h

    def frames_for(self, h, seconds):
        import time
        frames, deadline = [], time.monotonic() + seconds
        while time.monotonic() < deadline:
            frames += h.rest(quiet=0.5)
        return frames

    def ending(self, h, frames):
        while not any(f["type"] in ("result", "error") for f in frames):
            frames.append(h.frame(60))
        return frames

    def answered_again(self, h):
        h.send("prompt", session="s-1-1", text="again")
        _, after = h.until("result", timeout=90)
        self.assertIn("after the endless one", [f.get("text") for f in after if f["type"] == "assistant_message"], after[-3:])

    def test_an_endless_reply_forwards_at_most_256_kib_and_the_session_goes_on(self):
        # The fake's default pace: one 1023-byte piece every 25 ms. 256 KiB is no multiple of
        # 1023, so forwarding whole pieces past the cap cannot land on it by chance.
        h = self.start({"endless": "x" * 1022 + " "})
        frames = self.frames_for(h, 9)
        forwarded = sum(len(f["text"].encode()) for f in frames if f["type"] == "assistant_delta")
        # Exactly the longest prefix that fits 256 KiB (RoseCat 6071): the piece is ASCII.
        self.assertEqual(forwarded, MESSAGE_MAX, "a reply's deltas stop at exactly 256 KiB")
        h.send("interrupt", session="s-1-1")
        self.ending(h, frames)
        self.answered_again(h)
        h.send("shutdown")
        h.proc.wait(timeout=30)

    def test_a_failed_sdk_reader_gets_a_fresh_cli_and_the_old_one_is_gone(self):
        h = self.start({"endless": "x" * 1023 + " ", "every_ms": 0})  # unpaced, up to the fake's 8 MiB cap
        frames = self.ending(h, self.frames_for(h, 3))
        ends = [f for f in frames if f["type"] in ("result", "error")]
        self.assertEqual([(f["type"], f.get("code")) for f in ends], [("error", "sdk")], ends)
        import time
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and len(cli_pids(h.proc.pid)) != 1:
            time.sleep(0.2)
        self.assertEqual(len(cli_pids(h.proc.pid)), 1, "exactly the fresh CLI remains")
        self.answered_again(h)
        h.send("shutdown")
        h.proc.wait(timeout=30)


if __name__ == "__main__":
    unittest.main()
