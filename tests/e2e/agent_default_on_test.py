#!/usr/bin/env python3
"""S5b, the drawer is on by default (chat-drawer plan S5.5, user answer 1; rev 16.19):
- default-on: with no --agent-drawer flag and no ZIGBROWSER_AGENT_DRAWER, every window
  gets the drawer icon (`DRAWER <win> icon <rect>`), the popup too;
- off-still-off: `--agent-drawer off`, or the variable `off` with no flag, gives no
  drawer row at all, and the page still loads;
- not-set-up: without an installed runtime, the drawer tries setup, shows a
  retryable failure with `DRAWER status unavailable runtime-missing`, and leaves
  no helper running;
- helper-check: the shared teardown `slice2_common.stop_browser` fails a test in which an
  agent helper ran (an e2e that never presses Send must start none), so every existing
  e2e checks it with the icon now present; agent tests opt out through
  agent_common.Browser.stop.

The real binary runs on its own Xvfb (xsession.py) in a network namespace of its own
(re-exec'd as --sealed-child); helper-check uses the scripted fake_host.py in the
helper's place. Exit 1 when Xvfb, xauth, bwrap, the venv or the binary is missing."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_host_lifecycle_test as life  # noqa: E402 - its world, seams and process table
import slice2_common  # noqa: E402 - the shared teardown under test

RUNTIME_TEXT = "Claude Agent setup failed. Reopen the drawer or send again to retry."
OLD_TEXT = "Agent not available yet"


def plain_env(tmp: Path, extra: dict[str, str] | None = None) -> dict[str, str]:
    """No agent home and no drawer switch: a fresh XDG_DATA_HOME and HOME."""
    env = slice2_common.isolate_profile_env(dict(os.environ))
    for name in [n for n in env if n.startswith("ZIGBROWSER_AGENT_")]:
        env.pop(name)
    env["HOME"] = tempfile.mkdtemp(prefix="home-", dir=tmp)
    env["XDG_RUNTIME_DIR"] = str(life.runtime_dir())
    env.update(extra or {})
    return env


def browser(binary: Path, tmp: Path, label: str, args: list[str], env: dict[str, str],
            switch: dict[str, str] | None = None):
    """`switch` goes in after Browser drops any inherited ZIGBROWSER_AGENT_DRAWER."""
    from agent_common import Browser
    return Browser(binary, tmp, label, args, env=env, env_extra=switch)


def case_default_on(binary: Path, tmp: Path, check) -> None:
    b = browser(binary, tmp, "default-on", [], plain_env(tmp))
    try:
        check(b.wait(lambda: b.rows("icon", 1) != [], 20), "no flag and no variable: window 1 has the drawer icon", b)
        if check(b.wait_page(), "the page loaded", b):
            check(b.open_popup() and b.wait(lambda: b.rows("icon", 2) != [], 20), "the popup has its icon too", b)
    finally:
        b.stop()


def case_off_still_off(binary: Path, tmp: Path, check) -> None:
    for label, args, extra in (("flag-off", ["--agent-drawer", "off"], {}),
                               ("env-off", [], {"ZIGBROWSER_AGENT_DRAWER": "off"})):
        b = browser(binary, tmp, label, args, plain_env(tmp), extra)
        try:
            check(b.wait_page(), f"{label}: the page loaded", b)
            time.sleep(2.0)
            check(b.rows() == [], f"{label}: no drawer row at all ({[r.fields for r in b.rows()][:3]})", b)
        finally:
            b.stop()


def case_not_set_up(binary: Path, tmp: Path, check) -> None:
    # The flag is given so this case checks the sentence alone; default-on checks the default.
    b = browser(binary, tmp, "not-set-up", ["--agent-drawer", "on"], plain_env(tmp))
    try:
        if not check(b.wait(lambda: b.rows("icon", 1) != [], 20), "the drawer's icon", b):
            return
        time.sleep(1.0)
        before = set(life.descendants(b.proc.pid))
        life.send(b, "hi")
        check(b.wait(lambda: ("system", RUNTIME_TEXT) in life.bubbles(b), 10),
              f"Send reports a retryable setup failure ({life.bubbles(b)})", b)
        check(("unavailable", "runtime-missing") in life.statuses(b), f"status unavailable runtime-missing ({life.statuses(b)})")
        check(("user", "hi") in life.bubbles(b) and ("system", OLD_TEXT) not in life.bubbles(b),
              f"the user bubble, and not the S1 text ({life.bubbles(b)})")
        time.sleep(1.0)
        check(life.new_children(b, before) == [], f"nothing starts ({life.new_children(b, before)})")
    finally:
        life.release_x(b)
        b.stop()


def case_helper_check(binary: Path, tmp: Path, check) -> None:
    w = life.world(binary, tmp, "helpercheck")
    scratch = w.agent / "scratchpad"
    for name in ("fake-host-runs", "fake-host-frames.jsonl"):
        (scratch / name).unlink(missing_ok=True)
    reply = {"frame": {"type": "assistant_message", "session": "$SESSION", "text": "zb-helper-check-reply"}}
    (scratch / "fake-host-script.json").write_text(json.dumps({"runs": [{"on_prompt": [reply]}]}))
    b = life.launch(binary, tmp, "helper-check",
                    life.env_for(w, life.runtime_dir(), {"ZIGBROWSER_AGENT_HOST_CMD": str(life.FAKE_HOST_SCRIPT)}))
    try:
        life.send(b, "hi")
        if not check(b.wait(lambda: ("assistant", "zb-helper-check-reply") in life.bubbles(b), 30),
                     "a helper runs and answers", b):
            return
        life.release_x(b)
        try:
            slice2_common.stop_browser(b.proc)
            raised = None
        except AssertionError as exc:
            raised = str(exc)
        check(raised is not None and "agent helper" in raised,
              f"stop_browser fails the test: an agent helper ran ({raised!r})")
        check(b.proc.poll() is not None, "and the browser is stopped all the same")
    finally:
        b.stop()


CASES = {"default-on": case_default_on, "off-still-off": case_off_still_off,
         "not-set-up": case_not_set_up, "helper-check": case_helper_check}


def main() -> int:
    if "--sealed-child" not in sys.argv:
        done = subprocess.run(["/usr/bin/bwrap", "--unshare-net", "--die-with-parent", "--dev-bind", "/", "/",
                               "--proc", "/proc", "--", sys.executable, str(Path(__file__).resolve()),
                               "--sealed-child", *sys.argv[1:]])
        return done.returncode
    sys.argv.remove("--sealed-child")
    from agent_common import run_main
    try:
        return run_main(__doc__, CASES)
    finally:
        for d in life.RUNTIME_DIRS:
            subprocess.run(["find", str(d), "-delete"], check=False)


if __name__ == "__main__":
    raise SystemExit(main())
