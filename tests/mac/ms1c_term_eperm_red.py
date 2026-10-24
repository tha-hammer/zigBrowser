#!/usr/bin/env python3
"""RED, UNREGISTERED (SilverRidge f69c8dad): SIGTERM EPERM must retain the MS1c host fail-closed.

This drives the real ``stop_browser_term_only`` helper with an unconfirmed live browser group whose SIGTERM raises
EPERM, and separately with a browser whose actual pgid is not its spawned pid.  Poll, pid and actual pgid must all
be captured before any signal; EPERM and a mismatched group each produce one bounded identity-bearing LEAK and one
``FAIL<TAB>mac-teardown-leak`` at exit, without an exception, SIGKILL or signal to another group.

The real exec-arch probe then combines its original socket-timeout diagnostic with that teardown failure.  Finally,
the established fake-Mac fixture drives the real MS1c gate row: rc is nonzero, the one LEAK becomes a durable LEAKED
marker, the run root is retained, and the next attempt is HOST_HELD.  This file stays out of build.zig until green.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
TEARDOWN = ROOT / "tests" / "e2e" / "mac_term_teardown.py"
PROBE = ROOT / "tests" / "mac" / "exec_arch_probe.py"
SELFTEST = ROOT / "tests" / "mac" / "ms1c_app_gate_selftest.sh"
PID = 4242
OTHER_PGID = 3131
START = "Thu Oct 24 12:00:00 2026"
COMMAND = "/Applications/zigBrowser.app/Contents/MacOS/zigBrowser about:blank"
problems: list[str] = []


CASE_DRIVER = r'''#!/usr/bin/env python3
import errno
import importlib.util
import os
from pathlib import Path
import signal
import sys

root, mode, work = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
e2e = root / "tests" / "e2e"
mac = root / "tests" / "mac"
sys.path[:0] = [str(e2e), str(mac)]
import mac_term_teardown as teardown

events = []
pid = 4242
pgid = 3131 if mode == "wrong-pgid" else pid
start = "Thu Oct 24 12:00:00 2026"
command = "/Applications/zigBrowser.app/Contents/MacOS/zigBrowser about:blank"

class FakeProc:
    @property
    def pid(self):
        events.append("pid")
        return pid
    @property
    def returncode(self):
        events.append("returncode")
        return None
    def poll(self):
        events.append("poll")
        return None
    def wait(self, timeout=None):
        events.append("wait")
        raise AssertionError("EPERM or a mismatched pgid must not wait as though TERM was delivered")

proc = FakeProc()
def getpgid(got):
    assert got == pid
    events.append(f"getpgid:{pgid}")
    return pgid
def killpg(got, sig):
    events.append(f"killpg:{got}:{int(sig)}")
    if mode == "wrong-pgid":
        raise AssertionError("teardown signalled a process group other than the spawned pid")
    if got != pid or sig != signal.SIGTERM:
        raise AssertionError(f"unexpected signal killpg({got}, {sig})")
    raise PermissionError(errno.EPERM, os.strerror(errno.EPERM))
def identity(got):
    events.append(f"identity:{got}")
    return [(str(pid), str(got), start, command)]

teardown.os.getpgid = getpgid
teardown.os.killpg = killpg
teardown._group_identity = identity

if mode == "exec-arch":
    import exec_arch_probe as probe
    probe.subprocess.Popen = lambda *_a, **_kw: (events.append("popen") or proc)
    def timeout(sock_path, _timeout):
        events.append("read:" + sock_path)
        raise RuntimeError(f"automation socket/token did not appear at {sock_path}")
    probe.read_exec_arch = timeout
    os.chdir(work)
    socket_dir = Path("s")
    socket_dir.mkdir(mode=0o700)
    output = work / "reported"
    output.write_text("stale\n", encoding="ascii")
    sys.argv = ["exec_arch_probe.py", "--browser", "/fake/zigBrowser", "--out", str(output),
                "--socket-dir", str(socket_dir), "--timeout", "0.1"]
    try:
        rc = probe.main()
        print(f"PROBE_RC\t{rc}", flush=True)
    finally:
        state = f"out={'present' if output.exists() else 'absent'} dir={'present' if socket_dir.is_dir() else 'absent'}"
        print("STATE\t" + state, flush=True)
        print("EVENTS\t" + ",".join(events), flush=True)
else:
    try:
        teardown.stop_browser_term_only(proc, grace_s=0.1)
    finally:
        print("EVENTS\t" + ",".join(events), flush=True)
'''


GATE_SUFFIX = r'''
# Intercept only the requested Intel exec-arch row. All other fixture commands keep their original implementation.
mv -f "$X/hostbin/python3" "$X/hostbin/python3.fixture" || exit 1
cat > "$X/hostbin/python3" <<EOF
#!/bin/bash
script=\${1:-}
if [ "\${script##*/}" = exec_arch_probe.py ] && [ "\${ZB_ROLE:-}" = intel ] \
   && [ -f "$C/mode_term_eperm.intel" ]; then
  shift
  socket_dir=
  while [ \$# -gt 0 ]; do
    case "\$1" in --socket-dir) socket_dir=\${2:-}; shift 2 ;; *) shift ;; esac
  done
  printf '%s\n' "exec_arch_probe: FAIL (automation socket/token did not appear at \$socket_dir/a.sock)" >&2
  printf '%b\n' 'LEAK\t4242\t4242\tThu Oct 24 12:00:00 2026\t/Applications/zigBrowser.app/Contents/MacOS/zigBrowser about:blank'
  printf '%b\n' 'FAIL\tmac-teardown-leak\t1'
  exit 1
fi
exec "$X/hostbin/python3.fixture" "\$@"
EOF
chmod 0755 "$X/hostbin/python3"

cp -f -- "$ROOT/tests/mac/ms1c_home_protected_paths.txt" "$R/tests/mac/ms1c_home_protected_paths.txt" \
  && "${GIT[@]}" add -- tests/mac/ms1c_home_protected_paths.txt \
  && "${GIT[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m protected-data \
  || { bad "EPERM integration: could not add protected-path data"; exit 1; }
TREE=$("${GIT[@]}" rev-parse 'HEAD^{tree}')
COMMITSHA=$("${GIT[@]}" rev-parse HEAD)

run_gate term-eperm term_eperm.intel
rd=$(rd_of intel)
row="$rd/evidence/row-arch.out"
leak="LEAK${TB}4242${TB}4242${TB}Thu Oct 24 12:00:00 2026${TB}/Applications/zigBrowser.app/Contents/MacOS/zigBrowser about:blank"
kept="LEAKED${TB}${leak#LEAK${TB}}"
diag="exec_arch_probe: FAIL (automation socket/token did not appear at $rd/s/a.sock)"
gate=ok
[ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && leg_is arm64 PASS && no_pass \
  && grep -q "HOST_STOPPED${TB}arch" "$OUT" || gate="verdict/host-stop: exit $rc $(tailout)"
[ "$(pyrows intel)" = "m9_render_test.py m9_reply_channel_test.py m9_load_fail_test.py " ] \
  || gate="later-workload: $(pyrows intel)"
[ -n "$rd" ] && [ -d "$rd" ] && [ "$(cat "$rd/LEAKED" 2>/dev/null)" = "$kept" ] \
  || gate="retained marker: rd=$rd marker=$(cat "$rd/LEAKED" 2>/dev/null)"
[ -f "$row" ] && [ "$(grep -cFx "$diag" "$row")" -eq 1 ] && [ "$(grep -cFx "$leak" "$row")" -eq 1 ] \
  && [ "$(grep -cFx "FAIL${TB}mac-teardown-leak${TB}1" "$row")" -eq 1 ] && ! grep -q Traceback "$row" \
  || gate="row transcript: $(tr '\n' '|' < "$row" 2>/dev/null)"
grep -qxF "ROW${TB}arch${TB}rc=1" "$rd/evidence/leg.log" 2>/dev/null \
  && grep -qxF "HOST_STOPPED${TB}arch" "$rd/evidence/leg.log" 2>/dev/null \
  && grep -qxF "$kept" "$rd/evidence/leg.log" 2>/dev/null || gate="leg evidence incomplete"
[ ! -e "$rd/evidence/row-control.out" ] && ! grep -qF "$rd" "$C/find_delete" 2>/dev/null \
  && ! grep '^CLEANUP' "$OUT" | grep -qF "${rd##*/}" || gate="control or cleanup reached retained root"

run_gate leaknext
[ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && leg_is arm64 PASS \
  && grep -q "HOST_HELD${TB}$rd/LEAKED" "$OUT" && [ "$(cat "$rd/LEAKED" 2>/dev/null)" = "$kept" ] \
  && ! grep -q "^intel${TB}attach" "$C/seq" || gate="next run was not held: exit $rc $(tailout)"

if [ "$gate" = ok ]; then
  printf 'PASS\tms1c-term-eperm-gate\tnonzero row, diagnostic, one leak, retained and held\n'
else
  printf 'FAIL\tms1c-term-eperm-gate\t%s\n' "$gate"
  exit 1
fi
'''


def bad(label: str, detail: str) -> None:
    problems.append(f"{label}: {detail}")


def parse_events(lines: list[str]) -> list[str]:
    rows = [line.split("\t", 1)[1].split(",") for line in lines if line.startswith("EVENTS\t")]
    return rows[0] if len(rows) == 1 else []


def require_teardown_case(work: Path, mode: str, pgid: int) -> None:
    result = subprocess.run(
        [sys.executable, "-I", "-B", str(work / "case-driver.py"), str(ROOT), mode, str(work / mode)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=15,
    )
    lines = result.stdout.splitlines()
    leak = f"LEAK\t{PID}\t{pgid}\t{START}\t{COMMAND}"
    leaks = [line for line in lines if line.startswith("LEAK\t")]
    fails = [line for line in lines if line.startswith("FAIL\tmac-teardown-leak")]
    events = parse_events(lines)
    if result.returncode != 1 or leaks != [leak] or fails != ["FAIL\tmac-teardown-leak\t1"]:
        bad(mode, f"wanted exit 1, one exact LEAK and one failure; got rc={result.returncode} stdout={lines!r}")
    if "Traceback" in result.stderr or len(result.stderr.splitlines()) != 1:
        bad(mode, f"teardown escaped or diagnostics were unbounded: {result.stderr[-500:]!r}")
    for required in ("pid", "poll", f"getpgid:{pgid}"):
        if events.count(required) != 1:
            bad(mode, f"missing one pre-signal {required!r}: {events!r}")
    if pgid == PID:
        send = f"killpg:{PID}:{int(signal.SIGTERM)}"
        before = ("pid", "poll", f"getpgid:{pgid}")
        if (
            events.count(send) != 1
            or any(events.count(item) != 1 for item in before)
            or any(events.index(item) > events.index(send) for item in before)
        ):
            bad(mode, f"poll/pid/pgid were not captured before the one TERM attempt: {events!r}")
    elif any(event.startswith("killpg:") for event in events):
        bad(mode, f"a mismatched process group was signalled: {events!r}")
    if any(event.endswith(f":{int(signal.SIGKILL)}") for event in events):
        bad(mode, f"SIGKILL was attempted: {events!r}")


def require_exec_arch_case(work: Path) -> None:
    case_work = work / "exec-arch"
    case_work.mkdir()
    result = subprocess.run(
        [sys.executable, "-I", "-B", str(work / "case-driver.py"), str(ROOT), "exec-arch", str(case_work)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=15,
    )
    lines = result.stdout.splitlines()
    socket_path = Path("s") / "a.sock"
    diag = f"exec_arch_probe: FAIL (automation socket/token did not appear at {socket_path})"
    leak = f"LEAK\t{PID}\t{PID}\t{START}\t{COMMAND}"
    if result.returncode != 1 or lines.count(leak) != 1 or lines.count("FAIL\tmac-teardown-leak\t1") != 1:
        bad("exec-arch", f"wanted one leak failure and exit 1, got rc={result.returncode} stdout={lines!r}")
    if result.stderr.splitlines().count(diag) != 1 or "Traceback" in result.stderr:
        bad("exec-arch", f"the original socket diagnostic was lost or teardown escaped: {result.stderr[-600:]!r}")
    if "PROBE_RC\t2" not in lines or "STATE\tout=absent dir=present" not in lines:
        bad("exec-arch", f"probe did not fail closed while preserving its caller directory: {lines!r}")
    events = parse_events(lines)
    send = f"killpg:{PID}:{int(signal.SIGTERM)}"
    for required in ("popen", f"read:{socket_path}", "pid", "poll", f"getpgid:{PID}", send, f"identity:{PID}"):
        if events.count(required) != 1:
            bad("exec-arch", f"missing one {required!r}: {events!r}")
    if any(event.endswith(f":{int(signal.SIGKILL)}") for event in events):
        bad("exec-arch", f"SIGKILL was attempted: {events!r}")


def require_gate_case(work: Path) -> None:
    source = SELFTEST.read_text(encoding="utf-8")
    marker = "# ── Base run ──\n"
    if source.count(marker) != 1:
        bad("gate", f"expected one fixture boundary, found {source.count(marker)}")
        return
    driver = work / "gate-driver.sh"
    driver.write_text(source.split(marker, 1)[0] + GATE_SUFFIX, encoding="utf-8")
    driver.chmod(0o755)
    env = dict(os.environ)
    env["ZB_MS1C_SELFTEST_INNER"] = "1"
    env["ZB_MS1C_OUTER_PIDNS"] = "pid:[0]"
    result = subprocess.run(
        ["bash", str(driver), str(ROOT)], env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180,
    )
    expected = "PASS\tms1c-term-eperm-gate\tnonzero row, diagnostic, one leak, retained and held"
    if result.returncode != 0 or result.stderr or expected not in result.stdout.splitlines():
        bad("gate", f"rc={result.returncode} stdout={result.stdout.splitlines()[-8:]!r} stderr={result.stderr[-500:]!r}")


def main() -> int:
    if not all(path.is_file() for path in (TEARDOWN, PROBE, SELFTEST)):
        print("FAIL\tms1c-term-eperm-red\tmissing production input")
        return 1
    scratch = Path(os.environ.get("TMPDIR", ""))
    if not scratch.is_dir():
        print("FAIL\tms1c-term-eperm-red\tTMPDIR must name private scratch")
        return 1
    work = Path(tempfile.mkdtemp(prefix="term-eperm-red-", dir=scratch))
    try:
        driver = work / "case-driver.py"
        driver.write_text(CASE_DRIVER, encoding="utf-8")
        (work / "term-eperm").mkdir()
        (work / "wrong-pgid").mkdir()
        require_teardown_case(work, "term-eperm", PID)
        require_teardown_case(work, "wrong-pgid", OTHER_PGID)
        require_exec_arch_case(work)
        require_gate_case(work)
        if problems:
            for problem in problems:
                print(f"FAIL\tms1c-term-eperm-red\t{problem}")
            return 1
        print("PASS\tms1c-term-eperm-red\tEPERM, wrong-pgid, exec-arch diagnostic and retained gate root")
        return 0
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    raise SystemExit(main())
