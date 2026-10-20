"""S6b1 follow-up (RoseCat 6055 on 00530d4; plan rev 16.18.7): every credential control
is locked, observably, for the whole sign-in, including while the signed-in token's
store is still in flight.

Under --e2e-protocol the Secrets window reports each credential control's sensitivity
as GTK holds it (gtk_widget_get_sensitive). Rev 16.18.8 (RoseCat 6122): each time it
recomputes them it writes all five rows, in a fixed order, a complete census:

    SECRETS sensitive entry <0|1>
    SECRETS sensitive save <0|1>
    SECRETS sensitive remove <0|1>
    SECRETS sensitive file <0|1>
    SECRETS sensitive signin <0|1>

Every check takes the row count before its transition and requires a fresh, complete
census after it, asserting all five values; the first census after the window opens
must name all five.

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


def sensitive_rows(b) -> list[tuple[str, str]]:
    out = []
    for f in lt.rows(b, "sensitive"):
        if len(f) != 2 or f[0] not in CONTROLS or f[1] not in ("0", "1"):
            raise AssertionError(f"malformed SECRETS sensitive row: {f!r}")
        out.append((f[0], f[1]))
    return out


def mark(b) -> int:
    """The row count before a transition: only censuses written after it count."""
    return len(sensitive_rows(b))


def census_after(b, since: int):
    """The latest complete census (five rows in the order entry, save, remove, file,
    signin) written after row `since`, as a dict, or None."""
    rows = sensitive_rows(b)[since:]
    for start in range(len(rows) - 5, -1, -1):
        window = rows[start:start + 5]
        if tuple(name for name, _ in window) == CONTROLS:
            return dict(window)
    return None


def fresh(b, since: int, timeout: float = 10, **want) -> bool:
    """A census written after `since` holds exactly `want` for all five controls."""
    assert set(want) == set(CONTROLS), want
    return b.wait(lambda: census_after(b, since) == want, timeout)


ALL_ON = dict(entry="1", save="1", remove="1", file="1", signin="1")
ALL_OFF = dict(entry="0", save="0", remove="0", file="0", signin="0")


def initial_census(si, check) -> bool:
    """The first census after the window opens names all five controls."""
    b = si.b
    return check(b.wait(lambda: census_after(b, 0) is not None, 10),
                 f"the first census names entry, save, remove, file and signin ({sensitive_rows(b)[:5]})", b)


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
        if not (si.open_window(check) and initial_census(si, check)):
            return
        m = mark(b)
        if not save_by_hand(si, check, sec.canary(), "connected-secret-service"):
            return
        check(fresh(b, m, **ALL_ON), f"with a token stored, a fresh census: all five enabled ({census_after(b, m)})", b)
        m = mark(b)
        if not si.sign_in(check):
            return
        check(fresh(b, m, **ALL_OFF), f"Sign in: a fresh census, all five locked ({census_after(b, m)})", b)
        saving_before = lt.texts(b).count("Saving...")
        m = mark(b)
        si.paste(f"fakecode#{si.state()}")
        if not check(b.wait(lambda: lt.texts(b).count("Saving...") > saving_before, 15),
                     "the signed-in token's store is in flight (its Saving...)", b):
            return
        check(fresh(b, m, 5, **ALL_OFF) and lt.login_states(b)[-1:] != ["done"],
              f"at the store's start, a fresh census: all five still locked ({census_after(b, m)})", b)
        empty = sec.dark(sec.entry_pixels(b))
        sec.click_rect(b, lt.rect(b, "entry"))
        sec.type_text(b, sec.canary())
        sec.click_rect(b, lt.rect(b, "save"))
        time.sleep(0.3)
        check(sec.dark(sec.entry_pixels(b)) <= empty + 12, "typing during that store leaves the entry empty", b)
        check(lt.texts(b).count("Saving...") == saving_before + 1, "Save during that store starts no store", b)
        m = mark(b)
        check(b.wait(lambda: lt.login_states(b)[-1:] == ["done"], 15), "the sign-in ends with done", b)
        check(fresh(b, m, **ALL_ON), f"after the store answered, a fresh census: all five enabled ({census_after(b, m)})", b)
        time.sleep(4.0)
        check(si.kr.lookup() == si.token, "the keyring holds the signed-in token")
    finally:
        si.close()


def case_file_choice_locked(binary: Path, tmp: Path, check) -> None:
    si = lt.SignIn(binary, tmp, "file-locked", keyring=False)
    b = si.b
    try:
        if not (si.open_window(check) and initial_census(si, check)):
            return
        manual = sec.canary()
        # No keyring: nothing is stored, so Remove does not apply (it stays 0).
        offered = dict(entry="1", save="1", remove="0", file="1", signin="1")
        m = mark(b)
        if not save_by_hand(si, check, manual, "no-keyring"):
            return
        check(b.wait(lambda: lt.rect(b, "file") is not None, 10) and fresh(b, m, **offered),
              f"the file choice is offered: a fresh census with it enabled ({census_after(b, m)})", b)
        m = mark(b)
        if not si.sign_in(check):
            return
        check(fresh(b, m, **ALL_OFF), f"Sign in: a fresh census, all five locked ({census_after(b, m)})", b)
        m = mark(b)
        sec.click_rect(b, lt.rect(b, "cancel"))
        check(b.wait(lambda: lt.login_states(b)[-1:] == ["cancelled"], 15), "the sign-in is cancelled", b)
        check(fresh(b, m, **offered), f"after Cancel, a fresh census: as offered again ({census_after(b, m)})", b)
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
        if not (si.open_window(check) and initial_census(si, check)):
            return
        check(b.wait(lambda: lt.statuses(b)[-1:] == ["empty"], 10) and fresh(b, 0, entry="1", save="1", remove="0", file="1", signin="1"),
              f"with nothing stored: everything but Remove enabled ({census_after(b, 0)})", b)
        sec.click_rect(b, lt.rect(b, "entry"))
        sec.type_text(b, sec.canary())
        m = mark(b)
        sec.click_rect(b, lt.rect(b, "save"))
        check(b.wait(lambda: "Saving..." in lt.texts(b), 5), "the manual store is in flight", b)
        check(fresh(b, m, 5, **ALL_OFF), f"during it, a fresh census: all five locked ({census_after(b, m)})", b)
        m = mark(b)
        check(b.wait(lambda: lt.statuses(b)[-1:] == ["connected-secret-service"], 15), "the store answers", b)
        check(fresh(b, m, **ALL_ON), f"after it, a fresh census: all five enabled ({census_after(b, m)})", b)
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
