"""MS5.1b (macOS launch plan; RoseCat's linked-skills resolution, mail 5458 "keep skipping"): a link that resolves
outside its item is skipped, and the TARGET'S BYTES are absent from the whole built agent home, while dependency trees
still copy verbatim and unscanned.

test_provision pins one shape (a top-level skill linked outside; its canary absent from current/'s text). Setup's copy
(setup._copy_tree) is the same Python on macOS, so this Linux half pins every shape the macOS run must also hold:
- a directory link nested inside a skill, a file link inside a skill, a link inside a dependency tree
  (node_modules), and a relative link up into the user's HOME (outside ~/.claude) are each skipped with a warning
  naming it, and each target holds a distinct binary canary (NUL and 0xff around a marker);
- after setup, no regular file anywhere under the agent home (dist-<n>, current, state and every other path, walked
  without following links, read with O_NOFOLLOW) holds any canary's bytes, and no path name holds a canary marker;
- the dependency tree beside the skipped link is still copied byte for byte (no HOME rewrite, no scan).
Pure Python: setup runs in-process with a fake `bun`; no signal is sent.
Run: cd agent/host/tests && unshare --map-current-user --pid --fork --kill-child --mount-proc \\
  sh -c '"$ZB_AGENT_HOST_PYTHON" -X dev -m unittest -v test_ms5_1b_skipped_link_bytes; exit $?'
Unregistered until its registration."""
import contextlib
import io
import os
import unittest

import support  # noqa: F401  (puts the helper package on sys.path)

from test_provision import Sandbox

MARKERS = ("ZB-MS51B-DIR", "ZB-MS51B-FILE", "ZB-MS51B-DEP", "ZB-MS51B-HOME")


def canary(marker):
    return b"\x00" + marker.encode() + b"\xff"


class SkippedLinkBytes(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox(self)
        outside = self.box.tmp / "outside"
        outside.mkdir()
        (outside / "dir").mkdir()
        (outside / "dir" / f"{MARKERS[0]}.bin").write_bytes(canary(MARKERS[0]))
        (outside / "file.md").write_bytes(canary(MARKERS[1]))
        (outside / "dep").mkdir()
        (outside / "dep" / "index.js").write_bytes(canary(MARKERS[2]))
        (self.box.source_home / f"{MARKERS[3]}.txt").write_bytes(canary(MARKERS[3]))  # in HOME, not ~/.claude

        demo = self.box.source / "skills" / "demo"
        modules = demo / "node_modules"
        (modules / "pkg").mkdir(parents=True)
        self.module_body = f"require('/usr/../x'); const home = '{self.box.source_home}/y'; // /srv/z\n".encode()
        (modules / "pkg" / "index.js").write_bytes(self.module_body)
        os.symlink(outside / "dir", demo / "assets")
        os.symlink(outside / "file.md", demo / "notes.md")
        os.symlink(outside / "dep", modules / "evil")
        os.symlink("../../..", demo / "up")  # skills/demo/up -> ~ (the user's HOME)
        self.skipped = ("skills/demo/assets", "skills/demo/notes.md", "skills/demo/node_modules/evil",
                        "skills/demo/up")
        with contextlib.redirect_stderr(io.StringIO()) as self.err:
            self.box.provision()

    def test_each_outbound_link_is_skipped_with_a_warning(self):
        for rel in self.skipped:
            with self.subTest(link=rel):
                self.assertIn(f"skipped {rel}: it links outside", self.err.getvalue())
                self.assertFalse(os.path.lexists(self.box.home.root / ".claude" / rel), f"{rel} is in the home")

    def test_no_target_bytes_or_names_anywhere_in_the_home(self):
        found, names, files = [], [], 0
        for top, dirs, filenames in os.walk(self.box.home.root, followlinks=False):
            for name in dirs + filenames:
                if any(m in name for m in MARKERS):
                    names.append(os.path.join(top, name))
            for name in filenames:
                path = os.path.join(top, name)
                try:
                    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                except OSError:
                    continue  # a link (never followed here) or not readable
                with os.fdopen(fd, "rb") as f:
                    data = f.read()
                files += 1
                found += [(os.path.relpath(path, self.box.home.root), m) for m in MARKERS if m.encode() in data]
        self.assertGreater(files, 10, "the walk saw too little of the home to mean anything")
        self.assertEqual((found, names), ([], []))

    def test_the_dependency_tree_beside_it_is_still_copied_byte_for_byte(self):
        copied = self.box.home.root / ".claude/skills/demo/node_modules/pkg/index.js"
        self.assertEqual(copied.read_bytes(), self.module_body)


if __name__ == "__main__":
    unittest.main()
