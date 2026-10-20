"""S5d fix-forward (RoseCat 6307 item 3): `fit_message` sizes the exact frame the helper
emits, `prompt_id` included. Before, it sized an envelope without the id, so a message
that fit its check could become a line over the app's 256 KiB cap once the id was added,
and the app's reader would reject it.

Pure unit checks of `zb_agent_host.chat.fit_message`: no CLI, no sandbox. Run the module
alone, as the gate does."""

import inspect
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from zb_agent_host import chat  # noqa: E402
from zb_agent_host.frames import encode  # noqa: E402

MAX_ID = (1 << 53) - 1


def fit(session, text, prompt_id):
    if "prompt_id" in inspect.signature(chat.fit_message).parameters:
        return chat.fit_message(session, text, prompt_id=prompt_id)
    return chat.fit_message(session, text)  # red: the id is not sized


def line(session, text, prompt_id):
    """The production frame, at the largest seq the helper can give."""
    return encode({"v": 1, "seq": 2**53, "type": "assistant_message", "session": session,
                   "prompt_id": prompt_id, "text": text}).encode()


class FitTest(unittest.TestCase):
    def test_a_message_that_fits_only_without_the_id_is_cut_to_fit_with_it(self):
        session = "s-99-99"
        empty = len(encode({"v": 1, "seq": 2**53, "type": "assistant_message", "session": session, "text": ""}).encode())
        text = "a" * (chat.FRAME_MAX - empty)  # fills the line exactly, without the id
        self.assertLessEqual(len(text.encode()), chat.MESSAGE_TEXT_MAX)
        for prompt_id in (1, MAX_ID):
            with self.subTest(prompt_id=prompt_id):
                fitted = fit(session, text, prompt_id)
                self.assertLessEqual(len(line(session, fitted, prompt_id)), chat.FRAME_MAX,
                                     "the emitted line fits the app's frame cap")
                self.assertTrue(fitted.endswith(chat.TRUNCATED), fitted[-30:])
                kept = fitted[:-len(chat.TRUNCATED)]
                more = text[:len(kept) + 1] + chat.TRUNCATED
                self.assertGreater(len(line(session, more, prompt_id)), chat.FRAME_MAX, "maximal")

    def test_a_message_that_fits_with_the_id_is_whole(self):
        session = "s-1-1"
        text = "hello " * 100
        self.assertEqual(fit(session, text, MAX_ID), text)


if __name__ == "__main__":
    unittest.main()
