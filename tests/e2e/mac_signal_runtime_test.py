#!/usr/bin/env python3
"""RED, UNREGISTERED: prove the macOS signal path in the live application.

The eventual green row is run by ``tests/mac/ms_runtime_rows_gate.sh`` on both Macs.  It launches the exact
built browser afresh for a guard case and for SIGHUP, SIGINT and SIGTERM.  Before sending a signal it proves
bounded automation readiness and records an exact, live process identity.  The e2e-only disposition seam must
report the result of ``sigaction(signo, NULL, ...)`` as SIG_IGN for all three signals; without
``--e2e-protocol`` that report must be absent.  SIGHUP must reload exactly once and leave the app responsive.
SIGINT and SIGTERM must each exit normally with code 130.  No timeout path sends SIGKILL.

``--selftest`` is hostless.  It drives the same verdict code with a model of the good implementation and the
required old-handler, HUP/exit-swap, dropped-source, guard-drop and bad-identity mutants.  It also binds the
live-query source seam and its future named-gate/fake-host registration.  Until the green lands, those production
and gate contracts intentionally make this file exit 1.

Hostless red command (the outer namespace is mandatory even though the model never calls os.kill)::

  unshare --user --map-root-user --pid --fork --mount-proc \
    python3 -X dev tests/e2e/mac_signal_runtime_test.py --selftest
"""
from __future__ import annotations

import argparse
import http.server
import os
import secrets
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from automation_core_test import RpcClient, _read_lines  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SHIM = ROOT / "src" / "wkwebview_shim.m"
GATE = ROOT / "tests" / "mac" / "ms_runtime_rows_gate.sh"
EVIDENCE_SELFTEST = ROOT / "tests" / "mac" / "ms_runtime_rows_evidence_selftest.sh"
OUTPUT_SELFTEST = ROOT / "tests" / "mac" / "ms_runtime_rows_output_selftest.sh"
ROW_FILE = "tests/e2e/mac_signal_runtime_test.py"
ROW_ID = "mac-signal-runtime"
ROW_SPEC = f'"{ROW_FILE}|green|{ROW_ID}"'
SEAM_BEGIN = "// ZB_SIGNAL_DISPOSITION_SEAM_BEGIN"
SEAM_END = "// ZB_SIGNAL_DISPOSITION_SEAM_END"
REPORT_PREFIX = "SIGNAL_DISPOSITION\t"
REPORT = "SIGNAL_DISPOSITION\tSIGINT=SIG_IGN\tSIGTERM=SIG_IGN\tSIGHUP=SIG_IGN"
SIGNAL_CASES = (("HUP", signal.SIGHUP), ("INT", signal.SIGINT), ("TERM", signal.SIGTERM))
HUP_QUIT_AFTER_MS = 8000


@dataclass(frozen=True)
class Identity:
    pid: int
    pgid: int
    start: str
    command: str


class Verdict:
    def __init__(self, emit: Callable[[str], None]):
        self.failures: list[str] = []
        self.emit = emit

    def fail(self, code: str, detail: str) -> None:
        self.failures.append(f"{code}: {detail}")


class FixtureServer:
    """One no-store page per launch; its title and counter make a SIGHUP reload observable and countable."""

    def __init__(self):
        self._counts: dict[str, int] = {}
        self._lock = threading.Lock()
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                label = self.path.lstrip("/").split("?", 1)[0]
                with outer._lock:
                    outer._counts[label] = outer._counts.get(label, 0) + 1
                    count = outer._counts[label]
                title = f"{label}-{count}"
                body = ("<!doctype html><meta charset=utf-8><title>" + title + "</title><p>" + title).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                pass

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        self.base_url = f"http://127.0.0.1:{self._server.server_address[1]}"

    def __enter__(self):
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *_args):
        self._server.shutdown()
        self._server.server_close()

    def count(self, label: str) -> int:
        with self._lock:
            return self._counts.get(label, 0)


