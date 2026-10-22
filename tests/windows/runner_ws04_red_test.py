#!/usr/bin/env python3
"""WS0.4 item 4 RED (UNREGISTERED): the interactive scheduled-task runner never asks for elevation, and a failed
task delete fails the run.

Plan rev 2.21, WS0.4 item 4: "job cleanup and `schtasks /delete` whose failures fail the run (no ignored results),
`RunLevel` least privilege (not `/rl highest`)". The Win11 m8 run at 0f2486b failed 3/3 with
"ERROR: Access is denied." at `schtasks /create ... /it /rl highest`: the standard test user cannot request
the highest run level (review c70c24e; cause SUSPECTED until the live run).

Hostless: drives the REAL `slice2_common.run_windows_interactive_to_exit` (the scheduled-task PowerShell runner the
m8 tests use) and `run_windows_interactive_cmd_until` (the cmd runner) in a child Python whose PATH holds a
recording fake `schtasks`/`taskkill`. The fake acts like a standard user: it refuses a `/create` that requests
`/rl highest` with the VM's exact "ERROR: Access is denied.", and on `/run` it writes the result files the real
task wrapper would write. The only thing changed in the child is slice2_common's own `os` name: a proxy that reports
`name == "nt"` and passes every other attribute to the real os, so the runner's Windows-only guard lets it run; the
argv, the polling and the result handling are the production code.
The platform proof is a Win11 VM run of the m8 harness through the fixed runner.

The green moves these cases into gate_selftest.py (step windows-gate-selftest), as the plan names for WS0.4.

Run alone:  python3 -I tests/windows/runner_ws04_red_test.py -v
"""
import json
import os
import pathlib
import shlex
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]

# Recording fake schtasks: one argv line per call; behaves like a standard user's Task Scheduler.
_FAKE_SCHTASKS = r"""#!/usr/bin/env bash
printf 'schtasks' >> "$ZB_FAKE_LOG"; printf ' %q' "$@" >> "$ZB_FAKE_LOG"; printf '\n' >> "$ZB_FAKE_LOG"
verb="$1"; shift
tn=""; tr=""; rl=""
while [ $# -gt 0 ]; do
  case "$1" in
    /tn) tn="$2"; shift 2 ;;
    /tr) tr="$2"; shift 2 ;;
    /rl) rl="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$verb" in
  /create)
    if [ "$(printf '%s' "$rl" | tr 'A-Z' 'a-z')" = "highest" ] && [ -z "${ZB_FAKE_ALLOW_HIGHEST:-}" ]; then
      echo "ERROR: Access is denied." >&2; exit 1; fi
    printf '%s' "$tr" > "$ZB_FAKE_STATE/$tn.tr"; echo "SUCCESS: The scheduled task \"$tn\" has successfully been created."; exit 0 ;;
  /run)
    [ -f "$ZB_FAKE_STATE/$tn.tr" ] || { echo "ERROR: The system cannot find the file specified." >&2; exit 1; }
    script=$(sed -E 's/.*"([^"]+)"[^"]*$/\1/' "$ZB_FAKE_STATE/$tn.tr"); dir=$(dirname "$script")
    printf 'PASS\tfake\nZB_HARNESS_EXIT\t0\n' > "$dir/stdout.txt"; : > "$dir/stderr.txt"
    case "$script" in *.ps1) echo 4242 > "$dir/pid.txt"; echo 0 > "$dir/exit.txt" ;; esac
    echo "SUCCESS: Attempted to run the scheduled task \"$tn\"."; exit 0 ;;
  /end) exit "${ZB_FAKE_END_RC:-0}" ;;
  /delete)
    if [ "${ZB_FAKE_DELETE_RC:-0}" != 0 ]; then echo "ERROR: Access is denied." >&2; exit "$ZB_FAKE_DELETE_RC"; fi
    rm -f "$ZB_FAKE_STATE/$tn.tr"; echo "SUCCESS: The scheduled task \"$tn\" was successfully deleted."; exit 0 ;;
esac
exit 0
"""
_FAKE_TASKKILL = r"""#!/usr/bin/env bash
printf 'taskkill' >> "$ZB_FAKE_LOG"; printf ' %q' "$@" >> "$ZB_FAKE_LOG"; printf '\n' >> "$ZB_FAKE_LOG"
exit 0
"""

