"""S6b2's auth window, the oracles RoseCat 6457 found missing on 4fd6e44 (chat-drawer plan rev
16.20.33). Outside the gate until the green registers it. Same world as agent_auth_window_test.py:
the fake provider behind ZIGBROWSER_AGENT_AUTH_TEST, the real login helper, the fake CLI.

Every AUTH row is validated against D7b (`parse_auth_row`); a malformed or unknown one fails.

Cases (run alone or with --only):
- rejected-<variant> for wrong-state, missing-state, other-port, http, lookalike (#2): exactly one
  `AUTH blocked <reason>` and exactly one stderr line `zigBrowser: agent auth: callback rejected
  (<reason>)`; no stderr line holds the code or the state; no code reached the fake CLI.
- policies-off and policies-on (#3, S6.3): launched with `--media-source off
  --hardware-acceleration never` (or `on`/`always`), the auth page itself reports `typeof
  MediaSource` as `undefined` (or `function`), and exactly one `AUTH view hw never` (or `always`),
  read back from the auth view's own settings. A window without zb_apply_view_policies fails one
  of the two, whatever WebKit's default is.
- hand-close (#4): closing only the auth window (WM_DELETE_WINDOW) writes no AUTH row and ends
  nothing; the Secrets window's code entry stays; a pasted `<code>#<state>` then finishes the
  sign-in and stores the token.
- subframe (#1; RoseCat 6466): the sign-in page loads the exact callback (this sign-in's state,
  the right code) in an iframe: exactly one `AUTH blocked subframe` and its stderr line; no code
  reaches the fake CLI, nothing is stored, the window stays, the sign-in waits; the code page
  never runs (no beacon) and is requested at most once.
- iframe-then-main (#1): an iframe callback (IFRAME_CODE) first, then the main-frame Authorize
  link (CODE): `AUTH blocked subframe` for the iframe, then `AUTH captured`; the fake CLI gets
  exactly CODE's `<code>#<state>`; no code page ever runs; each callback is requested at most
  once."""

import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_auth_window_test as aw  # noqa: E402
import agent_login_test as lt  # noqa: E402
import agent_secrets_test as sec  # noqa: E402
import fake_provider as fp  # noqa: E402
from agent_common import run_main  # noqa: E402

REASONS = ("state", "origin", "path", "scheme", "code", "replay", "popup", "seam", "subframe", "unexpected", "pending")
AUTH_ROW = [
    (("allowed",), [r"https://[a-z0-9.-]+:443"]),
    (("captured",), []),
    (("blocked",), ["(" + "|".join(REASONS) + ")"]),
    (("view", "hw"), ["(never|always|on-demand)"]),
]


class RowError(AssertionError):
    pass


def parse_auth_row(line: str) -> tuple[str, ...]:
    """One `AUTH\\t...` stdout line -> its fields after AUTH, validated against D7b."""
    parts = line.split("\t")
    if parts[0] != "AUTH":
        raise RowError(f"not an AUTH row: {line!r}")
    fields = tuple(parts[1:])
    for head, rest in AUTH_ROW:
        if fields[:len(head)] == head and len(fields) == len(head) + len(rest) \
                and all(re.fullmatch(p, f) for p, f in zip(rest, fields[len(head):])):
            return fields
    raise RowError(f"AUTH row does not match D7b: {line!r}")


def auth_rows(b) -> list[tuple[str, ...]]:
    return [parse_auth_row(line) for line in list(b.out) if line == "AUTH" or line.startswith("AUTH\t")]


def sign_in_with(binary: Path, tmp: Path, name: str, args: list[str], **kw) -> lt.SignIn:
    """lt.SignIn, launched with more browser flags (SignIn itself takes none)."""
    original = sec.launch
    sec.launch = lambda *a, **k: original(*a, args=args, **k)
    try:
        return lt.SignIn(binary, tmp, name, **kw)
    finally:
        sec.launch = original


