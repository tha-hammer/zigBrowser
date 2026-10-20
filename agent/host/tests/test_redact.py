"""S5c-2 (chat-drawer plan S5.7, rev 16.20.2 to 16.20.8, approved 9868a65): the transcript
scrub, driven directly. No CLI, no thread: the test calls the scrubber's census and its
lifecycle scans itself, with an injectable file layer and an injected clock.

The API this pins (agent/host/zb_agent_host/redact.py):
- `Scrubber(config, token, files=Files(), clock=Clock())`, where `config` is the CLI's
  config directory as the helper sees it (transcripts are `projects/<ws>/<id>.jsonl` under
  it; in the sandbox `.claude`, on the host `state`) and `token` the fd-3 token.
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


def settle():
    """Past the scrubber's SETTLE_NS: a key is committed only for a file whose ctime is
    older, so a test that needs one committed waits this long after writing."""
    import time
    time.sleep(0.08)


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
        self.config = self.root / "state"  # the host's view of the sandbox's .claude
        self.ws = self.config / "projects" / "-workspace"
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
        return self.r.Scrubber(str(self.home.config), token, files=files or self.r.Files(), clock=self.clock)

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


class BoundTest(Base):
    """RoseCat 6381: a generic match's tail has no length limit; masking it must not take
    its whole length at once. Every mask write is at most one SCRUB_CHUNK, and a short
    write is finished, never left half-masked."""

    def writes(self, short=False):
        r, sizes = self.r, []

        class Recording(r.Files):
            def pwrite(self_, fd, data, offset):
                sizes.append(len(data))
                if short and len(data) > 1:
                    data = data[: len(data) // 2]  # the kernel may write less than asked
                return super().pwrite(fd, data, offset)
        return Recording(), sizes

    def test_a_generic_tail_longer_than_a_chunk_is_masked_in_chunk_sized_writes(self):
        chunk = self.r.SCRUB_CHUNK
        needle = b"sk-ant-api03-" + b"A1_-" * ((3 * chunk + 123) // 4)
        data = b'{"m":"' + needle + b'"}\n'
        for short in (False, True):
            with self.subTest(short=short):
                path = self.home.write("long.jsonl", data)
                files, sizes = self.writes(short)
                self.scrubber(files=files).scan("prompt_end")
                self.assert_masked(path, data, [(6, 6 + len(needle))])
                self.assertTrue(sizes, "it wrote")
                self.assertLessEqual(max(sizes), chunk, "no write larger than one chunk")

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
        settle()  # only the open candidate may keep its key uncommitted
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
        settle()
        s = self.scrubber()
        s.poll()
        self.assertIn(("-workspace", "a.jsonl"), s.keys, "the clean, settled file's key is committed")
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
                with self.assertRaises(self.r.ScrubFailed):
                    self.r.Scrubber(str(home.config), TOKEN, files=self.r.Files(), clock=self.clock).scan("start")
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
    def test_a_same_inode_append_during_the_revalidation_walk_is_scanned_before_it_answers(self):
        """RoseCat 6414: the file grows after the scanned fd's own check but while the
        revalidation walk reopens it (same inode, same listing): the walk's full key, not
        only its identity, must send the scan round again."""
        r = self.r
        path = self.home.write("a.jsonl", record("clean"))
        opens = {"n": 0}

        class Grow(r.Files):
            def openat(self_, dirfd, name, flags):
                if name == "a.jsonl":
                    opens["n"] += 1
                    if opens["n"] == 2:  # pass 1's revalidation walk
                        with open(path, "ab") as f:
                            f.write(record("late " + TOKEN))
                return super().openat(dirfd, name, flags)
        self.scrubber(Grow()).scan("prompt_end")
        self.assertGreaterEqual(opens["n"], 3, "the scan went round again")
        self.assertNotIn(TOKEN.encode(), path.read_bytes(), "masked before scan() returned")

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

    def test_a_missing_config_directory_fails_closed(self):
        shutil.rmtree(self.home.config)  # setup always makes it: its absence is not "no transcripts"
        with self.assertRaises(self.r.ScrubFailed):
            self.scrubber()

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
            r.Scrubber(str(self.home.config), TOKEN, files=NoRoot(), clock=self.clock)

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
        s.run(lambda exc, failed: None)  # the owner: its terminal path answers it (RoseCat 6379)
        self.assertTrue(request.done and request.event.is_set(), "the waiter is woken")
        self.assertIsInstance(request.error, r.ScrubFailed)

    def test_a_lifecycle_scan_of_a_file_that_keeps_growing_ends_within_its_passes(self):
        r = self.r
        path = self.home.write("grow.jsonl", b"x" * (2 * r.SCRUB_CHUNK))
        reads = {"n": 0, "passes": 0}

        class Grows(r.Files):
            def pread(self_, fd, n, offset):
                reads["n"] += 1
                reads["passes"] += offset == 0
                if reads["n"] > 200:
                    raise AssertionError("the scan chased the growth")
                with open(path, "ab") as f:
                    f.write(b"y" * r.SCRUB_CHUNK)
                return super().pread(fd, n, offset)
        with self.assertRaises(r.ScrubFailed):  # it changed during every pass
            self.scrubber(Grows()).scan("close")
        self.assertEqual(reads["passes"], r.SCRUB_LIFECYCLE_TRIES, "each pass ends at its snapshot size")

    def test_a_symlinked_home_is_refused_before_anything_is_read(self):
        outside = Path(tempfile.mkdtemp(prefix="zb-redact-outside-"))
        self.addCleanup(shutil.rmtree, outside)
        (outside / "projects" / "-w").mkdir(parents=True)
        canary = outside / "projects" / "-w" / "c.jsonl"
        canary.write_bytes(record(TOKEN))
        link = self.home.root / "config-link"
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
        s = Racy(str(self.home.config), TOKEN, files=Held(), clock=self.clock)

        def own():
            s.run(lambda exc, failed: None)
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

    def same_size_write_during_scan(self, name, wait):
        r = self.r
        path = self.home.write(name, b"z" * (3 * r.SCRUB_CHUNK) + b"\n")
        if wait:
            settle()
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
        return path

    def test_a_same_size_write_into_the_read_region_during_a_scan_is_found_by_the_next_census(self):
        """RoseCat 6292: the key after such a scan is the writer's, never committed."""
        path = self.same_size_write_during_scan("big.jsonl", wait=True)
        self.assertNotIn(TOKEN.encode(), path.read_bytes(), "the changed file's key was not committed")

    def test_a_same_size_write_inside_one_clock_tick_is_found_too(self):
        """The coarse kernel clock: a write in the same tick as the file's last change leaves
        its key as it was, so an unsettled file's key is never committed. Repeated, since a
        tick cannot be forced."""
        for i in range(10):
            path = self.same_size_write_during_scan(f"tick-{i}.jsonl", wait=False)
            self.assertNotIn(TOKEN.encode(), path.read_bytes(), f"run {i}")

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


