#!/usr/bin/env python3
"""RED, UNREGISTERED: prove the macOS signal path in the live application.

The eventual green row is run by ``tests/mac/ms_runtime_rows_gate.sh`` on both Macs.  It verifies exact-commit DMG,
read-only attach, ditto-unpack, app/executable/shim digests and the executable-relative shim reference, then launches
that unpacked ``zigBrowser.app`` executable afresh for a guard case and for SIGHUP, SIGINT and SIGTERM. Empty/fake
apps and renamed, copied or linked build-tree browsers are refused before launch. Before sending a signal it proves
bounded automation readiness and records an exact, live process identity.  The e2e-only disposition seam must
report the result of ``sigaction(signo, NULL, ...)`` as SIG_IGN for all three signals; without
``--e2e-protocol`` that report must be absent.  SIGHUP must reload exactly once and leave the app responsive.
SIGINT and SIGTERM must each exit normally with code 130.  No timeout path sends SIGKILL.

``--selftest`` is hostless.  It drives the same verdict code with a model of the good implementation and the
required old-handler, HUP/exit-swap, dropped-source, guard-drop and per-launch disposition/identity mutants. It also
binds package-substitution mutants, the live-query source seam and future named-gate/fake-host registration. Until
the green lands, those production and gate contracts intentionally make this file exit 1.

Hostless red command (the outer namespace is mandatory even though the model never calls os.kill)::

  unshare --user --map-root-user --pid --fork --mount-proc --net \
    python3 -X dev tests/e2e/mac_signal_runtime_test.py --selftest
"""
from __future__ import annotations

import argparse
import hashlib
import http.server
import os
import re
import secrets
import signal
import shutil
import stat
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
GATE_INTEGRATION = ROOT / "tests" / "mac" / "ms_signal_runtime_gate_red.sh"
ROW_FILE = "tests/e2e/mac_signal_runtime_test.py"
ROW_ID = "mac-signal-runtime"
ROW_SPEC = f'"{ROW_FILE}|green|{ROW_ID}"'
SEAM_BEGIN = "// ZB_SIGNAL_DISPOSITION_SEAM_BEGIN"
SEAM_END = "// ZB_SIGNAL_DISPOSITION_SEAM_END"
REPORT_PREFIX = "SIGNAL_DISPOSITION\t"
REPORT = "SIGNAL_DISPOSITION\tSIGINT=SIG_IGN\tSIGTERM=SIG_IGN\tSIGHUP=SIG_IGN"
SIGNAL_CASES = (("HUP", signal.SIGHUP), ("INT", signal.SIGINT), ("TERM", signal.SIGTERM))
HUP_QUIT_AFTER_MS = 8000
APP_SUFFIX = ("zigBrowser.app", "Contents", "MacOS", "zigBrowser")
SHIM_REL = Path("Contents/Frameworks/libwkwebview_shim.dylib")
SHIM_REF = "@executable_path/../Frameworks/libwkwebview_shim.dylib"
PACKAGE_TAGS = (
    "PACKAGE_COMMIT", "PACKAGE_PRODUCER", "PACKAGE_FLOW", "PACKAGE_DMG", "PACKAGE_APP", "PACKAGE_EXECUTABLE",
    "PACKAGE_BUILD_EXECUTABLE", "PACKAGE_SHIM", "PACKAGE_UNIVERSAL", "PACKAGE_CODESIGN", "PACKAGE_SHIM_REF",
)


