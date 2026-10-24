#!/usr/bin/env python3
"""RED, UNREGISTERED (SilverRidge 7f4c874b fix-forward): SIGTERM EPERM must retain the MS1c host fail-closed.

This drives the real ``stop_browser_term_only`` helper with an unconfirmed live browser group whose SIGTERM raises
EPERM, with a browser whose actual pgid is not its spawned pid, and with all three required getpgid failures.  Poll,
pid and actual pgid must be captured before any signal; every unconfirmed/mismatched group produces one bounded
identity-bearing LEAK and one ``FAIL<TAB>mac-teardown-leak`` at exit without signalling another group.

The real exec-arch probe then combines its original socket-timeout diagnostic with that teardown failure.  Finally,
the established fake-Mac fixture drives every real MS1c gate row: rc is nonzero, the one LEAK becomes a durable
LEAKED marker, the run root is retained, and the next attempt is HOST_HELD.  The oracle re-execs itself behind
causally verified private user/PID/network namespaces before creating any workload process or timeout, and traps all
direct/group/Popen signal APIs.  This file stays out of build.zig until green.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
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
FD_VARS = {
    "user": "ZB_TERM_EPERM_LAUNCHER_USERNS_FD",
    "pid": "ZB_TERM_EPERM_LAUNCHER_PIDNS_FD",
    "net": "ZB_TERM_EPERM_LAUNCHER_NETNS_FD",
}
GETPGID_CASES = (
    ("getpgid-processlookup", "getpgid:ProcessLookupError"),
    ("getpgid-permission", "getpgid:PermissionError"),
    ("getpgid-oserror", "getpgid:OSError"),
)
problems: list[str] = []


CASE_DRIVER = r'''#!/usr/bin/env python3
import errno
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
    def send_signal(self, sig):
        events.append(f"proc.send_signal:{int(sig)}")
        raise AssertionError("trapped signal API: FakeProc.send_signal")
    def terminate(self):
        events.append("proc.terminate")
        raise AssertionError("trapped signal API: FakeProc.terminate")
    def kill(self):
        events.append("proc.kill")
        raise AssertionError("trapped signal API: FakeProc.kill")

proc = FakeProc()
def getpgid(got):
    assert got == pid
    if mode == "getpgid-processlookup":
        events.append("getpgid:ProcessLookupError")
        raise ProcessLookupError(errno.ESRCH, os.strerror(errno.ESRCH))
    if mode == "getpgid-permission":
        events.append("getpgid:PermissionError")
        raise PermissionError(errno.EPERM, os.strerror(errno.EPERM))
    if mode == "getpgid-oserror":
        events.append("getpgid:OSError")
        raise OSError(errno.EIO, os.strerror(errno.EIO))
    events.append(f"getpgid:{pgid}")
    return pgid
def killpg(got, sig):
    events.append(f"killpg:{got}:{int(sig)}")
    if mode not in ("term-eperm", "exec-arch"):
        raise AssertionError(f"trapped unexpected killpg in {mode}")
    if got != pid or sig != signal.SIGTERM:
        raise AssertionError(f"unexpected signal killpg({got}, {sig})")
    raise PermissionError(errno.EPERM, os.strerror(errno.EPERM))
def kill(got, sig):
    events.append(f"kill:{got}:{int(sig)}")
    raise AssertionError("trapped signal API: os.kill")
def identity(got):
    events.append(f"identity:{got}")
    return [(str(pid), str(got), start, command)]

teardown.os.getpgid = getpgid
teardown.os.killpg = killpg
teardown.os.kill = kill
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
   && [ -f "$C/mode___MODE__.intel" ]; then
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

run_gate __TAG__ __MODE__.intel
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
  printf 'PASS\tms1c-term-eperm-gate\t__LABEL__: nonzero row, diagnostic, one leak, retained and held\n'
else
  printf 'FAIL\tms1c-term-eperm-gate\t%s\n' "$gate"
  exit 1
fi
'''


def launcher_namespace(kind: str) -> int:
    """Return the launcher's namespace inode through an inherited, verified open descriptor."""
    fd = int(os.environ[FD_VARS[kind]])
    if fd < 3:
        raise ValueError(f"descriptor {fd} is not a passed namespace")
    link = os.readlink(f"/proc/self/fd/{fd}")
    match = re.fullmatch(rf"{kind}:\[([0-9]+)\]", link)
    if not match:
        raise ValueError(f"descriptor {fd} is {link[:60]!r}, not a {kind} namespace")
    inode = os.fstat(fd).st_ino
    if inode != int(match.group(1)):
        raise ValueError(f"descriptor {fd} does not stat as {link}")
    return inode