class TerminalTest(Base):
    """RoseCat 6368: the owner's first lifecycle failure is terminal."""

    def own(self, s):
        """Runs the owner thread until it ends (it must, after a failure)."""
        import threading
        failures = []
        owner = threading.Thread(target=s.run, args=(lambda exc, failed: failures.append((exc, failed)),), daemon=True)
        owner.start()
        owner.join(5)
        self.assertFalse(owner.is_alive(), "the owner went on after a lifecycle failure")
        return failures

    def failing_once(self):
        r = self.r
        state = {"failed": False}

        class FailOnce(r.Files):
            def pread(self_, fd, n, offset):
                if not state["failed"]:
                    state["failed"] = True
                    raise OSError(5, "injected transient failure")
                return super().pread(fd, n, offset)
        return FailOnce()

    def test_after_a_lifecycle_failure_a_queued_request_never_gets_a_clean_answer(self):
        r = self.r
        self.home.write("a.jsonl", record("x"))
        s = self.scrubber(self.failing_once())
        first, second = s.post("prompt_end"), s.post("close")
        failures = self.own(s)
        self.assertIsInstance(first.error, r.ScrubFailed)
        self.assertTrue(second.done, "the queued request is answered")
        self.assertIsInstance(second.error, r.ScrubFailed, "never clean after a failure")
        self.assertEqual(len(failures), 1, "on_failure exactly once")
        with self.assertRaises(r.ScrubFailed):
            s.post("start")  # and nothing later is served

    def test_a_failure_nobody_waits_for_still_ends_the_owner(self):
        """A prompt cancelled while its prompt-end scan runs drops its wait; the scan's
        failure must still reach on_failure (the helper's exit), not vanish."""
        self.home.write("a.jsonl", record("x"))
        s = self.scrubber(self.failing_once())
        s.post("prompt_end")  # nobody waits on it
        failures = self.own(s)
        self.assertEqual(len(failures), 1)

    def test_the_owner_hands_its_failure_and_the_failed_requests_over_before_waking_anyone(self):
        """RoseCat 6379: one terminal path. on_failure gets the failure and every request it
        failed (with its tag, e.g. a prompt's session and id, so that path alone can send
        the prompt's error frame), and it runs before any requester is woken."""
        r = self.r
        self.home.write("a.jsonl", record("x"))
        s = self.scrubber(self.failing_once())
        first, second = s.post("prompt_end", tag=("s-1-1", 7)), s.post("close")
        seen = []

        def on_failure(exc, failed):
            seen.append((exc, [(q.kind, q.tag) for q in failed], [q.event.is_set() for q in failed]))
        import threading
        owner = threading.Thread(target=s.run, args=(on_failure,), daemon=True)
        owner.start()
        owner.join(5)
        self.assertFalse(owner.is_alive())
        self.assertEqual(len(seen), 1, "on_failure exactly once")
        exc, failed, woken = seen[0]
        self.assertIsInstance(exc, r.ScrubFailed)
        self.assertEqual(failed, [("prompt_end", ("s-1-1", 7)), ("close", None)])
        self.assertEqual(woken, [False, False], "nobody is woken before the terminal path ran")
        self.assertIs(first.error, exc)
        self.assertIs(second.error, exc)



