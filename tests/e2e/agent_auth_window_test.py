"""S6b2 (chat-drawer plan rev 16.18.16 to 16.18.20): the auth window, end to end, on the fake provider
(tests/e2e/fake_provider.py), reached only through ZIGBROWSER_AGENT_AUTH_TEST.

The browser runs the real login helper with the fake setup-token CLI, as agent_login_test.py does.
On the helper's `auth_url` a window titled "Sign in to Claude" opens on it; every main-frame
navigation goes through agent_auth.decideNavigation:
- allow: it loads (`AUTH allowed https://<host>:443`);
- capture: it does not load (`AUTH captured`), the code goes to the helper, the window closes;
- block: it does not load (`AUTH blocked <reason>`), the window stays;
- a popup is refused (`AUTH blocked popup`).
The fake page's one action fills it, so the test clicks the window's centre with X input.

Cases (run alone or with --only):
- capture: `AUTH captured`; the code page is requested at most once and never runs (rev
  16.20.33: captured at its main-frame response); the fake CLI received exactly
  `<code>#<state>`; the token is stored; the window is gone.
- wrong-state, missing-state (state), other-port (origin), http (scheme), lookalike (origin):
  five of section 9's A2 cases (the sixth, a replay, is a unit case: rev 16.18.19). Each writes
  its `AUTH blocked` row; the fake CLI received no code; nothing is stored; the window stays.
- popup: `AUTH blocked popup`; no second toplevel appears.
- isolation (S6.3, rev 16.18.20): a profile canary cookie for https://claude.com, planted
  through the automation API before Sign in, is not seen by the auth page, which does see the
  provider's own `zbprovider=1`; the profile still holds the canary and never gains
  `zbprovider`; the page has no zbHost; the window is not in page.list.
- seam-refused: a malformed ZIGBROWSER_AGENT_AUTH_TEST opens no window and writes
  `AUTH blocked seam` and `zigBrowser: ZIGBROWSER_AGENT_AUTH_TEST refused (shape)`.
- seam-ignored: without --e2e-protocol, in a network namespace with no network (S6.1's
  harness, rev 16.18.20), the seam is ignored with its one line and the fake proxy is never
  contacted."""

import os
import secrets
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_secrets_test as sec  # noqa: E402
import agent_login_test as lt  # noqa: E402
import fake_provider as fp  # noqa: E402
from agent_common import run_main  # noqa: E402

TITLE = "Sign in to Claude"
SEAM = "ZIGBROWSER_AGENT_AUTH_TEST"


def auth_rows(b) -> list[tuple[str, ...]]:
    return [tuple(line.split("\t")[1:]) for line in list(b.out) if line.startswith("AUTH\t")]


def window(b):
    tops = b.x.toplevels(TITLE, 50)
    return tops[0] if len(tops) == 1 else None


