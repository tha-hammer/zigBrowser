"""MS5.1b (macOS launch plan; RoseCat's linked-skills resolution, mail 5458 "keep skipping"): a link that resolves
outside its item is skipped, and the TARGET'S BYTES are absent from the whole built agent home, while dependency trees
still copy verbatim and unscanned.

test_provision pins one shape (a top-level skill linked outside; its canary absent from current/'s text). Setup's copy
(setup._copy_tree) is the same Python on macOS, so this Linux half pins every shape the macOS run must also hold:
- a directory link nested inside a skill, a file link inside a skill, a link inside a dependency tree
  (node_modules), and a relative link up into the user's HOME (outside ~/.claude) are each skipped with a warning
  naming it, and each target holds a distinct binary canary (NUL and 0xff around a marker);
- after setup, no regular file anywhere under the agent home (dist-<n>, current, state and every other path, walked
  without following links, read with O_NOFOLLOW) holds any canary's bytes, and no path name holds a canary marker.
  The census fails closed (RoseCat 7895): each entry is lstat'ed, only a symlink is passed over (never followed),
  anything else that is not a regular file or a directory is a finding, and a regular file that cannot be opened
  or read is a finding; a control row proves an unreadable file and a FIFO each fail the census;
- the dependency tree beside the skipped link is still copied byte for byte (no HOME rewrite, no scan).
Pure Python: setup runs in-process with a fake `bun`; no signal is sent.
Run: cd agent/host/tests && unshare --map-current-user --pid --fork --kill-child --mount-proc \\
  sh -c '"$ZB_AGENT_HOST_PYTHON" -X dev -m unittest -v test_ms5_1b_skipped_link_bytes; exit $?'
Unregistered until its registration."""
import contextlib
import io
import os
import stat
import unittest

import support  # noqa: F401  (puts the helper package on sys.path)

from test_provision import Sandbox

MARKERS = ("ZB-MS51B-DIR", "ZB-MS51B-FILE", "ZB-MS51B-DEP", "ZB-MS51B-HOME")


def canary(marker):
    return b"\x00" + marker.encode() + b"\xff"


def census(root):
    """(canary hits, marker names, problems, regular files read) over everything under `root`, failing closed."""
    found, names, problems, files = [], [], [], 0
    for top, dirs, filenames in os.walk(root, followlinks=False, onerror=lambda e: problems.append(("walk", repr(e)))):
        for name in dirs + filenames:
            path = os.path.join(top, name)
            rel = os.path.relpath(path, root)
            if any(m in name for m in MARKERS):
                names.append(rel)
            if name in dirs:
                continue
            st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode):
                continue  # never followed; its target is checked where it lives, if inside the home
            if not stat.S_ISREG(st.st_mode):
                problems.append((rel, "not a regular file"))
                continue
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                with os.fdopen(fd, "rb") as f:
                    data = f.read()
            except OSError as exc:
                problems.append((rel, f"unreadable: {exc.strerror}"))
                continue
            files += 1
            found += [(rel, m) for m in MARKERS if m.encode() in data]
    return found, names, problems, files


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
        found, names, problems, files = census(self.box.home.root)
        self.assertGreater(files, 10, "the walk saw too little of the home to mean anything")
        self.assertEqual((found, names, problems), ([], [], []))

    def test_the_census_fails_closed_on_an_unreadable_file_or_a_fifo(self):
        """The control: a canary the census cannot read, or an entry it cannot classify, is a finding."""
        hidden = self.box.home.root / "state" / "hidden.bin"
        hidden.write_bytes(canary(MARKERS[0]))
        hidden.chmod(0)
        self.addCleanup(hidden.chmod, 0o600)
        os.mkfifo(self.box.home.root / "state" / "pipe", 0o600)
        _found, _names, problems, _files = census(self.box.home.root)
        self.assertEqual(sorted(problems), [("state/hidden.bin", "unreadable: Permission denied"),
                                            ("state/pipe", "not a regular file")])

    def test_the_dependency_tree_beside_it_is_still_copied_byte_for_byte(self):
        copied = self.box.home.root / ".claude/skills/demo/node_modules/pkg/index.js"
        self.assertEqual(copied.read_bytes(), self.module_body)


if __name__ == "__main__":
    unittest.main()
