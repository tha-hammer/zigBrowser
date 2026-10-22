#!/usr/bin/env python3
"""S8 decision 16, part 5 red (RoseCat 7fcfadf on 661fe7d): a refused write shows the stored
value again (plan rev 16.20.58), and the drop-down's selection is read back, not inferred.

The same world as agent_navigate_selector_test.py. Every `SECRETS navapproval <value> <ok|
unreadable>` row names the drop-down's own selected item, read back from the control after it
was set; a refused write is followed by one such row for the store's value (a fresh
fail-closed read), and the refusal sentence stays the window's last line.

- refused-readback: `settings` is a symlink (the store reads as Yes, unreadable). Down tries
  No: `SECRETS navapproval-refused no`, then `SECRETS navapproval yes unreadable` (the
  drop-down is back on Yes), and the last status line is "The navigation approval setting
  could not be saved." Then Down again tries No again, which it can only do from Yes: had
  the drop-down stayed on No, Down would try Conditional. Refused again, back on Yes. Nothing
  is written through the link.

Runs in a PID namespace of its own, then sealed with bwrap. Unregistered until its green."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_host_lifecycle_test as life  # noqa: E402
from agent_navigate_approval_test import World  # noqa: E402
from agent_navigate_selector_test import REFUSED, choose, nav_rows, open_secrets, texts  # noqa: E402


def case_refused_readback(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "selector-readback", {})
    settings = w.store.parent
    elsewhere = settings.parent / "settings-elsewhere"
    try:
        for leftover in sorted(settings.iterdir()) if settings.is_dir() and not settings.is_symlink() else []:
            leftover.unlink()
        if settings.is_symlink():
            settings.unlink()
        elif settings.is_dir():
            settings.rmdir()
        elsewhere.mkdir(mode=0o700, exist_ok=True)
        (elsewhere / "navigate_approval").unlink(missing_ok=True)
        fd = os.open(elsewhere / "navigate_approval", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, b"no\n")
        os.close(fd)
        settings.symlink_to(elsewhere, target_is_directory=True)
        if not (w.ready(check) and open_secrets(w, check, "readback")):
            return
        check(w.b.wait(lambda: nav_rows(w)[-1:] == [("navapproval", "yes", "unreadable")], 10),
              f"the drop-down shows Yes, unreadable ({nav_rows(w)})", w.b)
        for key, tried in (("Down", "no"), ("Down", "no")):
            before = len(nav_rows(w))
            choose(w, key)
            want = [("navapproval-refused", tried), ("navapproval", "yes", "unreadable")]
            check(w.b.wait(lambda: nav_rows(w)[before:] == want, 10),
                  f"{key} tried {tried}: refused, then the drop-down reads back Yes ({nav_rows(w)[before:]})", w.b)
            check(w.b.wait(lambda: texts(w)[-1:] == [REFUSED], 5),
                  f"the refusal stays the last line ({texts(w)[-2:]})", w.b)
        check((elsewhere / "navigate_approval").read_bytes() == b"no\n" and settings.is_symlink(),
              "nothing was written through the link, and it is still a link")
    finally:
        w.close()
        if w.store.parent.is_symlink():
            w.store.parent.unlink()


CASES = {"refused-readback": case_refused_readback}


def main() -> int:
    if "--pid-ns" not in sys.argv and "--sealed-child" not in sys.argv:
        done = subprocess.run(["unshare", "--user", "--map-current-user", "--pid", "--fork", "--kill-child", "--mount-proc",
                               sys.executable, str(Path(__file__).resolve()), "--pid-ns", *sys.argv[1:]])
        return done.returncode
    if "--sealed-child" not in sys.argv:
        args = [a for a in sys.argv[1:] if a != "--pid-ns"]
        done = subprocess.run(["/usr/bin/bwrap", "--unshare-net", "--die-with-parent", "--dev-bind", "/", "/",
                               "--proc", "/proc", "--", sys.executable, str(Path(__file__).resolve()),
                               "--sealed-child", *args])
        return done.returncode
    sys.argv.remove("--sealed-child")
    from agent_common import run_main
    try:
        return run_main(__doc__, CASES)
    finally:
        for d in life.RUNTIME_DIRS:
            if str(d).startswith("/tmp/zbl-"):
                subprocess.run(["find", str(d), "-delete"], check=False)


if __name__ == "__main__":
    raise SystemExit(main())