class Run(aw.Run):
    def __init__(self, binary: Path, tmp: Path, name: str, variant: str = "ok", args: list[str] = ()):
        import tempfile
        self.tmp = Path(tempfile.mkdtemp(prefix=f"{name}-", dir=tmp))
        self.prov = fp.FakeProvider(self.tmp / "provider", variant=variant)
        self.si = sign_in_with(binary, self.tmp, name, list(args), bus_extra={aw.SEAM: self.prov.seam_value()})
        self.b = self.si.b


def rejected_case(variant: str, reason: str):
    def case(binary: Path, tmp: Path, check) -> None:
        run = Run(binary, tmp, f"rejected-{variant}", variant=variant)
        b, si = run.b, run.si
        try:
            if not run.open(check):
                return
            state = si.state()
            aw.click_centre(b, aw.window(b))
            line = f"zigBrowser: agent auth: callback rejected ({reason})"
            check(b.wait(lambda: ("blocked", reason) in auth_rows(b) and line in b.err, 20),
                  f"AUTH blocked {reason} and {line!r} ({auth_rows(b)})", b)
            time.sleep(1.0)
            rows = auth_rows(b)
            check([r for r in rows if r[0] == "blocked"] == [("blocked", reason)], f"exactly one blocked row ({rows})", b)
            check([l for l in b.err if "agent auth: callback rejected" in l] == [line], f"exactly one {line!r}", b)
            check(not any(fp.CODE in l or (state and state in l) for l in b.err), "no stderr line holds the code or state", b)
            check(si.codes() == [], f"the fake CLI received no code ({si.codes()})")
        finally:
            run.close()
    return case


def policies_case(media: str, hw: str, want_mse: str):
    def case(binary: Path, tmp: Path, check) -> None:
        run = Run(binary, tmp, f"policies-{hw}", args=["--media-source", media, "--hardware-acceleration", hw])
        b = run.b
        try:
            if not run.open(check):
                return
            check(b.wait(lambda: run.prov.reports != [], 20), "the auth page reported", b)
            reports = list(run.prov.reports)
            check(reports != [] and all(r.get("mse") == want_mse for r in reports),
                  f"the auth page sees typeof MediaSource == {want_mse!r} ({reports})")
            views = [r for r in auth_rows(b) if r[:2] == ("view", "hw")]
            check(views == [("view", "hw", hw)], f"exactly one AUTH view hw {hw} ({views})", b)
        finally:
            run.close()
    return case


def close_toplevel(b, title: str) -> None:
    """WM_PROTOCOLS/WM_DELETE_WINDOW to the toplevel titled `title`, as a close button sends it."""
    import ctypes

    class ClientMessage(ctypes.Structure):
        _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                    ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                    ("format", ctypes.c_int), ("data", ctypes.c_long * 5)]

    class Event(ctypes.Union):
        _fields_ = [("xclient", ClientMessage), ("pad", ctypes.c_long * 24)]

    x, dpy = b.x._x, b.x._dpy
    x.XInternAtom.restype = ctypes.c_ulong
    x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
    window = b.x.toplevels(title, 50)[-1][0]
    event = Event()
    event.xclient.type = 33  # ClientMessage
    event.xclient.window = window
    event.xclient.message_type = x.XInternAtom(dpy, b"WM_PROTOCOLS", 0)
    event.xclient.format = 32
    event.xclient.data[0] = x.XInternAtom(dpy, b"WM_DELETE_WINDOW", 0)
    x.XSendEvent(dpy, window, 0, 0, ctypes.byref(event))
    x.XFlush(dpy)


def case_hand_close(binary: Path, tmp: Path, check) -> None:
    run = Run(binary, tmp, "hand-close")
    b, si = run.b, run.si
    try:
        if not run.open(check):
            return
        state = si.state()
        before = len(auth_rows(b))
        close_toplevel(b, aw.TITLE)
        check(b.wait(lambda: aw.window(b) is None, 10), "the auth window is gone", b)
        time.sleep(2.0)
        check(auth_rows(b)[before:] == [], f"closing it wrote no AUTH row ({auth_rows(b)[before:]})", b)
        check(lt.endings(b) == [], f"the sign-in still waits ({lt.login_states(b)})", b)
        check(lt.rect(b, "code") is not None, "the Secrets window's code entry is still there", b)
        check(si.codes() == [], "no code was sent")
        si.paste(f"{fp.CODE}#{state}")
        check(b.wait(lambda: lt.endings(b) == ["done"], 30), f"the pasted code finishes it ({lt.login_states(b)})", b)
        check(si.codes() == [f"{fp.CODE}#{state}"], f"the fake CLI received the pasted code ({si.codes()})")
        check(b.wait(lambda: lt.statuses(b)[-1:] == ["connected-secret-service"], 20), "the token is stored", b)
    finally:
        run.close()


