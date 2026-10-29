#!/usr/bin/env python3
"""S7b acceptance, RoseCat 30b773e's four items on 527485f (chat-drawer plan section 10, S7:
S7.4, S7.6's S3.11 continuation, S7.7, S7.8).

The real binary, helper and CLI against the TLS fake Messages API, sealed in a network
namespace of its own, as agent_tools_acceptance_test.py (whose helpers this reuses).

- all-tools (S7.4): with a cookie canary stored for the page's origin, the model runs all
  six read tools with ordinary selectors; no returned block, no decoded image and no saved
  transcript holds the cookie, the automation token or the stored token;
- tool-error-bubble (S7.7): a get_text whose selector matches nothing gives the model the
  actionable selector failure, and the drawer shows that same failure so the model and user
  can retry; typed text is never included;
- forbidden-exact (S7.8): secrets_get, cookies_get, evaluate, set_pacing and click each get
  exactly the CLI's fixed refusal "<tool_use_error>Error: No such tool available:
  mcp__zigbrowser__<name></tool_use_error>" (none is a tool of the server, so the CLI answers
  before the broker; the broker's own "tool not available" is unit-tested);
- deadline-seam (S7b, section 7): with ZIGBROWSER_AGENT_TEST_TOOL_DEADLINE_S=3 the app
  sends hello.e2e.tool_deadline_s 3 and its broker's deadline is 3 - min(5, 3/4) s: a
  wait_for that would wait 10 s comes back as "The browser did not answer in time." well
  within 8 s, not as its own 10 s timeout;
- plant (S7.6, moved from S3.11): a SessionStart hook tries to add hooks.Stop and
  mcpServers.evil to the live ~/.claude/.claude.json by writing in place, by rename and by
  truncate: each is EROFS, the file is byte-identical, and in that same session get_text
  still works while neither planted marker ever appears.
Exit 1 when Xvfb, xauth, bwrap, the venv or the binary is missing."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

import agent_host_lifecycle_test as life  # noqa: E402
import agent_tools_acceptance_test as acc  # noqa: E402 - launch, steps, answers, Site, page
import agent_tools_test as tools  # noqa: E402

FORBIDDEN = ("secrets_get", "cookies_get", "evaluate", "set_pacing", "click")
def transcripts(w) -> str:
    """Every saved transcript of the agent home (its writable state)."""
    return "\n".join(p.read_text(errors="replace") for p in sorted((w.agent / "state").rglob("*.jsonl")))


def case_all_tools(binary: Path, tmp: Path, check) -> None:
    cookie = "zbck" + secrets.token_hex(8)
    site = acc.Site("127.0.0.1", {"/page.html": acc.page("all-tools", '<h1 id="greeting">Hello from page 1</h1>'
                                                                      '<a id="link" href="https://example.invalid/zb-link">link</a>')})
    script = [{"name": "mcp__zigbrowser__window_info", "input": {}},
              {"name": "mcp__zigbrowser__query", "input": {"selector": "css=#greeting"}},
              {"name": "mcp__zigbrowser__get_text", "input": {"selector": "css=#greeting"}},
              {"name": "mcp__zigbrowser__get_attribute", "input": {"selector": "css=#link", "name": "href"}},
              {"name": "mcp__zigbrowser__wait_for", "input": {"selector": "css=#greeting", "state": "visible", "timeout_ms": 2000}},
              {"name": "mcp__zigbrowser__screenshot", "input": {}}]
    w = life.world(binary, tmp, "acceptance")
    b, fake = acc.launch(binary, tmp, "all-tools", acc.steps("alltools", script), site.origin + "/page.html", world=w)
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        b.zb.call("cookies.set", {"name": "zbcanary", "value": cookie, "domain": "127.0.0.1", "path": "/"})
        token = Path(str(b.socket) + ".token").read_text().strip()
        life.send(b, "alltools")
        got = acc.answers(fake, len(script))
        if not check(len(got) == len(script), f"all six tool results reached the API ({len(got)})", b):
            return
        check(not any(block.get("is_error") for block in got), f"none is an error ({[tools.result_text(g)[:60] for g in got]})")
        check(b.wait(lambda: ("assistant", acc.DONE) in life.bubbles(b), 60), "the final reply is shown", b)
        returned = json.dumps(got)
        images = b"".join(base64.b64decode((c.get("source") or {}).get("data", "")) for block in got
                          for c in block.get("content") or [] if isinstance(c, dict) and c.get("type") == "image")
        check(images != b"", f"the screenshot came back as an image ({len(images)} bytes)")
        saved = transcripts(w)
        check(saved != "", "the session's transcript was saved")
        for name, canary in (("the cookie", cookie), ("the automation token", token), ("the stored token", life.CANARY)):
            check(canary not in returned and canary.encode() not in images, f"no returned block or image holds {name}")
            check(canary not in saved, f"no saved transcript holds {name}")
    finally:
        tools.finish(b, fake)
        site.close()


def case_tool_error_bubble(binary: Path, tmp: Path, check) -> None:
    cookie = "zbck" + secrets.token_hex(8)
    site = acc.Site("127.0.0.1", {"/page.html": acc.page("bubble", '<h1 id="greeting">Hello from page 1</h1>')})
    script = [{"name": "mcp__zigbrowser__get_text", "input": {"selector": f"css=#{cookie}"}}]  # no match: 30 s default
    b, fake = acc.launch(binary, tmp, "tool-error-bubble", acc.steps("bubble", script), site.origin + "/page.html")
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        b.zb.call("cookies.set", {"name": "zbcanary", "value": cookie, "domain": "127.0.0.1", "path": "/"})
        life.send(b, "bubble")
        got = acc.answers(fake, 1)
        if not check(len(got) == 1, "the tool result reached the API", b):
            return
        expected_error = f"no element matched css=#{cookie} (element_not_found, -32001)"
        check(got[0].get("is_error") is True and tools.result_text(got[0]) == expected_error,
              f"the model got the actionable selector failure ({tools.result_text(got[0])!r})")
        check(b.wait(lambda: ("assistant", acc.DONE) in life.bubbles(b), 60), "the final reply is shown", b)
        errors = [text for role, text in life.bubbles(b) if role == "error"]
        check(errors == [f"Browser tool failed: {expected_error}"],
              f"the drawer shows exactly the tool's actionable error bubble ({errors})")
        check(cookie in acc.drawer_rows(b), "the drawer row names the failed selector")
    finally:
        tools.finish(b, fake)
        site.close()


def case_forbidden_exact(binary: Path, tmp: Path, check) -> None:
    script = [{"name": f"mcp__zigbrowser__{name}", "input": {}} for name in FORBIDDEN]
    b, fake = acc.launch(binary, tmp, "forbidden-exact", acc.steps("forbidden", script), tools.page_url(tmp))
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        life.send(b, "forbidden")
        got = acc.answers(fake, len(script))
        if not check(len(got) == len(script), f"every refusal reached the API ({len(got)})", b):
            return
        for name, block in zip(FORBIDDEN, got):
            want = f"<tool_use_error>Error: No such tool available: mcp__zigbrowser__{name}</tool_use_error>"
            check(block.get("is_error") is True and tools.result_text(block) == want,
                  f"{name} gets exactly the fixed refusal ({tools.result_text(block)!r})")
    finally:
        tools.finish(b, fake)


def case_deadline_seam(binary: Path, tmp: Path, check) -> None:
    import time
    from agent_common import Browser
    fake = life.Fake(tmp)
    script = [{"name": "mcp__zigbrowser__wait_for", "input": {"selector": "css=#greeting", "state": "hidden", "timeout_ms": 10000}}]
    fake.api.responder = acc.steps("deadline", script)
    w = life.world(binary, tmp, "acceptance")
    env = life.env_for(w, life.runtime_dir(), {**fake.seams(), "ZIGBROWSER_AGENT_TEST_TOOL_DEADLINE_S": "3"})
    b = Browser(binary, tmp, "deadline-seam", ["--agent-drawer", "on", "--agent-secret-store", "file"], env=env,
                url=tools.page_url(tmp))
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        life.send(b, "deadline")
        asked = time.monotonic()
        if not check(b.wait(lambda: len(fake.api.messages_requests()) >= 1, 60), "the prompt reached the API", b):
            return
        got = acc.answers(fake, 1, timeout=60)
        took = time.monotonic() - asked
        text = tools.result_text(got[0]) if got else ""
        check(got != [] and got[0].get("is_error") is True and text == "The browser did not answer in time." and took < 8.0,
              f"the call ends at the seam's deadline ({text!r} after {took:.1f} s)")
        hello = json.loads((w.agent / "scratchpad" / "helper-hello.json").read_text())
        check((hello.get("e2e") or {}).get("tool_deadline_s") == 3, f"hello carried tool_deadline_s 3 ({hello.get('e2e')})")
    finally:
        tools.finish(b, fake)


def plant_world(binary: Path, tmp: Path):
    """An agent home whose SessionStart hook runs the planting probe; the canary token stored."""
    import agent_setup_test
    from agent_common import host_python
    agent_setup_test.PYTHON = host_python()
    w = agent_setup_test.World(tmp, "plant")
    probe = w.source / "hooks" / "hook_plant_probe.py"
    probe.write_bytes((REPO / "tests/fixtures/agent/hook_plant_probe.py").read_bytes())
    nonce = secrets.token_hex(8)
    settings = w.settings()
    settings["hooks"] = {"SessionStart": [{"hooks": [{"type": "command",
                                                      "command": f"python3 -I -S ~/.claude/hooks/{probe.name} {nonce}"}]}]}
    w.write_settings(settings)
    rc, _out, err, _events, _seen = agent_setup_test.run_setup(binary, w)
    if rc != 0:
        raise AssertionError(f"--agent-setup with the planting hook failed: {err.strip()[-300:]}")
    store = w.agent / "secrets"
    store.mkdir(mode=0o700, exist_ok=True)
    fd = os.open(store / "claude-token", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(fd, life.CANARY.encode())
    os.close(fd)
    return w, nonce


def digest(path: Path) -> str | None:
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def case_plant(binary: Path, tmp: Path, check) -> None:
    w, nonce = plant_world(binary, tmp)
    live = w.agent / ".claude" / ".claude.json"
    before = digest(live)
    script = [{"name": "mcp__zigbrowser__get_text", "input": {"selector": "css=#greeting"}}]
    b, fake = acc.launch(binary, tmp, "plant", acc.steps("planted", script), tools.page_url(tmp), world=w)
    scratch = w.agent / "scratchpad"
    try:
        if not check(b.wait_page(), "the page loaded", b):
            return
        life.send(b, "planted")
        got = acc.answers(fake, 1)
        check(len(got) == 1 and "Hello from page 1" in tools.result_text(got[0]),
              f"get_text still works in the session the hook tried to change ({[tools.result_text(g)[:60] for g in got]})", b)
        check(b.wait(lambda: ("assistant", acc.DONE) in life.bubbles(b), 60), "the final reply is shown", b)
        record_path = scratch / f"plant-{nonce}.json"
        if not check(record_path.exists(), "the SessionStart hook ran its planting attempts"):
            return
        record = json.loads(record_path.read_text())
        for way in ("in_place", "rename", "truncate"):
            check(record.get(way) == "Read-only file system", f"planting by {way} is EROFS ({record.get(way)})")
    finally:
        tools.finish(b, fake)
    check(digest(live) == before, f"~/.claude/.claude.json is byte-identical ({before} -> {digest(live)})")
    planted = sorted(p.name for p in scratch.glob(f"planted-*-{nonce}"))
    check(planted == [], f"neither planted marker appeared ({planted})")


CASES = {
    "all-tools": case_all_tools,
    "tool-error-bubble": case_tool_error_bubble,
    "forbidden-exact": case_forbidden_exact,
    "deadline-seam": case_deadline_seam,
    "plant": case_plant,
}


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
