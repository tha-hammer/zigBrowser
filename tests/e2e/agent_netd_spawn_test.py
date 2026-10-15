#!/usr/bin/env python3
"""Chat drawer S3n2, native spawn wiring (plan rev 16.2 §3c.2, §3c.4; BlueBeaver
5575, BlackRobin 5577): the browser starts netd, handles its failures, and
stops it.

Until S3b spawns the helper, the agent starts on the drawer's first Send,
and only when the agent home is provisioned (its `current` build exists;
otherwise Send says "Agent not available yet" as before and nothing starts):
- the browser starts `<venv python> -I -S <agent-host>/zb_agent_host/netd.py
  --sockdir $XDG_RUNTIME_DIR/zigbrowser-agent-<browser pid>-<16 hex> --bwrap
  /usr/bin/bwrap` plus, with --e2e-protocol only, the pairs of
  ZIGBROWSER_AGENT_NET_TEST, with an environment it builds (no ZIGBROWSER_*);
- it waits for `netd ready` (at most 5 s) and writes the row
  `AGENTNET ready <dir>`; netd made the directory 0700 with egress/ and
  bridges/;
- a refused seam, a missing XDG_RUNTIME_DIR, or a netd that exits or never gets
  ready gives one stderr line, the row `AGENTNET unavailable <reason>`, and the
  drawer bubble "Agent network unavailable"; netd is never started again in
  this browser, and every later Send shows the same bubble;
- at quit the browser closes netd's stdin and waits for it: no netd process
  and no socket directory remain.

Each case gets a private, short XDG_RUNTIME_DIR (0700, under /tmp: sun_path)
and private decoy ports; nothing touches the real voice server, DISPLAY :0,
the live socket or the live profile. Exit 1 when Xvfb, xauth or the binary is
missing."""

from __future__ import annotations

import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))

UNAVAILABLE = "Agent network unavailable"
NETD_SCRIPT = "zb_agent_host/netd.py"


RUNTIME_DIRS: list[Path] = []


def runtime_dir(tmp: Path) -> Path:
    """A private XDG_RUNTIME_DIR, short enough for sun_path (0700, ours). main() removes
    every one at the end, whatever a case left in it."""
    d = Path(tempfile.mkdtemp(prefix="zbr-", dir="/tmp"))
    os.chmod(d, 0o700)
    RUNTIME_DIRS.append(d)
    return d


WORLDS: dict[str, object] = {}


def provisioned_world(binary: Path, tmp: Path):
    """One agent home provisioned by the real --agent-setup (S3a), shared by the cases."""
    if "world" not in WORLDS:
        import agent_setup_test
        from agent_common import host_python
        agent_setup_test.PYTHON = host_python()  # World.env reads it (set by that file's main)
        world = agent_setup_test.World(tmp, "netd")
        rc, _out, err, _events, _seen = agent_setup_test.run_setup(binary, world)
        if rc != 0:
            raise AssertionError(f"--agent-setup failed: {err.strip()[-300:]}")
        WORLDS["world"] = world
    return WORLDS["world"]


def env_for(world, rt: Path | None, extra: dict[str, str] | None = None) -> dict[str, str]:
    """The world's HOME, XDG_DATA_HOME and helper runtime (a provisioned agent home, or None
    for a fresh, unprovisioned one), a private XDG_RUNTIME_DIR, and `extra`."""
    import agent_setup_test
    from agent_common import host_python
    from slice2_common import isolate_profile_env
    agent_setup_test.PYTHON = host_python()
    env = isolate_profile_env(dict(os.environ))
    env.pop("XDG_RUNTIME_DIR", None)
    for name in [n for n in env if n.startswith("ZIGBROWSER_AGENT_")]:
        env.pop(name)
    env.update(world.env())
    if rt is not None:
        env["XDG_RUNTIME_DIR"] = str(rt)
    env.update(extra or {})
    return env