class ActualSession:
    """One real browser launch.  Every signal send revalidates the recorded identity immediately beforehand."""

    def __init__(self, browser: Path, fixture: FixtureServer, label: str, e2e: bool, timeout_sec: float):
        self.browser = str(browser.resolve())
        self.fixture = fixture
        self.label = label
        self.timeout_sec = timeout_sec
        self.sent: list[int] = []
        self.tmp = Path(tempfile.mkdtemp(prefix=f"zb-signal-{label.lower()}-"))
        (self.tmp / "profile").mkdir()
        socket_root = Path(os.environ.get("ZB_E2E_SOCKET_DIR", str(self.tmp)))
        self.socket_path = socket_root / f"sig-{label.lower()}-{secrets.token_hex(3)}.sock"
        if sys.platform == "darwin" and len(str(self.socket_path)) > 103:
            raise RuntimeError(f"socket path is {len(str(self.socket_path))} bytes; macOS permits 103")
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(self.socket_path)
        env["ZB_DEBUG_SIGNAL_DISPOSITIONS"] = "1"
        env["ZB_DEBUG_EPHEMERAL_DATA_STORE"] = "1"
        if label == "HUP":
            env["ZB_DEBUG_QUIT_AFTER_MS"] = str(HUP_QUIT_AFTER_MS)
        argv = [self.browser, f"{fixture.base_url}/{label}", "--automation-api"]
        if e2e:
            argv.append("--e2e-protocol")
        argv += ["--profile-dir", str(self.tmp / "profile")]
        self.proc = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, start_new_session=True,
        )
        self.out: list[str] = []
        self.err: list[str] = []
        for stream, lines in ((self.proc.stdout, self.out), (self.proc.stderr, self.err)):
            threading.Thread(target=_read_lines, args=(stream, lines), daemon=True).start()
        self.rpc: RpcClient | None = None
        self._leak_printed = False

    def ready(self) -> bool:
        try:
            self.rpc = RpcClient(self.socket_path, self.timeout_sec)
            title = self.rpc.call("page.title", {"timeout_ms": 10000}).get("title")
            return title == f"{self.label}-1"
        except Exception:
            return False

    def disposition_lines(self, wait_sec: float) -> list[str]:
        deadline = time.monotonic() + wait_sec
        while time.monotonic() < deadline:
            lines = [line for line in self.err if line.startswith(REPORT_PREFIX)]
            if lines:
                time.sleep(0.1)  # a duplicate from the same startup must be visible to the exact-count check
                return [line for line in self.err if line.startswith(REPORT_PREFIX)]
            if self.proc.poll() is not None:
                break
            time.sleep(0.02)
        return [line for line in self.err if line.startswith(REPORT_PREFIX)]

    def identity(self) -> Identity:
        pid = self.proc.pid
        ids = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "pid=", "-o", "pgid="],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout.split()
        if len(ids) != 2:
            raise RuntimeError(f"ps returned no unique pid/pgid for {pid}: {ids!r}")
        start = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "lstart="],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout.strip()
        command = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "command="],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout.strip()
        return Identity(int(ids[0]), int(ids[1]), start, command)

    def deliver(self, signo: int, recorded: Identity) -> None:
        current = self.identity()
        if current != recorded:
            raise RuntimeError(f"identity changed before send: recorded={recorded!r} current={current!r}")
        if isinstance(current.pid, bool) or current.pid <= 1:
            raise RuntimeError(f"refused unsafe pid {current.pid!r}")
        os.kill(current.pid, signo)
        self.sent.append(signo)

    def observe_hup(self) -> tuple[int, bool, bool]:
        responsive = False
        deadline = time.monotonic() + self.timeout_sec
        while time.monotonic() < deadline and self.proc.poll() is None:
            try:
                title = self.rpc.call("page.title", {"timeout_ms": 1500}).get("title") if self.rpc else None
                if title == "HUP-2":
                    responsive = True
                    break
            except Exception:
                pass
            time.sleep(0.05)
        if responsive:
            time.sleep(0.5)
            try:
                responsive = self.rpc.call("page.title", {"timeout_ms": 1500}).get("title") == "HUP-2"
            except Exception:
                responsive = False
        return self.fixture.count("HUP") - 1, responsive, self.proc.poll() is None

    def wait_exit(self, timeout_sec: float) -> int | None:
        try:
            return self.proc.wait(timeout=timeout_sec)
        except subprocess.TimeoutExpired:
            return None

    def _group_members(self) -> list[Identity]:
        try:
            output = subprocess.run(
                ["/bin/ps", "-A", "-o", "pid=,pgid=,lstart=,command="],
                capture_output=True, text=True, timeout=5, check=True,
            ).stdout
        except Exception as exc:
            return [Identity(self.proc.pid, self.proc.pid, "?", f"process census failed: {exc}")]
        members: list[Identity] = []
        for line in output.splitlines():
            fields = line.split(None, 7)
            if len(fields) == 8 and fields[1] == str(self.proc.pid):
                members.append(Identity(int(fields[0]), int(fields[1]), " ".join(fields[2:7]), fields[7]))
        return members

    def teardown_clean(self, timeout_sec: float) -> bool:
        deadline = time.monotonic() + timeout_sec
        while time.monotonic() < deadline:
            if not self._group_members():
                return True
            time.sleep(0.05)
        for ident in self._group_members():
            print(f"LEAK\t{ident.pid}\t{ident.pgid}\t{ident.start}\t{ident.command}", flush=True)
        self._leak_printed = True
        return False

    def leak(self, reason: str) -> None:
        if self.proc.poll() is not None or self._leak_printed:
            return
        self._leak_printed = True
        try:
            ident = self.identity()
            print(f"LEAK\t{ident.pid}\t{ident.pgid}\t{ident.start}\t{ident.command}", flush=True)
        except Exception as exc:
            print(f"LEAK\t{self.proc.pid}\t?\t?\t{reason}; identity unavailable: {exc}", flush=True)

    def close(self) -> None:
        if self.rpc is not None:
            self.rpc.close()
            self.rpc = None
        if self.proc.poll() is not None and not self._leak_printed:
            for stream in (self.proc.stdout, self.proc.stderr):
                if stream is not None:
                    stream.close()
            shutil.rmtree(self.tmp)
        elif self.proc.poll() is None:
            self.leak("session remained alive")


