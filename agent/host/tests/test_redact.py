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
        # ctime has the kernel's coarse clock (a jiffy); a rewrite inside the scan's own tick
        # is a residual the plan states, so this one comes a tick later.
        import time
        time.sleep(0.05)
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
        with self.assertRaises(self.r.ScrubFailed) as failed:  # and never blocks on the FIFO
            self.scrubber().scan("start")
        self.assertIn("not a regular file", str(failed.exception), "the fstat check, before any read")

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
        after_first = calls["n"]
        self.clock.sleep(r.SCRUB_POLL_S)
        s.poll()
        self.assertGreater(calls["n"], after_first, "no key was committed after the short read: read again")
        self.assert_masked(path, data, self.spans(data, TOKEN))

    def test_a_short_pread_makes_a_lifecycle_scan_start_again_never_succeed_on_that_pass(self):
        r = self.r
        data = record("leak " + TOKEN)
        path = self.home.write("a.jsonl", data)
        passes = {"short": 0, "from_zero": 0}

        class ShortOnce(r.Files):
            def pread(self_, fd, n, offset):
                got = super().pread(fd, n, offset)
                passes["from_zero"] += offset == 0
                if passes["short"] == 0 and len(got) > 4:
                    passes["short"] += 1
                    return got[:4]
                return got
        self.scrubber(ShortOnce()).scan("prompt_end")
        self.assertEqual(passes["short"], 1)
        self.assertEqual(passes["from_zero"], 2, "the short read started a second pass from byte 0")
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

        names, first_reads = {}, []

        class Churn(r.Files):
            def openat(self_, dirfd, name, flags):
                fd = super().openat(dirfd, name, flags)
                names[fd] = name
                return fd

            def pread(self_, fd, n, offset):
                passes["n"] += 1
                if names.get(fd) == "a.jsonl" and offset == 0:
                    first_reads.append(fd)  # one per pass: each pass reads a.jsonl from byte 0
                (ws / f"churn-{passes['n']}.jsonl").write_bytes(record("x"))
                return super().pread(fd, n, offset)
        with self.assertRaises(r.ScrubFailed):
            self.scrubber(Churn()).scan("close")
        self.assertEqual(r.SCRUB_LIFECYCLE_TRIES, 3)
        self.assertEqual(len(first_reads), r.SCRUB_LIFECYCLE_TRIES, "exactly the named number of passes")


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


