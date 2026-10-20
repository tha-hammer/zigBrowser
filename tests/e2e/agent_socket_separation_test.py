#!/usr/bin/env python3
"""S7b, S7.1 (chat-drawer plan section 10, S7, rev 16.20.34): the automation core runs for
the drawer without the socket.

- drawer-only: with `--agent-drawer on` and no `--automation-api`, no socket file and no
  token sidecar ever exist, and the agent's get_text still reads the page (the core runs
  in process);
- both-flags: with both flags the socket behaves as before (its token sidecar is 0600,
  page.url answers through it), and the agent's get_text works too.

The real binary, helper and CLI against the TLS fake Messages API, as agent_tools_test.py,
in a network namespace of its own (re-exec'd as --sealed-child).
Exit 1 when Xvfb, xauth, bwrap, the venv or the binary is missing."""

from __future__ import annotations

import stat
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_host_lifecycle_test as life  # noqa: E402
import agent_tools_test as tools  # noqa: E402 - its page, responder and readers

CALL = {"read-greeting": {"name": "mcp__zigbrowser__get_text", "input": {"selector": "css=#greeting"}}}


def loaded(b) -> bool:
    """The page's title row (NAV <url> <title>) on stdout: no socket needed."""
    return any(line.startswith("NAV\t") and line.endswith("\ttools") for line in list(b.out))


def case_drawer_only(binary: Path, tmp: Path, check) -> None:
    b, fake = tools.start(binary, tmp, "drawer-only", CALL, automation=False)
    sidecar = Path(str(b.socket) + ".token")
    seen = []
    try:
        if not check(b.wait(lambda: loaded(b) and b.rows("icon", 1) != [], 30), "the page loaded and the drawer is up", b):
            return
        block = None
        life.send(b, "read-greeting")
        deadline = time.monotonic() + 150
        while time.monotonic() < deadline and block is None:
            seen.append(b.socket.exists() or sidecar.exists())
            for entry in fake.api.messages_requests():
                found = tools.tool_results(entry)
                if found:
                    block = found[0]
            time.sleep(0.1)
        if not check(block is not None, "a tool_result reached the API", b):
            return
        text = tools.result_text(block)
        check(not block.get("is_error") and "Hello from page 1" in text, f"get_text read the page without the socket ({text[:120]!r})")
        check(not any(seen) and not b.socket.exists() and not sidecar.exists(),
              f"no socket file or token sidecar existed ({b.socket.exists()}, {sidecar.exists()}, {sum(seen)} of {len(seen)} looks)")
    finally:
        tools.finish(b, fake)


def case_both_flags(binary: Path, tmp: Path, check) -> None:
    b, fake = tools.start(binary, tmp, "both-flags", CALL, automation=True)
    sidecar = Path(str(b.socket) + ".token")
    try:
        if not check(b.wait_page(), "the page loaded (through the socket)", b):
            return
        check(sidecar.exists() and stat.S_IMODE(sidecar.stat().st_mode) == 0o600, "the token sidecar exists, 0600")
        url = (b.zb.call("page.url", {"window_id": "window-1"}) or {}).get("url", "")
        check(url.endswith("tools-page.html"), f"page.url answers through the socket ({url})")
        block = tools.ask(b, check, fake, "read-greeting")
        if block is not None:
            text = tools.result_text(block)
            check(not block.get("is_error") and "Hello from page 1" in text, f"get_text reads the page with both flags ({text[:120]!r})")
    finally:
        tools.finish(b, fake)


CASES = {"drawer-only": case_drawer_only, "both-flags": case_both_flags}


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
            if str(d).startswith("/tmp/zbl-"):
                subprocess.run(["find", str(d), "-delete"], check=False)


if __name__ == "__main__":
    raise SystemExit(main())
