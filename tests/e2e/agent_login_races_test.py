"""S6b1 follow-up (RoseCat 6024 on 4c659aa; plan rev 16.18.6): the sign-in and the
Secrets window's own credential controls never overlap, a sign-in has exactly one
ending even through the file fallback, and the inert route cancels cleanly.

Cases (run alone or with --only):
- save-during-signin: while a sign-in waits for its code, typing a token into the
  Secrets entry and clicking Save does nothing: no "Saving...", no new status, no
  store. The keyring store is delayed (store=3000 ms), so an overlapping store
  would be seen. After the code, the keyring holds exactly the signed-in token,
  and "Signed in." is the window's last word.
- signin-during-save: while a manual Save's keyring store is in flight (delayed),
  Sign in starts nothing (no `SECRETS login` row). Once the store answers, Sign in
  works again.
- file-fallback: with no keyring, a signed-in token's store fails and gives
  `error-store`, the one ending. The window still offers "Save to a private file
  instead" for that token. Choosing it stores the token in the file as an ordinary
  Save ("Connected. The token is stored in a private file."), and no second ending
  (no `done`) follows.
- inert-cancel: without --e2e-protocol (no rows), in a namespace with no network,
  Sign in is started by Alt+I and cancelled by Alt+C (the Cancel button's mnemonic).
  Afterwards no login helper, login netd or `-login` directory under this browser
  remains."""

import os
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_secrets_test as sec  # noqa: E402
import agent_login_test as lt  # noqa: E402 - its SignIn world, rows and process census
from agent_common import run_main  # noqa: E402

DELAY = {sec.DELAY_ENV: "store=3000"}
TEXT_WORKING = "Saving..."
TEXT_FILE = "Connected. The token is stored in a private file."


def case_save_during_signin(binary: Path, tmp: Path, check) -> None:
    si = lt.SignIn(binary, tmp, "save-during", bus_extra=DELAY)
    b = si.b
    try:
        if not si.open_and_sign_in(check):
            return
        manual = sec.canary()
        mark_text, mark_status = len(lt.texts(b)), len(lt.statuses(b))
        sec.click_rect(b, lt.rect(b, "entry"))
        sec.type_text(b, manual)
        sec.click_rect(b, lt.rect(b, "save"))
        time.sleep(2.0)
        check(TEXT_WORKING not in lt.texts(b)[mark_text:], f"Save during the sign-in started no store ({lt.texts(b)[mark_text:]})", b)
        check(lt.statuses(b)[mark_status:] == [], f"and changed no status ({lt.statuses(b)[mark_status:]})", b)
        # The typed keys may have landed in the focused code field: select all of it and
        # paste the code over the selection.
        owner = sec.ClipboardOwner(b, f"fakecode#{si.state()}")
        try:
            sec.click_rect(b, lt.rect(b, "code"))
            b.x.key("a", ("Control_L",))
            b.x.key("v", ("Control_L",))
            time.sleep(0.3)
            sec.click_rect(b, lt.rect(b, "send-code"))
            time.sleep(0.3)
        finally:
            owner.close()
        check(b.wait(lambda: lt.login_states(b)[-1:] == ["done"], 30), "the sign-in ends with done", b)
        time.sleep(4.0)  # longer than one delayed store: an overlapping one would have landed
        check(si.kr.lookup() == si.token, "the keyring holds exactly the signed-in token")
        check(lt.texts(b)[-1:] == [lt.TEXT_SIGNED_SERVICE], f"\"Signed in.\" is the last word ({lt.texts(b)[-3:]})", b)
        check(not sec.leaks("\n".join(b.out + b.err), manual), "the typed token appears nowhere in rows or stderr", b)
    finally:
        si.close()


def case_signin_during_save(binary: Path, tmp: Path, check) -> None:
    si = lt.SignIn(binary, tmp, "signin-during", bus_extra=DELAY)
    b = si.b
    try:
        if not si.open_window(check):
            return
        manual = sec.canary()
        sec.click_rect(b, lt.rect(b, "entry"))
        sec.type_text(b, manual)
        sec.click_rect(b, lt.rect(b, "save"))
        check(b.wait(lambda: TEXT_WORKING in lt.texts(b), 5), "the manual Save's store is in flight", b)
        sec.click_rect(b, lt.rect(b, "signin"))
        time.sleep(1.5)
        check(lt.login_states(b) == [], f"Sign in during the store started nothing ({lt.login_states(b)})", b)
        check(b.wait(lambda: lt.statuses(b)[-1:] == ["connected-secret-service"], 15), "the manual Save completes", b)
        check(si.kr.lookup() == manual, "the keyring holds the saved token")
        sec.click_rect(b, lt.rect(b, "signin"))
        check(b.wait(lambda: lt.login_states(b)[:1] == ["starting"], 15), "after it, Sign in works again", b)
        if not check(b.wait(lambda: lt.rect(b, "cancel") is not None, 15), "SECRETS rect cancel", b):
            return
        sec.click_rect(b, lt.rect(b, "cancel"))
        lt.nothing_left(si, check, "after cancel")
    finally:
        si.close()