class TerminalLineTest(Base):
    """RoseCat 6410: names in the transcript tree are the agent's to choose. A failure's
    detail stays in the exception; the helper's terminal stderr line is fixed text."""

    def test_a_hostile_file_name_never_reaches_the_terminal_line(self):
        import subprocess
        sentinel = "\x1b[31m\nzigBrowser: agent: forged line"
        name = TOKEN + sentinel + ".jsonl"
        os.mkfifo(self.home.ws / name)  # not a regular file: the scan fails naming it
        with self.assertRaises(self.r.ScrubFailed) as failed:
            self.scrubber().scan("start")
        self.assertIn(TOKEN, str(failed.exception), "the detail is in the exception")
        # chat's real fail-closed path, in a process of its own (it ends with exit 3).
        done = subprocess.run(
            [sys.executable, "-c", "import sys; from zb_agent_host import chat; chat.fail_closed(sys.argv[1])",
             str(failed.exception)], cwd=str(Path(__file__).resolve().parents[1]), capture_output=True, timeout=60)
        self.assertEqual(done.returncode, 3, done.stderr[-500:])
        self.assertEqual(done.stderr, b"zigBrowser: agent: transcript scrub failed\n")
        self.assertEqual(done.stdout, b"")

    def test_a_stuck_output_pipe_never_holds_the_helper_up(self):
        """RoseCat 6423: the app stopped reading, and a frame write blocks holding the
        emitter's lock. The terminal path still ends within its bound: its descendants are
        killed and it exits 3, the prompt's frame given up."""
        import subprocess
        import time
        pidfile = self.home.root / "child.pid"
        script = """
import os, subprocess, sys, threading, time
from zb_agent_host import chat
from zb_agent_host.frames import Emitter
r, w = os.pipe()  # nobody reads r
out = Emitter(stream=os.fdopen(w, "w"))
child = subprocess.Popen(["sleep", "600"])
open(sys.argv[1], "w").write(str(child.pid))
def flood():
    while True:
        out.emit("assistant_delta", session="s-1-1", prompt_id=1, text="x" * 1000)
threading.Thread(target=flood, daemon=True).start()
time.sleep(0.5)  # the pipe is full: flood blocks inside emit, holding its lock
chat.fail_closed("stuck", out, [("error", {"session": "s-1-1", "prompt_id": 1, "code": "sdk",
                                          "message": "transcript scrub failed"})])
"""
        started = time.monotonic()
        try:
            done = subprocess.run([sys.executable, "-c", script, str(pidfile)], cwd=str(Path(__file__).resolve().parents[1]),
                                  capture_output=True, timeout=10)
        except subprocess.TimeoutExpired:
            done = None
        child = int(pidfile.read_text()) if pidfile.exists() else None
        if child is not None:
            self.addCleanup(lambda: os.path.exists(f"/proc/{child}") and os.kill(child, 9))
        self.assertIsNotNone(done, "the helper never ended: its terminal path waited for the output")
        self.assertEqual(done.returncode, 3, done.stderr[-300:])
        self.assertLess(time.monotonic() - started, 6.0)
        self.assertIsNotNone(child)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and self.running(child):
            time.sleep(0.05)
        self.assertFalse(self.running(child), "the descendant was killed")

    def test_a_readable_pipe_gets_exactly_the_last_frame_and_nothing_after(self):
        import json
        import threading
        from zb_agent_host.frames import Emitter
        r, w = os.pipe()
        out = Emitter(stream=os.fdopen(w, "w"))
        out.emit("assistant_delta", session="s-1-1", prompt_id=1, text="before")
        self.assertTrue(out.seal([("error", {"session": "s-1-1", "prompt_id": 1, "code": "sdk",
                                              "message": "transcript scrub failed"})]))
        late = threading.Thread(target=out.emit, args=("result",), kwargs={"session": "s-1-1"}, daemon=True)
        late.start()
        late.join(0.3)
        self.assertTrue(late.is_alive(), "a later emit waits forever")
        os.set_blocking(r, False)
        lines = os.read(r, 65536).decode().splitlines()
        os.close(r)
        frames = [json.loads(line) for line in lines]
        self.assertEqual([(f["seq"], f["type"]) for f in frames], [(1, "assistant_delta"), (2, "error")])
        self.assertEqual(frames[1]["code"], "sdk")

    @staticmethod
    def running(pid):
        try:
            with open(f"/proc/{pid}/stat") as f:
                return f.read().rsplit(")", 1)[1].split()[0] != "Z"
        except OSError:
            return False

if __name__ == "__main__":
    unittest.main()
