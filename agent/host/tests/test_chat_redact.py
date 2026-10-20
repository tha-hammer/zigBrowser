"""S5c-2 (chat-drawer plan S5.7, rev 16.20.2 to 16.20.8, approved 9868a65): the transcript
scrub in the running helper, with the real CLI against a fake Messages API whose errors
echo the request's credentials, as the real server's do. The CLI saves that body in its
transcript (`projects/<ws>/<id>.jsonl` in its config directory: in the sandbox `.claude`,
whose `projects` is the bind of `state/projects`; this unsandboxed helper's CLI writes
through the `.claude` link); the helper must mask it:
- (a) before a prompt's ending frame; (b) by its monitor, within about a second, while
  the session idles; (c) when a session closes, before `session_ended`; (d) at start,
  before `ready`. A failure on the way to a transcript fails closed: exit 3, and at a
  prompt's end an `error sdk` instead of `result`; no `session_ended` and no later frame.

These drive `python -m zb_agent_host chat` (test_chat's Helper); run the module alone, as
the gate does. Large planted files are sparse (no RAM on tmpfs); run under capped.sh."""

import contextlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_chat import CANARY, HOST_DIR, FakeAnthropicApi, Helper, net_dir, provisioned  # noqa: E402

OTHER = "sk-ant-api03-" + "x7Y_" * 6  # another Anthropic credential: the generic shape
MIB = 1 << 20


def echo(entry, index):
    """A 401 whose body echoes every request header, the credential included."""
    said = " ".join(f"{k}={v}" for k, v in sorted((entry.get("headers") or {}).items()))
    if "error" in str(entry.get("body")):
        return {"status": 401, "body": {"type": "error", "error": {"type": "authentication_error", "message": said}}}
    return {"text": "a reply"}


class Base(unittest.TestCase):
    def start(self, box=None, responder=echo, prelude=None):
        self.box = box or provisioned(self)
        self.api = FakeAnthropicApi(responder=responder).start()
        self.addCleanup(self.api.stop)
        self.h = Helper(self, self.box.home, prelude=prelude)
        return self.h

    def hello_and_open(self, h=None):
        h = h or self.h
        self.assertEqual(h.frame()["type"], "ready")
        h.send("hello", agent_home=str(self.box.home.root), workspace=str(self.box.home.workspace),
               scratchpad=str(self.box.home.scratchpad), route="R1", e2e={"test_base_url": self.api.base_url})
        h.send("open_session", session="s-1-1", window_id="window-1")
        h.until("session_opened")

    def prompt(self, text, prompt_id, timeout=120):
        self.h.send("prompt", session="s-1-1", prompt_id=prompt_id, text=text)
        frames = []
        while not any(f["type"] in ("result", "error") for f in frames):
            frames.append(self.h.frame(timeout))
        return frames

    @property
    def projects(self) -> Path:
        return Path(os.path.realpath(self.box.home.claude_dir)) / "projects"

    def transcripts(self) -> list[Path]:
        return sorted(self.projects.glob("*/*.jsonl")) if self.projects.is_dir() else []

    def holding(self, needle: str) -> list[str]:
        return [str(p) for p in self.transcripts() if needle.encode() in p.read_bytes()]

    def clean_within(self, needle: str, seconds: float) -> bool:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not self.holding(needle):
                return True
            time.sleep(0.05)
        return not self.holding(needle)

    def plant(self, data: bytes, ws: str = "-planted", name: str = "planted.jsonl") -> Path:
        path = self.projects / ws / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def exits_3_with_no_later_frame(self, frames_before=()):
        rest = self.h.rest(quiet=5.0)
        code = self.h.proc.wait(timeout=30)
        self.assertEqual(code, 3, (rest[-3:], self.h.proc.stderr.read()[-500:]))
        self.assertNotIn("session_ended", [f["type"] for f in [*frames_before, *rest]])
        return rest


