"""S7.0.7 (chat-drawer plan section 10, S7, rev 16.20.32; RoseCat 6538): the app's
`tool_result` carries the D7b envelope exactly, `"v": 1` and an integer `"seq"` of at least
1, as every frame does. A tool_result without `v`, without `seq`, or without both, is
malformed: the call ends "the browser sent a bad result", its id is forgotten, and the helper
emits one helper-wide `error protocol`.

Pure Python: the real Bridge and Emitter. Run the module alone, as the gate does."""

import asyncio
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_bridge import Out, answer, bridge, error_text, started  # noqa: E402

BAD = "the browser sent a bad result"


class MissingEnvelopeTest(unittest.IsolatedAsyncioTestCase):
    async def test_a_tool_result_without_its_envelope_is_malformed(self):
        for missing in (("v",), ("seq",), ("v", "seq")):
            with self.subTest(missing=missing):
                out = Out()
                b = bridge(out, lambda: 7)
                task, calls = await started(b, out)
                bad = answer(calls[0])
                for key in missing:
                    del bad[key]
                b.resolve(bad)
                self.assertEqual(error_text(await asyncio.wait_for(task, 5)), (True, BAD))
                self.assertEqual([(f["type"], f.get("session"), f.get("code"), f.get("message"))
                                  for f in out.frames()[1:]], [("error", None, "protocol", "bad tool_result")])
                self.assertEqual(b.waiting(), [])

    async def test_a_seq_that_is_not_an_integer_is_malformed(self):
        for seq in ("1", 1.0, True, None):
            with self.subTest(seq=seq):
                out = Out()
                b = bridge(out, lambda: 7)
                task, calls = await started(b, out)
                b.resolve(answer(calls[0], seq=seq))
                self.assertEqual(error_text(await asyncio.wait_for(task, 5)), (True, BAD))


if __name__ == "__main__":
    unittest.main()
