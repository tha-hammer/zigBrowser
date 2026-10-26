#!/usr/bin/env python3
"""RED: bind ActualSession socket allocation to Darwin's encoded-byte boundary.

This hostless oracle stops at the real ``ActualSession`` Popen call.  It never
starts a process or sends a signal.  The supplied socket directories model the
87-byte Intel and 83-byte arm64 paths observed in the consumed signal-only run.
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

import mac_signal_runtime_test as runtime


LABELS = ("GUARD", "HUP", "INT", "TERM")
DARWIN_SOCKET_LIMIT = 103


class LaunchBoundaryReached(Exception):
    """The generated environment reached the intercepted Popen boundary."""

    def __init__(self, socket: str):
        super().__init__(socket)
        self.socket = socket


def lexical_root(encoded_length: int, *, multibyte: bool = False) -> Path:
    """Return an absolute, uncreated path having the requested encoded length."""
    prefix = "/tmp/"
    remaining = encoded_length - len(os.fsencode(prefix))
    if remaining <= 0:
        raise AssertionError(f"encoded length {encoded_length} is too short for {prefix!r}")
    if multibyte:
        pairs = min(remaining // 2, 40)
        component = "é" * pairs + "u" * (remaining - (pairs * 2))
    else:
        component = "s" * remaining
    path = Path(prefix + component)
    actual = len(os.fsencode(path))
    if actual != encoded_length:
        raise AssertionError(f"fixture length {actual}, want {encoded_length}: {path!s}")
    return path


def boundary_problems() -> list[str]:
    problems: list[str] = []
    fake_popen_calls: list[str] = []
    fake_kill_calls: list[tuple[object, ...]] = []
    token_counter = 0
    state_counter = 0
    old_socket_dir = os.environ.get("ZB_E2E_SOCKET_DIR")
    old_platform = runtime.sys.platform
    old_popen = runtime.subprocess.Popen
    old_kill = runtime.os.kill
    old_token_hex = runtime.secrets.token_hex
    old_mkdtemp = runtime.tempfile.mkdtemp

    with tempfile.TemporaryDirectory(prefix="zb-signal-socket-boundary-") as temp:
        state_root = Path(temp)

        def fake_token_hex(nbytes: int) -> str:
            nonlocal token_counter
            token_counter += 1
            return f"{token_counter:0{nbytes * 2}x}"[-(nbytes * 2):]

        def fake_mkdtemp(*, prefix: str = "", **_kwargs: object) -> str:
            nonlocal state_counter
            state_counter += 1
            path = state_root / f"{prefix}{state_counter:02d}"
            path.mkdir()
            return str(path)

        def fake_popen(*_args: object, **kwargs: object) -> object:
            env = kwargs.get("env")
            if not isinstance(env, dict) or not isinstance(env.get("ZIGBROWSER_SOCKET"), str):
                raise AssertionError("Popen boundary lacked one ZIGBROWSER_SOCKET value")
            socket = env["ZIGBROWSER_SOCKET"]
            fake_popen_calls.append(socket)
            raise LaunchBoundaryReached(socket)

        def forbidden_kill(*args: object, **_kwargs: object) -> None:
            fake_kill_calls.append(args)
            raise AssertionError(f"socket boundary oracle attempted os.kill{args!r}")

        runtime.sys.platform = "darwin"
        runtime.subprocess.Popen = fake_popen
        runtime.os.kill = forbidden_kill
        runtime.secrets.token_hex = fake_token_hex
        runtime.tempfile.mkdtemp = fake_mkdtemp

        def construct(socket_root: Path, label: str) -> tuple[str, Path | None]:
            os.environ["ZB_E2E_SOCKET_DIR"] = str(socket_root)
            try:
                runtime.ActualSession(
                    Path("/unlaunched/zigBrowser.app/Contents/MacOS/zigBrowser"),
                    SimpleNamespace(base_url="http://127.0.0.1:9"),
                    label,
                    label != "GUARD",
                    0.01,
                )
            except LaunchBoundaryReached as reached:
                return "launch-boundary", Path(reached.socket)
            except RuntimeError as exc:
                return f"refused: {exc}", None
            except Exception as exc:  # a different pre-launch failure is still evidence, never a crash
                return f"unexpected {type(exc).__name__}: {exc}", None
            return "returned without reaching the launch boundary", None

        try:
            for root_length in (87, 83):
                socket_root = lexical_root(root_length)
                seen: set[Path] = set()
                by_label: dict[str, list[Path]] = {label: [] for label in LABELS}
                for _round in range(2):
                    for label in LABELS:
                        outcome, path = construct(socket_root, label)
                        if outcome != "launch-boundary" or path is None:
                            problems.append(
                                f"B1 {root_length}-byte root {label} did not reach the intercepted boundary: {outcome}"
                            )
                            continue
                        if path.parent != socket_root:
                            problems.append(
                                f"B2 {root_length}-byte root {label} escaped supplied directory: {path!s}"
                            )
                        encoded = len(os.fsencode(path))
                        if encoded > DARWIN_SOCKET_LIMIT:
                            problems.append(
                                f"B3 {root_length}-byte root {label} produced {encoded} encoded bytes: {path!s}"
                            )
                        if path in seen:
                            problems.append(
                                f"B4 {root_length}-byte root reused a socket path: {path!s}"
                            )
                        seen.add(path)
                        by_label[label].append(path)
                for label, paths in by_label.items():
                    if len(paths) != 2 or paths[0] == paths[1]:
                        problems.append(
                            f"B5 {root_length}-byte root {label} lacks two unique session paths: {paths!r}"
                        )

            ascii_oversized = lexical_root(DARWIN_SOCKET_LIMIT + 1)
            before = len(fake_popen_calls)
            outcome, _path = construct(ascii_oversized, "GUARD")
            if not outcome.startswith("refused: socket path is") or len(fake_popen_calls) != before:
                problems.append(
                    f"B6 oversized ASCII root reached or bypassed the Darwin guard: {outcome}"
                )

            multibyte_oversized = lexical_root(DARWIN_SOCKET_LIMIT + 1, multibyte=True)
            if len(str(multibyte_oversized)) >= DARWIN_SOCKET_LIMIT:
                problems.append("B7 multibyte fixture does not isolate encoded-byte counting")
            before = len(fake_popen_calls)
            outcome, _path = construct(multibyte_oversized, "TERM")
            if not outcome.startswith("refused: socket path is") or len(fake_popen_calls) != before:
                problems.append(
                    "B8 oversized multibyte root survived encoded-byte enforcement: " + outcome
                )
        finally:
            runtime.sys.platform = old_platform
            runtime.subprocess.Popen = old_popen
            runtime.os.kill = old_kill
            runtime.secrets.token_hex = old_token_hex
            runtime.tempfile.mkdtemp = old_mkdtemp
            if old_socket_dir is None:
                os.environ.pop("ZB_E2E_SOCKET_DIR", None)
            else:
                os.environ["ZB_E2E_SOCKET_DIR"] = old_socket_dir

    if fake_kill_calls:
        problems.append(f"B9 socket boundary oracle reached os.kill: {fake_kill_calls!r}")
    if len(fake_popen_calls) != 16:
        problems.append(
            f"B10 intercepted Popen count is {len(fake_popen_calls)}, want 16 allowed constructions"
        )
    return problems


def main() -> int:
    problems = boundary_problems()
    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        print(f"FAIL\tmac-signal-socket-path-red\t{len(problems)} problem(s)")
        return 1
    print("PASS\tmac-signal-socket-path-red")
    return 0


if __name__ == "__main__":
    sys.exit(main())