class OrderTest(Base):
    def test_no_transcript_holds_the_token_when_the_ending_frame_arrives(self):
        self.start()
        self.hello_and_open()
        frames = self.prompt("make an error", 1)
        self.assertEqual(frames[-1]["type"], "error", frames[-1])
        self.assertTrue(self.transcripts(), "the CLI saved a transcript")
        self.assertEqual(self.holding(CANARY), [], "scrubbed before the ending frame")

    def test_a_token_line_written_after_the_end_is_masked_within_a_second(self):
        self.start()
        self.hello_and_open()
        self.prompt("hello", 1)
        path = self.transcripts()[-1]
        with open(path, "ab") as f:
            f.write(b'{"late":"' + CANARY.encode() + b'"}\n')
        self.assertTrue(self.clean_within(CANARY, 1.0), self.holding(CANARY))

    def test_our_token_as_a_final_line_with_no_newline_is_masked_within_a_second(self):
        self.start()
        self.hello_and_open()
        self.prompt("hello", 1)
        with open(self.transcripts()[-1], "ab") as f:
            f.write(b'{"tail":"' + CANARY.encode())
        self.assertTrue(self.clean_within(CANARY, 1.0), self.holding(CANARY))

    def test_a_replaced_projects_directory_is_masked_and_the_next_end_waits_for_it(self):
        self.start()
        self.hello_and_open()
        self.prompt("hello", 1)
        self.projects.rename(self.projects.parent / "projects.old")
        planted = self.plant(b'{"x":"' + CANARY.encode() + b'"}\n')
        self.assertTrue(self.clean_within(CANARY, 1.0), self.holding(CANARY))
        frames = self.prompt("hello again", 2)
        self.assertEqual(frames[-1]["type"], "result")
        self.assertNotIn(CANARY.encode(), planted.read_bytes())

    def test_a_large_transcript_truncated_during_a_scan_and_regrown_is_masked(self):
        self.start()
        self.hello_and_open()
        big = self.plant(b"", name="big.jsonl")
        with open(big, "r+b") as f:
            f.truncate(256 * MIB)  # sparse: a paced scan takes about 4 s
        time.sleep(1.0)  # the monitor is inside it
        with open(big, "r+b") as f:
            f.truncate(0)
            f.write(b'{"x":"' + OTHER.encode() + b'"}\n')
        self.assertTrue(self.clean_within(OTHER, 6.0), self.holding(OTHER))
        self.assertIsNone(self.h.proc.poll(), "no crash")


class StartTest(Base):
    def test_crash_residue_with_no_newline_is_clean_by_ready(self):
        box = provisioned(self)
        self.box = box
        planted = self.plant(b'{"ok":1}\n{"t":"' + CANARY.encode())
        self.start(box)
        self.assertEqual(self.h.frame()["type"], "ready")
        self.assertNotIn(CANARY.encode(), planted.read_bytes())

    def test_an_outside_symlink_exits_3_before_ready_and_leaves_the_outside_untouched(self):
        box = provisioned(self)
        self.box = box
        outside = Path(tempfile.mkdtemp(prefix="zb-redact-outside-"))
        self.addCleanup(shutil.rmtree, outside)
        canary = outside / "canary.jsonl"
        canary.write_bytes(b'{"x":"' + CANARY.encode() + b'"}\n')
        self.projects.mkdir(parents=True, exist_ok=True)
        (self.projects / "-outside").symlink_to(outside)
        self.start(box)
        frames = self.h.rest(quiet=10.0)
        self.assertEqual(self.h.proc.wait(timeout=30), 3)
        self.assertNotIn("ready", [f["type"] for f in frames])
        self.assertEqual(canary.read_bytes(), b'{"x":"' + CANARY.encode() + b'"}\n')

    def test_a_fifo_in_a_transcripts_place_exits_3_before_ready(self):
        box = provisioned(self)
        self.box = box
        self.projects.joinpath("-ws").mkdir(parents=True)
        os.mkfifo(self.projects / "-ws" / "x.jsonl")
        self.start(box)
        frames = self.h.rest(quiet=10.0)
        self.assertEqual(self.h.proc.wait(timeout=30), 3)
        self.assertNotIn("ready", [f["type"] for f in frames])