class ActualFactory:
    def __init__(self, browser: Path, fixture: FixtureServer, timeout_sec: float):
        self.browser = str(browser.resolve())
        self._browser = browser
        self.fixture = fixture
        self.timeout_sec = timeout_sec

    def launch(self, label: str, e2e: bool):
        return ActualSession(self._browser, self.fixture, label, e2e, self.timeout_sec)


class FakeSession:
    def __init__(self, factory, label: str, e2e: bool):
        self.factory = factory
        self.label = label
        self.e2e = e2e
        self.sent: list[int] = []
        self.alive = True
        self.rc: int | None = None
        self.reloads = 0
        self.rpc = None

    def ready(self) -> bool:
        return True

    def disposition_lines(self, _wait_sec: float) -> list[str]:
        if not self.e2e:
            return [REPORT] if self.factory.variant == "unguarded" else []
        if self.factory.variant == "old-handler":
            return ["SIGNAL_DISPOSITION\tSIGINT=CUSTOM\tSIGTERM=CUSTOM\tSIGHUP=CUSTOM"]
        return [REPORT]

    def identity(self) -> Identity:
        if self.factory.variant == "bad-identity" and self.label == "HUP":
            return Identity(1, 1, "Fri Oct 24 12:00:00 2026", self.factory.browser + " /HUP")
        return Identity(4242 + len(self.factory.sessions), 4242 + len(self.factory.sessions),
                        "Fri Oct 24 12:00:00 2026", self.factory.browser + f" /{self.label}")

    def deliver(self, signo: int, recorded: Identity) -> None:
        if recorded != self.identity() or recorded.pid <= 1:
            raise RuntimeError("fake identity was not safe at send")
        self.sent.append(signo)
        variant = self.factory.variant
        if variant == "dropped-source":
            return
        if variant == "swap-hup-exit":
            if signo == signal.SIGHUP:
                self.alive, self.rc = False, 130
            else:
                self.reloads += 1
            return
        if signo == signal.SIGHUP:
            self.reloads += 1
        else:
            self.alive, self.rc = False, 130

    def observe_hup(self) -> tuple[int, bool, bool]:
        return self.reloads, self.reloads == 1 and self.alive, self.alive

    def wait_exit(self, _timeout_sec: float) -> int | None:
        if self.label == "HUP" and self.factory.variant != "swap-hup-exit":
            self.alive, self.rc = False, 0  # the independent e2e quit hook ends the successful HUP launch
        return self.rc

    def teardown_clean(self, _timeout_sec: float) -> bool:
        return not self.alive

    def leak(self, _reason: str) -> None:
        pass

    def close(self) -> None:
        pass


class FakeFactory:
    browser = "/exact/zigBrowser"

    def __init__(self, variant: str):
        self.variant = variant
        self.sessions: list[FakeSession] = []

    def launch(self, label: str, e2e: bool) -> FakeSession:
        session = FakeSession(self, label, e2e)
        self.sessions.append(session)
        return session


