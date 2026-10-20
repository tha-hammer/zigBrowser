"""S6b1 part B's finding (chat-drawer plan rev 16.18.9; the orchestrator 2026-10-20, RoseCat 6156):
after Send code the sign-in reaches Claude through the relay proxy, and it never waits in
silence: a CLI that fails or says nothing ends it with a visible reason.

On the user's screen the real `claude setup-token` took the code and the window said
"Signing in..." for minutes, with an empty census: the helper gave the CLI no HTTPS_PROXY,
the CLI failed to resolve platform.claude.com in the sandbox, printed "OAuth error" and
"Press Enter to retry." and waited. The fake CLI's `mode` file (in the agent home's
scratchpad, beside its `state`) now models that.

Rows: `SECRETS login`, `SECRETS text`, `SECRETS status` as in agent_login_test.py, and
`SECRETS reason <sentence>|-` (the fixed reason line under "Sign-in failed.").
stderr: the login netd's `netd census <host>:<port> <allowed|refused>`.

Cases (run alone or with --only):
- proxy: `needs-proxy`. The fake reaches the relay proxy from its environment and sends
  one CONNECT zb-proxy-probe.invalid:443 (refused, and censused, by the login netd;
  nothing goes further), then prints the token: the sign-in ends `done` and the keyring
  holds the token.
- oauth-error: `oauth-error`. Within 15 s of Send code the one ending is
  `error-exchange`; the window says "Sign-in failed." with the exchange reason; nothing
  is stored and no login helper remains.
- silent: `silent`. The one ending is `error-timeout`, 55 to 75 s after Send code (the
  60 s exchange clock), with the timeout reason.
- again: after an `error-exchange`, Sign in hides the reason (`SECRETS reason -`), and
  with the fake's default mode the new sign-in stores the token."""

import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_secrets_test as sec  # noqa: E402
import agent_login_test as lt  # noqa: E402
from agent_common import run_main  # noqa: E402

TEXT_FAILED = "Sign-in failed."
REASON_EXCHANGE = "Claude.ai could not be reached, or it did not accept the code. Try again."
REASON_TIMEOUT = "The sign-in took too long. Try again."
CENSUS_PROBE = "netd census zb-proxy-probe.invalid:443 refused"


def reasons(b) -> list[str]:
    return [f[0] for f in lt.rows(b, "reason")]


def with_mode(si, word: str | None) -> None:
    path = si.fake_dir / "mode"
    if word is None:
        path.unlink(missing_ok=True)
    else:
        path.write_text(word + "\n", encoding="ascii")


def send_right_code(si, check) -> float:
    si.paste(f"fakecode#{si.state()}")
    sent = time.monotonic()
    check(si.b.wait(lambda: lt.texts(si.b)[-1:] == [lt.TEXT_SIGNING], 10), "Send code shows \"Signing in...\"", si.b)
    return sent


def case_proxy(binary: Path, tmp: Path, check) -> None:
    si = lt.SignIn(binary, tmp, "exch-proxy")
    b = si.b
    try:
        with_mode(si, "needs-proxy")
        if not si.open_and_sign_in(check):
            return
        send_right_code(si, check)
        check(b.wait(lambda: lt.endings(b) != [], 30) and lt.endings(b) == ["done"],
              f"the sign-in ends done through the relay proxy ({lt.login_states(b)})", b)
        check(any(CENSUS_PROBE in line for line in b.err), f"stderr has {CENSUS_PROBE!r}", b)
        check(b.wait(lambda: lt.statuses(b)[-1:] == ["connected-secret-service"], 15), "connected-secret-service", b)
        time.sleep(1.0)
        check(si.kr.lookup() == si.token, "the keyring holds the signed-in token")
    finally:
        si.close()