# The child: import the real runner, then let its Windows-only guard pass, then call it and print the result.
_CHILD = r"""
import json, os, sys, pathlib
sys.path.insert(0, sys.argv[1])
import slice2_common as s

class _WindowsName:
    # slice2_common's own `os`, reporting name "nt" so the runner's `os.name != "nt"` guard passes; every other
    # attribute is the real os module (pathlib, tempfile and subprocess keep their real, POSIX os).
    name = "nt"
    def __getattr__(self, attr):
        return getattr(os, attr)

s.os = _WindowsName()
which = sys.argv[2]
if which == "ps1":
    r = s.run_windows_interactive_to_exit(["C:\\zb\\fake.exe", "--flag"], {"ZB_X": "1"}, 10, cwd=pathlib.Path.cwd())
    matched = None
else:
    matched, r = s.run_windows_interactive_cmd_until(["C:\\zb\\fake.exe"], {}, 10,
                                                     lambda o, e, p: p.returncode is not None, cwd=pathlib.Path.cwd())
print(json.dumps({"matched": matched, "returncode": r.returncode, "stdout": r.stdout_lines, "stderr": r.stderr_lines}))
"""


class RunnerNeverElevatesRed(unittest.TestCase):
    def _run(self, which, **fake_env):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = td / "bin"; bindir.mkdir()
            state = td / "state"; state.mkdir()
            for name, body in (("schtasks", _FAKE_SCHTASKS), ("taskkill", _FAKE_TASKKILL)):
                (bindir / name).write_text(body); (bindir / name).chmod(0o755)
            log = td / "calls.log"; log.write_text("")
            env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td), "TMPDIR": str(td),
                   "ZB_FAKE_LOG": str(log), "ZB_FAKE_STATE": str(state)}
            env.update(fake_env)
            proc = subprocess.run(["python3", "-I", "-c", _CHILD, str(REPO / "tests" / "e2e"), which], cwd=td,
                                  env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
            calls = [shlex.split(c) for c in log.read_text().splitlines()]
        detail = (f"\nchild rc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\ncalls:\n"
                  + "\n".join(map(shlex.join, calls)))
        self.assertEqual(proc.returncode, 0, "the child driver itself must not crash" + detail)
        return json.loads(proc.stdout.strip().splitlines()[-1]), calls, detail

    def _create_call(self, calls, detail):
        creates = [c for c in calls if c[:2] == ["schtasks", "/create"]]
        self.assertEqual(len(creates), 1, "exactly one task is created" + detail)
        return creates[0]

    def test_ps1_runner_creates_the_task_at_least_privilege(self):
        result, calls, detail = self._run("ps1")
        argv = self._create_call(calls, detail)
        self.assertNotIn("highest", [a.lower() for a in argv], "the runner must never request elevation" + detail)
        self.assertIn("/rl", argv, "the run level must be stated, not left to a default" + detail)
        self.assertEqual(argv[argv.index("/rl") + 1].lower(), "limited", "least privilege is /rl limited" + detail)
        self.assertIn("/it", argv, "the task must still run only in the interactive session" + detail)

    def test_cmd_runner_creates_the_task_at_least_privilege(self):
        result, calls, detail = self._run("cmd")
        argv = self._create_call(calls, detail)
        self.assertNotIn("highest", [a.lower() for a in argv], "the runner must never request elevation" + detail)
        self.assertEqual(argv[argv.index("/rl") + 1].lower(), "limited", detail)

    def test_standard_user_host_runs_the_task(self):
        # The fake refuses /rl highest exactly as the VM did; a least-privilege runner gets its task run.
        for which in ("ps1", "cmd"):
            with self.subTest(runner=which):
                result, calls, detail = self._run(which)
                self.assertEqual(result["returncode"], 0, "a standard user's task must be created and run" + detail)
                self.assertNotIn("ERROR: Access is denied.", result["stderr"], detail)
                self.assertTrue(any(c[:2] == ["schtasks", "/run"] for c in calls), "the task was run" + detail)

    def test_failed_task_delete_fails_the_run(self):
        for which in ("ps1", "cmd"):
            with self.subTest(runner=which):
                # The fake accepts any run level here, so this case isolates the delete result.
                result, calls, detail = self._run(which, ZB_FAKE_DELETE_RC="1", ZB_FAKE_ALLOW_HIGHEST="1")
                self.assertTrue(any(c[:2] == ["schtasks", "/delete"] for c in calls), "the delete was attempted" + detail)
                self.assertNotEqual(result["returncode"], 0, "a task left behind must fail the run" + detail)
                self.assertTrue(any("schtasks /delete" in l and "rc=1" in l for l in result["stderr"]),
                                "the failed delete must be named in the result's stderr" + detail)
                if which == "cmd":
                    self.assertFalse(result["matched"], "a run whose cleanup failed is not a match" + detail)


if __name__ == "__main__":
    unittest.main()