class FaultTest(Base):
    def fifo_in_place(self):
        path = self.transcripts()[-1]
        path.unlink()
        os.mkfifo(path)

    def test_the_monitor_failing_exits_3_with_no_session_ended(self):
        self.start()
        self.hello_and_open()
        self.prompt("hello", 1)
        self.fifo_in_place()
        self.exits_3_with_no_later_frame()

    def test_end_session_failing_exits_3_with_no_session_ended(self):
        self.start()
        self.hello_and_open()
        self.prompt("hello", 1)
        self.fifo_in_place()
        self.h.send("end_session", session="s-1-1")
        self.exits_3_with_no_later_frame()

    def test_shutdown_failing_exits_3_with_no_session_ended(self):
        self.start()
        self.hello_and_open()
        self.prompt("hello", 1)
        self.fifo_in_place()
        self.h.send("shutdown")
        self.exits_3_with_no_later_frame()

    def test_a_prompt_end_that_cannot_scrub_never_sends_result(self):
        self.start()
        self.hello_and_open()
        self.prompt("hello", 1)
        os.chmod(self.transcripts()[-1], 0o444)  # O_RDWR fails: the scrub cannot write
        self.h.send("prompt", session="s-1-1", prompt_id=2, text="hello again")
        rest = self.exits_3_with_no_later_frame()
        self.assertNotIn("result", [f["type"] for f in rest], "never a result")

    def test_a_failing_prompt_end_scan_sends_exactly_its_sdk_error_then_exits_3(self):
        """RoseCat 6379: only the prompt-end scan fails (the monitor never does); the
        prompt's `error sdk` is the last frame, deterministically, then exit 3."""
        self.start(prelude=PROMPT_END_FAILS)
        self.hello_and_open()
        self.h.send("prompt", session="s-1-1", prompt_id=1, text="hello")
        rest = self.exits_3_with_no_later_frame()
        ends = [f for f in rest if f["type"] in ("result", "error")]
        self.assertEqual([(f["type"], f.get("code"), f.get("prompt_id")) for f in ends], [("error", "sdk", 1)], rest[-3:])
        self.assertIs(rest[-1], ends[0], "it is the last frame")

    def test_a_monitor_failure_lets_no_frame_out_while_the_helper_ends(self):
        """RoseCat 6379: the monitor fails while a reply streams, and the helper's end is
        held a second (its /proc walk) while the loop goes on: no frame follows the
        failure's hand-over (its seq, recorded there)."""
        turn = {"deltas": [f"piece {i} " for i in range(100)], "gap_ms": 50}
        self.start(responder=lambda entry, index: turn, prelude=MONITOR_FAILS)
        self.hello_and_open()
        self.h.send("prompt", session="s-1-1", prompt_id=1, text="stream")
        self.h.until("assistant_delta")
        started = descendants(self.h.proc.pid)
        self.assertTrue(started, "the session's CLI runs under the helper")
        (self.box.home.scratchpad / "zb-fail-now").write_text("")
        rest = self.exits_3_with_no_later_frame()
        # RoseCat 6368: the helper's own end killed them, before the harness's cleanup does.
        deadline = time.monotonic() + 5
        while alive(started) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(alive(started), [], "every process the helper started is gone")
        handed = self.box.home.scratchpad / "zb-failed-at-seq"
        self.assertTrue(handed.exists(), "the owner's terminal path ran")
        at = int(handed.read_text())
        later = [f for f in rest if f["seq"] > at]
        self.assertEqual(later, [], f"frames after the failure (seq {at})")


class OwnerStartTest(Base):
    """RoseCat 6440: the start sweep is the owner thread's work like every other scan:
    `ready` waits for it, and its failure takes the one terminal path, once."""

    def scans(self):
        path = self.box.home.scratchpad / "zb-scans"
        return path.read_text().splitlines() if path.exists() else []

    def test_the_start_sweep_runs_on_the_scrub_owner_before_ready(self):
        self.start(prelude=TRACE_START)
        self.assertEqual(self.h.frame()["type"], "ready")
        lines = self.scans()
        self.assertIn("scan start zb-scrub", lines, lines)
        self.assertLess(lines.index("scan start zb-scrub"), lines.index("emit ready"), lines)

    def test_a_start_fault_takes_the_one_terminal_path_once(self):
        self.start(prelude=START_FAILS)
        frames = self.h.rest(quiet=5.0)
        self.assertEqual(self.h.proc.wait(timeout=30), 3)
        self.assertNotIn("ready", [f["type"] for f in frames])
        self.assertEqual(self.scans(), ["handed start"], "the owner's hand-over, exactly once")
        self.assertEqual(self.h.proc.stderr.read(), "zigBrowser: agent: transcript scrub failed\n")