@dataclass(frozen=True)
class Identity:
    pid: int
    pgid: int
    start: str
    command: str


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def app_tree_sha256(app: Path) -> str:
    """Hash path bytes, type, mode and contents so post-unpack substitutions cannot reuse package evidence."""
    if app.is_symlink() or not app.is_dir():
        raise ValueError("the packaged app root is not a real directory")
    entries: list[tuple[bytes, Path]] = []
    for dirpath, dirs, names in os.walk(app, followlinks=False):
        dirs.sort(key=os.fsencode)
        names.sort(key=os.fsencode)
        base = Path(dirpath)
        for name in dirs + names:
            path = base / name
            entries.append((os.fsencode(os.path.relpath(path, app)), path))
    digest = hashlib.sha256()
    for rel, path in sorted(entries):
        info = path.lstat()
        if stat.S_ISREG(info.st_mode):
            kind, payload = b"f", bytes.fromhex(file_sha256(path))
        elif stat.S_ISDIR(info.st_mode):
            kind, payload = b"d", b""
        elif stat.S_ISLNK(info.st_mode):
            kind, payload = b"l", os.fsencode(os.readlink(path))
        else:
            raise ValueError(f"special file in packaged app: {os.fsdecode(rel)!r}")
        for field in (rel, kind, f"{stat.S_IMODE(info.st_mode):o}".encode(), payload):
            digest.update(len(field).to_bytes(8, "big"))
            digest.update(field)
    return digest.hexdigest()


