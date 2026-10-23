#!/usr/bin/env python3
"""UNREGISTERED RED for zigBrowser-4pa.82.

Drive only slice2_common.detect_runner with the preference passed by each of
the 20 registered E2E steps.  Xvfb/xauth discovery and the X1 socket are
faked; process creation is forbidden, so this never starts a browser, X
server, or X client.

Run from the repository root with DISPLAY set to a fake value and with a
private HOME/TMPDIR inside a private network namespace.
"""

from __future__ import annotations

import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
E2E = ROOT / "tests" / "e2e"
sys.path.insert(0, str(E2E))

import slice2_common  # noqa: E402


REGISTERED = {
    "automation_api_e2e": "tests/e2e/automation_api_lifecycle_test.py",
    "automation_core_e2e": "tests/e2e/automation_core_test.py",
    "automation_readiness_e2e": "tests/e2e/automation_readiness_test.py",
    "sdk_python_live_e2e": "tests/e2e/sdk_python_live_test.py",
    "x_flows_e2e": "tests/e2e/x_flows_test.py",
    "x_native_e2e": "tests/e2e/x_native_test.py",
    "social_flows_e2e": "tests/e2e/social_flows_test.py",
    "automation_expect_flow_e2e": "tests/e2e/automation_expect_flow_test.py",
    "automation_expect_x_flow_e2e": "tests/e2e/automation_expect_x_flow_test.py",
    "automation_recipient_guard_e2e": "tests/e2e/automation_recipient_guard_test.py",
    "automation_recipient_owner_e2e": "tests/e2e/automation_recipient_owner_test.py",
    "automation_thread_document_e2e": "tests/e2e/automation_thread_document_test.py",
    "automation_scroll_e2e": "tests/e2e/automation_scroll_test.py",
    "automation_native_ports_e2e": "tests/e2e/automation_native_ports_test.py",
    "automation_pacing_e2e": "tests/e2e/automation_pacing_persist_test.py",
    "automation_windows_e2e": "tests/e2e/automation_windows_test.py",
    "automation_input_e2e": "tests/e2e/automation_input_test.py",
    "automation_profile_e2e": "tests/e2e/automation_profile_test.py",
    "automation_cookies_e2e": "tests/e2e/automation_cookies_test.py",
    "ipc_roundtrip_e2e": "tests/e2e/ipc_roundtrip_test.py",
}
IPC_CONTROL = "ipc_roundtrip_e2e"
FAKE_DISPLAY = ":59999"

COMMAND = re.compile(r"const (\w+) = b\.addSystemCommand\(&\.\{(.*?)\}\);", re.S)
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
ZIG_ESCAPE = re.compile(r"\\(.)")
ZIG_CHARS = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "'": "'", "\\": "\\"}


def zig_unescape(text: str) -> str:
    return ZIG_ESCAPE.sub(lambda match: ZIG_CHARS.get(match.group(1), "\\" + match.group(1)), text)


def commands(source: str) -> dict[str, list[str]]:
    return {
        match.group(1): [zig_unescape(item) for item in STRING.findall(match.group(2))]
        for match in COMMAND.finditer(source)
    }


class RegisteredE2EPrivateDisplay(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.build = (ROOT / "build.zig").read_text(encoding="utf-8")
        cls.commands = commands(cls.build)
        cls.tmp = Path(tempfile.gettempdir()).resolve()
        if cls.tmp == Path("/tmp"):
            raise AssertionError("run with a private TMPDIR, not /tmp")
        cls.fake_x1 = cls.tmp / "fake-.X11-unix" / "X1"
        cls.fake_x1.parent.mkdir(parents=True, exist_ok=True)
        cls.fake_x1.touch()

    def preference(self, variable: str) -> bool:
        argv = self.commands[variable]
        self.assertEqual(argv[:2], ["sh", "-c"], f"{variable}: expected the registered sh -c command")
        return re.search(r"(?:^|\s)--prefer-xvfb(?:\s|$)", argv[2]) is not None

    def detect(self, prefer_xvfb: bool, x1: bool):
        real_exists = Path.exists

        def fake_exists(path: Path) -> bool:
            if str(path) == "/tmp/.X11-unix/X1":
                return x1 and real_exists(self.fake_x1)
            return real_exists(path)

        with (
            mock.patch.dict(os.environ, {"DISPLAY": FAKE_DISPLAY}, clear=False),
            mock.patch.object(Path, "exists", fake_exists),
            mock.patch.object(
                slice2_common.shutil,
                "which",
                side_effect=lambda tool: f"/fake-not-executed/{tool}" if tool in ("Xvfb", "xauth") else None,
            ),
            mock.patch.object(slice2_common.subprocess, "Popen", side_effect=AssertionError("process launch forbidden")),
            mock.patch.object(slice2_common.subprocess, "run", side_effect=AssertionError("process launch forbidden")),
        ):
            if x1:
                os.environ.pop("DISPLAY", None)
            os.environ.pop("WAYLAND_DISPLAY", None)
            os.environ.pop("XAUTHORITY", None)
            return slice2_common.detect_runner(prefer_xvfb)

    @staticmethod
    def private(result) -> bool:
        if result is None:
            return False
        prefix, _env, note = result
        return note == "xvfb" and "--xvfb" in prefix

    def test_c1_exact_registered_detect_runner_census(self) -> None:
        self.assertEqual(len(REGISTERED), 20)
        discovered = {}
        for variable, argv in self.commands.items():
            if len(argv) < 3 or argv[:2] != ["sh", "-c"]:
                continue
            match = re.search(r"python3 (tests/e2e/[A-Za-z0-9_]+\.py)(?:\s|$)", argv[2])
            if match is None:
                continue
            script = match.group(1)
            if "detect_runner(args.prefer_xvfb)" not in (ROOT / script).read_text(encoding="utf-8"):
                continue
            if f"test_step.dependOn(&{variable}.step);" in self.build:
                discovered[variable] = script
        self.assertEqual(discovered, REGISTERED)

    def test_c2_existing_explicit_preference_control_is_private(self) -> None:
        self.assertTrue(self.preference(IPC_CONTROL))
        for x1 in (False, True):
            with self.subTest(mode="x1" if x1 else "inherited"):
                self.assertTrue(self.private(self.detect(True, x1)))

    def assert_registered_private(self, x1: bool) -> None:
        offenders = []
        for variable in REGISTERED:
            result = self.detect(self.preference(variable), x1)
            if not self.private(result):
                prefix, env, note = result if result is not None else ([], {}, "none")
                offenders.append(
                    f"{variable}: note={note}, DISPLAY={env.get('DISPLAY')!r}, xvfb={'--xvfb' in prefix}"
                )
        if offenders:
            self.fail(
                f"{len(offenders)}/{len(REGISTERED)} registered steps selected a non-private display:\n"
                + "\n".join(offenders)
            )

    def test_d1_fake_inherited_display_is_never_selected(self) -> None:
        self.assert_registered_private(x1=False)

    def test_d2_fake_x1_socket_is_never_selected(self) -> None:
        self.assert_registered_private(x1=True)


if __name__ == "__main__":
    unittest.main()