def identity_before_send(session, factory, label: str, verdict: Verdict) -> Identity | None:
    try:
        ident = session.identity()
    except Exception as exc:
        verdict.fail(f"{label}-IDENTITY", f"could not read live identity: {exc}")
        session.leak("identity unavailable")
        return None
    command_ok = ident.command == factory.browser or ident.command.startswith(factory.browser + " ")
    if (isinstance(ident.pid, bool) or not isinstance(ident.pid, int) or ident.pid <= 1 or ident.pgid != ident.pid
            or not ident.start or not command_ok):
        verdict.fail(f"{label}-IDENTITY", f"refused pid/pgid/start/command {ident!r}")
        session.leak("unsafe identity refused before signal")
        return None
    verdict.emit(
        f"SIGNAL_IDENTITY\t{label}\tpid={ident.pid}\tpgid={ident.pgid}\tstart={ident.start}\tcommand={ident.command}"
    )
    return ident


def deliver_once(session, factory, label: str, signo: int, verdict: Verdict) -> bool:
    ident = identity_before_send(session, factory, label, verdict)
    if ident is None:
        return False
    if session.sent:
        verdict.fail(f"{label}-SEND", f"signal already sent: {session.sent!r}")
        return False
    try:
        session.deliver(signo, ident)
    except Exception as exc:
        verdict.fail(f"{label}-SEND", f"send refused/failed: {exc}")
        session.leak("signal send failed")
        return False
    if session.sent != [signo]:
        verdict.fail(f"{label}-SEND", f"send record is {session.sent!r}, want exactly [{signo}]")
        return False
    verdict.emit(f"SIGNAL_SEND\t{label}\tpid={ident.pid}\tsignal={signal.Signals(signo).name}\tcount=1")
    return True


def exercise(factory, emit: Callable[[str], None]) -> list[str]:
    """The one verdict path used by the hostless models and by the real two-Mac row."""
    verdict = Verdict(emit)

    guard = factory.launch("GUARD", False)
    try:
        if not guard.ready():
            verdict.fail("GUARD-READY", "browser did not become automation-ready")
            guard.leak("guard readiness failed")
        lines = guard.disposition_lines(0.5)
        if lines:
            verdict.fail("GUARD-INERT", f"disposition seam emitted without --e2e-protocol: {lines!r}")
        if deliver_once(guard, factory, "GUARD", signal.SIGTERM, verdict):
            rc = guard.wait_exit(10.0)
            if rc != 130:
                verdict.fail("GUARD-EXIT", f"SIGTERM exit={rc!r}, want normal 130")
                if rc is None:
                    guard.leak("guard SIGTERM timed out")
            if rc is not None and not guard.teardown_clean(10.0):
                verdict.fail("GUARD-TEARDOWN", "process group did not return to its before-set")
    finally:
        guard.close()

    for label, signo in SIGNAL_CASES:
        session = factory.launch(label, True)
        try:
            ready = session.ready()
            if not ready:
                verdict.fail(f"{label}-READY", "browser did not become automation-ready")
                session.leak(f"{label} readiness failed")
            lines = session.disposition_lines(5.0)
            if lines != [REPORT]:
                verdict.fail(f"{label}-DISPOSITION", f"got {lines!r}, want exactly {[REPORT]!r}")
            if not ready or not deliver_once(session, factory, label, signo, verdict):
                continue
            if label == "HUP":
                reloads, responsive, alive = session.observe_hup()
                if reloads != 1:
                    verdict.fail("HUP-RELOAD", f"observed {reloads} reloads, want exactly 1")
                if not responsive:
                    verdict.fail("HUP-RESPONSIVE", "page.title did not answer with the reloaded title")
                if not alive:
                    verdict.fail("HUP-NO-EXIT", "process exited after SIGHUP")
                rc = session.wait_exit((HUP_QUIT_AFTER_MS / 1000.0) + 5.0)
                if rc != 0:
                    verdict.fail("HUP-CONTROLLED-EXIT", f"e2e quit-hook exit={rc!r}, want 0")
                    if rc is None:
                        session.leak("HUP controlled exit timed out")
                if rc is not None and not session.teardown_clean(10.0):
                    verdict.fail("HUP-TEARDOWN", "process group did not return to its before-set")
            else:
                rc = session.wait_exit(10.0)
                if rc != 130:
                    kind = "negative signal status" if isinstance(rc, int) and rc < 0 else "timeout/leak" if rc is None else "wrong exit"
                    verdict.fail(f"{label}-EXIT", f"{kind}: {rc!r}, want normal 130")
                    if rc is None:
                        session.leak(f"{label} did not exit")
                if rc is not None and not session.teardown_clean(10.0):
                    verdict.fail(f"{label}-TEARDOWN", "process group did not return to its before-set")
        finally:
            session.close()
    return verdict.failures


