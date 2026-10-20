"""S6b1 follow-up (RoseCat 6055 on 00530d4; plan rev 16.18.7): every credential control
is locked, observably, for the whole sign-in, including while the signed-in token's
store is still in flight.

Under --e2e-protocol the Secrets window reports each credential control's sensitivity
as GTK holds it (gtk_widget_get_sensitive, read back after every change):

    SECRETS sensitive <entry|save|remove|file|signin> <0|1>

Cases (run alone or with --only):
- locks-through-the-store: the keyring store is delayed 3 s. A token saved by hand
  leaves the entry, Save, Remove and Sign in enabled. Sign in locks the entry, Save,
  Remove and Sign in. After Send code, while the signed-in token's own store is in
  flight (its "Saving..."), they are all still locked, typing leaves the entry empty
  (its pixels), and Save starts no store. When that store answers, they unlock, and
  the keyring holds the signed-in token.
- file-choice-locked: with no keyring, a token saved by hand is offered "Save to a
  private file instead" (the file choice is enabled). Sign in locks it; Cancel unlocks
  it, and the file choice then stores that token as an ordinary Save.
- signin-locked-during-save: while a manual Save's store is in flight (delayed), Sign
  in is reported insensitive; once the store answers, it is enabled again."""

import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_secrets_test as sec  # noqa: E402
import agent_login_test as lt  # noqa: E402
from agent_common import run_main  # noqa: E402

DELAY = {sec.DELAY_ENV: "store=3000"}
CONTROLS = ("entry", "save", "remove", "file", "signin")


def sensitive(b) -> dict[str, str]:
    """The latest reported sensitivity of each credential control."""
    out = {}
    for f in lt.rows(b, "sensitive"):
        if len(f) != 2 or f[0] not in CONTROLS or f[1] not in ("0", "1"):
            raise AssertionError(f"malformed SECRETS sensitive row: {f!r}")
        out[f[0]] = f[1]
    return out


def has(b, **want) -> bool:
    got = sensitive(b)
    return all(got.get(name) == value for name, value in want.items())


def save_by_hand(si, check, token: str, done_status: str) -> bool:
    b = si.b
    sec.click_rect(b, lt.rect(b, "entry"))
    sec.type_text(b, token)
    sec.click_rect(b, lt.rect(b, "save"))
    return check(b.wait(lambda: lt.statuses(b)[-1:] == [done_status], 20), f"the manual Save ends {done_status}", b)


def case_locks_through_the_store(binary: Path, tmp: Path, check) -> None:
    si = lt.SignIn(binary, tmp, "locks-store", bus_extra=DELAY)
    b = si.b
    try:
        if not si.open_window(check):
            return
        if not save_by_hand(si, check, sec.canary(), "connected-secret-service"):
            return
        check(b.wait(lambda: has(b, entry="1", save="1", remove="1", signin="1"), 10),
              f"with a token stored: entry, Save, Remove and Sign in are enabled ({sensitive(b)})", b)
        if not si.sign_in(check):
            return
        check(b.wait(lambda: has(b, entry="0", save="0", remove="0", signin="0"), 10),
              f"Sign in locks the entry, Save, Remove and Sign in ({sensitive(b)})", b)
        saving_before = lt.texts(b).count("Saving...")
        si.paste(f"fakecode#{si.state()}")
        if not check(b.wait(lambda: lt.texts(b).count("Saving...") > saving_before, 15),
                     "the signed-in token's store is in flight (its Saving...)", b):
            return
        check(has(b, entry="0", save="0", remove="0", signin="0"),
              f"during that store all four stay locked ({sensitive(b)})", b)
        empty = sec.dark(sec.entry_pixels(b))
        sec.click_rect(b, lt.rect(b, "entry"))
        sec.type_text(b, sec.canary())
        sec.click_rect(b, lt.rect(b, "save"))
        time.sleep(0.3)
        check(sec.dark(sec.entry_pixels(b)) <= empty + 12, "typing during that store leaves the entry empty", b)
        check(lt.texts(b).count("Saving...") == saving_before + 1, "Save during that store starts no store", b)
        check(b.wait(lambda: lt.login_states(b)[-1:] == ["done"], 15), "the sign-in ends with done", b)
        check(b.wait(lambda: has(b, entry="1", save="1", remove="1", signin="1"), 10),
              f"after the store answered, they unlock ({sensitive(b)})", b)
        time.sleep(4.0)
        check(si.kr.lookup() == si.token, "the keyring holds the signed-in token")
    finally:
        si.close()


def case_file_choice_locked(binary: Path, tmp: Path, check) -> None:
    si = lt.SignIn(binary, tmp, "file-locked", keyring=False)
    b = si.b
    try:
        if not si.open_window(check):
            return
        manual = sec.canary()
        if not save_by_hand(si, check, manual, "no-keyring"):
            return
        check(b.wait(lambda: lt.rect(b, "file") is not None and has(b, file="1"), 10),
              f"the file choice is offered and enabled ({sensitive(b)})", b)
        if not si.sign_in(check):
            return
        check(b.wait(lambda: has(b, file="0", save="0", entry="0"), 10),
              f"Sign in locks the file choice, Save and the entry ({sensitive(b)})", b)
        sec.click_rect(b, lt.rect(b, "cancel"))
        check(b.wait(lambda: lt.login_states(b)[-1:] == ["cancelled"], 15), "the sign-in is cancelled", b)
        check(b.wait(lambda: has(b, file="1", save="1", entry="1"), 10),
              f"after it, the file choice, Save and the entry are enabled again ({sensitive(b)})", b)
        sec.click_rect(b, lt.rect(b, "file"))
        check(b.wait(lambda: lt.statuses(b)[-1:] == ["connected-file"], 10), "the file choice stores the token", b)
        token_file = si.world.agent / "secrets" / "claude-token"
        check(token_file.exists() and token_file.read_text().strip() == manual, "the file holds the hand-saved token")
    finally:
        si.close()


def case_signin_locked_during_save(binary: Path, tmp: Path, check) -> None:
    si = lt.SignIn(binary, tmp, "signin-locked", bus_extra=DELAY)
    b = si.b
    try:
        if not si.open_window(check):
            return
        check(b.wait(lambda: has(b, signin="1"), 10), f"Sign in is enabled ({sensitive(b)})", b)
        sec.click_rect(b, lt.rect(b, "entry"))
        sec.type_text(b, sec.canary())
        sec.click_rect(b, lt.rect(b, "save"))
        check(b.wait(lambda: "Saving..." in lt.texts(b), 5), "the manual store is in flight", b)
        check(b.wait(lambda: has(b, signin="0", save="0", entry="0"), 5),
              f"during it Sign in, Save and the entry are locked ({sensitive(b)})", b)
        check(b.wait(lambda: lt.statuses(b)[-1:] == ["connected-secret-service"], 15), "the store answers", b)
        check(b.wait(lambda: has(b, signin="1", save="1", entry="1"), 10),
              f"after it, Sign in, Save and the entry are enabled ({sensitive(b)})", b)
    finally:
        si.close()


CASES = {
    "locks-through-the-store": case_locks_through_the_store,
    "file-choice-locked": case_file_choice_locked,
    "signin-locked-during-save": case_signin_locked_during_save,
}


def main() -> int:
    return run_main(__doc__, CASES)


if __name__ == "__main__":
    sys.exit(main())
