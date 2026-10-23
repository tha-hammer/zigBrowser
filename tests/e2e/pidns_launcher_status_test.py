"""bd zigBrowser-3ui.4: every PID-namespace launcher in build.zig must pass its test's exit status through.

build.zig runs signal/kill tests inside `exec 9</proc/self/ns/pid; exec unshare ... sh -c '"$@"; :' sh "$1"`. The
trailing `:` makes the namespace's shell exit 0 whatever the test returned, so a registered step built on it can never
fail. This test reads every launcher string out of build.zig (each Zig string literal holding the fd-9 PID-namespace
form), unescapes it, and RUNS it on a command that exits 7 and on one that exits 0. The step must report 7, then 0.

Two shapes are driven, exactly as build.zig runs them (cwd = the repo root):
  * the artifact launcher: `sh -c <launcher> sh <test-binary>`; the test binary here is a stub that exits with its code;
  * the agent-host launcher: `sh -c <launcher>`, which resolves the test python through tools/agent_host_env.sh
    --check; ZB_AGENT_HOST_PYTHON names a stub python that exits with its code and prints nothing (so the step's
    ResourceWarning/'skipped' text checks cannot be what fails it).
No signal is sent; the stubs only exit. Stdlib only.

Run:  python3 -I tests/e2e/pidns_launcher_status_test.py
"""
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
BUILD_ZIG = ROOT / "build.zig"
PIDNS_FORM = "exec 9</proc/self/ns/pid; exec unshare"
AGENT_HOST_PREFIX = "py=$(tools/agent_host_env.sh --check)"
# The four masked sites of bd 3ui.4 plus the recovery-txn launcher that already keeps the status (6ff2ccc).
EXPECTED_AT_LEAST = 5
_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", "'": "'", '"': '"'}


def zig_string(line):
    """The Zig string literal that starts `line` (after indentation), unescaped; None if the line holds none."""
    s = line.lstrip()
    if not s.startswith('"'):
        return None
    out, i = [], 1
    while i < len(s):
        ch = s[i]
        if ch == '"':
            return "".join(out)
        if ch == "\\":
            nxt = s[i + 1]
            if nxt == "x":
                out.append(chr(int(s[i + 2:i + 4], 16)))
                i += 4
                continue
            if nxt not in _ESCAPES:
                raise ValueError(f"unsupported Zig escape \\{nxt} in {line!r}")
            out.append(_ESCAPES[nxt])
            i += 2
            continue
        out.append(ch)
        i += 1
    raise ValueError(f"unterminated Zig string in {line!r}")


def launchers():
    """(build.zig line number, launcher text) for every string literal holding the fd-9 PID-namespace form."""
    found = []
    for n, line in enumerate(BUILD_ZIG.read_text(encoding="utf-8").splitlines(), 1):
        text = zig_string(line)
        if text is not None and PIDNS_FORM in text:
            found.append((n, text))
    return found


def stub(directory, code):
    """An executable that ignores its arguments and exits with `code`, printing nothing."""
    path = pathlib.Path(directory) / f"exit{code}"
    path.write_text(f"#!/bin/sh\nexit {code}\n", encoding="utf-8")
    path.chmod(0o755)
    return str(path)


def drive(text, code, directory):
    """Run one launcher the way build.zig does, on a stub that exits with `code`; return the step's exit status."""
    env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": directory}
    exe = stub(directory, code)
    if text.startswith(AGENT_HOST_PREFIX):
        env["ZB_AGENT_HOST_PYTHON"] = exe
        argv = ["sh", "-c", text]
    else:
        argv = ["sh", "-c", text, "sh", exe]
    done = subprocess.run(argv, cwd=ROOT, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, timeout=60, check=False)
    return done.returncode, done.stdout.decode("utf-8", "replace")


class LauncherStatus(unittest.TestCase):
    def test_reader_unescapes_a_zig_literal(self):
        self.assertEqual(zig_string('        "a \\"b\\" \\\\$@ \\x41\\n",'), 'a "b" \\$@ A\n')
        self.assertIsNone(zig_string("    // not a literal"))

    def test_every_pidns_launcher_is_found(self):
        found = launchers()
        self.assertGreaterEqual(len(found), EXPECTED_AT_LEAST, f"only {[n for n, _ in found]} hold {PIDNS_FORM!r}")

    def test_every_pidns_launcher_keeps_the_exit_status(self):
        found = launchers()
        self.assertTrue(found)
        failures = []
        with tempfile.TemporaryDirectory(prefix="zb-pidns-status-") as d:
            for n, text in found:
                rc_fail, out_fail = drive(text, 7, d)
                rc_pass, out_pass = drive(text, 0, d)
                if rc_fail != 7 or rc_pass != 0:
                    failures.append(f"build.zig:{n}: a test exiting 7 gave rc={rc_fail}, exiting 0 gave rc={rc_pass}"
                                    f" (want 7, 0); output {out_fail.strip()[-200:]!r} / {out_pass.strip()[-200:]!r}")
        self.assertEqual(failures, [], "\n".join(failures))


if __name__ == "__main__":
    if sys.flags.isolated != 1:
        sys.exit("run with python3 -I")
    unittest.main(verbosity=2)
