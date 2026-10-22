#!/usr/bin/env python3
"""S8 decision 16, part 5 red (chat-drawer plan rev 16.20.50: the selector's one native
control): the Secrets window's "Navigation approval" drop-down (Yes, No, Conditional) is the
only writer of agent-home/settings/navigate_approval.

The same world as agent_navigate_approval_test.py (the real binary on its own Xvfb, the
real helper and CLI against the fake Messages API, sealed, a private bus). The Secrets window
is opened with the drawer's Account button; the drop-down is reached with its mnemonic,
Alt+N, and changed with Home, Down and End, as a keyboard user does. Its rows:
- `SECRETS navapproval <yes|no|conditional> <ok|unreadable>` when the window shows the store
  (each time it opens) and after each value the control wrote;
- `SECRETS navapproval-refused <value>` when a write was refused, with the status line
  "The navigation approval setting could not be saved.";
- `SECRETS rect navapproval <x,y,w,h>`.

Cases:
- control: a missing store shows Conditional; Home writes `yes\\n`, Down `no\\n`, Down
  `conditional\\n`, each 0600 and the user's own, each with its row; the window closed and
  opened again shows what was stored;
- effect: Yes set with the control, then a prompt in the open drawer (interactive use) gets a
  card, as the store says;
- unreadable: a 0644 store shows Yes, says "Navigation approval setting is unreadable; asking
  for every navigation.", and End (Conditional) rewrites it 0600;
- refused: a settings directory that is a symlink shows Yes (unreadable); Home is refused:
  nothing is written through the link, it stays a link, and the window says so.

Stopping each browser signals its own process group, so the test runs in a PID namespace of
its own, then sealed with bwrap (RoseCat 7814). Exit 1 when Xvfb, xauth, bwrap, the venv or the
binary is missing. Unregistered until its green."""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_host_lifecycle_test as life  # noqa: E402
import agent_secrets_test as sec  # noqa: E402
from agent_navigate_approval_test import World, nav, wait_card  # noqa: E402

UNREADABLE = "Navigation approval setting is unreadable; asking for every navigation."
REFUSED = "The navigation approval setting could not be saved."


def nav_rows(w: World) -> list[tuple[str, ...]]:
    return [tuple(line.split("\t")[1:]) for line in list(w.b.out)
            if line.startswith(("SECRETS\tnavapproval\t", "SECRETS\tnavapproval-refused\t"))]


def texts(w: World) -> list[str]:
    return [f[0] for k, f in sec.secrets_lines(w.b) if k == "text"]


def open_secrets(w: World, check, label: str) -> bool:
    seen = len(sec.secrets_status(w.b))
    if not w.open_drawer(1):
        return check(False, f"{label}: window 1's drawer opens", w.b)
    sec.click_account(w.b)
    return check(sec.opens_now(w.b, seen) and w.b.wait(lambda: sec.secrets_rect(w.b, "navapproval") is not None, 10),
                 f"{label}: the Secrets window shows the Navigation approval control", w.b)


def choose(w: World, key: str) -> None:
    """Focus the window (its token entry), reach the drop-down by its mnemonic, then `key`."""
    sec.click_rect(w.b, sec.secrets_rect(w.b, "entry"))
    w.b.x.key("n", ("Alt_L",))
    time.sleep(0.2)
    w.b.x.key(key)


def stored(w: World) -> tuple[bytes, int, int] | None:
    try:
        st = os.lstat(w.store)
        return w.store.read_bytes(), st.st_mode & 0o777, st.st_uid
    except FileNotFoundError:
        return None