def bounded_region(source: str) -> str | None:
    if source.count(SEAM_BEGIN) != 1 or source.count(SEAM_END) != 1:
        return None
    begin = source.index(SEAM_BEGIN) + len(SEAM_BEGIN)
    end = source.index(SEAM_END, begin)
    return source[begin:end]


def source_problems(source: str, check_mutant: bool = True) -> list[str]:
    """Tripwire for the live-query seam.  Runtime delivery, not this parser, is the behavioral proof."""
    problems: list[str] = []
    region = bounded_region(source)
    if region is None:
        return [f"SC1 missing one bounded {SEAM_BEGIN} and {SEAM_END} region",
                "SC8 guard-drop mutant unavailable while the seam is absent"]
    required = (
        "static const char *zb_debug_signal_disposition_name(int signo)",
        "struct sigaction action;",
        "sigaction(signo, NULL, &action)",
        "action.sa_handler == SIG_IGN",
        "action.sa_handler == SIG_DFL",
        'return "CUSTOM";',
        "static void zb_debug_report_signal_dispositions(BOOL hooks_enabled)",
        "if (!hooks_enabled) return;",
        'getenv("ZB_DEBUG_SIGNAL_DISPOSITIONS")',
        '"SIGNAL_DISPOSITION\\tSIGINT=%s\\tSIGTERM=%s\\tSIGHUP=%s\\n"',
        "zb_debug_signal_disposition_name(SIGINT)",
        "zb_debug_signal_disposition_name(SIGTERM)",
        "zb_debug_signal_disposition_name(SIGHUP)",
    )
    for item in required:
        if item not in region:
            problems.append(f"SC2 live disposition seam missing {item!r}")
    if region.count("sigaction(signo, NULL, &action)") != 1:
        problems.append("SC3 the disposition name must come from exactly one live sigaction query")
    normalized = " ".join(region.split())
    exact_query = (
        'static const char *zb_debug_signal_disposition_name(int signo) { struct sigaction action; '
        'if (sigaction(signo, NULL, &action) != 0) return "ERROR"; '
        'if (action.sa_handler == SIG_IGN) return "SIG_IGN"; '
        'if (action.sa_handler == SIG_DFL) return "SIG_DFL"; return "CUSTOM"; }'
    )
    if exact_query not in normalized:
        problems.append("SC6 disposition names are not derived by the reviewed exact live-query decision")
    exact_report = (
        'fprintf(stderr, "SIGNAL_DISPOSITION\\tSIGINT=%s\\tSIGTERM=%s\\tSIGHUP=%s\\n", '
        'zb_debug_signal_disposition_name(SIGINT), zb_debug_signal_disposition_name(SIGTERM), '
        'zb_debug_signal_disposition_name(SIGHUP));'
    )
    if exact_report not in normalized:
        problems.append("SC7 the report fields are not the three live-query results")
    call = "zb_debug_report_signal_dispositions(zb_auto_test_hooks_enabled());"
    if source.count(call) != 1:
        problems.append("SC4 report call must pass the real e2e hook guard exactly once")
    install = source.find("if (!zb_install_signal_sources(host))")
    report = source.find(call)
    first_window = source.find("ZbWindow *window = zb_window_new", max(report, 0))
    if install < 0 or report < install or first_window < report:
        problems.append("SC5 live dispositions must be reported after source installation and before the first window")
    if check_mutant and source.count(call) == 1:
        mutant = source.replace(call, "zb_debug_report_signal_dispositions(YES);", 1)
        mutant_problems = source_problems(mutant, False)
        if not any(problem.startswith("SC4 ") for problem in mutant_problems):
            problems.append("SC8 replacing the e2e guard with YES survived the source contract")
    return problems


