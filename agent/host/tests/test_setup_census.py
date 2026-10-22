"""R1 on macOS, the census broker, setup's half (RoseCat 7019; BlueBeaver 7021; JadeBeacon 7023, 0aa5845): the process
census runs in setup, OUTSIDE Seatbelt, over setup's own descendants; the probe (inside, with the CLI) only asks.
On Linux with the platform injected (`setup.PLATFORM`), the MS6 seam faked with its real signature, and the census
verdict `proc_darwin.cli_env_clean(exe, root, token, canary)` recorded:

- probe_r1 on Darwin makes an AF_UNIX SOCK_STREAM socketpair outside the sandbox, passes the probe's end with
  `--census-fd <fd>` (pass_fds holds exactly the listener and that end), and serves the other end itself.
- One request, exactly b"census <zb-probe-[0-9a-f]{48}> http://127.0.0.1:<the listener's port>\\n" (at most 256 bytes),
  is answered with b"clean\\n" or b"dirty\\n", then setup shuts its side. The verdict is
  proc_darwin.cli_env_clean(realpath(cli), getpid(), token, b"ANTHROPIC_BASE_URL=<url>"): setup's own descendants.
- The request is everything the probe sends up to its EOF (it half-closes after its one line), and it must
  full-match that one line: a malformed, oversized or wrong-port request, a second request, or any trailing byte is
  "dirty" (or no answer) and the census verdict is never computed for it (RoseCat 7078).
- probe_r1 is True only when the probe's verdict is {"r1": true} AND setup's own census said clean: the probe alone
  cannot select R1.
- Both socketpair ends are closed explicitly on every path, and no census thread outlives probe_r1.
- Abandoned (BlackRobin 7060): a census still running after setup's bounded join (CENSUS_JOIN_S) is no R1; setup does
  not close its end under the live thread, its late "clean" changes nothing, and the thread closes the end itself.
- Bounded (RoseCat 7041): a live probe-side peer that stays silent or sends a partial request without EOF, a run that
  times out, and a census verdict that raises each give "no R1" within 5 s, both ends closed, the thread joined; a
  raising census answers "dirty".
- Linux is unchanged: no socketpair, no --census-fd.

Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_setup_census. Unregistered until the
green.
"""
import contextlib
import json
import os
import socket
import threading
import time
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import proc_darwin, sandbox_macos, setup

WRAPPER = "/rt/runtime/bin/zb-claude"
CLI = "/opt/claude"
TOKEN = "zb-probe-" + "ef" * 24


class Base(unittest.TestCase):
    def setUp(self):
        if not hasattr(proc_darwin, "cli_env_clean"):
            self.fail("proc_darwin.cli_env_clean (setup's census verdict) is missing (7021)")
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(setup, "PLATFORM", "darwin").start()
        self.census_calls = []
        self.census_says = True
        mock.patch.object(proc_darwin, "cli_env_clean",
                          side_effect=lambda *a: self.census_calls.append(a) or self.census_says).start()

        @contextlib.contextmanager
        def seam(scratch, ro_paths, command, *, loopback_port=None):
            yield ["/usr/bin/sandbox-exec", "-f", f"{scratch}/p.sb", *command]

        mock.patch.object(sandbox_macos, "setup_sandbox", seam).start()
        self.pairs = []
        real_pair = socket.socketpair

        def tracking_pair(*args, **kwargs):
            a, b = real_pair(*args, **kwargs)
            self.pairs.append((a, b))
            return a, b

        mock.patch.object(setup.socket, "socketpair", side_effect=tracking_pair).start()
        self.addCleanup(lambda: [s.close() for p in self.pairs for s in p])
        self.runs = []

    def probe(self, request="good", verdict=True, hold=False, raises=None):
        """A fake probe run: asks setup's census like route_probe does, then prints its own verdict. `hold` keeps a
        live duplicate of the probe's end open after the run (a stray descendant that never answers or closes), so
        only setup's own bound can end the census; `raises` makes the run itself raise."""
        def run(argv, **kwargs):
            rec = {"argv": list(argv), "pass_fds": tuple(kwargs.get("pass_fds", ()))}
            self.runs.append(rec)
            if raises is not None:
                raise raises(argv, kwargs.get("timeout"))
            if hold and "--census-fd" in argv:
                held = socket.socket(fileno=os.dup(int(argv[argv.index("--census-fd") + 1])))
                self.addCleanup(held.close)
                if request == "partial":
                    held.sendall(b"census zb-probe-")
                return setup.subprocess.CompletedProcess(argv, 0, stdout=json.dumps({"r1": verdict}) + "\n",
                                                         stderr="")
            if "--census-fd" not in argv:
                return setup.subprocess.CompletedProcess(argv, 0, stdout=json.dumps({"r1": verdict}) + "\n", stderr="")
            cfd = int(argv[argv.index("--census-fd") + 1])
            port = int(argv[argv.index("--listen-port") + 1])
            rec["census_fd"] = cfd
            s = socket.socket(fileno=os.dup(cfd))
            with s:
                rec["family"] = (s.family, s.type)
                s.settimeout(10)
                url = f"http://127.0.0.1:{port}"
                lines = {
                    "good": f"census {TOKEN} {url}\n".encode(),
                    "wrong-port": f"census {TOKEN} http://127.0.0.1:{port + 1 if port < 65535 else 1}\n".encode(),
                    "bad-token": f"census zb-probe-XYZ {url}\n".encode(),
                    "extra-field": f"census {TOKEN} {url} more\n".encode(),
                    "no-newline": f"census {TOKEN} {url}".encode(),
                    "oversized": b"census " + b"a" * 4096 + b"\n",
                    "twice": f"census {TOKEN} {url}\ncensus {TOKEN} {url}\n".encode(),
                    "junk-after": f"census {TOKEN} {url}\nX".encode(),
                }
                if request == "none-but-ask-async":
                    s.sendall(lines["good"])  # asks (one line, then EOF), but ends without waiting for the verdict
                    s.shutdown(socket.SHUT_WR)
                    return setup.subprocess.CompletedProcess(argv, 0, stdout=json.dumps({"r1": verdict}) + "\n",
                                                             stderr="")
                if request != "none":
                    s.sendall(lines[request])
                    s.shutdown(socket.SHUT_WR)
                    reply = b""
                    try:
                        while chunk := s.recv(64):
                            reply += chunk
                    except OSError:
                        pass
                    rec["reply"] = reply
            return setup.subprocess.CompletedProcess(argv, 0, stdout=json.dumps({"r1": verdict}) + "\n", stderr="")

        support.fake_setup_runs(setup, side_effect=run).start()

    def census_threads(self):
        return [t for t in threading.enumerate() if "census" in t.name]