def namespace_problem() -> str | None:
    """Return None only in this oracle's causally verified private user, PID and network namespaces."""
    try:
        launcher = {kind: launcher_namespace(kind) for kind in FD_VARS}
        current = {kind: os.stat(f"/proc/self/ns/{kind}").st_ino for kind in FD_VARS}
    except (KeyError, TypeError, ValueError, OSError) as exc:
        return f"launcher namespace descriptors missing, closed or fake ({type(exc).__name__}: {exc})"
    unchanged = [kind for kind in FD_VARS if current[kind] == launcher[kind]]
    if unchanged:
        return f"not in private {','.join(unchanged)} namespace(s)"
    if os.getpid() == 1 or os.getpid() > 50:
        return f"not under a reaping init in the private PID namespace (pid {os.getpid()})"
    return None


def refusal(why: str) -> str:
    reason = " ".join(why.split())[:300]
    return f"FAIL\tms1c-term-eperm-red\tnamespace refused: {reason}; nothing was run"


def launch_inner() -> int:
    fds = tuple(os.open(f"/proc/self/ns/{kind}", os.O_RDONLY) for kind in FD_VARS)
    try:
        env = {key: value for key, value in os.environ.items() if key not in FD_VARS.values()}
        env.update({FD_VARS[kind]: str(fd) for kind, fd in zip(FD_VARS, fds)})
        command = '"$1" -I -B "$2" --inner; exit $?'
        return subprocess.run(
            ["unshare", "--user", "--map-root-user", "--pid", "--fork", "--kill-child", "--mount-proc",
             "--net", "bash", "-c", command, "term-eperm-init", sys.executable, str(Path(__file__).resolve())],
            env=env, pass_fds=fds, stdin=subprocess.DEVNULL,
        ).returncode
    finally:
        for fd in fds:
            os.close(fd)


def bad(label: str, detail: str) -> None:
    problems.append(f"{label}: {detail}")


def parse_events(lines: list[str]) -> list[str]:
    rows = [line.split("\t", 1)[1].split(",") for line in lines if line.startswith("EVENTS\t")]
    return rows[0] if len(rows) == 1 else []


def signal_events(events: list[str]) -> list[str]:
    return [event for event in events if event.startswith(("killpg:", "kill:", "proc."))]


def require_namespace_refusal(work: Path) -> None:
    guard = work / "namespace-refusal"
    guard.mkdir()
    env = {key: value for key, value in os.environ.items() if key not in FD_VARS.values()}
    env["TMPDIR"] = str(guard)
    result = subprocess.run(
        [sys.executable, "-I", "-B", str(Path(__file__).resolve()), "--inner"], env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=15,
    )
    lines = (result.stdout + result.stderr).splitlines()
    if (result.returncode != 1 or len(lines) != 1 or not lines[0].startswith(
            "FAIL\tms1c-term-eperm-red\tnamespace refused:") or len(lines[0]) > 400 or any(guard.iterdir())):
        bad("namespace", f"unguarded inner run was not bounded/refused: rc={result.returncode} output={lines!r}")


