"""R1 on macOS, the probe's environment check (BlueBeaver 6977; RoseCat 6958): macOS has no /proc, so the probe
reads its CLI descendants through zb_agent_host.proc_darwin, a pure-stdlib module (libproc + sysctl KERN_PROCARGS2
through ctypes) that also runs on a Mac without the SDK. These Linux tests pin its pure parts and its walk with the
three OS calls injected; tests/mac/ms5_r1_env_gate.sh drives the real calls on both Macs.

- parse_procargs2(raw) -> (argv, env) or None. The KERN_PROCARGS2 layout: a native int argc, the NUL-terminated exec
  path, NUL padding, argc NUL-terminated argv strings, then the environment up to the first empty string (the
  "apple" strings follow it). A buffer too short for argc, an exec path or argv that runs off the end, or a negative
  argc is None: never a guess.
- environ_of(pid) -> (raw, argv, env), raising OSError when the read fails or the buffer does not parse.
- descendants_running(exe, root): every descendant of `root` (a breadth-first walk of children()) whose path() is
  `exe`; a process that is not a descendant is never listed, and a cycle in a corrupt table never loops.

Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_proc_darwin. Unregistered until the green.
"""
import struct
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)

try:
    from zb_agent_host import proc_darwin
except ImportError:
    proc_darwin = None


def buf(argc, exe, argv, env, pad=3, apple=(b"executable_path=/x", b"ptr_munge="), tail=b"\0\0"):
    out = struct.pack("=i", argc) + exe + b"\0" + b"\0" * pad
    for s in argv:
        out += s + b"\0"
    for s in env:
        out += s + b"\0"
    out += b"\0"
    for s in apple:
        out += s + b"\0"
    return out + tail


class Base(unittest.TestCase):
    def setUp(self):
        if proc_darwin is None:
            self.fail("agent/host/zb_agent_host/proc_darwin.py is missing (6977)")


class Parse(Base):
    def test_a_normal_buffer(self):
        raw = buf(2, b"/opt/claude", [b"/opt/claude", b"--print"], [b"A=1", b"ANTHROPIC_BASE_URL=http://127.0.0.1:5"])
        self.assertEqual(proc_darwin.parse_procargs2(raw),
                         ([b"/opt/claude", b"--print"], [b"A=1", b"ANTHROPIC_BASE_URL=http://127.0.0.1:5"]))

    def test_no_padding_and_no_apple_strings(self):
        raw = buf(1, b"/c", [b"/c"], [b"X=y"], pad=0, apple=(), tail=b"")
        self.assertEqual(proc_darwin.parse_procargs2(raw), ([b"/c"], [b"X=y"]))

    def test_an_environment_hidden_by_the_os_is_an_empty_env(self):
        # macOS 15.3 returns argc, the exec path and argv only for an Apple platform binary (Intel Mac, 6977).
        raw = struct.pack("=i", 2) + b"/bin/sleep\0\0\0/bin/sleep\0" + b"5\0"
        self.assertEqual(proc_darwin.parse_procargs2(raw), ([b"/bin/sleep", b"5"], []))

    def test_broken_buffers_are_none(self):
        for name, raw in (("empty", b""), ("short argc", b"\x01\0"),
                          ("negative argc", struct.pack("=i", -1) + b"/c\0"),
                          ("exec path runs off the end", struct.pack("=i", 1) + b"/c"),
                          ("argv runs off the end", struct.pack("=i", 3) + b"/c\0\0/c\0x\0"),
                          ("argv unterminated", struct.pack("=i", 1) + b"/c\0\0/c")):
            with self.subTest(name=name):
                self.assertIsNone(proc_darwin.parse_procargs2(raw))


class EnvironOf(Base):
    def test_a_readable_buffer(self):
        raw = buf(1, b"/c", [b"/c"], [b"A=1"])
        with mock.patch.object(proc_darwin, "procargs2", return_value=raw):
            self.assertEqual(proc_darwin.environ_of(42), (raw, [b"/c"], [b"A=1"]))

    def test_a_failed_read_or_an_unparsable_buffer_is_oserror(self):
        def denied(pid):
            raise PermissionError(1, "denied")

        for name, fake in (("denied", denied), ("garbage", lambda pid: b"\x01")):
            with self.subTest(name=name), mock.patch.object(proc_darwin, "procargs2", side_effect=fake):
                with self.assertRaises(OSError):
                    proc_darwin.environ_of(42)


class Descendants(Base):
    def walk(self, tree, paths, exe="/opt/claude", root=10):
        with mock.patch.object(proc_darwin, "children", side_effect=lambda pid: list(tree.get(pid, []))), \
                mock.patch.object(proc_darwin, "path", side_effect=lambda pid: paths.get(pid)):
            return sorted(proc_darwin.descendants_running(exe, root))

    def test_only_descendants_with_the_exact_path(self):
        tree = {10: [11, 12], 11: [13], 13: [14], 99: [100]}
        paths = {11: "/usr/bin/python3", 12: "/opt/claude", 13: "/opt/claude", 14: "/opt/claude-other",
                 100: "/opt/claude"}  # 100 runs the CLI but is not our descendant
        self.assertEqual(self.walk(tree, paths), [12, 13])

    def test_a_vanished_process_is_skipped(self):
        def children(pid):
            if pid == 11:
                raise ProcessLookupError(3, "gone")
            return {10: [11, 12]}.get(pid, [])

        with mock.patch.object(proc_darwin, "children", side_effect=children), \
                mock.patch.object(proc_darwin, "path", side_effect={11: None, 12: "/opt/claude"}.get):
            self.assertEqual(proc_darwin.descendants_running("/opt/claude", 10), [12])

    def test_a_cycle_terminates(self):
        self.assertEqual(self.walk({10: [11], 11: [10, 12]}, {12: "/opt/claude"}), [12])


if __name__ == "__main__":
    unittest.main()