class CliStderrTest(Base):
    """RoseCat 6442 (T6): what the CLI writes to its stderr is drained, never reprinted. A
    stand-in CLI writes a token-shaped canary and control characters to stderr, then
    fails; neither reaches the helper's stderr or any frame."""

    def test_the_clis_stderr_reaches_no_helper_surface(self):
        box = provisioned(self)
        self.box = box
        wrapper = box.home.runtime / "bin" / "zb-claude"
        wrapper.parent.mkdir(parents=True, exist_ok=True)
        with contextlib.suppress(FileNotFoundError):
            wrapper.unlink()
        wrapper.write_text("#!/bin/sh\n: > \"$HOME/scratchpad/zb-cli-ran\"\nprintf 'cli says %s \\033[31m\\nzigBrowser: forged\\n' '" + OTHER
                           + "' >&2\nsleep 1\nexit 1\n")
        wrapper.chmod(0o700)
        self.start(box)
        self.assertEqual(self.h.frame()["type"], "ready")
        self.h.send("hello", agent_home=str(box.home.root), workspace=str(box.home.workspace),
                    scratchpad=str(box.home.scratchpad), route="R1", e2e={"test_base_url": self.api.base_url})
        self.h.send("open_session", session="s-1-1", window_id="window-1")
        frames = self.h.rest(quiet=8.0)
        self.h.send("shutdown")
        frames += self.h.rest(quiet=5.0)
        self.h.proc.wait(timeout=30)
        err = self.h.proc.stderr.read()
        self.assertTrue((box.home.scratchpad / "zb-cli-ran").exists(), "the stand-in CLI ran")
        for needle in (OTHER, "forged", "\x1b"):
            self.assertNotIn(needle, err, "the helper's stderr")
            self.assertNotIn(needle, json.dumps(frames), "a frame")


class SandboxTest(unittest.TestCase):
    """RoseCat 6374: the real chain (launch -> bwrap -> the relay -> chat). In the sandbox the
    host's `state` is not mounted; the CLI's transcripts are at `.claude/projects`, the bind
    of `state/projects`. A token planted there on the host is masked by the start sweep
    before `ready`: the scrub reaches exactly the bytes the CLI writes."""

    def test_the_start_sweep_in_the_sandbox_masks_the_hosts_state_projects(self):
        box = provisioned(self)
        planted = box.home.root / "state" / "projects" / "-workspace" / "left.jsonl"
        planted.parent.mkdir(parents=True, exist_ok=True)
        data = b'{"error":"echo ' + CANARY.encode() + b' end"}\n'
        planted.write_bytes(data)
        read, write = os.pipe()
        os.write(write, CANARY.encode())
        os.close(write)
        move = "" if read == 3 else f"exec 3<&{read} {read}<&-; "
        env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PYTHONPATH": str(HOST_DIR), "PYTHONDONTWRITEBYTECODE": "1"}
        proc = subprocess.Popen(["/bin/sh", "-c", move + 'exec "$0" "$@"', sys.executable, "-m", "zb_agent_host",
                                 "launch", "--home", str(box.home.root), "--python", sys.executable,
                                 "--net-dir", str(net_dir(self))],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                                pass_fds=(read,), text=True, start_new_session=True)
        os.close(read)

        def stop():
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            for stream in (proc.stdin, proc.stdout, proc.stderr):
                stream.close()
        self.addCleanup(stop)
        line = proc.stdout.readline()
        self.assertTrue(line, proc.stderr.read() if proc.poll() is not None else "no ready frame")
        self.assertEqual(json.loads(line)["type"], "ready")
        after = planted.read_bytes()
        self.assertEqual(len(after), len(data))
        self.assertEqual(after, data.replace(CANARY.encode(), b"*" * len(CANARY)), "masked before ready")


def descendants(pid):
    parents = {}
    for entry in os.listdir("/proc"):
        if entry.isdigit():
            try:
                with open(f"/proc/{entry}/stat") as f:
                    parents.setdefault(int(f.read().rsplit(")", 1)[1].split()[1]), []).append(int(entry))
            except (OSError, IndexError, ValueError):
                continue
    found, todo = [], list(parents.get(pid, []))
    while todo:
        found.append(todo.pop())
        todo += parents.get(found[-1], [])
    return found


def alive(pids):
    """The ones still running (a zombie has ended)."""
    out = []
    for pid in pids:
        try:
            with open(f"/proc/{pid}/stat") as f:
                if f.read().rsplit(")", 1)[1].split()[0] != "Z":
                    out.append(pid)
        except OSError:
            continue
    return out


