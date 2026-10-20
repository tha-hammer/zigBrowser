"""S5c-2 (chat-drawer plan S5.7, rev 16.20.2 to 16.20.8, approved 9868a65): the transcript
scrub, driven directly. No CLI, no thread: the test calls the scrubber's census and its
lifecycle scans itself, with an injectable file layer and an injected clock.

The API this pins (agent/host/zb_agent_host/redact.py):
- `Scrubber(home, token, files=Files(), clock=Clock())`, where `home` is the agent home
  (transcripts are `state/projects/<ws>/<id>.jsonl` under it) and `token` the fd-3 token.
- `poll()`: one monitor census, paced, serving any posted lifecycle request at a chunk
  boundary. `scan(kind)`: a lifecycle scan (`"prompt_end"`, `"close"` or `"start"`), run
  now. `post(kind)`: a lifecycle request for the next quantum boundary; its `.done` and
  `.error` say how it ended. Each raises or records `ScrubFailed` on a failure.
- `Files`: `open_root(path)`, `openat(dirfd, name, flags)`, `scandir(fd)`, `fstat(fd)`,
  `pread(fd, n, offset)`, `pwrite(fd, data, offset)`, `fsync(fd)`, `close(fd)`.
- `Clock`: `monotonic()`, `sleep(seconds)`.
- `SCRUB_POLL_S`, `SCRUB_CHUNK`, `SCRUB_RATE_BYTES_PER_S`, `SCRUB_LIFECYCLE_TRIES`, `GENERIC`.

Run the module alone, as the gate does."""

import hashlib
import os
import re
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

TOKEN = "sk-ant-oat01-" + "Zq9_-" * 8 + "Ab"  # the fd-3 token: the setup-token shape
OTHER = "sk-ant-api03-" + "x7Y_" * 6  # another Anthropic credential: the generic shape
HEX64 = "9f" * 32
MIB = 1 << 20


def redact():
    from zb_agent_host import redact as module  # red: the module does not exist yet
    return module


def record(text: str) -> bytes:
    return ('{"type":"system","error":{"message":"' + text + '"}}\n').encode()


class FakeClock:
    def __init__(self):
        self.now = 1000.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += max(0.0, seconds)


def counting_files(module, clock, on_pread=None):
    """A real file layer that logs every pread (time, fd, n, offset) and can run a hook."""
    class Counting(module.Files):
        def __init__(self):
            super().__init__()
            self.reads = []

        def pread(self, fd, n, offset):
            self.reads.append((clock.monotonic(), fd, n, offset))
            if on_pread is not None:
                on_pread(self, fd, n, offset)
            return super().pread(fd, n, offset)
    return Counting()


class Home:
    """An agent home with one workspace; files are written as the CLI would."""

    def __init__(self, tc):
        box = tempfile.TemporaryDirectory(prefix="zb-redact-")
        tc.addCleanup(box.cleanup)
        self.root = Path(box.name)
        self.ws = self.root / "state" / "projects" / "-workspace"
        self.ws.mkdir(parents=True)

    def write(self, name: str, data: bytes) -> Path:
        path = self.ws / name
        path.write_bytes(data)
        return path

    def append(self, name: str, data: bytes) -> None:
        with open(self.ws / name, "ab") as f:
            f.write(data)


class Base(unittest.TestCase):
    def setUp(self):
        self.r = redact()
        self.home = Home(self)
        self.clock = FakeClock()

    def scrubber(self, files=None, token=TOKEN):
        return self.r.Scrubber(str(self.home.root), token, files=files or self.r.Files(), clock=self.clock)

    def assert_masked(self, path: Path, before: bytes, spans: list[tuple[int, int]]) -> None:
        """Exactly `spans` became `*` (same length); every other byte is unchanged."""
        after = path.read_bytes()
        self.assertEqual(len(after), len(before), "the length is unchanged")
        want = bytearray(before)
        for start, end in spans:
            want[start:end] = b"*" * (end - start)
        self.assertEqual(after, bytes(want), self.diff(before, after))

    @staticmethod
    def diff(before: bytes, after: bytes) -> str:
        changed = [i for i, (x, y) in enumerate(zip(before, after)) if x != y]
        return f"{len(changed)} bytes changed, first {changed[:3]}, sha {hashlib.sha256(after).hexdigest()[:12]}"

    def spans(self, data: bytes, *needles: str) -> list[tuple[int, int]]:
        out = []
        for needle in needles:
            for m in re.finditer(re.escape(needle.encode()), data):
                out.append((m.start(), m.end()))
        return out