def case_oauth_error(binary: Path, tmp: Path, check) -> None:
    si = lt.SignIn(binary, tmp, "exch-oauth")
    b = si.b
    try:
        with_mode(si, "oauth-error")
        if not si.open_and_sign_in(check):
            return
        sent = send_right_code(si, check)
        ended = b.wait(lambda: lt.endings(b) != [], 15)
        check(ended and lt.endings(b) == ["error-exchange"],
              f"within 15 s of Send code the one ending is error-exchange ({lt.login_states(b)}, "
              f"{time.monotonic() - sent:.1f}s)", b)
        check(b.wait(lambda: lt.texts(b)[-1:] == [TEXT_FAILED], 5), f"\"{TEXT_FAILED}\"", b)
        check(b.wait(lambda: reasons(b)[-1:] == [REASON_EXCHANGE], 5), f"the reason: {REASON_EXCHANGE!r} ({reasons(b)})", b)
        check(b.wait(lambda: lt.login_helpers(b) == [], 10), "no login helper remains", b)
        check(si.kr.lookup() is None, "nothing is stored")
    finally:
        si.close()


def case_silent(binary: Path, tmp: Path, check) -> None:
    si = lt.SignIn(binary, tmp, "exch-silent")
    b = si.b
    try:
        with_mode(si, "silent")
        if not si.open_and_sign_in(check):
            return
        sent = send_right_code(si, check)
        ended = b.wait(lambda: lt.endings(b) != [], 80)
        elapsed = time.monotonic() - sent
        check(ended and lt.endings(b) == ["error-timeout"], f"the one ending is error-timeout ({lt.login_states(b)})", b)
        check(55 <= elapsed <= 75, f"it comes 55 to 75 s after Send code ({elapsed:.1f}s)", b)
        check(b.wait(lambda: reasons(b)[-1:] == [REASON_TIMEOUT], 5), f"the reason: {REASON_TIMEOUT!r} ({reasons(b)})", b)
        check(si.kr.lookup() is None, "nothing is stored")
    finally:
        si.close()


def case_again(binary: Path, tmp: Path, check) -> None:
    si = lt.SignIn(binary, tmp, "exch-again")
    b = si.b
    try:
        with_mode(si, "oauth-error")
        if not si.open_and_sign_in(check):
            return
        send_right_code(si, check)
        if not check(b.wait(lambda: lt.endings(b) == ["error-exchange"], 15), f"error-exchange ({lt.login_states(b)})", b):
            return
        check(b.wait(lambda: reasons(b)[-1:] == [REASON_EXCHANGE], 5), f"the reason is shown ({reasons(b)})", b)
        check(b.wait(lambda: lt.login_helpers(b) == [], 10), "the failed sign-in's helper is gone", b)
        with_mode(si, None)
        starting = lt.login_states(b).count("starting")
        need = lt.login_states(b).count("need-code")
        (si.fake_dir / "state").unlink(missing_ok=True)
        sec.click_rect(b, lt.rect(b, "signin"))
        check(b.wait(lambda: lt.login_states(b).count("starting") == starting + 1, 15), "Sign in starts again", b)
        check(b.wait(lambda: reasons(b)[-1:] == ["-"], 5), f"Sign in hides the reason ({reasons(b)})", b)
        if not check(b.wait(lambda: lt.login_states(b).count("need-code") == need + 1 and si.state() is not None
                            and lt.rect(b, "code") is not None, 60), "the new sign-in asks for a code", b):
            return
        si.paste(f"fakecode#{si.state()}")
        check(b.wait(lambda: lt.endings(b)[-1:] == ["done"], 30), f"the new sign-in ends done ({lt.login_states(b)})", b)
        check(b.wait(lambda: lt.statuses(b)[-1:] == ["connected-secret-service"], 15), "connected-secret-service", b)
        time.sleep(1.0)
        check(si.kr.lookup() == si.token, "the keyring holds the signed-in token")
    finally:
        si.close()


CASES = {
    "proxy": case_proxy,
    "oauth-error": case_oauth_error,
    "silent": case_silent,
    "again": case_again,
}


def main() -> int:
    return run_main(__doc__, CASES)


if __name__ == "__main__":
    sys.exit(main())