class Broker(Base):
    def test_a_clean_census_and_a_true_probe_select_r1(self):
        self.probe()
        self.assertIs(setup.probe_r1(WRAPPER, CLI), True)
        (run,) = self.runs
        self.assertEqual(run["family"], (socket.AF_UNIX, socket.SOCK_STREAM))
        listen_fd = int(run["argv"][run["argv"].index("--listen-fd") + 1])
        self.assertEqual(sorted(run["pass_fds"]), sorted((listen_fd, run["census_fd"])), "exactly the two fds")
        self.assertEqual(run["reply"], b"clean\n")
        port = int(run["argv"][run["argv"].index("--listen-port") + 1])
        self.assertEqual(self.census_calls,
                         [(os.path.realpath(CLI), os.getpid(), TOKEN.encode(),
                           f"ANTHROPIC_BASE_URL=http://127.0.0.1:{port}".encode())])

    def test_a_dirty_census_is_no_r1_even_when_the_probe_says_true(self):
        self.census_says = False
        self.probe()
        self.assertIs(setup.probe_r1(WRAPPER, CLI), False)
        self.assertEqual(self.runs[0]["reply"], b"dirty\n")

    def test_no_census_request_is_no_r1_even_when_the_probe_says_true(self):
        self.probe(request="none")
        self.assertIs(setup.probe_r1(WRAPPER, CLI), False)
        self.assertEqual(self.census_calls, [])

    def test_a_bad_request_is_never_clean_and_never_censused(self):
        for request in ("wrong-port", "bad-token", "extra-field", "no-newline", "oversized"):
            with self.subTest(request=request):
                self.runs.clear()
                self.census_calls.clear()
                self.probe(request=request)
                self.assertIs(setup.probe_r1(WRAPPER, CLI), False)
                self.assertIn(self.runs[0].get("reply"), (b"", b"dirty\n"))
                self.assertEqual(self.census_calls, [])

    def test_anything_after_the_one_request_is_dirty_and_never_censused(self):
        # RoseCat 7078: the request is the WHOLE stream up to the probe's EOF and must full-match one line; a second
        # request or a single trailing byte makes it dirty, and the census verdict is never computed.
        for request in ("twice", "junk-after"):
            with self.subTest(request=request):
                self.runs.clear()
                self.census_calls.clear()
                self.probe(request=request)
                self.assertIs(setup.probe_r1(WRAPPER, CLI), False)
                self.assertEqual(self.runs[0]["reply"], b"dirty\n")
                self.assertEqual(self.census_calls, [])

    def test_both_ends_are_closed_and_no_census_thread_survives(self):
        for request, verdict in (("good", True), ("none", True), ("oversized", True), ("good", False)):
            with self.subTest(request=request, verdict=verdict):
                self.runs.clear()
                self.pairs.clear()
                self.probe(request=request, verdict=verdict)
                setup.probe_r1(WRAPPER, CLI)
                self.assertEqual(len(self.pairs), 1, "one socketpair per probe")
                self.assertEqual([s.fileno() for s in self.pairs[0]], [-1, -1], "both ends closed explicitly")
                self.assertEqual(self.census_threads(), [])

    def test_the_census_ends_are_closed_when_the_seam_refuses(self):
        @contextlib.contextmanager
        def refusing(scratch, ro_paths, command, *, loopback_port=None):
            raise setup.SetupError("the macOS sandbox is not ready")
            yield

        mock.patch.object(sandbox_macos, "setup_sandbox", refusing).start()
        self.probe()
        with self.assertRaises(setup.SetupError):
            setup.probe_r1(WRAPPER, CLI)
        self.assertEqual(self.runs, [])
        for pair in self.pairs:
            self.assertEqual([s.fileno() for s in pair], [-1, -1])
        self.assertEqual(self.census_threads(), [])