class RuleTest(Base):
    def test_the_exact_token_and_the_generic_shape_are_masked_in_place(self):
        data = record("bad key " + TOKEN + " then") + record("other " + OTHER + ".")
        path = self.home.write("a.jsonl", data)
        self.scrubber().scan("prompt_end")
        self.assert_masked(path, data, self.spans(data, TOKEN, OTHER))

    def test_no_false_hits_on_hashes_and_normal_text(self):
        data = (record(HEX64) + record("sk-ant- is a prefix, sk-ant-x-short and sk-live-" + "a" * 30)
                + record("Bearer " + HEX64 + " and ordinary words"))
        path = self.home.write("a.jsonl", data)
        self.scrubber().scan("prompt_end")
        self.assertEqual(path.read_bytes(), data)

    def test_generic_needs_its_whole_shape(self):
        self.assertIsNone(re.fullmatch(self.r.GENERIC, "sk-ant-api03-" + "a" * 19))
        self.assertIsNotNone(re.fullmatch(self.r.GENERIC, "sk-ant-api03-" + "a" * 20))
        self.assertIsNone(re.fullmatch(self.r.GENERIC, "sk-ant-" + "a" * 11 + "-" + "a" * 30))


class ChunkTest(Base):
    def test_an_exact_token_and_a_generic_match_straddling_a_chunk_edge_are_masked(self):
        chunk = self.r.SCRUB_CHUNK
        for needle in (TOKEN, OTHER):
            with self.subTest(needle=needle[:12]):
                head = b"x" * (chunk - 10)
                data = head + needle.encode() + b'"}\n'
                path = self.home.write("edge.jsonl", data)
                self.scrubber().scan("prompt_end")
                self.assert_masked(path, data, [(len(head), len(head) + len(needle))])

    def test_a_partial_prefix_ending_one_chunk_is_completed_by_the_next(self):
        chunk = self.r.SCRUB_CHUNK
        head = b"y" * (chunk - 4)  # "sk-a" ends the first chunk
        data = head + OTHER.encode() + b" end\n"
        path = self.home.write("prefix.jsonl", data)
        self.scrubber().scan("prompt_end")
        self.assert_masked(path, data, [(len(head), len(head) + len(OTHER))])


class StarTest(Base):
    def test_ordinary_star_runs_stay_byte_identical_at_every_scan_point(self):
        for tail in (b"\n", b""):
            data = record("********documentation and **word") + b"********documentation" + tail
            path = self.home.write("stars.jsonl", data)
            s = self.scrubber()
            s.poll()
            for kind in ("prompt_end", "close", "start"):
                s.scan(kind)
            self.assertEqual(path.read_bytes(), data, tail)

    def test_star_text_written_where_a_mask_was_stays_as_written(self):
        data = record("leak " + OTHER + " here")
        path = self.home.write("a.jsonl", data)
        s = self.scrubber()
        s.scan("prompt_end")
        masked_at = data.index(OTHER.encode())
        regrown = data[:masked_at] + b"*" * 8 + b"docs" + b"z" * (len(OTHER) - 12) + data[masked_at + len(OTHER):]
        with open(path, "r+b") as f:  # same inode: truncate and regrow
            f.truncate(0)
            f.write(regrown)
        s.poll()
        s.scan("close")
        self.assertEqual(path.read_bytes(), regrown)