def require_teardown_case(work: Path, mode: str, pgid: int, getpgid_event: str,
                          allowed_signals: list[str]) -> None:
    result = subprocess.run(
        [sys.executable, "-I", "-B", str(work / "case-driver.py"), str(ROOT), mode, str(work / mode)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=15,
    )
    lines = result.stdout.splitlines()
    stderr_lines = result.stderr.splitlines()
    leak = f"LEAK\t{PID}\t{pgid}\t{START}\t{COMMAND}"
    leaks = [line for line in lines if line.startswith("LEAK\t")]
    fails = [line for line in lines if line.startswith("FAIL\tmac-teardown-leak")]
    events = parse_events(lines)
    if result.returncode != 1 or leaks != [leak] or fails != ["FAIL\tmac-teardown-leak\t1"]:
        bad(mode, f"wanted exit 1, one exact LEAK and one failure; got rc={result.returncode} stdout={lines!r}")
    if ("Traceback" in result.stderr or len(stderr_lines) != 1 or len(stderr_lines[0]) > 600
            or len(lines) > 4 or any(len(line) > 1000 for line in lines)):
        bad(mode, f"teardown escaped or diagnostics were unbounded: {result.stderr[-500:]!r}")
    before = ("pid", "poll", getpgid_event)
    for required in before + (f"identity:{pgid}",):
        if events.count(required) != 1:
            bad(mode, f"missing one required event {required!r}: {events!r}")
    if (all(events.count(item) == 1 for item in before)
            and [events.index(item) for item in before] != sorted(events.index(item) for item in before)):
        bad(mode, f"pid/poll/pgid were not captured in order: {events!r}")
    if signal_events(events) != allowed_signals:
        bad(mode, f"signal APIs were {signal_events(events)!r}, wanted {allowed_signals!r}; all events={events!r}")
    if "returncode" in events or "wait" in events:
        bad(mode, f"teardown used uncached status or waited after an unconfirmed TERM: {events!r}")
    if (allowed_signals and events.count(allowed_signals[0]) == 1
            and all(events.count(item) == 1 for item in before)):
        if events.index(allowed_signals[0]) < max(events.index(item) for item in before):
            bad(mode, f"a signal was attempted before pid/poll/pgid capture: {events!r}")


def require_exec_arch_case(work: Path) -> None:
    case_work = work / "exec-arch"
    case_work.mkdir()
    result = subprocess.run(
        [sys.executable, "-I", "-B", str(work / "case-driver.py"), str(ROOT), "exec-arch", str(case_work)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=15,
    )
    lines = result.stdout.splitlines()
    stderr_lines = result.stderr.splitlines()
    socket_path = Path("s") / "a.sock"
    diag = f"exec_arch_probe: FAIL (automation socket/token did not appear at {socket_path})"
    leak = f"LEAK\t{PID}\t{PID}\t{START}\t{COMMAND}"
    if result.returncode != 1 or lines.count(leak) != 1 or lines.count("FAIL\tmac-teardown-leak\t1") != 1:
        bad("exec-arch", f"wanted one leak failure and exit 1, got rc={result.returncode} stdout={lines!r}")
    if (stderr_lines.count(diag) != 1 or "Traceback" in result.stderr or len(stderr_lines) != 2
            or any(len(line) > 600 for line in stderr_lines)):
        bad("exec-arch", f"the socket diagnostic was lost or teardown diagnostics escaped: {result.stderr[-600:]!r}")
    if "PROBE_RC\t2" not in lines or "STATE\tout=absent dir=present" not in lines:
        bad("exec-arch", f"probe did not fail closed while preserving its caller directory: {lines!r}")
    events = parse_events(lines)
    send = f"killpg:{PID}:{int(signal.SIGTERM)}"
    required = ("popen", f"read:{socket_path}", "pid", "poll", f"getpgid:{PID}", send, f"identity:{PID}")
    for event in required:
        if events.count(event) != 1:
            bad("exec-arch", f"missing one {event!r}: {events!r}")
    if signal_events(events) != [send]:
        bad("exec-arch", f"signal APIs were {signal_events(events)!r}, wanted only {[send]!r}")
    before = ("pid", "poll", f"getpgid:{PID}")
    if all(events.count(item) == 1 for item in before) and events.count(send) == 1:
        if events.index(send) < max(events.index(item) for item in before):
            bad("exec-arch", f"TERM preceded pid/poll/pgid capture: {events!r}")
    if "returncode" in events or "wait" in events:
        bad("exec-arch", f"teardown used uncached status or waited after EPERM: {events!r}")


def require_signal_mutants(work: Path) -> None:
    source = TEARDOWN.read_text(encoding="utf-8")
    anchor = "os.killpg(pgid, signal.SIGTERM)"
    if source.count(anchor) != 1:
        bad("signal-mutants", f"expected one killpg anchor, found {source.count(anchor)}")
        return
    mutants = (
        ("direct-kill", "os.kill(pgid, signal.SIGTERM)", f"kill:{PID}:{int(signal.SIGTERM)}"),
        ("proc-send-signal", "proc.send_signal(signal.SIGTERM)", f"proc.send_signal:{int(signal.SIGTERM)}"),
        ("proc-terminate", "proc.terminate()", "proc.terminate"),
        ("proc-kill", "proc.kill()", "proc.kill"),
    )
    for label, replacement, expected_event in mutants:
        root = work / f"mutant-{label}"
        target = root / "tests" / "e2e" / "mac_term_teardown.py"
        target.parent.mkdir(parents=True)
        target.write_text(source.replace(anchor, replacement, 1), encoding="utf-8")
        case_work = work / f"case-{label}"
        case_work.mkdir()
        result = subprocess.run(
            [sys.executable, "-I", "-B", str(work / "case-driver.py"), str(root), "term-eperm", str(case_work)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=15,
        )
        lines = result.stdout.splitlines()
        events = parse_events(lines)
        if (result.returncode != 1 or signal_events(events) != [expected_event]
                or "AssertionError: trapped signal API" not in result.stderr
                or any(line.startswith(("LEAK\t", "FAIL\tmac-teardown-leak")) for line in lines)):
            bad(label, f"signal mutant was not safely red: rc={result.returncode} events={events!r} "
                       f"stdout={lines!r} stderr={result.stderr[-300:]!r}")


def require_gate_case(work: Path, mode: str, label: str) -> None:
    source = SELFTEST.read_text(encoding="utf-8")
    marker = "# ── Base run ──\n"
    if source.count(marker) != 1:
        bad(f"gate-{mode}", f"expected one fixture boundary, found {source.count(marker)}")
        return
    shell_mode = mode.replace("-", "_")
    suffix = GATE_SUFFIX.replace("__MODE__", shell_mode).replace("__TAG__", mode).replace("__LABEL__", label)
    driver = work / f"gate-driver-{shell_mode}.sh"
    driver.write_text(source.split(marker, 1)[0] + suffix, encoding="utf-8")
    driver.chmod(0o755)
    env = dict(os.environ)
    env["ZB_MS1C_SELFTEST_INNER"] = "1"
    env["ZB_MS1C_OUTER_PIDNS"] = "pid:[0]"
    result = subprocess.run(
        ["bash", str(driver), str(ROOT)], env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180,
    )
    expected = (f"PASS\tms1c-term-eperm-gate\t{label}: nonzero row, diagnostic, one leak, retained and held")
    if result.returncode != 0 or result.stderr or expected not in result.stdout.splitlines():
        bad(f"gate-{mode}", f"rc={result.returncode} stdout={result.stdout.splitlines()[-8:]!r} "
                            f"stderr={result.stderr[-500:]!r}")


def run_inner() -> int:
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
        for mode in ("term-eperm", "wrong-pgid", *(case[0] for case in GETPGID_CASES)):
            (work / mode).mkdir()
        require_namespace_refusal(work)
        send = f"killpg:{PID}:{int(signal.SIGTERM)}"
        require_teardown_case(work, "term-eperm", PID, f"getpgid:{PID}", [send])
        require_teardown_case(work, "wrong-pgid", OTHER_PGID, f"getpgid:{OTHER_PGID}", [])
        for mode, getpgid_event in GETPGID_CASES:
            require_teardown_case(work, mode, PID, getpgid_event, [])
        require_exec_arch_case(work)
        require_signal_mutants(work)
        gate_cases = (("term-eperm", "killpg EPERM"),
                      ("getpgid-processlookup", "getpgid ProcessLookupError"),
                      ("getpgid-permission", "getpgid PermissionError"),
                      ("getpgid-oserror", "getpgid OSError"))
        for mode, label in gate_cases:
            require_gate_case(work, mode, label)
        if problems:
            for problem in problems:
                print(f"FAIL\tms1c-term-eperm-red\t{problem}")
            return 1
        print("PASS\tms1c-term-eperm-red\tprivate namespaces, all signal APIs, EPERM/getpgid failures, "
              "exec diagnostic and retained gate roots")
        return 0
    finally:
        shutil.rmtree(work)


def main() -> int:
    args = sys.argv[1:]
    if not args:
        return launch_inner()
    why = namespace_problem()
    if args != ["--inner"] or why:
        print(refusal(why or f"bad arguments {args!r}"), flush=True)
        return 1
    return run_inner()


if __name__ == "__main__":
    raise SystemExit(main())