def package_problems(browser: Path, evidence: Path | None, expected_commit: str | None) -> tuple[list[str], str | None]:
    """Validate the exact DMG -> read-only attach -> ditto artifact before any browser process exists."""
    problems: list[str] = []
    if evidence is None or expected_commit is None:
        return ["PK0 package evidence and exact commit are required"], None
    if not re.fullmatch(r"[0-9a-f]{40}", expected_commit):
        return [f"PK1 invalid exact package commit {expected_commit!r}"], None
    try:
        lines = evidence.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        return [f"PK2 could not read package evidence: {exc}"], None
    fields = [line.split("\t") for line in lines]
    if len(fields) != len(PACKAGE_TAGS) or [row[0] if row else "" for row in fields] != list(PACKAGE_TAGS):
        return [f"PK3 package evidence must contain the exact ordered {PACKAGE_TAGS!r} records"], None
    commit, producer, flow, dmg_row, app_row, exe_row, build_row, shim_row, universal, codesign, ref_row = fields
    if commit != ["PACKAGE_COMMIT", expected_commit]:
        problems.append("PK4 package evidence is not for the requested exact commit")
    if flow != ["PACKAGE_FLOW", "hdiutil-attach-readonly", "ditto"]:
        problems.append("PK5 package did not come through read-only DMG attach and ditto")
    shaped = ((dmg_row, 4, "DMG"), (app_row, 3, "APP"), (exe_row, 4, "EXECUTABLE"),
              (build_row, 4, "BUILD_EXECUTABLE"), (shim_row, 4, "SHIM"))
    for row, size, name in shaped:
        if len(row) != size or not re.fullmatch(r"[0-9a-f]{64}", row[1]):
            problems.append(f"PK6 malformed PACKAGE_{name} evidence")
    dmg_digest = dmg_row[1] if len(dmg_row) == 4 else ""
    if (len(producer) != 4 or producer[1] != "packaging/macos/build-dmg.sh" or producer[2] != expected_commit
            or not re.fullmatch(r"[0-9a-f]{64}", producer[3]) or producer[3] != dmg_digest):
        problems.append("PK7 DMG digest is not bound to the real exact-commit package producer")
    if universal != ["PACKAGE_UNIVERSAL", "executable=arm64,x86_64", "shim=arm64,x86_64"]:
        problems.append("PK8 package executable and shim are not the reviewed universal pair")
    if codesign != ["PACKAGE_CODESIGN", "--verify --strict --deep", "rc=0"]:
        problems.append("PK9 unpacked app lacks strict package verification")
    if ref_row != ["PACKAGE_SHIM_REF", SHIM_REF, "x86_64=1", "arm64=1"]:
        problems.append("PK10 package has no exact per-slice executable-relative shim reference")
    if problems:
        return problems, None
    try:
        raw_dmg = Path(dmg_row[3])
        raw_app = Path(app_row[2])
        packaged_exe = Path(exe_row[3])
        build_exe = Path(build_row[3])
        shim = Path(shim_row[3])
        resolved = browser.resolve(strict=True)
        run_root = browser.parents[4].resolve(strict=True)
        expected_app = run_root / "app/zigBrowser.app"
        if not re.fullmatch(rf"zb-gate-{expected_commit}-[0-9a-f]+", run_root.name):
            problems.append("PK11 browser is not in the exact-commit gate run root")
        if (evidence.resolve(strict=True) != run_root / "evidence/package.manifest"
                or raw_app != expected_app or raw_dmg.parent != run_root
                or build_exe != run_root / "zig-out/bin/zigBrowser"
                or shim != expected_app / SHIM_REL):
            problems.append("PK12 package evidence names a path outside the exact run-root layout")
        app = raw_app.resolve(strict=True)
        dmg = raw_dmg.resolve(strict=True)
        if app != resolved.parents[2] or resolved != packaged_exe.resolve(strict=True):
            problems.append("PK13 browser/app paths do not name the evidenced unpacked package")
        if tuple(resolved.parts[-4:]) != APP_SUFFIX or "zig-out" in resolved.parts:
            problems.append("PK14 browser is not the unpacked packaged executable")
        for path, name in ((raw_app, "app"), (packaged_exe, "executable"), (shim, "shim"), (raw_dmg, "dmg")):
            if path.is_symlink():
                problems.append(f"PK15 evidenced {name} is a symlink")
        if not packaged_exe.is_file() or packaged_exe.stat().st_size <= 0 or not os.access(packaged_exe, os.X_OK):
            problems.append("PK16 packaged executable is empty, missing or not executable")
        if not shim.is_file() or shim.stat().st_size <= 0 or shim.resolve() != app / SHIM_REL:
            problems.append("PK17 package shim is absent or outside the app")
        if not dmg.is_file() or dmg.stat().st_size <= 0:
            problems.append("PK18 package DMG is absent or empty")
        if not build_exe.is_file() or tuple(build_exe.parts[-3:]) != ("zig-out", "bin", "zigBrowser"):
            problems.append("PK19 exact-commit build executable evidence is absent")
        actual_dmg = file_sha256(dmg)
        actual_app = app_tree_sha256(app)
        actual_exe = file_sha256(packaged_exe)
        actual_build = file_sha256(build_exe)
        actual_shim = file_sha256(shim)
        checks = (
            (actual_dmg, dmg.stat().st_size, dmg_row, "DMG"),
            (actual_exe, packaged_exe.stat().st_size, exe_row, "executable"),
            (actual_build, build_exe.stat().st_size, build_row, "build executable"),
            (actual_shim, shim.stat().st_size, shim_row, "shim"),
        )
        for actual_sha, actual_size, row, name in checks:
            if row[1] != actual_sha or row[2] != str(actual_size):
                problems.append(f"PK20 {name} digest/size does not match package evidence")
        if app_row[1] != actual_app:
            problems.append("PK21 unpacked app tree digest does not match package evidence")
        if actual_exe == actual_build or os.path.samefile(packaged_exe, build_exe):
            problems.append("PK22 packaged executable is a renamed, copied or linked build-tree binary")
    except (OSError, ValueError, IndexError) as exc:
        problems.append(f"PK23 package verification failed closed: {exc}")
        return problems, None
    if problems:
        return problems, None
    package_line = (f"PACKAGE\t{expected_commit}\tproducer=packaging/macos/build-dmg.sh\tdmg={dmg_row[1]}\tapp={app_row[1]}\t"
                    f"exe={exe_row[1]}\tshim={shim_row[1]}\tshim-ref={SHIM_REF}")
    return [], package_line


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
                # The no-e2e GUARD has no disposition report by design, so it must never receive a cleanup signal.
                # Keep its initial load unfinished: the production 15 s initial-load timer exits normally with 8.
                self.send_header("Content-Length", str(len(body) + (4096 if label == "GUARD" else 0)))
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
                if label == "GUARD":
                    time.sleep(30.0)

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

    def guard_ready(self) -> bool:
        """The hanging guard load cannot finish; the OOB window census proves the live app/socket instead."""
        try:
            self.rpc = RpcClient(self.socket_path, self.timeout_sec)
            pages = (self.rpc.call("page.list", {}) or {}).get("pages") or []
            return len(pages) == 1
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
        self.leaks: list[tuple[str, bool]] = []

    def ready(self) -> bool:
        return True

    def guard_ready(self) -> bool:
        return True

    def disposition_lines(self, _wait_sec: float) -> list[str]:
        if not self.e2e:
            return [REPORT] if self.factory.variant == "unguarded" else []
        reports = {
            "old-handler": ["SIGNAL_DISPOSITION\tSIGINT=CUSTOM\tSIGTERM=CUSTOM\tSIGHUP=CUSTOM"],
            "disp-missing": [],
            "disp-duplicate": [REPORT, REPORT],
            "disp-sigint-dfl": ["SIGNAL_DISPOSITION\tSIGINT=SIG_DFL\tSIGTERM=SIG_IGN\tSIGHUP=SIG_IGN"],
            "disp-sigterm-custom": ["SIGNAL_DISPOSITION\tSIGINT=SIG_IGN\tSIGTERM=CUSTOM\tSIGHUP=SIG_IGN"],
            "disp-sighup-error": ["SIGNAL_DISPOSITION\tSIGINT=SIG_IGN\tSIGTERM=SIG_IGN\tSIGHUP=ERROR"],
            "disp-malformed": ["SIGNAL_DISPOSITION\tSIGINT=SIG_IGN\tSIGTERM\tSIGHUP=SIG_IGN"],
            "disp-mixed": ["SIGNAL_DISPOSITION\tSIGINT=SIG_IGN\tSIGTERM=SIG_DFL\tSIGHUP=CUSTOM"],
        }
        if self.factory.variant in reports:
            return reports[self.factory.variant]
        later_reports = {
            ("int-disp-malformed", "INT"): ["SIGNAL_DISPOSITION\tSIGINT=SIG_IGN\tSIGTERM\tSIGHUP=SIG_IGN"],
            ("int-disp-nonign", "INT"): ["SIGNAL_DISPOSITION\tSIGINT=CUSTOM\tSIGTERM=SIG_IGN\tSIGHUP=SIG_IGN"],
            ("term-disp-malformed", "TERM"): ["SIGNAL_DISPOSITION\tSIGINT=SIG_IGN\tSIGTERM=SIG_IGN\tSIGHUP"],
            ("term-disp-nonign", "TERM"): ["SIGNAL_DISPOSITION\tSIGINT=SIG_IGN\tSIGTERM=SIG_DFL\tSIGHUP=SIG_IGN"],
        }
        if (self.factory.variant, self.label) in later_reports:
            return later_reports[(self.factory.variant, self.label)]
        return [REPORT]

    def identity(self) -> Identity:
        bad_label = {"bad-identity": "HUP", "bad-identity-int": "INT", "bad-identity-term": "TERM"}.get(
            self.factory.variant
        )
        if self.label == bad_label:
            return Identity(1, 1, "Fri Oct 24 12:00:00 2026", self.factory.browser + f" /{self.label}")
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
        if self.label == "GUARD":
            self.alive, self.rc = False, 8  # production initial-load timeout: no signal used for guard teardown
            return self.rc
        if self.label == "HUP" and self.factory.variant != "swap-hup-exit":
            self.alive, self.rc = False, 0  # the independent e2e quit hook ends the successful HUP launch
        return self.rc

    def teardown_clean(self, _timeout_sec: float) -> bool:
        return not self.alive

    def leak(self, reason: str) -> None:
        self.leaks.append((reason, self.alive))

    def close(self) -> None:
        pass


