"""WS7.4 [L] — RED-FIRST for the pure SAI copy rules on a FAKE filesystem (plan line 1668; RoseCat 9ec1600 rework).

A link resolving OUTSIDE its item root is skipped with NO destination and NO target bytes in the home, for BOTH
symlinks AND junctions (reparse points, which os.scandir(...).is_symlink() does not catch). A link resolving INSIDE
the item is followed under its OWN name. A link/junction that resolves to an ancestor on the current path is a cycle
and is skipped (bounded). One portable copy-rule engine serves Linux and Windows; only the path primitives differ.

UNREGISTERED, signal-free, no VM, no Macs. Only `agent/host/tests/` touched (not `zb_agent_host/`), so no ms5
inventory change. RED now: `setup.copy_tree_fs` does not exist (AttributeError). The green refactors `copy_sai`
onto this engine (Linux os-backed, Windows reparse-aware) and binds the real copy_sai path to it.

MUTANTS (committed as rows below): follow-outside-links (outside dest/bytes leak), and cycle-follow (a loop dest
appears instead of being skipped).
"""

import unittest

import support  # noqa: F401  (puts agent/host on sys.path)

from zb_agent_host import setup

CANARY = b"SECRET-TARGET-BYTES-OUTSIDE-THE-ITEM"
REAL = b"REAL-IN-ITEM"
INNER = b"INNER-IN-ITEM"


def _fs():
    """`/src/skills`: a real file + subdir, an INSIDE symlink (alias) to sub/inner, an INSIDE junction to sub, an
    OUTSIDE symlink and junction, and a symlink + junction that both cycle back to the item root."""
    return {
        "/src/skills": ("dir", ["real.txt", "sub", "alias", "injunc", "sym", "junc", "loop", "jloop"]),
        "/src/skills/real.txt": ("file", REAL),
        "/src/skills/sub": ("dir", ["inner.txt"]),
        "/src/skills/sub/inner.txt": ("file", INNER),
        "/src/skills/alias": ("link", "/src/skills/sub/inner.txt"),  # INSIDE -> followed under "alias"
        "/src/skills/injunc": ("junction", "/src/skills/sub"),       # INSIDE dir junction -> followed under "injunc"
        "/src/skills/sym": ("link", "/outside/secret.txt"),          # OUTSIDE -> skipped (no dest)
        "/src/skills/junc": ("junction", "/outside/secretdir"),      # OUTSIDE -> skipped (no dest)
        "/src/skills/loop": ("link", "/src/skills"),                 # CYCLE -> skipped (bounded)
        "/src/skills/jloop": ("junction", "/src/skills"),            # CYCLE -> skipped (bounded)
        "/outside/secret.txt": ("file", CANARY),
        "/outside/secretdir": ("dir", ["leak.txt"]),
        "/outside/secretdir/leak.txt": ("file", CANARY),
    }


class WindowsCopyRules(unittest.TestCase):
    def setUp(self):
        self.copied = setup.copy_tree_fs(_fs(), "/src/skills")  # -> {dest_rel: bytes}

    def test_in_item_files_are_copied_verbatim(self):
        self.assertEqual(self.copied.get("skills/real.txt"), REAL)
        self.assertEqual(self.copied.get("skills/sub/inner.txt"), INNER)

    def test_inside_symlink_is_followed_to_its_exact_destination_and_value(self):
        # causal: the alias destination is its OWN name and carries the target's bytes (not merely "some bytes").
        self.assertIn("skills/alias", self.copied)
        self.assertEqual(self.copied["skills/alias"], INNER)

    def test_inside_junction_is_followed_under_its_own_name(self):
        self.assertEqual(self.copied.get("skills/injunc/inner.txt"), INNER)

    def test_outside_symlink_and_junction_leave_no_destination_and_no_bytes(self):
        self.assertNotIn("skills/sym", self.copied)   # destination absent (follow-outside mutant -> present)
        self.assertNotIn("skills/junc", self.copied)
        self.assertNotIn(CANARY, b"".join(self.copied.values()))  # and no target bytes

    def test_symlink_and_junction_cycles_are_bounded_and_skipped(self):
        # the call returned (no unbounded recursion) and neither cycle produced a destination.
        self.assertNotIn("skills/loop", self.copied)   # cycle-follow mutant -> a loop dest appears
        self.assertNotIn("skills/jloop", self.copied)


if __name__ == "__main__":
    unittest.main()