class Bounded(Base):
    """RoseCat 7041 #2: a live peer that holds the socket silently or with a partial line, a run that times out,
    and a census that raises each end as "no R1" within a measured bound, with both ends closed and the broker
    thread joined."""

    def assert_bounded_no_r1(self, bound=5):
        started = time.monotonic()
        self.assertIs(setup.probe_r1(WRAPPER, CLI), False)
        self.assertLess(time.monotonic() - started, bound, "the census ends within its bound")
        self.assertEqual(len(self.pairs), 1)
        self.assertEqual([s.fileno() for s in self.pairs[0]], [-1, -1], "both ends closed explicitly")
        self.assertEqual(self.census_threads(), [], "the broker thread is joined")

    def test_a_live_silent_peer(self):
        self.probe(hold=True, request="none")
        self.assert_bounded_no_r1()
        self.assertEqual(self.census_calls, [])

    def test_a_live_peer_with_a_partial_request(self):
        self.probe(hold=True, request="partial")
        self.assert_bounded_no_r1()
        self.assertEqual(self.census_calls, [])

    def test_a_run_that_times_out(self):
        self.probe(raises=setup.subprocess.TimeoutExpired)
        self.assert_bounded_no_r1()

    def test_a_census_that_raises_answers_dirty(self):
        mock.patch.object(proc_darwin, "cli_env_clean", side_effect=RuntimeError("boom")).start()
        self.probe()
        self.assert_bounded_no_r1()
        self.assertEqual(self.runs[0]["reply"], b"dirty\n")


class AbandonedCensus(Base):
    """BlackRobin 7060: a census verdict still running when setup's join times out. setup must not close its end
    under the live thread (the fd number could be reused), must not read a verdict nobody waited for, and the thread
    closes the end itself when it finishes, so nothing leaks."""

    def test_a_census_still_running_after_the_join_is_no_r1_and_its_late_clean_changes_nothing(self):
        # Deterministic: the verdict is computed at once (clean, so result["clean"] is already True), but setup's
        # reply blocks in sendall past the bounded join. Only "abandoned => no R1" keeps that verdict, which nobody
        # waited for, from selecting R1.
        if not hasattr(setup, "CENSUS_JOIN_S"):
            self.fail("setup.CENSUS_JOIN_S (the bounded census join) is missing (7060)")
        mock.patch.object(setup, "CENSUS_JOIN_S", 0.3).start()
        release, replying = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        real_pair = socket.socketpair

        class StuckReply(socket.socket):
            def sendall(self, data, *args):
                replying.set()
                release.wait(10)
                return super().sendall(data, *args)

        def pair(*args, **kwargs):
            a, b = real_pair(*args, **kwargs)  # Base's tracking pair: it already recorded (a, b)
            ours = StuckReply(fileno=a.detach())
            self.pairs[-1] = (ours, b)
            return ours, b

        mock.patch.object(setup.socket, "socketpair", side_effect=pair).start()
        self.probe(request="none-but-ask-async")
        self.assertIs(setup.probe_r1(WRAPPER, CLI), False, "a census nobody waited for is no R1")
        self.assertTrue(replying.is_set(), "the census had its (clean) verdict and was replying")
        (pair_,) = self.pairs
        self.assertNotEqual(pair_[0].fileno(), -1, "setup does not close its end under the live census thread")
        release.set()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and self.census_threads():
            time.sleep(0.02)
        self.assertEqual(self.census_threads(), [], "the census thread ends")
        self.assertEqual(pair_[0].fileno(), -1, "and closes the end setup left to it")


class LinuxUnchanged(Base):
    def test_linux_has_no_census(self):
        mock.patch.object(setup, "PLATFORM", "linux").start()
        self.probe()
        self.assertIs(setup.probe_r1(WRAPPER, CLI), True)
        (run,) = self.runs
        self.assertNotIn("--census-fd", run["argv"])
        self.assertEqual(self.pairs, [])


if __name__ == "__main__":
    unittest.main()
