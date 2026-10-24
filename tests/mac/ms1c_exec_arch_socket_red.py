#!/usr/bin/env python3
"""RED, UNREGISTERED (SilverRidge f69c8dad): MS1c must give the real exec-arch probe a short socket path.

The consumed Intel run placed ``automation.sock`` under its long private TMPDIR and produced a 135-byte pathname,
which cannot fit in macOS's 104-byte ``sockaddr_un.sun_path`` field.  This oracle drives the real probe main path,
browser launch and TERM-only cleanup while replacing only the already-tested JSON-RPC reader seam.  A long TMPDIR
is retained, but an explicit socket directory inside the same run root must produce short socket/token paths, clean
both artifacts, replace stale output, and report the executing architecture.  Both paths must be rejected before
launch when they are not shorter than the macOS bound.  Finally, a field-isolated restoration of
``tempfile.mkdtemp()`` beneath the long TMPDIR must make the oracle red.

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


def bad(label: str, detail: str) -> None:
    problems.append(f"{label}: {detail}")


def byte_len(path: Path | str) -> int:
    return len(os.fsencode(path))


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

        if problems:
            for problem in problems:
                print(f"FAIL\tms1c-exec-arch-socket-red\t{problem}")
            return 1
        print("PASS\tms1c-exec-arch-socket-red\tshort-path, preflight, cleanup and TMPDIR mutant")
        return 0
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    raise SystemExit(main())