def case_control(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "selector-control", {})
    try:
        if not (w.ready(check) and open_secrets(w, check, "control")):
            return
        check(w.b.wait(lambda: nav_rows(w)[-1:] == [("navapproval", "conditional", "ok")], 10),
              f"a missing store shows Conditional ({nav_rows(w)})", w.b)
        me = os.geteuid()
        for key, value in (("Home", "yes"), ("Down", "no"), ("Down", "conditional")):
            choose(w, key)
            check(w.b.wait(lambda: nav_rows(w)[-1:] == [("navapproval", value, "ok")], 10),
                  f"{key} chose {value} ({nav_rows(w)[-2:]})", w.b)
            check(stored(w) == (f"{value}\n".encode(), 0o600, me), f"the store holds exactly {value!r}, 0600, mine ({stored(w)})")
        check(sec.closed(w.b), "the Secrets window closed", w.b)
        shown = len(nav_rows(w))
        if open_secrets(w, check, "reopened"):
            check(w.b.wait(lambda: nav_rows(w)[shown:] == [("navapproval", "conditional", "ok")], 10),
                  f"opened again, it shows what is stored ({nav_rows(w)[shown:]})", w.b)
    finally:
        w.close()


def case_effect(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "selector-effect", {"naveffect": None})
    try:
        if not (w.ready(check) and open_secrets(w, check, "effect")):
            return
        choose(w, "Home")
        if not check(w.b.wait(lambda: nav_rows(w)[-1:] == [("navapproval", "yes", "ok")], 10), "Yes chosen", w.b):
            return
        check(sec.closed(w.b), "the Secrets window closed", w.b)
        w.gated.calls["naveffect"] = nav(w.pages.target())
        w.raise_first()
        w.prompt("naveffect", 1, headless=False)
        card = wait_card(w, check, "Yes, interactive")
        check(card is not None, "with Yes chosen in the control, an interactive call gets a card")
        time.sleep(1.0)
        check(w.path(1) == "/one.html", f"nothing ran before an Approve ({w.path(1)})")
    finally:
        w.close()


def case_unreadable(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "selector-unreadable", {}, store=b"no\n", store_mode=0o644)
    try:
        if not (w.ready(check) and open_secrets(w, check, "unreadable")):
            return
        check(w.b.wait(lambda: nav_rows(w)[-1:] == [("navapproval", "yes", "unreadable")], 10),
              f"a 0644 store shows Yes, unreadable ({nav_rows(w)})", w.b)
        check(w.b.wait(lambda: UNREADABLE in texts(w), 10), f"and says so ({texts(w)[-2:]})", w.b)
        choose(w, "End")
        check(w.b.wait(lambda: nav_rows(w)[-1:] == [("navapproval", "conditional", "ok")], 10),
              f"End chose Conditional ({nav_rows(w)[-2:]})", w.b)
        check(stored(w) == (b"conditional\n", 0o600, os.geteuid()), f"the store is rewritten 0600 ({stored(w)})")
    finally:
        w.close()


def case_refused(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "selector-refused", {})
    elsewhere = w.store.parent.parent / "settings-elsewhere"
    try:
        settings = w.store.parent
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
        if not (w.ready(check) and open_secrets(w, check, "refused")):
            return
        check(w.b.wait(lambda: nav_rows(w)[-1:] == [("navapproval", "yes", "unreadable")], 10),
              f"a symlinked settings directory shows Yes, unreadable ({nav_rows(w)})", w.b)
        choose(w, "Home")
        check(w.b.wait(lambda: nav_rows(w)[-1:] == [("navapproval-refused", "yes")], 10),
              f"Yes is refused ({nav_rows(w)[-2:]})", w.b)
        check(w.b.wait(lambda: REFUSED in texts(w), 10), f"and the window says so ({texts(w)[-2:]})", w.b)
        check((elsewhere / "navigate_approval").read_bytes() == b"no\n" and settings.is_symlink(),
              "nothing was written through the link, and it is still a link")
    finally:
        w.close()
        if w.store.parent.is_symlink():
            w.store.parent.unlink()  # the next World's store is a plain directory again


CASES = {"control": case_control, "effect": case_effect, "unreadable": case_unreadable, "refused": case_refused}


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