class ReviewTest(Base):
    """RoseCat 6249, 6269, 6280, 6289, 6292 on the first scrubber."""

    def test_a_missing_state_directory_fails_closed(self):
        shutil.rmtree(self.home.root / "state")  # setup always makes it: its absence is not "no transcripts"
        s = self.scrubber()
        with self.assertRaises(self.r.ScrubFailed):
            s.scan("start")
        with self.assertRaises(self.r.ScrubFailed):
            s.poll()

    def test_workspaces_named_state_and_projects_are_scanned_like_any_other(self):
        projects = self.home.root / "state" / "projects"
        for ws in ("state", "projects"):
            (projects / ws).mkdir()
            (projects / ws / "t.jsonl").write_bytes(record(TOKEN))
        s = self.scrubber()
        s.poll()
        st = os.stat(projects)
        self.assertEqual(s.projects_id, (st.st_dev, st.st_ino), "the identity kept is projects', not a workspace's")
        self.clock.sleep(self.r.SCRUB_POLL_S)
        s.poll()
        s.scan("close")
        for ws in ("state", "projects"):
            self.assertNotIn(TOKEN.encode(), (projects / ws / "t.jsonl").read_bytes(), ws)

    def test_open_root_and_scandir_faults_fail_closed(self):
        r = self.r

        class NoRoot(r.Files):
            def open_root(self_, path):
                raise OSError(5, "injected open_root failure")
        with self.assertRaises(r.ScrubFailed):
            r.Scrubber(str(self.home.root), TOKEN, files=NoRoot(), clock=self.clock)

        class NoList(r.Files):
            def scandir(self_, fd):
                raise OSError(5, "injected scandir failure")
        self.home.write("a.jsonl", record("x"))
        with self.assertRaises(r.ScrubFailed):
            self.scrubber(NoList()).scan("close")
        with self.assertRaises(r.ScrubFailed):
            self.scrubber(NoList()).poll()

    def test_an_unexpected_exception_fails_closed_and_answers_a_posted_request(self):
        r = self.r
        self.home.write("a.jsonl", record("x"))

        class Broken(r.Files):
            def pread(self_, fd, n, offset):
                raise ValueError("an unexpected error")
        with self.assertRaises(r.ScrubFailed):
            self.scrubber(Broken()).scan("close")
        s = self.scrubber(Broken())
        request = s.post("close")
        with self.assertRaises(r.ScrubFailed):
            s.poll()
        self.assertTrue(request.done and request.event.is_set(), "the waiter is woken")
        self.assertIsInstance(request.error, r.ScrubFailed)

    def test_a_lifecycle_scan_of_a_file_that_keeps_growing_ends_within_its_passes(self):
        r = self.r
        path = self.home.write("grow.jsonl", b"x" * (2 * r.SCRUB_CHUNK))
        reads = {"n": 0}

        class Grows(r.Files):
            def pread(self_, fd, n, offset):
                reads["n"] += 1
                if reads["n"] > 200:
                    raise AssertionError("the scan chased the growth")
                with open(path, "ab") as f:
                    f.write(b"y" * r.SCRUB_CHUNK)
                return super().pread(fd, n, offset)
        with self.assertRaises(r.ScrubFailed):  # it changed during every pass
            self.scrubber(Grows()).scan("close")
        self.assertLessEqual(reads["n"], r.SCRUB_LIFECYCLE_TRIES * 3, "each pass ends at its snapshot size")

    def test_a_symlinked_home_is_refused_before_anything_is_read(self):
        outside = Path(tempfile.mkdtemp(prefix="zb-redact-outside-"))
        self.addCleanup(shutil.rmtree, outside)
        (outside / "state" / "projects" / "-w").mkdir(parents=True)
        canary = outside / "state" / "projects" / "-w" / "c.jsonl"
        canary.write_bytes(record(TOKEN))
        link = self.home.root.parent / (self.home.root.name + "-link")
        link.symlink_to(outside)
        self.addCleanup(link.unlink)
        with self.assertRaises(self.r.ScrubFailed):
            self.r.Scrubber(str(link), TOKEN, files=self.r.Files(), clock=self.clock).scan("start")
        self.assertEqual(canary.read_bytes(), record(TOKEN))

    def test_a_request_racing_the_owners_failure_gets_it_and_never_waits(self):
        """The interleaving of RoseCat 6280: the requester has looked at `failed` (none yet);
        the owner then fails, answers what is queued and exits; then the requester queues.
        It must get the failure. The owner's census is held until the requester looks."""
        import threading
        r = self.r
        looked, owner_done = threading.Event(), threading.Event()

        class Held(r.Files):
            def openat(self_, dirfd, name, flags):
                looked.wait(5)  # the owner fails only once the requester has looked
                raise OSError(5, "injected census failure")

        class Racy(r.Scrubber):
            @property
            def failed(self_):
                seen = self_.__dict__.get("_failed")  # what the requester observes
                if threading.current_thread().name == "asker" and not looked.is_set():
                    looked.set()
                    owner_done.wait(1)  # with a check-then-enqueue gap, the owner finishes here
                return seen

            @failed.setter
            def failed(self_, value):
                self_.__dict__["_failed"] = value
        s = Racy(str(self.home.root), TOKEN, files=Held(), clock=self.clock)

        def own():
            s.run(lambda exc: None)
            owner_done.set()
        owner = threading.Thread(target=own, daemon=True)
        owner.start()
        result = []

        def ask():
            try:
                s.request("close")
                result.append("clean")
            except r.ScrubFailed:
                result.append("failed")
        asker = threading.Thread(target=ask, name="asker", daemon=True)
        asker.start()
        asker.join(5)
        self.assertFalse(asker.is_alive(), "the request was stranded")
        self.assertEqual(result, ["failed"])

    def test_projects_replaced_during_a_lifecycle_scan_is_scanned_before_it_answers(self):
        r = self.r
        projects = self.home.root / "state" / "projects"
        self.home.write("a.jsonl", record("clean"))
        swapped = {"done": False}

        class Swap(r.Files):
            def pread(self_, fd, n, offset):
                got = super().pread(fd, n, offset)
                if not swapped["done"]:
                    swapped["done"] = True
                    projects.rename(projects.parent / "projects.old")
                    (projects / "-w").mkdir(parents=True)
                    (projects / "-w" / "new.jsonl").write_bytes(record("late " + TOKEN))
                return got
        self.scrubber(Swap()).scan("close")
        self.assertNotIn(TOKEN.encode(), (projects / "-w" / "new.jsonl").read_bytes())

    def test_a_listed_transcript_that_vanishes_before_its_open_is_not_a_failure(self):
        r = self.r
        self.home.write("gone.jsonl", record("x"))
        kept = self.home.write("kept.jsonl", record("leak " + TOKEN))
        ws = self.home.ws

        class Vanish(r.Files):
            def openat(self_, dirfd, name, flags):
                if name == "gone.jsonl" and (ws / name).exists():
                    (ws / name).unlink()
                return super().openat(dirfd, name, flags)
        self.scrubber(Vanish()).scan("close")
        self.assertNotIn(TOKEN.encode(), kept.read_bytes())

    def test_a_same_size_write_into_the_read_region_during_a_scan_is_found_by_the_next_census(self):
        r = self.r
        path = self.home.write("big.jsonl", b"z" * (3 * r.SCRUB_CHUNK) + b"\n")
        writes = {"done": False}

        class Writer(r.Files):
            def pread(self_, fd, n, offset):
                if offset >= r.SCRUB_CHUNK and not writes["done"]:
                    writes["done"] = True
                    with open(path, "r+b") as f:  # same size, into bytes already read
                        f.write(b'{"x":"' + TOKEN.encode() + b'"}')
                return super().pread(fd, n, offset)
        s = self.scrubber(Writer())
        s.poll()
        self.assertTrue(writes["done"])
        self.clock.sleep(r.SCRUB_POLL_S)
        s.poll()
        self.assertNotIn(TOKEN.encode(), path.read_bytes(), "the changed file's key was not committed")

    def test_the_monitor_reads_at_most_exactly_the_named_rate_in_any_one_second(self):
        r = self.r
        path = self.home.ws / "huge.jsonl"
        with open(path, "wb") as f:
            f.truncate(100 * MIB)
        files = counting_files(r, self.clock)
        s = self.scrubber(files)
        for _ in range(6):
            with open(path, "r+b") as f:
                f.seek(0)
                f.write(os.urandom(8))
            s.poll()
            self.clock.sleep(r.SCRUB_POLL_S)
        for i, (start, _fd, _n, _o) in enumerate(files.reads):
            window = sum(n for t, _fd, n, _o in files.reads[i:] if t < start + 1.0)
            self.assertLessEqual(window, r.SCRUB_RATE_BYTES_PER_S, f"the window from {start:.3f}")


if __name__ == "__main__":
    unittest.main()