def callback_counts(prov) -> dict[str, int]:
    counts: dict[str, int] = {}
    for path in list(prov.callback_loads):
        counts[path] = counts.get(path, 0) + 1
    return counts


def case_subframe(binary: Path, tmp: Path, check) -> None:
    run = Run(binary, tmp, "subframe", variant="iframe")
    b, si = run.b, run.si
    try:
        if not run.open(check):
            return
        line = "zigBrowser: agent auth: callback rejected (subframe)"
        check(b.wait(lambda: ("blocked", "subframe") in auth_rows(b) and line in b.err, 20),
              f"AUTH blocked subframe and its stderr line ({auth_rows(b)})", b)
        time.sleep(1.5)
        check([r for r in auth_rows(b) if r[0] in ("blocked", "captured")] == [("blocked", "subframe")],
              f"exactly one AUTH blocked subframe, no capture ({auth_rows(b)})", b)
        check([l for l in b.err if "agent auth: callback rejected" in l] == [line], f"exactly one {line!r}", b)
        check(si.codes() == [], f"the fake CLI received no code ({si.codes()})")
        check(aw.window(b) is not None, "the auth window stays", b)
        check(lt.endings(b) == [], f"the sign-in still waits ({lt.login_states(b)})", b)
        check(si.kr.lookup() is None, "nothing is stored")
        check(list(run.prov.callback_beacons) == [], f"the code page never ran ({run.prov.callback_beacons})")
        check(all(n <= 1 for n in callback_counts(run.prov).values()), f"each callback requested at most once ({callback_counts(run.prov)})")
    finally:
        run.close()


def case_iframe_then_main(binary: Path, tmp: Path, check) -> None:
    run = Run(binary, tmp, "iframe-then-main", variant="iframe-then-main")
    b, si = run.b, run.si
    try:
        if not run.open(check):
            return
        state = si.state()
        check(b.wait(lambda: ("blocked", "subframe") in auth_rows(b), 20), f"the iframe's callback: AUTH blocked subframe ({auth_rows(b)})", b)
        aw.click_centre(b, aw.window(b))
        check(b.wait(lambda: ("captured",) in auth_rows(b), 20), f"then AUTH captured ({auth_rows(b)})", b)
        check(b.wait(lambda: lt.endings(b) == ["done"], 30), f"the sign-in ends done ({lt.login_states(b)})", b)
        check(si.codes() == [f"{fp.CODE}#{state}"], f"the fake CLI received exactly the main frame's code ({si.codes()})")
        check(list(run.prov.callback_beacons) == [], f"no code page ever ran ({run.prov.callback_beacons})")
        check(all(n <= 1 for n in callback_counts(run.prov).values()), f"each callback requested at most once ({callback_counts(run.prov)})")
        rows = auth_rows(b)
        check(rows.count(("captured",)) == 1 and rows.count(("blocked", "subframe")) == 1, f"one of each ({rows})", b)
    finally:
        run.close()


CASES = {
    "rejected-wrong-state": rejected_case("wrong-state", "state"),
    "rejected-missing-state": rejected_case("missing-state", "state"),
    "rejected-other-port": rejected_case("other-port", "origin"),
    "rejected-http": rejected_case("http", "scheme"),
    "rejected-lookalike": rejected_case("lookalike", "origin"),
    "policies-off": policies_case("off", "never", "undefined"),
    "policies-on": policies_case("on", "always", "function"),
    "hand-close": case_hand_close,
    "subframe": case_subframe,
    "iframe-then-main": case_iframe_then_main,
}


def main() -> int:
    return run_main(__doc__, CASES)


if __name__ == "__main__":
    sys.exit(main())
