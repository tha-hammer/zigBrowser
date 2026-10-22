"""The MS6.3 hard-gate case reads the helper's frames as the helper writes them (11eaceb on both Macs, BlueBeaver 7832).

On both Macs the real helper's turn completed (rc 0, an assistant_message "ok", then a result frame, subtype success,
is_error false), yet the case failed "the helper's turn completes": it looked for the bytes '"type": "result"' (with
a space), while the helper writes compact frames (zb_agent_host/frames.py encode: separators (",", ":")). The fake
staged host of ms6_hard_gate_fd3_cli_case_test wrote the spaced form, so Linux never saw it.

Against the same fake staged host, whose fake helper now writes its frames with the real frames.encode:
- an honest host passes every row (the turn: an assistant_message, then a result frame, success, not an error);
- a result frame that is an error (subtype error_during_execution, is_error true) fails the completion check;
- a turn with no result frame (only the assistant_message) fails the completion check;
- a line that merely contains the result frame's bytes but is not a frame (no JSON object) fails it too.
Run as our own uid in a PID namespace: cd tests/e2e && unshare --map-current-user --pid --fork --kill-child \\
  --mount-proc sh -c 'setsid -w python3 -X dev -m unittest -v ms6_hard_gate_fd3_cli_frames_test; exit $?'
No signal is sent (the base fixture patches os.kill / os.killpg to raise; h.spawn_group is a fake).
Unregistered until the green."""
import importlib.util
import os
import unittest

import ms6_hard_gate_fd3_cli_case_test as base

_spec = importlib.util.spec_from_file_location(
    "zb_frames", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "agent", "host", "zb_agent_host",
                              "frames.py"))
frames = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(frames)  # stdlib only: the helper's own encoder, not a copy

ASSISTANT = {"v": 1, "seq": 1, "type": "assistant_message", "session": "contract", "text": "ok"}
RESULT = {"v": 1, "seq": 2, "type": "result", "session": "contract", "subtype": "success", "is_error": False,
          "num_turns": 1}


def lines(*frs):
    return "".join(frames.encode(f) + "\n" for f in frs).encode()


class CompactFrames(base.FakeStagedHost):
    turn = lines(ASSISTANT, RESULT)

    def fake_run(self, argv, env, pass_fds):
        rc, out, err = super().fake_run(argv, env, pass_fds)
        if rc == 0 and b'"type": "result"' in out:  # the base's spaced stand-in: write what the helper writes
            out = self.turn
        return rc, out, err

    def completes(self, h):
        return [label for ok, label in h.checks if "the helper's turn completes" in label and not ok]

    def test_an_honest_host_writing_compact_frames_passes_every_row(self):
        h = self.run_case()
        self.assertEqual(self.failed(h), [])

    def test_an_error_result_frame_does_not_complete(self):
        self.turn = lines(ASSISTANT, dict(RESULT, subtype="error_during_execution", is_error=True))
        self.assertEqual(len(self.completes(self.run_case())), 2, "positive and decoy must both fail")

    def test_a_turn_without_a_result_frame_does_not_complete(self):
        self.turn = lines(ASSISTANT)
        self.assertEqual(len(self.completes(self.run_case())), 2, "positive and decoy must both fail")

    def test_the_result_bytes_outside_a_frame_do_not_complete(self):
        self.turn = b'not a frame: "type":"result","subtype":"success","is_error":false\n'
        self.assertEqual(len(self.completes(self.run_case())), 2, "positive and decoy must both fail")


def load_tests(loader, tests, pattern):
    """Only this file's own rows: the inherited ones pin the plain fixture."""
    return unittest.TestSuite(CompactFrames(name) for name in (
        "test_an_honest_host_writing_compact_frames_passes_every_row",
        "test_an_error_result_frame_does_not_complete",
        "test_a_turn_without_a_result_frame_does_not_complete",
        "test_the_result_bytes_outside_a_frame_do_not_complete"))


if __name__ == "__main__":
    unittest.main()