def netd_launchers(rt: Path) -> list[int]:
    """Live netd launchers (not the sandboxed --serve side) whose --sockdir is under `rt`."""
    found = []
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            argv = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        text = [a.decode(errors="replace") for a in argv if a]
        if any(a.endswith(NETD_SCRIPT) for a in text) and "--serve" not in text and "--sockdir" in text:
            if text[text.index("--sockdir") + 1].startswith(str(rt) + "/"):
                found.append(int(pid))
    return found


def argv_of(pid: int) -> list[str]:
    return [a.decode() for a in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0") if a]


def env_names_of(pid: int) -> list[str]:
    raw = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
    return sorted(e.split(b"=", 1)[0].decode() for e in raw if e)


def agentnet_rows(b) -> list[list[str]]:
    return [line.rstrip("\n").split("\t")[1:] for line in list(b.out) if line.startswith("AGENTNET\t")]


def bubbles(b) -> list[tuple[str, str]]:
    return [(r.fields[0], r.fields[1]) for r in b.rows("msg", 1)]


def send(b, text: str) -> None:
    """Opens the drawer with an X click on the icon (if closed), types `text`, presses Enter."""
    from agent_common import centre
    if not b.rows("open", 1):
        icon = b.wait_row("icon", 1)
        b.x.click(*centre(tuple(int(v) for v in icon.fields[0].split(","))))
        b.wait_row("open", 1, timeout=10)
    for ch in text:
        b.x.key({" ": "space"}.get(ch, ch), settle=0.005)
    b.x.key("Return")


def launch(binary: Path, tmp: Path, label: str, env: dict[str, str]):
    from agent_common import Browser
    return Browser(binary, tmp, label, ["--agent-drawer", "on"], env=env)


# --- the cases ------------------------------------------------------------------------------
def case_ready(binary: Path, tmp: Path, check) -> None:
    """Send starts netd with the exact argv and a built environment; it gets ready."""
    from agent_hook_net import HookNetDecoys
    rt = runtime_dir(tmp)
    decoys = HookNetDecoys()
    seam = " ".join(decoys.netd_test_args())
    b = launch(binary, tmp, "ready", env_for(provisioned_world(binary, tmp), rt, {"ZIGBROWSER_AGENT_NET_TEST": seam}))
    try:
        check(b.wait(lambda: b.rows("icon", 1) != [], 20), "the drawer's icon is up", b)
        check(netd_launchers(rt) == [], "no netd before the first Send")
        send(b, "hello")
        check(b.wait(lambda: any(r[:1] == ["ready"] for r in agentnet_rows(b)), 15), "AGENTNET ready", b)
        ready = [r for r in agentnet_rows(b) if r[:1] == ["ready"]]
        sockdir = Path(ready[0][1]) if ready and len(ready[0]) > 1 else None
        # (b.proc is the xsession wrapper, not the browser, so the pid itself is not compared.)
        name_ok = sockdir is not None and re.fullmatch(re.escape(str(rt)) + r"/zigbrowser-agent-\d+-[0-9a-f]{16}", str(sockdir))
        check(bool(name_ok), f"the socket directory is <XDG_RUNTIME_DIR>/zigbrowser-agent-<pid>-<16 hex> ({sockdir})")
        launchers = netd_launchers(rt)
        check(len(launchers) == 1, f"exactly one netd launcher ({launchers})")
        if launchers and sockdir is not None:
            argv = argv_of(launchers[0])
            expect = ["-I", "-S", str(REPO / "agent" / "host" / NETD_SCRIPT), "--sockdir", str(sockdir),
                      "--bwrap", "/usr/bin/bwrap", *decoys.netd_test_args()]
            check(argv[1:] == expect, f"netd's argv is exact ({argv[1:]})")
            names = env_names_of(launchers[0])
            check(not [n for n in names if n.startswith("ZIGBROWSER")], f"no ZIGBROWSER_* reaches netd ({names})")
            check(set(names) <= {"PATH", "PYTHONDONTWRITEBYTECODE", "LANG", "LC_ALL"}, f"netd's environment is built ({names})")
            check(oct(sockdir.stat().st_mode & 0o777) == "0o700", "the socket directory is 0700")
            layout = sorted(str(p.relative_to(sockdir)) for p in sockdir.rglob("*"))
            check(layout == ["bridges", "bridges/port-31337.sock", "bridges/port-51091.sock", "egress", "egress/proxy.sock"],
                  f"netd's layout ({layout})")
        send(b, "again")
        time.sleep(1.0)
        check(len(netd_launchers(rt)) == 1, "a second Send starts no second netd")
        check(not any(t == UNAVAILABLE for _, t in bubbles(b)), "no 'Agent network unavailable' while netd runs", b)
    finally:
        b.stop()
        decoys.close()
    check(netd_launchers(rt) == [], "no netd remains after quit")
    check(list(rt.iterdir()) == [], f"quit leaves no socket directory ({list(rt.iterdir())})")


def case_not_set_up(binary: Path, tmp: Path, check) -> None:
    """No provisioned agent home: Send says "Agent not available yet" and starts no netd."""
    import agent_setup_test
    from agent_common import host_python
    agent_setup_test.PYTHON = host_python()
    rt = runtime_dir(tmp)
    fresh = agent_setup_test.World(tmp, "unset")
    b = launch(binary, tmp, "unset", env_for(fresh, rt))
    try:
        send(b, "hello")
        check(b.wait(lambda: ("system", "Agent not available yet") in bubbles(b), 10), "Send says 'Agent not available yet'", b)
        time.sleep(1.0)
        check(netd_launchers(rt) == [] and agentnet_rows(b) == [], "no netd and no AGENTNET row", b)
    finally:
        b.stop()


def expect_unavailable(b, reason_line: str, check, label: str) -> None:
    check(b.wait(lambda: any(r[:1] == ["unavailable"] for r in agentnet_rows(b)), 15), f"{label}: AGENTNET unavailable", b)
    check(b.wait(lambda: ("system", UNAVAILABLE) in bubbles(b), 10), f"{label}: the drawer says '{UNAVAILABLE}'", b)
    lines = [l for l in b.err if reason_line in l]
    check(len(lines) == 1, f"{label}: one stderr line '{reason_line}' ({lines})", b)


def case_bad_seam(binary: Path, tmp: Path, check) -> None:
    """A bad ZIGBROWSER_AGENT_NET_TEST refuses the agent with one line; no netd starts."""
    rt = runtime_dir(tmp)
    b = launch(binary, tmp, "badseam", env_for(provisioned_world(binary, tmp), rt, {"ZIGBROWSER_AGENT_NET_TEST": "--test-allow evil.invalid=1"}))
    try:
        send(b, "hello")
        expect_unavailable(b, "zigBrowser: agent: bad ZIGBROWSER_AGENT_NET_TEST", check, "bad seam")
        time.sleep(1.0)
        check(netd_launchers(rt) == [], "no netd is started")
    finally:
        b.stop()


def case_bad_ca(binary: Path, tmp: Path, check) -> None:
    """A ZIGBROWSER_AGENT_NET_TEST_CA that is a link refuses the agent with one line."""
    rt = runtime_dir(tmp)
    real = tmp / "ca.pem"
    real.write_text("-----BEGIN CERTIFICATE-----\n")
    link = tmp / "ca-link.pem"
    link.symlink_to(real)
    b = launch(binary, tmp, "badca", env_for(provisioned_world(binary, tmp), rt, {"ZIGBROWSER_AGENT_NET_TEST_CA": str(link)}))
    try:
        send(b, "hello")
        expect_unavailable(b, "zigBrowser: agent: bad ZIGBROWSER_AGENT_NET_TEST_CA", check, "bad CA")
        check(netd_launchers(rt) == [], "no netd is started")
    finally:
        b.stop()


def case_no_runtime_dir(binary: Path, tmp: Path, check) -> None:
    """Without XDG_RUNTIME_DIR there is nowhere to put the sockets: unavailable, no netd."""
    b = launch(binary, tmp, "nort", env_for(provisioned_world(binary, tmp), None))
    try:
        send(b, "hello")
        expect_unavailable(b, "zigBrowser: agent: network unavailable (XDG_RUNTIME_DIR)", check, "no runtime dir")
    finally:
        b.stop()


def case_netd_dies(binary: Path, tmp: Path, check) -> None:
    """netd killed after it got ready: one log line, the bubble, and never a restart."""
    rt = runtime_dir(tmp)
    b = launch(binary, tmp, "dies", env_for(provisioned_world(binary, tmp), rt))
    try:
        send(b, "hello")
        check(b.wait(lambda: any(r[:1] == ["ready"] for r in agentnet_rows(b)), 15), "AGENTNET ready", b)
        for pid in netd_launchers(rt):
            os.kill(pid, signal.SIGKILL)
        expect_unavailable(b, "zigBrowser: agent: network helper exited (signal 9)", check, "netd killed")
        before = len([1 for _, t in bubbles(b) if t == UNAVAILABLE])
        send(b, "again")
        check(b.wait(lambda: len([1 for _, t in bubbles(b) if t == UNAVAILABLE]) == before + 1, 10),
              "the next Send shows the same bubble", b)
        time.sleep(2.0)
        check(netd_launchers(rt) == [], "netd is not restarted")
    finally:
        b.stop()
    # A killed netd leaves its directory (the crash rule, §3c.2); main() removes it.


def case_never_ready(binary: Path, tmp: Path, check) -> None:
    """netd that exits before `netd ready` (here: XDG_RUNTIME_DIR not 0700, which netd
    refuses with exit 2) is reported the same way, and not retried."""
    rt = runtime_dir(tmp)
    os.chmod(rt, 0o755)
    b = launch(binary, tmp, "notready", env_for(provisioned_world(binary, tmp), rt))
    try:
        send(b, "hello")
        expect_unavailable(b, "zigBrowser: agent: network helper exited (exit 2)", check, "netd refuses")
        send(b, "again")
        time.sleep(2.0)
        check(netd_launchers(rt) == [], "netd is not retried")
    finally:
        b.stop()


def case_ready_timeout(binary: Path, tmp: Path, check) -> None:
    """A netd that never prints `netd ready` (a stand-in Python that only sleeps) is killed
    after 5 s and reported, and not retried."""
    rt = runtime_dir(tmp)
    fake = tmp / "sleepy-python"
    fake.write_text("#!/bin/sh\nexec sleep 60\n")
    fake.chmod(0o755)
    b = launch(binary, tmp, "timeout", env_for(provisioned_world(binary, tmp), rt, {"ZB_AGENT_HOST_PYTHON": str(fake)}))
    try:
        started = time.monotonic()
        send(b, "hello")
        check(b.wait(lambda: any(r[:1] == ["starting"] for r in agentnet_rows(b)), 10), "AGENTNET starting", b)
        expect_unavailable(b, "zigBrowser: agent: network helper not ready within 5 s", check, "never ready")
        took = time.monotonic() - started
        check(4.0 <= took <= 12.0, f"given up after about 5 s ({took:.1f} s)")
        check(any("network helper exited (signal 9)" in l for l in b.err), "the stand-in was killed", b)
        send(b, "again")
        time.sleep(1.0)
        starts = [r for r in agentnet_rows(b) if r[:1] == ["starting"]]
        check(len(starts) == 1, f"it is not retried (AGENTNET starting rows: {len(starts)})", b)
    finally:
        b.stop()


CASES = {
    "not-set-up": case_not_set_up,
    "ready": case_ready,
    "bad-seam": case_bad_seam,
    "bad-ca": case_bad_ca,
    "no-runtime-dir": case_no_runtime_dir,
    "netd-dies": case_netd_dies,
    "never-ready": case_never_ready,
    "ready-timeout": case_ready_timeout,
}


def main() -> int:
    from agent_common import run_main
    try:
        return run_main(__doc__, CASES)
    finally:
        for d in RUNTIME_DIRS:
            subprocess.run(["find", str(d), "-delete"], check=False)


if __name__ == "__main__":
    raise SystemExit(main())