class FakeFactory:
    browser = "/run/unpacked/zigBrowser.app/Contents/MacOS/zigBrowser"

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
        if not guard.guard_ready():
            verdict.fail("GUARD-READY", "browser did not expose its live OOB window census")
            guard.leak("guard readiness failed")
        lines = guard.disposition_lines(0.5)
        if lines:
            verdict.fail("GUARD-INERT", f"disposition seam emitted without --e2e-protocol: {lines!r}")
        rc = guard.wait_exit(25.0)
        if rc != 8:
            verdict.fail("GUARD-EXIT", f"initial-load timeout exit={rc!r}, want normal 8 without any signal")
            if rc is None:
                guard.leak("guard initial-load timeout did not exit")
        if guard.sent:
            verdict.fail("GUARD-NO-SEND", f"guard sent a signal: {guard.sent!r}")
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
                session.leak(f"{label} disposition precondition refused before signal")
                return verdict.failures
            verdict.emit(f"SIGNAL_DISPOSITION\t{label}\tSIGINT=SIG_IGN\tSIGTERM=SIG_IGN\tSIGHUP=SIG_IGN")
            if not ready:
                return verdict.failures
            if not deliver_once(session, factory, label, signo, verdict):
                return verdict.failures
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
    packaged_arg = ('python3 "$file" --browser "$root/app/zigBrowser.app/Contents/MacOS/zigBrowser" '
                    '--package-evidence "$root/evidence/package.manifest" --package-commit "$commit"')
    if gate.count(packaged_arg) != 1 or 'python3 "$file" --browser zig-out/bin/zigBrowser' in gate:
        problems.append("GC5 signal row must receive the evidenced exact-commit DMG/ditto app, never the build-tree browser")
    producer_call = 'ZB_GATE_COMMIT="$COMMIT" bash packaging/macos/build-dmg.sh'
    if gate.count(producer_call) != 1:
        problems.append("GC6 named gate must execute the real exact-commit build-dmg producer exactly once")
    package_tokens = ("hdiutil attach -readonly", "ditto", "codesign --verify --strict --deep", "lipo -archs", "otool -arch",
                      "PRODUCER_DMG", "PACKAGE_PRODUCER", "PACKAGE_DMG", "PACKAGE_APP", "PACKAGE_SHIM_REF")
    for token in package_tokens:
        if token not in gate:
            problems.append(f"GC7 named gate package flow is missing {token!r}")
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


