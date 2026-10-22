"""tests/e2e/run_step.sh: a gate step that says what it printed and why it ended (agent-netd-spawn-e2e in
BlackRobin's gates: zig build inherits a system command's stdout/stderr, so under -j its lines interleave with every
other step's, unlabelled, and the failure block says only "process exited with error code 1"; the run that ended in
Xlib's exit(1) printed no summary, which nobody could attribute).

    run_step.sh <label> [--summary <ERE>] -- <command> [args...]

- every line the command printed, stdout and stderr together and in order, is printed after it ends, each prefixed
  "[<label>] ", in one block;
- exit 0: nothing more, and run_step.sh exits 0;
- otherwise one reason line, then the command's own status: "<label>: exit <n>", or for a status above 128
  "<label>: status <n> (signal-style: 128+<s>)": a shell sees only the status, so an explicit `exit 143` and a SIGTERM
  read the same and neither is called a signal (RoseCat 7573);
- with --summary, a command whose last line does not match the ERE also gets "<label>: no summary line (the process
  ended mid-run); last line: <it>", even when it exited 0 (and then run_step.sh exits 1);
- the build.zig step agent-netd-spawn-e2e runs its test through run_step.sh, label agent-netd-spawn-e2e, with the
  run_main summary ERE.
The commands are plain shells; the only signal is one a shell sends itself (kill -TERM $$). Run inside a PID
namespace like its siblings: cd tests/e2e && env -u DISPLAY unshare --user --map-root-user --pid --fork --mount-proc \\
  sh -c 'setsid python3 -X dev -m unittest -v test_run_step'
Unregistered until the green."""

import re
import subprocess
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
STEP = HERE / "run_step.sh"
SUMMARY = "^[0-9]+ checks, [0-9]+ failed$"


def step(script: str, summary: bool = True) -> subprocess.CompletedProcess:
    argv = ["sh", str(STEP), "netd"] + (["--summary", SUMMARY] if summary else []) + ["--", "sh", "-c", script]
    return subprocess.run(argv, capture_output=True, text=True, timeout=60)


class RunStep(unittest.TestCase):
    def test_a_passing_run_is_labelled_and_says_nothing_more(self):
        done = step("echo 'ok   one'; echo 'warn' >&2; echo '1 checks, 0 failed'")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.splitlines(), ["[netd] ok   one", "[netd] warn", "[netd] 1 checks, 0 failed"])

    def test_an_exit_without_a_summary_names_the_status_and_the_last_line(self):
        done = step("echo 'ok   the stand-in started'; echo 'XIO:  fatal IO error 0 (Success) on X server' >&2; exit 1")
        self.assertEqual(done.returncode, 1)
        lines = done.stdout.splitlines()
        self.assertEqual(lines[:2], ["[netd] ok   the stand-in started",
                                     "[netd] XIO:  fatal IO error 0 (Success) on X server"])
        self.assertIn("netd: exit 1", lines)
        self.assertIn("netd: no summary line (the process ended mid-run); last line: "
                      "XIO:  fatal IO error 0 (Success) on X server", lines)

    def test_a_signal_is_a_signal_style_status(self):
        done = step("echo 'ok   one'; kill -TERM $$")
        self.assertEqual(done.returncode, 143)
        self.assertIn("netd: status 143 (signal-style: 128+15)", done.stdout.splitlines())

    def test_an_explicit_exit_143_reads_the_same_and_is_not_called_a_signal(self):
        done = step("echo '1 checks, 0 failed'; exit 143")
        self.assertEqual(done.returncode, 143)
        self.assertEqual(done.stdout.splitlines()[-1], "netd: status 143 (signal-style: 128+15)")
        self.assertNotIn("killed", done.stdout)

    def test_a_clean_exit_without_its_summary_still_fails(self):
        done = step("echo 'ok   one'")
        self.assertEqual(done.returncode, 1)
        self.assertIn("netd: no summary line (the process ended mid-run); last line: ok   one",
                      done.stdout.splitlines())

    def test_a_failing_run_with_its_summary_names_only_the_status(self):
        done = step("echo 'FAIL two'; echo '2 checks, 1 failed'; exit 1")
        self.assertEqual(done.returncode, 1)
        self.assertEqual(done.stdout.splitlines()[-1], "netd: exit 1")
        self.assertNotIn("no summary line", done.stdout)

    def test_without_summary_only_the_status_counts(self):
        done = step("echo hi", summary=False)
        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout.splitlines(), ["[netd] hi"])


class NetdStepUsesIt(unittest.TestCase):
    def test_the_build_step_runs_the_netd_test_through_run_step(self):
        text = (REPO / "build.zig").read_text()
        m = re.search(r"const agent_netd_spawn_e2e = b\.addSystemCommand\(&\.\{(.*?)\}\);", text, re.S)
        self.assertIsNotNone(m, "the agent-netd-spawn-e2e step is gone")
        body = m.group(1)
        self.assertIn('sh tests/e2e/run_step.sh agent-netd-spawn-e2e --summary \'^[0-9]+ checks, [0-9]+ failed$\' '
                      '-- python3 tests/e2e/agent_netd_spawn_test.py --binary', body)


if __name__ == "__main__":
    unittest.main()