# Fault injection, run in the helper before its module (test_chat.Helper's prelude).
TRACE_START = """
import os, threading
from zb_agent_host import frames, redact
_scan, _emit = redact.Scrubber.scan, frames.Emitter.emit
def note(text):
    with open(os.path.join(os.environ["HOME"], "scratchpad", "zb-scans"), "a") as f:
        f.write(text + "\\n")
def scan(self, kind):
    note(f"scan {kind} {threading.current_thread().name}")
    return _scan(self, kind)
def emit(self, type_, **fields):
    note(f"emit {type_}")
    return _emit(self, type_, **fields)
redact.Scrubber.scan, frames.Emitter.emit = scan, emit
"""
START_FAILS = """
import os
from zb_agent_host import chat, redact
_scan, _handed = redact.Scrubber.scan, chat.Chat.on_scrub_failed
def scan(self, kind):
    if kind == "start":
        raise redact.ScrubFailed("injected start failure")
    return _scan(self, kind)
def handed(self, exc, failed):
    with open(os.path.join(os.environ["HOME"], "scratchpad", "zb-scans"), "a") as f:
        f.write("handed " + ",".join(q.kind for q in failed) + "\\n")
    return _handed(self, exc, failed)
redact.Scrubber.scan, chat.Chat.on_scrub_failed = scan, handed
"""
PROMPT_END_FAILS = """
from zb_agent_host import redact
_scan = redact.Scrubber.scan
def scan(self, kind):
    if kind == "prompt_end":
        raise redact.ScrubFailed("injected prompt-end failure")
    return _scan(self, kind)
redact.Scrubber.scan = scan
"""
MONITOR_FAILS = """
import os, threading, time
from zb_agent_host import frames, redact
_poll, _init, _listdir, _run = redact.Scrubber.poll, frames.Emitter.__init__, os.listdir, redact.Scrubber.run
emitters = []
def mark(seq):
    with open(os.path.join(os.environ["HOME"], "scratchpad", "zb-failed-at-seq"), "w") as f:
        f.write(str(seq))
def init(self, *a, **kw):
    _init(self, *a, **kw)
    emitters.append(self)
def poll(self):
    if os.path.exists(os.path.join(os.environ["HOME"], "scratchpad", "zb-fail-now")):
        raise redact.ScrubFailed("injected monitor failure")
    return _poll(self)
def listdir(path="."):
    if path == "/proc":
        time.sleep(1.0)  # the end is held: the loop still streams
    return _listdir(path)
if hasattr(frames.Emitter, "seal"):  # the failure's hand-over: where the output ends
    _seal = frames.Emitter.seal
    def seal(self, last=()):
        _seal(self, last)
        mark(self._seq)
    frames.Emitter.seal = seal
else:  # no seal: the owner's hand-over itself
    def run(self, on_failure):
        def handed(*a):
            with emitters[0]._lock:
                mark(emitters[0]._seq)
            return on_failure(*a)
        return _run(self, handed)
    redact.Scrubber.run = run
frames.Emitter.__init__, redact.Scrubber.poll, os.listdir = init, poll, listdir
"""


class LivenessTest(Base):
    def test_a_growing_100_mib_transcript_does_not_stall_a_prompt_or_grow_the_helper(self):
        turn = {"deltas": [f"piece {i} " for i in range(80)], "gap_ms": 100}  # about 8 s
        self.start(responder=lambda entry, index: turn)
        self.hello_and_open()
        big = self.plant(b"", name="big.jsonl")
        with open(big, "r+b") as f:
            f.truncate(100 * MIB)

        def rss_kb():
            with open(f"/proc/{self.h.proc.pid}/status") as status:
                for line in status:
                    if line.startswith("VmRSS:"):
                        return int(line.split()[1])
        base = rss_kb()
        started = time.monotonic()
        self.h.send("prompt", session="s-1-1", prompt_id=1, text="stream")
        frames, peak, next_append = [], base, time.monotonic()
        while not any(f["type"] in ("result", "error") for f in frames):
            # It grows while the reply streams (about 8 s) and stops before its end: a file
            # that changes through every pass of the prompt-end scan fails closed (S5.7).
            if time.monotonic() >= next_append and time.monotonic() - started < 5:
                with open(big, "ab") as f:
                    f.truncate(f.seek(0, 2) + MIB)  # 1 MiB more, sparse
                next_append += 0.1
            frames += self.h.rest(quiet=0.05)
            peak = max(peak, rss_kb() or peak)
        took = time.monotonic() - started
        self.assertEqual(frames[-1]["type"], "result", frames[-1])
        self.assertLess(took, 8.0 + 2.0 + 5.0, f"{took:.1f} s")  # normal time + 2 s, + 5 s for the CLI's start
        self.assertLess((peak - base) / 1024, 32, f"RSS grew {(peak - base) / 1024:.1f} MiB")


if __name__ == "__main__":
    unittest.main()