def click_centre(b, top) -> None:
    _, x, y, w, h = top
    b.x.click(x + w // 2, y + h // 2)


class Run:
    """A sign-in with the fake provider behind the seam; the auth window open on its page."""

    def __init__(self, binary: Path, tmp: Path, name: str, variant: str = "ok", seam: str | None = None):
        self.tmp = Path(tempfile.mkdtemp(prefix=f"{name}-", dir=tmp))
        self.prov = fp.FakeProvider(self.tmp / "provider", variant=variant)
        self.si = lt.SignIn(binary, self.tmp, name, bus_extra={SEAM: seam if seam is not None else self.prov.seam_value()})
        self.b = self.si.b

    def open(self, check) -> bool:
        b = self.b
        if not self.si.open_and_sign_in(check):
            return False
        if not check(b.wait(lambda: window(b) is not None, 20), f'the "{TITLE}" window opens', b):
            return False
        check(b.wait(lambda: ("allowed", "https://claude.com:443") in auth_rows(b), 20),
              f"AUTH allowed https://claude.com:443 ({auth_rows(b)})", b)
        return check(b.wait(lambda: any(r["path"] == "/cai/oauth/authorize" for r in self.prov.requests), 20)
                     and b.wait(lambda: self.prov.reports != [], 20),
                     "the sign-in page loaded through the seam's proxy and ran", b)

    def close(self) -> None:
        try:
            self.si.close()
        finally:
            self.prov.close()


def case_capture(binary: Path, tmp: Path, check) -> None:
    run = Run(binary, tmp, "auth-capture")
    b, si = run.b, run.si
    try:
        if not run.open(check):
            return
        state = si.state()
        click_centre(b, window(b))
        check(b.wait(lambda: ("captured",) in auth_rows(b), 20), f"AUTH captured ({auth_rows(b)})", b)
        check(b.wait(lambda: lt.endings(b) == ["done"], 30), f"the sign-in ends done ({lt.login_states(b)})", b)
        check(si.codes() == [f"{fp.CODE}#{state}"], f"the fake CLI received exactly the code ({si.codes()})")
        # Rev 16.20.33: captured at its main-frame response, so requested at most once, but
        # never committed, rendered or run (RoseCat 6466).
        check(len(run.prov.callback_loads) <= 1 and run.prov.callback_beacons == [],
              f"the code page was requested at most once and never ran ({run.prov.callback_loads}, {run.prov.callback_beacons})")
        check(b.wait(lambda: lt.statuses(b)[-1:] == ["connected-secret-service"], 20), "the token is stored", b)
        check(b.wait(lambda: window(b) is None, 10), "the auth window is gone", b)
    finally:
        run.close()


def blocked_case(variant: str, reason: str):
    def case(binary: Path, tmp: Path, check) -> None:
        run = Run(binary, tmp, f"auth-{variant}", variant=variant)
        b, si = run.b, run.si
        try:
            if not run.open(check):
                return
            click_centre(b, window(b))
            check(b.wait(lambda: ("blocked", reason) in auth_rows(b), 20), f"AUTH blocked {reason} ({auth_rows(b)})", b)
            time.sleep(1.0)
            check(si.codes() == [], f"the fake CLI received no code ({si.codes()})")
            check(run.prov.callback_loads == [], "nothing was loaded from the callback")
            check(window(b) is not None, "the auth window stays", b)
            check(lt.endings(b) == [], f"the sign-in still waits ({lt.login_states(b)})", b)
            check(si.kr.lookup() is None, "nothing is stored")
        finally:
            run.close()
    return case


def case_popup(binary: Path, tmp: Path, check) -> None:
    run = Run(binary, tmp, "auth-popup", variant="popup")
    b = run.b
    try:
        if not run.open(check):
            return
        click_centre(b, window(b))
        check(b.wait(lambda: ("blocked", "popup") in auth_rows(b), 20), f"AUTH blocked popup ({auth_rows(b)})", b)
        time.sleep(1.0)
        check(len(b.x.toplevels(TITLE, 50)) == 1, "still exactly one auth window", b)
        check(not any(r["host"] == "claude.ai" for r in run.prov.requests) and "claude.ai:443" not in run.prov.connects,
              "the popup's target was never contacted")
    finally:
        run.close()


def case_isolation(binary: Path, tmp: Path, check) -> None:
    run = Run(binary, tmp, "auth-isolation")
    b = run.b
    canary = "zbprofile" + secrets.token_hex(12)
    try:
        check(b.wait_page(), "the browser's page is ready", b)
        b.zb.call("cookies.set", {"name": "zbprofile", "value": canary, "domain": "claude.com", "path": "/",
                                  "secure": True})
        before = b.zb.call("cookies.getAll", {"url": "https://claude.com/"})["cookies"]
        if not check(any(c["name"] == "zbprofile" and c["value"] == canary for c in before),
                     "the profile canary is planted", b):
            return
        if not run.open(check):
            return
        reports = list(run.prov.reports)
        check(reports != [] and all("zbprovider=1" in r["cookie"] for r in reports),
              f"the auth page sees its own zbprovider=1 (the positive control): {reports}")
        check(all(canary not in r["cookie"] and "zbprofile" not in r["cookie"] for r in reports),
              f"the auth page never sees the profile canary: {reports}")
        check(all(r["zbhost"] == "0" for r in reports), f"the auth page has no zbHost: {reports}")
        check(len(b.zb.page.list()["pages"]) == 1, "the auth window is not in page.list", b)
        after = b.zb.call("cookies.getAll", {"url": "https://claude.com/"})["cookies"]
        check(any(c["name"] == "zbprofile" and c["value"] == canary for c in after), "the profile still holds the canary", b)
        check(not any(c["name"] == "zbprovider" for c in after), f"the profile never gains zbprovider ({[c['name'] for c in after]})", b)
    finally:
        run.close()


def case_seam_refused(binary: Path, tmp: Path, check) -> None:
    run = Run(binary, tmp, "auth-seam-refused", seam="garbage")
    b = run.b
    try:
        if not run.si.open_and_sign_in(check):
            return
        line = f"zigBrowser: {SEAM} refused (shape)"
        check(b.wait(lambda: ("blocked", "seam") in auth_rows(b), 20), f"AUTH blocked seam ({auth_rows(b)})", b)
        check(b.wait(lambda: line in b.err, 5) and [l for l in b.err if l == line] == [line], f"one line: {line}", b)
        time.sleep(2.0)
        check(window(b) is None, "no auth window opened", b)
        check(run.prov.connects == [], f"the provider was never contacted ({run.prov.connects})")
    finally:
        run.close()


def case_seam_ignored(binary: Path, tmp: Path, check) -> None:
    """Without --e2e-protocol, in a network namespace with no network (S6.1's harness)."""
    from agent_common import Browser
    from agent_host_lifecycle_test import icon_centre
    from slice2_common import isolate_profile_env
    world = sec.provisioned(binary, tmp, "seam-ignored")
    with fp.FakeProvider(Path(tempfile.mkdtemp(prefix="provider-", dir=tmp))) as prov, sec.PrivateKeyring(tmp) as kr:
        env = isolate_profile_env(dict(os.environ))
        env.update(world.env({SEAM: prov.seam_value()}))
        env.update(kr.bus_env)
        sec.assert_not_user_bus(env)
        b = Browser(binary, tmp, "seam-ignored", ["--agent-drawer", "on"], env=env, e2e=False,
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
            line = f"zigBrowser: {SEAM} ignored without --e2e-protocol"
            check(b.wait(lambda: line in b.err, 30) and [l for l in b.err if l == line] == [line], f"one line: {line}", b)
            time.sleep(5)
            check(prov.connects == [] and prov.requests == [], "the fake provider was never contacted")
        finally:
            b.stop()


CASES = {
    "capture": case_capture,
    "wrong-state": blocked_case("wrong-state", "state"),
    "missing-state": blocked_case("missing-state", "state"),
    "other-port": blocked_case("other-port", "origin"),
    "http": blocked_case("http", "scheme"),
    "lookalike": blocked_case("lookalike", "origin"),
    "popup": case_popup,
    "isolation": case_isolation,
    "seam-refused": case_seam_refused,
    "seam-ignored": case_seam_ignored,
}


def main() -> int:
    return run_main(__doc__, CASES)


if __name__ == "__main__":
    sys.exit(main())
