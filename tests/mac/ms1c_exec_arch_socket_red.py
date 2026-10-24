#!/usr/bin/env python3
"""RED, UNREGISTERED (SilverRidge f69c8dad): MS1c must give the real exec-arch probe a short socket path.

The consumed Intel run placed ``automation.sock`` under its long private TMPDIR and produced a 135-byte pathname,
which cannot fit in macOS's 104-byte ``sockaddr_un.sun_path`` field.  This oracle drives the real probe main path,
browser launch and TERM-only cleanup while replacing only the already-tested JSON-RPC reader seam.  A long TMPDIR
is retained, but an explicit socket directory inside the same run root must produce short socket/token paths, clean
both artifacts, replace stale output, and report the executing architecture.  Both paths must be rejected before
launch when they are not shorter than the macOS bound.  Finally, a field-isolated restoration of
``tempfile.mkdtemp()`` beneath the long TMPDIR must make the oracle red.  The real MS1c fake-Mac execution fixture
also records the gate-to-probe argv and directory state for both legs, preserving P5/F19 while rejecting dropped,
TMPDIR, outside, duplicate and other-run-root caller arguments.

This file stays out of build.zig until the production green.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap


MACOS_SUN_PATH_BYTES = 104
SOCKET_BASENAME = "a.sock"
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
PROBE = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else HERE / "exec_arch_probe.py"
SELFTEST = HERE / "ms1c_app_gate_selftest.sh"
problems: list[str] = []


FAKE_BROWSER = r'''#!/usr/bin/env python3
import os
import signal

path = os.environ.get("ZIGBROWSER_SOCKET", "")
with open(os.environ["ZB_BROWSER_LOG"], "a", encoding="utf-8") as log:
    log.write(path + "\n")
while True:
    signal.pause()
'''


PROBE_DRIVER = r'''#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import sys

probe = Path(sys.argv[1]).resolve()
forwarded = sys.argv[2:]
spec = importlib.util.spec_from_file_location("exec_arch_probe_under_test", probe)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

real_popen = module.subprocess.Popen
def recording_popen(*args, **kwargs):
    with open(os.environ["ZB_POPEN_LOG"], "a", encoding="utf-8") as log:
        log.write(kwargs.get("env", {}).get("ZIGBROWSER_SOCKET", "") + "\n")
    return real_popen(*args, **kwargs)
module.subprocess.Popen = recording_popen

def read_exec_arch(sock_path, _timeout):
    with open(os.environ["ZB_SOCKET_LOG"], "a", encoding="utf-8") as log:
        log.write(sock_path + "\n")
    token_path = sock_path + ".token"
    if len(os.fsencode(sock_path)) >= 104 or len(os.fsencode(token_path)) >= 104:
        raise RuntimeError(f"automation socket/token did not appear at {sock_path}")
    Path(sock_path).write_bytes(b"socket-sentinel")
    Path(token_path).write_text("token-sentinel\n", encoding="ascii")
    return "x86_64"

module.read_exec_arch = read_exec_arch
sys.argv = [str(probe)] + forwarded
raise SystemExit(module.main())
'''


INTEGRATION_SUFFIX = r'''
# Record the executed exec_arch_probe.py argv before the fixture consumes it. This is execution evidence from the
# real gate's remote leg: the wrapper delegates every call to the unchanged fixture implementation.
mv -f "$X/hostbin/python3" "$X/hostbin/python3.fixture" || exit 1
cat > "$X/hostbin/python3" <<EOF
#!/bin/bash
script=\${1:-}
if [ "\${script##*/}" = exec_arch_probe.py ]; then
  shift
  args=("\$@")
  printf '1\n' >> "$C/socket-call.\${ZB_ROLE}.count"
  { printf '%s\0' "\$ZB_ROLE" "\$PWD"; printf '%s\0' "\${args[@]}"; } > "$C/socket-call.\${ZB_ROLE}.argv"
  : > "$C/socket-call.\${ZB_ROLE}.dirs"
  i=0
  while [ \$i -lt \${#args[@]} ]; do
    if [ "\${args[\$i]}" = --socket-dir ]; then
      j=\$((i + 1)); value=\${args[\$j]:-}
      exists=no; [ -d "\$value" ] && exists=yes
      mode=\$(/usr/bin/stat -c '%a' -- "\$value" 2>/dev/null || printf -- -)
      printf '%s\t%s\t%s\n' "\$value" "\$exists" "\$mode" >> "$C/socket-call.\${ZB_ROLE}.dirs"
      i=\$((i + 2))
    else
      i=\$((i + 1))
    fi
  done
  exec "$X/hostbin/python3.fixture" "\$script" "\${args[@]}"
fi
exec "$X/hostbin/python3.fixture" "\$@"
EOF
chmod 0755 "$X/hostbin/python3"

cat > "$T/check-socket-call.py" <<'PY'
import os
from pathlib import Path
import sys

ctl, role, run_root = Path(sys.argv[1]), sys.argv[2], os.path.normpath(sys.argv[3])
prefix = ctl / ("socket-call." + role)
try:
    counts = (Path(str(prefix) + ".count")).read_text(encoding="ascii").splitlines()
    raw = (Path(str(prefix) + ".argv")).read_bytes().split(b"\0")
    dirs = (Path(str(prefix) + ".dirs")).read_text(encoding="utf-8").splitlines()
except OSError:
    raise SystemExit(1)
if raw[-1:] == [b""]:
    raw.pop()
fields = [os.fsdecode(item) for item in raw]
if counts != ["1"] or len(fields) < 2 or fields[:2] != [role, run_root]:
    raise SystemExit(1)
args = fields[2:]
indices = [index for index, arg in enumerate(args) if arg == "--socket-dir"]
if len(indices) != 1 or indices[0] + 1 >= len(args):
    raise SystemExit(1)
value = os.path.normpath(args[indices[0] + 1])
want = os.path.join(run_root, "s")
if value != want or os.path.dirname(value) != run_root or os.path.basename(value) != "s":
    raise SystemExit(1)
if dirs != [f"{want}\tyes\t700"]:
    raise SystemExit(1)
PY

cp -f -- "$ROOT/tests/mac/ms1c_home_protected_paths.txt" "$R/tests/mac/ms1c_home_protected_paths.txt" \
  && "${GIT[@]}" add -- tests/mac/ms1c_home_protected_paths.txt \
  && "${GIT[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m protected-data \
  || { bad "caller integration: could not add protected-path data"; exit 1; }
TREE=$("${GIT[@]}" rev-parse 'HEAD^{tree}')
COMMITSHA=$("${GIT[@]}" rev-parse HEAD)
CANDIDATE="$T/ms1c_app_gate.candidate"
cp -f -- "$R/tests/mac/ms1c_app_gate.sh" "$CANDIDATE" || exit 1

socket_contract() { # socket_contract <role>
  local role=$1 rd
  rd=$(rd_of "$role")
  [ -n "$rd" ] && /usr/bin/python3 -I -B "$T/check-socket-call.py" "$C" "$role" "$rd"
}
p5_contract() {
  local role rd rows names wantenv p5=ok
  for role in intel arm; do
    rd=$(rd_of "$role")
    rows=$(awk -F'\t' -v r=$role '$1 == r && $2 != "control"' "$C/py.log" 2>/dev/null)
    names=$(cut -f2 <<<"$rows" | LC_ALL=C sort | tr '\n' ' ')
    [ "$names" = "exec_arch_probe.py m9_load_fail_test.py m9_render_test.py m9_reply_channel_test.py " ] \
      || { p5="$role ran '$names'"; continue; }
    wantenv="HOME=$rd/run-env/home|CF=$rd/run-env/home|TMPDIR=$rd/run-env/tmp/|XD=$rd/run-env/xdg-data|XC=$rd/run-env/xdg-cache|XG=$rd/run-env/xdg-config|XR=$rd/run-env/xdg-runtime|S=$rd/s|E=1"
    while IFS=$'\t' read -r _ name br zo envl; do
      [ "$br" = "$rd/$APPEXE" ] && [ "$zo" = absent ] && [ "$envl" = "$wantenv" ] \
        || p5="$role $name: browser '$br' zig-out $zo env '$envl'"
    done <<<"$rows"
  done
  [ "$p5" = ok ]
}
base_gate_ok() {
  [ "$rc" -eq 0 ] && leg_is x86_64 PASS && leg_is arm64 PASS \
    && grep -q "^PASS${TB}ms1c-app-gate${TB}both-arches${TB}" "$OUT" && p5_contract
}

run_gate socket-caller
if base_gate_ok; then ok "I-P5: the unmodified P5 workload/environment contract still passes"
else bad "I-P5: base gate or P5 failed: exit $rc $(tailout)"; fi
if socket_contract intel && socket_contract arm; then
  ok "I1: each real gate leg passes one exact existing mode-0700 <RD>/s to exec_arch_probe.py"
else
  bad "I1: the real gate did not pass one exact existing mode-0700 <RD>/s per leg"
fi

run_gate socket-f19 skip_arch.intel
if [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && p5_contract \
   && socket_contract intel && socket_contract arm; then
  ok "I-F19: exec_arch_probe exit 77 remains FAIL while the caller contract is preserved"
else
  bad "I-F19: F19 or its caller contract regressed: exit $rc $(tailout)"
fi

install_variant() { # install_variant <dropped|tmpdir|outside|duplicate|other-root>
  local variant=$1
  /usr/bin/python3 -I -B - "$CANDIDATE" "$R/tests/mac/ms1c_app_gate.sh" "$variant" <<'PY'
from pathlib import Path
import sys
source, target, variant = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
text = source.read_text()
needle = ' --socket-dir "$RD/s"'
if text.count(needle) != 1:
    raise SystemExit(4)
replacement = {
    "dropped": "",
    "tmpdir": ' --socket-dir "$TMPDIR"',
    "outside": ' --socket-dir "/tmp/zb-ms1c-socket-outside"',
    "duplicate": needle + needle,
    "other-root": ' --socket-dir "$REAL_HOME/other-run/s"',
}[variant]
target.write_text(text.replace(needle, replacement))
PY
  [ "$?" -eq 0 ] || return 2
  "${GIT[@]}" add -- tests/mac/ms1c_app_gate.sh \
    && "${GIT[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m "socket-$variant" \
    || return 1
  TREE=$("${GIT[@]}" rev-parse 'HEAD^{tree}')
  COMMITSHA=$("${GIT[@]}" rev-parse HEAD)
}

mutants=ok
for variant in dropped tmpdir outside duplicate other-root; do
  if ! install_variant "$variant"; then
    mutants="setup-$variant"; break
  fi
  if [ "$variant" = other-root ]; then
    for role in intel arm; do mkdir -p "$X/hosts/$role/other-run/s"; chmod 700 "$X/hosts/$role/other-run/s"; done
  fi
  run_gate "socket-$variant"
  if ! base_gate_ok; then mutants="gate-$variant"; break; fi
  if socket_contract intel || socket_contract arm; then mutants="survived-$variant"; break; fi
done
if [ "$mutants" = ok ]; then
  ok "IM: dropped, TMPDIR, outside, duplicate and other-run-root caller mutants are red"
else
  bad "IM: caller mutant result $mutants"
fi

if [ "$fails" -eq 0 ]; then
  printf 'PASS\tms1c-exec-arch-caller\treal gate, P5/F19 and five caller mutants\n'
fi
exit "$fails"
'''


def bad(label: str, detail: str) -> None:
    problems.append(f"{label}: {detail}")


def byte_len(path: Path | str) -> int:
    return len(os.fsencode(path))


def run_gate_integration(work: Path) -> None:
    try:
        source = SELFTEST.read_text(encoding="utf-8")
    except OSError as exc:
        bad("gate integration", f"could not read {SELFTEST}: {exc}")
        return
    marker = "# ── Base run ──\n"
    if source.count(marker) != 1:
        bad("gate integration", f"expected one fixture boundary, found {source.count(marker)}")
        return
    driver = work / "caller-integration.sh"
    driver.write_text(source.split(marker, 1)[0] + INTEGRATION_SUFFIX, encoding="utf-8")
    driver.chmod(0o755)
    env = dict(os.environ)
    env["ZB_MS1C_SELFTEST_INNER"] = "1"
    env["ZB_MS1C_OUTER_PIDNS"] = "pid:[0]"
    try:
        result = subprocess.run(
            ["bash", str(driver), str(ROOT)], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=240,
        )
    except subprocess.TimeoutExpired:
        bad("gate integration", "real gate execution fixture timed out")
        return
    expected = "PASS\tms1c-exec-arch-caller\treal gate, P5/F19 and five caller mutants"
    if result.returncode != 0 or result.stderr or expected not in result.stdout.splitlines():
        failures = [line for line in result.stdout.splitlines() if line.startswith("FAIL")]
        bad("gate integration", f"rc={result.returncode} failures={failures[-8:]!r} stderr={result.stderr[-400:]!r}")


def run_probe(
    driver: Path,
    probe: Path,
    browser: Path,
    output: Path,
    socket_log: Path,
    long_tmp: Path,
    socket_dir: Path | None,
) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["TMPDIR"] = str(long_tmp)
    env["ZB_SOCKET_LOG"] = str(socket_log)
    env["ZB_BROWSER_LOG"] = str(socket_log) + ".browser"
    env["ZB_POPEN_LOG"] = str(socket_log) + ".popen"
    argv = [sys.executable, "-I", "-B", str(driver), str(probe), "--browser", str(browser), "--out", str(output),
            "--timeout", "0.5"]
    if socket_dir is not None:
        argv.extend(("--socket-dir", str(socket_dir)))
    return subprocess.run(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)


def socket_dir_for_length(parent: Path, wanted_socket_bytes: int, tag: str) -> Path:
    base = parent / tag
    base.mkdir()
    fixed = byte_len(base) + 2 + len(SOCKET_BASENAME.encode())
    component = wanted_socket_bytes - fixed
    if not 1 <= component <= 200:
        raise RuntimeError(f"cannot construct {wanted_socket_bytes}-byte socket below {base}: need {component}")
    result = base / ("d" * component)
    result.mkdir()
    actual = byte_len(result / SOCKET_BASENAME)
    if actual != wanted_socket_bytes:
        raise RuntimeError(f"constructed socket is {actual}, not {wanted_socket_bytes} bytes")
    return result


def expect_preflight(
    label: str,
    driver: Path,
    probe: Path,
    browser: Path,
    run_root: Path,
    long_tmp: Path,
    socket_dir: Path,
    kind: str,
    size: int,
) -> None:
    output = run_root / f"{label}.out"
    socket_log = run_root / f"{label}.browser-log"
    output.write_text("stale\n", encoding="ascii")
    result = run_probe(driver, probe, browser, output, socket_log, long_tmp, socket_dir)
    expected = f"exec_arch_probe: FAIL (automation {kind} path is {size} bytes; macOS Unix-domain limit is 103 bytes)"
    if result.returncode != 2:
        bad(label, f"wanted preflight rc 2, got {result.returncode}: {result.stderr[-300:]!r}")
    if result.stdout:
        bad(label, f"preflight wrote stdout {result.stdout!r}")
    if result.stderr.splitlines() != [expected]:
        bad(label, f"wanted one bounded diagnostic {expected!r}, got {result.stderr.splitlines()!r}")
    if output.exists():
        bad(label, "stale output survived the refused run")
    browser_log = Path(str(socket_log) + ".browser")
    popen_log = Path(str(socket_log) + ".popen")
    if socket_log.exists() or browser_log.exists() or popen_log.exists():
        bad(label, "Popen, the reader or the browser ran before preflight")


def main() -> int:
    if not PROBE.is_file():
        print(f"FAIL\tms1c-exec-arch-socket-red\tmissing probe {PROBE}")
        return 1
    scratch = Path(os.environ.get("TMPDIR", ""))
    if not scratch.is_dir():
        print("FAIL\tms1c-exec-arch-socket-red\tTMPDIR must name the private scratch directory")
        return 1
    work = Path(tempfile.mkdtemp(prefix="socket-red-", dir=scratch))
    try:
        run_root = work / "run"
        socket_dir = run_root / "s"
        long_tmp = run_root / "run-env" / "tmp" / ("long-" + "t" * 70)
        socket_dir.mkdir(parents=True)
        long_tmp.mkdir(parents=True)
        browser = work / "fake-browser"
        browser.write_text(textwrap.dedent(FAKE_BROWSER), encoding="utf-8")
        browser.chmod(0o755)
        driver = work / "probe-driver.py"
        driver.write_text(textwrap.dedent(PROBE_DRIVER), encoding="utf-8")

        short_socket = socket_dir / SOCKET_BASENAME
        short_token = Path(str(short_socket) + ".token")
        if byte_len(short_token) >= MACOS_SUN_PATH_BYTES:
            bad("setup", f"explicit token path is not short: {byte_len(short_token)} bytes")

        # Control: the current implicit tempfile placement is too long under this otherwise valid private run root.
        old_out = run_root / "implicit.out"
        old_log = run_root / "implicit.browser-log"
        old = run_probe(driver, PROBE, browser, old_out, old_log, long_tmp, None)
        seen = old_log.read_text(encoding="utf-8").splitlines() if old_log.is_file() else []
        if old.returncode == 0 or old_out.exists():
            bad("implicit control", f"overlong implicit placement unexpectedly passed with rc {old.returncode}")
        if seen:
            if len(seen) != 1 or not seen[0].startswith(str(long_tmp) + os.sep):
                bad("implicit control", f"reader did not observe one TMPDIR socket: {seen!r}")
            elif byte_len(seen[0]) < MACOS_SUN_PATH_BYTES and byte_len(seen[0] + ".token") < MACOS_SUN_PATH_BYTES:
                bad("implicit control", f"fixture did not cross the macOS limit: {seen[0]!r}")
        elif "macOS Unix-domain limit is 103 bytes" not in old.stderr:
            bad("implicit control", f"neither the overlong path nor its preflight was observed: {old.stderr!r}")

        # Required path: the same long TMPDIR succeeds only because the socket is explicitly placed at <run>/s/a.sock.
        output = run_root / "reported-arch"
        socket_log = run_root / "explicit.browser-log"
        output.write_text("stale\n", encoding="ascii")
        result = run_probe(driver, PROBE, browser, output, socket_log, long_tmp, socket_dir)
        if result.returncode != 0:
            bad("explicit placement", f"wanted rc 0, got {result.returncode}: {result.stderr[-400:]!r}")
        if result.stdout.splitlines() != ["exec_arch_probe: build.exec_arch=x86_64"] or result.stderr:
            bad("explicit placement", f"unexpected transcript stdout={result.stdout!r} stderr={result.stderr!r}")
        if not output.is_file() or output.read_text(encoding="ascii") != "x86_64\n":
            bad("explicit placement", "stale output was not replaced by the reported architecture")
        observed = socket_log.read_text(encoding="utf-8").splitlines() if socket_log.is_file() else []
        if observed != [str(short_socket)]:
            bad("explicit placement", f"browser observed {observed!r}, not {[str(short_socket)]!r}")
        popen_log = Path(str(socket_log) + ".popen")
        launched = popen_log.read_text(encoding="utf-8").splitlines() if popen_log.is_file() else []
        if launched != [str(short_socket)]:
            bad("explicit placement", f"Popen observed {launched!r}, not {[str(short_socket)]!r}")
        if short_socket.exists() or short_token.exists():
            bad("explicit placement", "probe did not delete both socket and token")
        if not socket_dir.is_dir() or not str(short_socket).startswith(str(run_root) + os.sep):
            bad("explicit placement", "short socket directory escaped or was removed with the endpoint")

        # The token can cross the limit while the socket still fits; each path therefore needs its own preflight.
        token_limit_dir = socket_dir_for_length(run_root, 100, "token-limit")
        expect_preflight("token preflight", driver, PROBE, browser, run_root, long_tmp, token_limit_dir, "token", 106)
        socket_limit_dir = socket_dir_for_length(run_root, 104, "socket-limit")
        expect_preflight("socket preflight", driver, PROBE, browser, run_root, long_tmp, socket_limit_dir, "socket", 104)

        # Causal mutant: restore only the old TMPDIR placement while leaving the path checks and all other code intact.
        source = PROBE.read_text(encoding="utf-8")
        anchor = ('    tmp = args.socket_dir if args.socket_dir is not None '
                  'else tempfile.mkdtemp(prefix="zb-exec-arch-")\n')
        if source.count(anchor) != 1:
            bad("TMPDIR mutant", f"expected one explicit-placement anchor, found {source.count(anchor)}")
        else:
            mutant_root = work / "mutant"
            mutant_mac = mutant_root / "tests" / "mac"
            mutant_e2e = mutant_root / "tests" / "e2e"
            mutant_mac.mkdir(parents=True)
            mutant_e2e.mkdir(parents=True)
            mutant = mutant_mac / "exec_arch_probe.py"
            mutant.write_text(source.replace(anchor, '    tmp = tempfile.mkdtemp(prefix="zb-exec-arch-")\n'),
                              encoding="utf-8")
            shutil.copy2(ROOT / "tests" / "e2e" / "mac_term_teardown.py", mutant_e2e / "mac_term_teardown.py")
            mutant_out = run_root / "mutant.out"
            mutant_log = run_root / "mutant.browser-log"
            mutated = run_probe(driver, mutant, browser, mutant_out, mutant_log, long_tmp, socket_dir)
            if mutated.returncode == 0 or mutant_out.exists():
                bad("TMPDIR mutant", f"restored tempfile placement survived with rc {mutated.returncode}")

        run_gate_integration(work)

        if problems:
            for problem in problems:
                print(f"FAIL\tms1c-exec-arch-socket-red\t{problem}")
            return 1
        print("PASS\tms1c-exec-arch-socket-red\tshort-path, real caller, preflight, cleanup and six mutants")
        return 0
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    raise SystemExit(main())
