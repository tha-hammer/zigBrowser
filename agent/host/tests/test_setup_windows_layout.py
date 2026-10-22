"""WS7.4 [L] — RED-FIRST for the pure SAI copy rules on a FAKE filesystem (plan line 1668).

The copy follows the "Hook commands only" rule and the S3a corrections: a link that resolves OUTSIDE its item root
is skipped with NO target bytes in the home. On Windows this must hold for BOTH symlinks AND junctions (reparse
points) — `os.scandir(...).is_symlink()` does not catch a junction, so the current Linux-only check would copy a
junction's target bytes. This [L] test drives a PORTABLE copy-rule engine over a fake filesystem (junctions cannot
exist on Linux), so one engine serves Linux and Windows and only the path primitives differ.

UNREGISTERED (no gate step builds it), signal-free, no VM, no Macs. Only `agent/host/tests/` is touched (not
`zb_agent_host/`), so no ms5 inventory change. RED now: `setup.copy_tree_fs` (the portable fake-FS engine) does not
exist (AttributeError). The green refactors `copy_sai` onto this engine (Linux os-backed, Windows reparse-aware).

MUTANT (follow links): an engine that follows an outside-resolving link/junction copies the canary -> red.
"""

import unittest

import support  # noqa: F401  (puts agent/host on sys.path)

from zb_agent_host import setup

CANARY = b"SECRET-TARGET-BYTES-OUTSIDE-THE-ITEM"


def _fake_fs():
    """A skill item `/src/skills` with: a real in-item file, a symlink to an outside file, and a junction to an
    outside directory. Each node is ('dir', [names]) | ('file', bytes) | ('link', target) | ('junction', target)."""
    return {
        "/src/skills": ("dir", ["real.txt", "sub", "sym", "junc"]),
        "/src/skills/real.txt": ("file", b"in-item-bytes"),
        "/src/skills/sub": ("dir", ["inner.txt"]),
        "/src/skills/sub/inner.txt": ("file", b"in-item-inner"),
        "/src/skills/sym": ("link", "/outside/secret.txt"),
        "/src/skills/junc": ("junction", "/outside/secretdir"),
        "/outside/secret.txt": ("file", CANARY),
        "/outside/secretdir": ("dir", ["leak.txt"]),
        "/outside/secretdir/leak.txt": ("file", CANARY),
    }


class WindowsCopyRules(unittest.TestCase):
    def test_outside_symlink_and_junction_bring_no_target_bytes(self):
        copied = setup.copy_tree_fs(_fake_fs(), "/src/skills")  # -> {dest_rel: bytes}
        blob = b"".join(copied.values())
        # the real in-item files ARE copied...
        self.assertIn(b"in-item-bytes", blob)
        self.assertIn(b"in-item-inner", blob)
        # ...but neither the outside symlink NOR the outside junction brings any target bytes into the home.
        self.assertNotIn(CANARY, blob)  # follow-links mutant -> CANARY present -> red

    def test_an_inside_link_is_still_followed(self):
        fs = {
            "/src/skills": ("dir", ["a.txt", "alias"]),
            "/src/skills/a.txt": ("file", b"inside-bytes"),
            "/src/skills/alias": ("link", "/src/skills/a.txt"),  # resolves INSIDE the item root
        }
        copied = setup.copy_tree_fs(fs, "/src/skills")
        self.assertIn(b"inside-bytes", b"".join(copied.values()))  # an in-item link is not skipped


if __name__ == "__main__":
    unittest.main()