def gate_problems() -> list[str]:
    problems: list[str] = []
    try:
        gate = GATE.read_text()
        evidence = EVIDENCE_SELFTEST.read_text()
        output = OUTPUT_SELFTEST.read_text()
    except OSError as exc:
        return [f"GC0 could not read the named gate/fake-host tests: {exc}"]
    if gate.count(ROW_SPEC) != 1:
        problems.append(f"GC1 named gate must contain exactly one {ROW_SPEC}")
    mapping = f"{ROW_FILE}) id={ROW_ID} ;;"
    for name, text in (("evidence", evidence), ("output", output)):
        if mapping not in " ".join(text.split()):
            problems.append(f"GC2 {name} fake host does not map {ROW_FILE} to {ROW_ID}")
        if text.count(ROW_ID) < 2:
            problems.append(f"GC3 {name} fake-host coverage does not select and verify {ROW_ID}")
    coverage = evidence + output
    for token in ("EVIDENCE", "REMOVED", "LEAK", "remote-success"):
        if token not in coverage:
            problems.append(f"GC4 named-gate fake-host coverage is missing {token}")
    return problems


def fake_selftest_problems() -> list[str]:
    problems: list[str] = []
    good = FakeFactory("good")
    got = exercise(good, lambda _line: None)
    if got:
        problems.append(f"T1 good runtime model failed: {got!r}")
    else:
        print(f"ASSERT\t{ROW_ID}\tmodel-good\tpass")
    required = {
        "old-handler": "-DISPOSITION",
        "swap-hup-exit": "HUP-RELOAD",
        "dropped-source": "HUP-RELOAD",
        "unguarded": "GUARD-INERT",
        "bad-identity": "HUP-IDENTITY",
    }
    for variant, marker in required.items():
        factory = FakeFactory(variant)
        got = exercise(factory, lambda _line: None)
        if not any(marker in failure for failure in got):
            problems.append(f"T2 {variant} mutant was not red for {marker}: {got!r}")
        else:
            print(f"ASSERT\t{ROW_ID}\tmutant-{variant}\tred")
        if variant == "bad-identity":
            hup = next(session for session in factory.sessions if session.label == "HUP")
            if hup.sent:
                problems.append(f"T3 bad identity reached signal delivery: {hup.sent!r}")
            else:
                print(f"ASSERT\t{ROW_ID}\tbad-identity-no-send\tpass")
    return problems


def selftest() -> int:
    problems = fake_selftest_problems()
    try:
        source = SHIM.read_text()
    except OSError as exc:
        problems.append(f"SC0 could not read {SHIM}: {exc}")
    else:
        source_failures = source_problems(source)
        problems += source_failures
        if not source_failures:
            print(f"ASSERT\t{ROW_ID}\tlive-sigaction-query\tpass")
            print(f"ASSERT\t{ROW_ID}\tmutant-guard-source\tred")
    registration_failures = gate_problems()
    problems += registration_failures
    if not registration_failures:
        print(f"ASSERT\t{ROW_ID}\tnamed-gate-fake-host-coverage\tpass")
    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        print(f"FAIL\t{ROW_ID}\t{len(problems)} problem(s)")
        return 1
    print(f"PASS\t{ROW_ID}")
    return 0


def real_row(browser: Path, timeout_sec: float) -> int:
    if sys.platform != "darwin":
        print(f"FAIL\t{ROW_ID}\trequires-darwin")
        return 1
    if not browser.is_file():
        print(f"FAIL\t{ROW_ID}\tbinary-missing")
        return 1
    problems: list[str] = []
    try:
        problems += source_problems(SHIM.read_text())
    except OSError as exc:
        problems.append(f"SC0 could not read {SHIM}: {exc}")
    problems += gate_problems()
    if problems:
        for problem in problems:
            print(f"FAIL {problem}")
        print(f"FAIL\t{ROW_ID}\tprecondition")
        return 1
    with FixtureServer() as fixture:
        runtime = ActualFactory(browser, fixture, timeout_sec)
        problems += exercise(runtime, lambda line: print(line, flush=True))
    if problems:
        for problem in problems:
            print(f"FAIL {problem}")
        print(f"FAIL\t{ROW_ID}\t{len(problems)} problem(s)")
        return 1
    print(f"PASS\t{ROW_ID}")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--browser", type=Path, default=Path("zig-out/bin/zigBrowser"))
    parser.add_argument("--timeout-sec", type=float, default=25.0)
    args = parser.parse_args(argv[1:])
    return selftest() if args.selftest else real_row(args.browser, args.timeout_sec)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