def case_file_fallback(binary: Path, tmp: Path, check) -> None:
    si = lt.SignIn(binary, tmp, "fallback", keyring=False)
    b = si.b
    try:
        if not si.open_and_sign_in(check):
            return
        si.paste(f"fakecode#{si.state()}")
        check(b.wait(lambda: lt.endings(b) == ["error-store"], 30), f"error-store is the one ending ({lt.login_states(b)})", b)
        check(b.wait(lambda: lt.rect(b, "file") is not None, 10), "the private-file choice is offered", b)
        sec.click_rect(b, lt.rect(b, "file"))
        check(b.wait(lambda: lt.statuses(b)[-1:] == ["connected-file"], 10), "the token is stored in the file", b)
        check(lt.texts(b)[-1:] == [TEXT_FILE], f"as an ordinary Save: \"{TEXT_FILE}\" ({lt.texts(b)[-2:]})", b)
        token_file = si.world.agent / "secrets" / "claude-token"
        check(token_file.exists() and token_file.read_text().strip() == si.token, "the file holds the signed-in token")
        time.sleep(1.0)
        check(lt.endings(b) == ["error-store"], f"no second ending after the file choice ({lt.login_states(b)})", b)
    finally:
        si.close()


def case_inert_cancel(binary: Path, tmp: Path, check) -> None:
    from agent_common import Browser
    from agent_host_lifecycle_test import icon_centre
    from slice2_common import isolate_profile_env
    world = sec.provisioned(binary, tmp, "inert-cancel")
    markers = Path(tempfile.mkdtemp(prefix="markers-", dir=tmp))
    marker_cli = markers / "cli.sh"
    marker_cli.write_text(f"#!/bin/sh\ntouch {markers}/cli.ran\nexit 0\n")
    marker_cli.chmod(0o755)
    with sec.PrivateKeyring(tmp) as kr:
        runtime = Path(kr.bus_env["XDG_RUNTIME_DIR"])
        env = isolate_profile_env(dict(os.environ))
        env.update(world.env({"ZIGBROWSER_AGENT_CLAUDE_CLI": str(marker_cli)}))
        env.update(kr.bus_env)
        sec.assert_not_user_bus(env)
        b = Browser(binary, tmp, "inert-cancel", ["--agent-drawer", "on"], env=env, e2e=False,
                    prefix=["unshare", "--user", "--map-current-user", "--net"])
        try:
            b.wait(lambda: b.display_file.exists(), 20)
            icon = None
            deadline = time.monotonic() + 30
            while icon is None and time.monotonic() < deadline:
                time.sleep(0.5)
                icon = icon_centre(b)
            if not check(icon is not None, "the icon is on the screen", b):
                return
            b.x.click(*icon)
            time.sleep(1.0)
            for ch in "hi":
                b.x.key(ch, settle=0.005)
            b.x.key("Return")
            check(b.wait(lambda: b.x.toplevels("Claude Agent account") != [], 20), "the Secrets window opened", b)
            check(lt.focus_window(b, "Claude Agent account"), "the Secrets window has the input focus", b)
            b.x.key("i", ("Alt_L",))
            if not check(b.wait(lambda: lt.login_helpers(b) != [], 30), "Alt+I (Sign in) started the login helper", b):
                return
            check(b.wait(lambda: len(lt.login_netds(b, runtime)) == 1, 10), "one login netd serves", b)
            lt.focus_window(b, "Claude Agent account")
            b.x.key("c", ("Alt_L",))
            check(b.wait(lambda: lt.login_helpers(b) == [], 15), "Alt+C (Cancel): no login helper remains", b)
            check(b.wait(lambda: lt.login_netds(b, runtime) == [], 15), "no login netd remains", b)
            check(b.wait(lambda: lt.login_dirs(runtime) == [], 15), "no -login directory remains", b)
            check(not (markers / "cli.ran").exists(), "the marker CLI never ran")
        finally:
            b.stop()


CASES = {
    "save-during-signin": case_save_during_signin,
    "signin-during-save": case_signin_during_save,
    "file-fallback": case_file_fallback,
    "inert-cancel": case_inert_cancel,
}


def main() -> int:
    return run_main(__doc__, CASES)


if __name__ == "__main__":
    sys.exit(main())