class TailTest(Base):
    def test_our_token_in_a_final_line_with_no_newline_is_masked_by_the_monitor(self):
        data = record("ok") + b'{"t":"' + TOKEN.encode()
        path = self.home.write("a.jsonl", data)
        self.scrubber().poll()
        self.assert_masked(path, data, self.spans(data, TOKEN))

    def test_a_generic_match_at_the_end_is_left_by_the_monitor_and_masked_by_each_lifecycle_scan(self):
        for kind in ("prompt_end", "close", "start"):
            with self.subTest(kind=kind):
                data = record("ok") + b'{"t":"' + OTHER.encode()
                path = self.home.write("tail.jsonl", data)
                s = self.scrubber()
                for _ in range(3):
                    s.poll()
                    self.clock.sleep(self.r.SCRUB_POLL_S)
                self.assertEqual(path.read_bytes(), data, "the monitor writes nothing at an open candidate")
                s.scan(kind)
                self.assert_masked(path, data, self.spans(data, OTHER))

    def test_a_file_whose_scan_left_a_candidate_is_scanned_again_by_the_next_census(self):
        files = counting_files(self.r, self.clock)
        self.home.write("tail.jsonl", record("ok") + b'{"t":"' + OTHER.encode())
        s = self.scrubber(files)
        s.poll()
        first = len(files.reads)
        self.clock.sleep(self.r.SCRUB_POLL_S)
        s.poll()
        self.assertGreater(len(files.reads), first, "the key was not committed, so the file is read again")

    def test_lifecycle_scans_read_every_file_whatever_the_keys(self):
        files = counting_files(self.r, self.clock)
        self.home.write("a.jsonl", record("clean"))
        self.home.write("b.jsonl", record("clean too"))
        s = self.scrubber(files)
        s.poll()
        before = len(files.reads)
        s.scan("close")
        read = {fd for _t, fd, _n, off in files.reads[before:] if off == 0}
        self.assertEqual(len(read), 2, files.reads[before:])


class ChangeKeyTest(Base):
    def scanned_clean(self, data: bytes) -> tuple[Path, object]:
        path = self.home.write("a.jsonl", data)
        s = self.scrubber()
        s.poll()
        return path, s

    def test_truncate_and_regrow_to_exactly_the_prior_size_is_rescanned(self):
        data = record("a" * len(OTHER) + " pad")
        path, s = self.scanned_clean(data)
        regrown = record(OTHER + " pad")
        self.assertEqual(len(regrown), len(data))
        st = os.stat(path)
        with open(path, "r+b") as f:
            f.truncate(0)
            f.write(regrown)
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + 1))  # only the mtime and ctime move
        self.clock.sleep(self.r.SCRUB_POLL_S)
        s.poll()
        self.assert_masked(path, regrown, self.spans(regrown, OTHER))

    def test_an_in_place_rewrite_with_its_old_mtime_restored_is_rescanned(self):
        data = record("b" * len(OTHER) + " pad")
        path, s = self.scanned_clean(data)
        st = os.stat(path)
        regrown = record(OTHER + " pad")
        with open(path, "r+b") as f:
            f.write(regrown)
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))  # the ctime still moved
        self.clock.sleep(self.r.SCRUB_POLL_S)
        s.poll()
        self.assert_masked(path, regrown, self.spans(regrown, OTHER))

    def test_a_replaced_file_is_rescanned_whole(self):
        path, s = self.scanned_clean(record("clean"))
        fresh = record("now " + OTHER)
        tmp = self.home.ws / "a.jsonl.new"
        tmp.write_bytes(fresh)
        os.replace(tmp, path)
        self.clock.sleep(self.r.SCRUB_POLL_S)
        s.poll()
        self.assert_masked(path, fresh, self.spans(fresh, OTHER))

    def test_a_replaced_projects_directory_is_walked_again(self):
        _path, s = self.scanned_clean(record("clean"))
        projects = self.home.root / "state" / "projects"
        projects.rename(self.home.root / "state" / "projects.old")
        (projects / "-workspace").mkdir(parents=True)
        fresh = record("now " + TOKEN)
        new = projects / "-workspace" / "a.jsonl"
        new.write_bytes(fresh)
        self.clock.sleep(self.r.SCRUB_POLL_S)
        s.poll()
        self.assert_masked(new, fresh, self.spans(fresh, TOKEN))