def gate_integration_problems() -> list[str]:
    """Execute the real named gate against two fake hosts; comments and inert lexical tokens cannot satisfy this."""
    try:
        result = subprocess.run(
            ["bash", str(GATE_INTEGRATION), str(ROOT)], capture_output=True, text=True, timeout=180,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return [f"GI0 fake-host integration could not run: {exc}"]
    if result.returncode == 0 and result.stdout.splitlines()[-1:] == ["PASS\tms-signal-runtime-gate-red"]:
        print(f"ASSERT\t{ROW_ID}\treal-fake-host-integration\tpass")
        return []
    tail = " | ".join((result.stdout + result.stderr).splitlines()[-12:])
    return [f"GI1 real fake-host integration is red (rc={result.returncode}): {tail}"]


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
            if hup.sent or not hup.leaks or not hup.leaks[0][1]:
                problems.append(f"T3 bad identity must leak live before delivery: sent={hup.sent!r} leaks={hup.leaks!r}")
            else:
                print(f"ASSERT\t{ROW_ID}\tbad-identity-no-send\tpass")
    disposition_variants = (
        "disp-missing", "disp-duplicate", "disp-sigint-dfl", "disp-sigterm-custom",
        "disp-sighup-error", "disp-malformed", "disp-mixed",
    )
    for variant in disposition_variants:
        factory = FakeFactory(variant)
        got = exercise(factory, lambda _line: None)
        sent = [signo for session in factory.sessions for signo in session.sent]
        hup = next(session for session in factory.sessions if session.label == "HUP")
        if not any("HUP-DISPOSITION" in failure for failure in got) or sent or not hup.leaks or not hup.leaks[0][1]:
            problems.append(f"T4 {variant} must leak live and stop before every send: "
                            f"failures={got!r} sent={sent!r} leaks={hup.leaks!r}")
        else:
            print(f"ASSERT\t{ROW_ID}\t{variant}-no-send\tpass")
    old = FakeFactory("old-handler")
    old_failures = exercise(old, lambda _line: None)
    old_sent = [signo for session in old.sessions for signo in session.sent]
    old_hup = next(session for session in old.sessions if session.label == "HUP")
    if (not any("HUP-DISPOSITION" in failure for failure in old_failures) or old_sent
            or not old_hup.leaks or not old_hup.leaks[0][1]):
        problems.append(f"T5 old-handler must leak live, be red and signal-free: "
                        f"failures={old_failures!r} sent={old_sent!r} leaks={old_hup.leaks!r}")
    else:
        print(f"ASSERT\t{ROW_ID}\told-handler-no-send\tpass")
    later_cases = (
        ("int-disp-malformed", "INT", "INT-DISPOSITION", [signal.SIGHUP]),
        ("int-disp-nonign", "INT", "INT-DISPOSITION", [signal.SIGHUP]),
        ("term-disp-malformed", "TERM", "TERM-DISPOSITION", [signal.SIGHUP, signal.SIGINT]),
        ("term-disp-nonign", "TERM", "TERM-DISPOSITION", [signal.SIGHUP, signal.SIGINT]),
        ("bad-identity-int", "INT", "INT-IDENTITY", [signal.SIGHUP]),
        ("bad-identity-term", "TERM", "TERM-IDENTITY", [signal.SIGHUP, signal.SIGINT]),
    )
    for variant, affected_label, marker, want_sent in later_cases:
        factory = FakeFactory(variant)
        got = exercise(factory, lambda _line: None)
        sent = [signo for session in factory.sessions for signo in session.sent]
        affected = next(session for session in factory.sessions if session.label == affected_label)
        if (not any(marker in failure for failure in got) or sent != want_sent or affected.sent
                or len(affected.leaks) != 1 or not affected.leaks[0][1]):
            problems.append(f"T6 {variant} must refuse only {affected_label} live after legitimate earlier sends: "
                            f"failures={got!r} sent={sent!r} leaks={affected.leaks!r}")
        else:
            print(f"ASSERT\t{ROW_ID}\t{variant}-later-launch-refusal\tpass")
    return problems


def write_package_fixture(root: Path, variant: str) -> tuple[Path, Path, str]:
    """Construct one package-evidence model. Mutants may regenerate truthful digests; policy must still refuse them."""
    commit = "1" * 40
    build = root / "zig-out/bin/zigBrowser"
    app = root / ("fake/zigBrowser.app" if variant == "fake-app" else "app/zigBrowser.app")
    browser = app / "Contents/MacOS/zigBrowser"
    shim = app / SHIM_REL
    dmg = root / "zigBrowser-exact.dmg"
    evidence = root / "evidence/package.manifest"
    build.parent.mkdir(parents=True)
    browser.parent.mkdir(parents=True)
    shim.parent.mkdir(parents=True)
    evidence.parent.mkdir(parents=True)
    build.write_bytes(b"thin exact-commit build executable\n")
    build.chmod(0o755)
    browser.write_bytes(b"fat executable produced by exact-commit package flow\n")
    browser.chmod(0o755)
    shim.write_bytes(b"fat packaged wkwebview shim\n")
    (app / "Contents/Info.plist").write_text("exact package metadata\n", encoding="utf-8")
    dmg.write_bytes(b"exact-commit dmg bytes containing the reviewed app\n")
    original_build_sha, original_build_size = file_sha256(build), build.stat().st_size
    if variant == "placeholder":
        browser.write_bytes(b"")
    elif variant == "renamed-build":
        browser.unlink()
        build.rename(browser)
    elif variant == "copied-build":
        shutil.copyfile(build, browser)
        browser.chmod(0o755)
    elif variant == "symlinked-build":
        browser.unlink()
        browser.symlink_to(build)
    elif variant == "hardlinked-build":
        browser.unlink()
        os.link(build, browser)
    flow = ["PACKAGE_FLOW", "mkdir-only", "none"] if variant == "fake-app" else [
        "PACKAGE_FLOW", "hdiutil-attach-readonly", "ditto"
    ]
    build_sha = file_sha256(build) if build.exists() else original_build_sha
    build_size = build.stat().st_size if build.exists() else original_build_size
    lines = (
        ["PACKAGE_COMMIT", commit],
        ["PACKAGE_PRODUCER", "packaging/macos/build-dmg.sh", commit, file_sha256(dmg)],
        flow,
        ["PACKAGE_DMG", file_sha256(dmg), str(dmg.stat().st_size), str(dmg)],
        ["PACKAGE_APP", app_tree_sha256(app), str(app)],
        ["PACKAGE_EXECUTABLE", file_sha256(browser), str(browser.stat().st_size), str(browser)],
        ["PACKAGE_BUILD_EXECUTABLE", build_sha, str(build_size), str(build)],
        ["PACKAGE_SHIM", file_sha256(shim), str(shim.stat().st_size), str(shim)],
        ["PACKAGE_UNIVERSAL", "executable=arm64,x86_64", "shim=arm64,x86_64"],
        ["PACKAGE_CODESIGN", "--verify --strict --deep", "rc=0"],
        ["PACKAGE_SHIM_REF", SHIM_REF, "x86_64=0" if variant == "missing-shim-ref" else "x86_64=1", "arm64=1"],
    )
    evidence.write_text("".join("\t".join(row) + "\n" for row in lines), encoding="utf-8")
    if variant == "wrong-dmg-digest":
        with dmg.open("ab") as target:
            target.write(b"mutated after package evidence\n")
    return browser, evidence, commit


def package_selftest_problems() -> list[str]:
    problems: list[str] = []
    with tempfile.TemporaryDirectory(prefix="zb-signal-package-") as temp:
        good_root = Path(temp) / "good" / f"zb-gate-{'1' * 40}-deadbeef"
        browser, evidence, commit = write_package_fixture(good_root, "good")
        got, line = package_problems(browser, evidence, commit)
        if got or line is None:
            problems.append(f"PKT1 good exact-commit package model failed: {got!r}")
        else:
            print(f"ASSERT\t{ROW_ID}\tpackage-model-good\tpass")
        variants = (
            "placeholder", "renamed-build", "copied-build", "symlinked-build", "hardlinked-build",
            "fake-app", "wrong-dmg-digest", "missing-shim-ref",
        )
        for variant in variants:
            root = Path(temp) / variant / f"zb-gate-{'1' * 40}-deadbeef"
            browser, evidence, commit = write_package_fixture(root, variant)
            got, line = package_problems(browser, evidence, commit)
            if not got or line is not None:
                problems.append(f"PKT2 package substitution {variant} survived: {got!r}")
            else:
                print(f"ASSERT\t{ROW_ID}\tpackage-mutant-{variant}\tred")
    return problems


def selftest() -> int:
    problems = fake_selftest_problems()
    problems += package_selftest_problems()
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
    problems += gate_integration_problems()
    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        print(f"FAIL\t{ROW_ID}\t{len(problems)} problem(s)")
        return 1
    print(f"PASS\t{ROW_ID}")
    return 0


def real_row(browser: Path, timeout_sec: float, package_evidence: Path | None, package_commit: str | None) -> int:
    if sys.platform != "darwin":
        print(f"FAIL\t{ROW_ID}\trequires-darwin")
        return 1
    if not browser.is_file():
        print(f"FAIL\t{ROW_ID}\tbinary-missing")
        return 1
    package_failures, package_line = package_problems(browser, package_evidence, package_commit)
    if package_failures:
        for problem in package_failures:
            print(f"FAIL {problem}")
        print(f"FAIL\t{ROW_ID}\tpackage-precondition")
        return 1
    resolved = browser.resolve()
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
    print(package_line, flush=True)
    with FixtureServer() as fixture:
        runtime = ActualFactory(resolved, fixture, timeout_sec)
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
    parser.add_argument("--browser", type=Path, default=Path("app/zigBrowser.app/Contents/MacOS/zigBrowser"))
    parser.add_argument("--package-evidence", type=Path)
    parser.add_argument("--package-commit")
    parser.add_argument("--timeout-sec", type=float, default=25.0)
    args = parser.parse_args(argv[1:])
    return selftest() if args.selftest else real_row(
        args.browser, args.timeout_sec, args.package_evidence, args.package_commit,
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv))
