"""Part B's second finding (chat-drawer plan rev 16.20.27), end to end: a real-length code
pasted in the Secrets window finishes the sign-in. The fake setup-token CLI now has the real
CLI's paste rule (one read holding the Enter and more than 64 other bytes does not submit),
so a helper that types the code and its Enter in one write leaves it waiting, as the real
CLI did on the user's screen, until the 60 s exchange clock ends it `error-timeout`.

Rows: `SECRETS login`, `SECRETS status` as in agent_login_test.py.

Cases (run alone or with --only):
- real-length: a 100-character code with the fake's 43-character state: within 20 s of Send
  code the one ending is `done`, the fake received exactly that code, its Enter was a read
  holding at most 16 code bytes (rev 16.20.29's pacing), and the token is stored
  (`connected-secret-service`).
- short: a short code, the same (the control: before the fix it ended `done` too, but
  its Enter came in the same read as the code)."""

import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_login_test as lt  # noqa: E402
from agent_common import run_main  # noqa: E402

REAL_LENGTH = ("zbRealLengthCode-" * 8)[:100]
CHUNK = 16  # agent/host/zb_agent_host/login.py's CHUNK (rev 16.20.29): the Enter's read holds at most this many code bytes


def reads(si) -> list[tuple[int, int]]:
    try:
        text = (si.fake_dir / "reads.log").read_text(encoding="ascii")
    except OSError:
        return []
    return [tuple(int(v) for v in line.split()) for line in text.splitlines()]


def paste_case(code_part: str, label: str):
    def case(binary: Path, tmp: Path, check) -> None:
        si = lt.SignIn(binary, tmp, f"paste-{label}")
        b = si.b
        try:
            if not si.open_and_sign_in(check):
                return
            code = f"{code_part}#{si.state()}"
            started = time.monotonic()
            si.paste(code)
            check(b.wait(lambda: lt.endings(b) != [], 20) and lt.endings(b) == ["done"],
                  f"{label}: the one ending is done within 20 s ({lt.login_states(b)}, {time.monotonic() - started:.1f} s)", b)
            check(si.codes() == [code], f"{label}: the fake received exactly the code ({len(si.codes())} lines)")
            last = reads(si)[-1:]
            check(last != [] and last[0][1] == 1 and last[0][0] <= CHUNK,
                  f"{label}: its Enter's read held at most {CHUNK} code bytes (rev 16.20.29; {reads(si)})")
            check(b.wait(lambda: lt.statuses(b)[-1:] == ["connected-secret-service"], 20), f"{label}: the token is stored", b)
        finally:
            si.close()
    return case


CASES = {
    "real-length": paste_case(REAL_LENGTH, "real-length"),
    "short": paste_case("c0de", "short"),
}


def main() -> int:
    return run_main(__doc__, CASES)


if __name__ == "__main__":
    sys.exit(main())