class IdentityTest(Base):
    def test_a_symlinked_transcript_and_a_fifo_fail(self):
        outside = Path(tempfile.mkdtemp(prefix="zb-redact-outside-"))
        self.addCleanup(shutil.rmtree, outside)
        canary = outside / "canary.jsonl"
        canary.write_bytes(record(TOKEN))
        (self.home.ws / "link.jsonl").symlink_to(canary)
        with self.assertRaises(self.r.ScrubFailed):
            self.scrubber().scan("start")
        self.assertEqual(canary.read_bytes(), record(TOKEN))
        (self.home.ws / "link.jsonl").unlink()
        os.mkfifo(self.home.ws / "pipe.jsonl")
        with self.assertRaises(self.r.ScrubFailed):  # and never blocks on the FIFO
            self.scrubber().scan("start")

    def test_a_symlink_at_any_component_of_the_path_fails_closed(self):
        for component in ("state", "projects", "-workspace"):
            with self.subTest(component=component):
                home = Home(self)
                outside = Path(tempfile.mkdtemp(prefix="zb-redact-outside-"))
                self.addCleanup(shutil.rmtree, outside)
                (outside / "projects" / "-workspace").mkdir(parents=True)
                canary_bytes = record(TOKEN)
                target = {"state": outside, "projects": outside / "projects",
                          "-workspace": outside / "projects" / "-workspace"}[component]
                (outside / "projects" / "-workspace" / "c.jsonl").write_bytes(canary_bytes)
                where = {"state": home.root / "state", "projects": home.root / "state" / "projects",
                         "-workspace": home.ws}[component]
                shutil.rmtree(where)
                where.symlink_to(target)
                s = self.r.Scrubber(str(home.root), TOKEN, files=self.r.Files(), clock=self.clock)
                with self.assertRaises(self.r.ScrubFailed):
                    s.scan("start")
                self.assertEqual((outside / "projects" / "-workspace" / "c.jsonl").read_bytes(), canary_bytes)

    def test_no_projects_yet_and_a_vanished_file_are_not_failures(self):
        shutil.rmtree(self.home.root / "state" / "projects")
        self.scrubber().scan("start")


