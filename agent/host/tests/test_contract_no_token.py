"""contract-config fails closed with one fixed, token-free frame when fd 3 holds no usable token (MS6.3 follow-up;
BlueBeaver 7522: with no fd 3 it raised an uncaught OSError (EBADF) before its try, so the run ended in a traceback
naming the agent-host's paths, and the MS6.3 hard-gate's no-channel row could only assert rc != 0).

Like the chat helper (chat.py: `error` frame, code "auth", message "no usable token", exit 2), contract-config, given
- no fd 3 at all,
- fd 3 a socketpair end holding a token of the wrong shape (too short),
- fd 3 holding a non-ASCII token,
- fd 3 holding more than the largest token,
writes exactly ONE frame and nothing else on stdout, the whole object being (no extra key)
`{"v": 1, "seq": 1, "type": "error", "session": "contract", "code": "auth", "message": "no usable token"}`,
nothing on stderr (no traceback), exits 2, and creates no token FIFO directory: nothing after the read runs. A planted
token-shaped canary in the bad inputs never appears in its output.
No signal is sent (subprocess.run with a bound; each run ends by itself). It needs the pinned agent-host interpreter
(tools/agent_host_env.sh --check; a bare system python fails earlier, on claude_agent_sdk). Run inside a PID namespace:
  cd agent/host/tests && unshare --map-current-user --pid --fork --kill-child --mount-proc \\
    sh -c 'setsid -w "$ZB_AGENT_HOST_PYTHON" -X dev -m unittest -v test_contract_no_token; exit $?'
Unregistered until the green."""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parents[1]
CANARY = "ZBCANARY" + "q7x2" * 3  # inside the "too short"/"oversized" inputs, never echoed
FRAME = {"v": 1, "seq": 1, "type": "error", "session": "contract", "code": "auth", "message": "no usable token"}
PLACE_FD3 = 'fd=$1; shift; [ "$fd" -eq 3 ] || eval "exec 3<&$fd $fd<&-"; exec "$@"'


class NoUsableToken(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="zb-contract-notoken-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.fifo_dir = self.tmp / "fifo"

    def run_contract(self, token_bytes):
        """contract-config with `token_bytes` on fd 3 (a socketpair end), or with no fd 3 when None."""
        command = [sys.executable, "-m", "zb_agent_host", "contract-config", "--home", str(self.tmp / "home"),
                   "--base-url", "http://127.0.0.1:9", "--fifo-dir", str(self.fifo_dir), "--prompt", "hi"]
        env = {"PATH": "/usr/bin:/bin", "PYTHONPATH": str(HOST_DIR), "PYTHONDONTWRITEBYTECODE": "1"}
        if token_bytes is None:
            return subprocess.run(command, env=env, capture_output=True, text=True, timeout=60)
        ours, theirs = socket.socketpair()
        try:
            try:
                ours.sendall(token_bytes)
            finally:
                ours.close()
            return subprocess.run(["/bin/sh", "-c", PLACE_FD3, "sh", str(theirs.fileno()), *command], env=env,
                                  pass_fds=(theirs.fileno(),), capture_output=True, text=True, timeout=60)
        finally:
            theirs.close()

    def check(self, token_bytes):
        done = self.run_contract(token_bytes)
        frames = [json.loads(line) for line in done.stdout.splitlines()]
        # The COMPLETE output (RoseCat 7692): one whole protocol object, no extra key (no detail, path or value).
        self.assertEqual(frames, [FRAME], done.stdout + done.stderr)
        self.assertEqual(done.stderr, "", "a traceback (or anything) on stderr")
        self.assertEqual(done.returncode, 2)
        self.assertFalse(self.fifo_dir.exists(), "something after the token read ran")
        self.assertNotIn(CANARY, done.stdout + done.stderr)

    def test_no_fd_3(self):
        self.check(None)

    def test_a_token_of_the_wrong_shape(self):
        self.check(b"short")

    def test_a_non_ascii_token(self):
        self.check(("é" + CANARY).encode())

    def test_more_than_the_largest_token(self):
        self.check((CANARY * 100).encode())


if __name__ == "__main__":
    unittest.main()