class FaultTest(Base):
    def faulty(self, name, effect):
        base = self.r.Files

        class Faulty(base):
            pass

        real = getattr(base, name)

        def call(self_, *args):
            if effect == "short":
                fd, data, offset = args
                return real(self_, fd, data[: max(0, len(data) - 1)], offset)
            raise OSError(5, f"injected {name} failure")
        setattr(Faulty, name, call)
        return Faulty()

    def test_each_injected_fault_fails_the_lifecycle_scan_and_the_census(self):
        for name, effect in (("openat", "fail"), ("fstat", "fail"), ("pread", "fail"), ("pwrite", "short"),
                             ("pwrite", "fail"), ("fsync", "fail")):
            with self.subTest(call=name, effect=effect):
                self.home.write("a.jsonl", record("leak " + TOKEN))
                with self.assertRaises(self.r.ScrubFailed):
                    self.scrubber(self.faulty(name, effect)).scan("prompt_end")
                self.home.write("a.jsonl", record("leak " + TOKEN))
                with self.assertRaises(self.r.ScrubFailed):
                    self.scrubber(self.faulty(name, effect)).poll()

    def test_a_short_pread_ends_a_monitor_scan_without_a_failure_and_the_next_census_rescans(self):
        r = self.r
        data = b"q" * (2 * r.SCRUB_CHUNK) + TOKEN.encode() + b"\n"
        path = self.home.write("big.jsonl", data)
        calls = {"n": 0}

        class Short(r.Files):
            def pread(self_, fd, n, offset):
                calls["n"] += 1
                got = super().pread(fd, n, offset)
                return got[: len(got) // 2] if calls["n"] == 1 else got
        s = self.scrubber(Short())
        s.poll()  # no failure
        self.clock.sleep(r.SCRUB_POLL_S)
        s.poll()
        self.assert_masked(path, data, self.spans(data, TOKEN))

    def test_a_short_pread_makes_a_lifecycle_scan_start_again_never_succeed_on_that_pass(self):
        r = self.r
        data = record("leak " + TOKEN)
        path = self.home.write("a.jsonl", data)
        passes = {"short": 0}

        class ShortOnce(r.Files):
            def pread(self_, fd, n, offset):
                got = super().pread(fd, n, offset)
                if passes["short"] == 0 and len(got) > 4:
                    passes["short"] += 1
                    return got[:4]
                return got
        self.scrubber(ShortOnce()).scan("prompt_end")
        self.assertEqual(passes["short"], 1)
        self.assert_masked(path, data, self.spans(data, TOKEN))


class RevalidationTest(Base):
    def test_a_transcript_swapped_during_a_lifecycle_scan_is_masked_before_it_answers(self):
        r = self.r
        ws = self.home.ws
        self.home.write("a.jsonl", record("clean"))
        swapped = {"done": False}

        class Swap(r.Files):
            def pread(self_, fd, n, offset):
                got = super().pread(fd, n, offset)
                if not swapped["done"]:
                    swapped["done"] = True
                    (ws / "a.new").write_bytes(record("late " + TOKEN))
                    os.replace(ws / "a.new", ws / "a.jsonl")
                return got
        self.scrubber(Swap()).scan("close")
        data = (ws / "a.jsonl").read_bytes()
        self.assertNotIn(TOKEN.encode(), data)

    def test_a_tree_that_keeps_changing_fails_closed_after_the_named_tries(self):
        r = self.r
        ws = self.home.ws
        self.home.write("a.jsonl", record("clean"))
        passes = {"n": 0}

        class Churn(r.Files):
            def pread(self_, fd, n, offset):
                passes["n"] += 1
                (ws / f"churn-{passes['n']}.jsonl").write_bytes(record("x"))
                return super().pread(fd, n, offset)
        with self.assertRaises(r.ScrubFailed):
            self.scrubber(Churn()).scan("close")
        self.assertEqual(r.SCRUB_LIFECYCLE_TRIES, 3)


class PaceTest(Base):
    def test_the_monitor_reads_at_most_the_named_rate_and_one_chunk_at_a_time(self):
        r = self.r
        path = self.home.ws / "huge.jsonl"
        with open(path, "wb") as f:  # sparse: no RAM on tmpfs
            f.truncate(100 * MIB)
        files = counting_files(r, self.clock)
        s = self.scrubber(files)
        for _ in range(8):
            with open(path, "r+b") as f:  # changed at every census
                f.seek(0)
                f.write(os.urandom(8))
            s.poll()
            self.clock.sleep(r.SCRUB_POLL_S)
        self.assertTrue(files.reads)
        self.assertLessEqual(max(n for _t, _fd, n, _o in files.reads), r.SCRUB_CHUNK)
        times = [t for t, _fd, _n, _o in files.reads]
        for i, start in enumerate(times):
            window = sum(n for t, _fd, n, _o in files.reads[i:] if t < start + 1.0)
            self.assertLessEqual(window, r.SCRUB_RATE_BYTES_PER_S + r.SCRUB_CHUNK, f"the window from {start:.2f}")

    def test_a_lifecycle_request_posted_mid_scan_starts_at_the_next_chunk_boundary(self):
        r = self.r
        path = self.home.ws / "huge.jsonl"
        with open(path, "wb") as f:
            f.truncate(16 * MIB)
        self.home.write("small.jsonl", record("leak " + TOKEN))
        posted = {}

        def hook(files, fd, n, offset):
            if len(files.reads) == 3 and "request" not in posted:
                posted["request"] = s.post("close")
                posted["at"] = len(files.reads)
        files = counting_files(r, self.clock, hook)
        s = self.scrubber(files)
        s.poll()
        self.assertIn("request", posted)
        self.assertTrue(posted["request"].done, "the request ran within the census")
        self.assertIsNone(posted["request"].error)
        nxt = files.reads[posted["at"]]
        self.assertEqual(nxt[3], 0, "the read after the posting is the lifecycle scan's first, from offset 0")
        self.assertNotIn(TOKEN.encode(), (self.home.ws / "small.jsonl").read_bytes())


if __name__ == "__main__":
    unittest.main()
