#!/usr/bin/env python3
"""MS0 slice D (RoseCat 5750/5752; JadeBeacon 5753/5762, BlueBeaver 5755): the
browser hands netd the backend's network manifest.

When the agent home is provisioned, the browser starts netd with
`--net-manifest <agent home>/runtime/net.json` right after `--bwrap BWRAP`
(before any --e2e-protocol seam), and netd serves the manifest's bridge
ports and allow-list (agent/host/tests/test_netd_manifest.py drives netd's
own rules). These cases watch the real browser:

- manifest-ports: a manifest with ports 40101 and 40102 gives exactly
  bridges/port-40101.sock and bridges/port-40102.sock;
- manifest-missing: a home without runtime/net.json (set up before the
  manifest existed) still gets the built-in 51091 and 31337;
- manifest-bad: a manifest netd refuses gives netd's exit before ready, the
  row `AGENTNET unavailable`, the bubble "Agent network unavailable", and no
  manifest content in any output.

The cases share one home provisioned with the real --agent-setup; each
replaces only its runtime/net.json, as a stand-in for the backend's values
(JadeBeacon's slice D tests setup's side: the backend's LaunchSpec network
field written to that file). Private XDG_RUNTIME_DIR, no D-Bus (the file
store), no real network: nothing touches DISPLAY :0, the voice server or the
live profile. Exit 1 when Xvfb, xauth or the binary is missing."""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_netd_spawn_test as spawn  # noqa: E402

CANARY = "zbqxmanifest"
WORLD: list[object] = []


def own_world(binary: Path, tmp: Path):
    """One home provisioned by the real --agent-setup for these cases, with a canary token
    in the file store (each case then replaces runtime/net.json)."""
    if WORLD:
        return WORLD[0]
    import agent_setup_test
    from agent_common import host_python
    agent_setup_test.PYTHON = host_python()
    world = agent_setup_test.World(tmp, "netd-manifest")
    rc, _out, err, _events, _seen = agent_setup_test.run_setup(binary, world)
    if rc != 0:
        raise AssertionError(f"--agent-setup failed: {err.strip()[-300:]}")
    secrets_dir = world.agent / "secrets"
    secrets_dir.mkdir(mode=0o700, exist_ok=True)
    fd = os.open(secrets_dir / "claude-token", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(fd, b"sk-ant-oat01-ZBCANARY-netd-manifest-0123456789")
    os.close(fd)
    WORLD.append(world)
    return world


def replace_manifest(world, content: bytes | None) -> Path:
    """runtime/net.json replaced by `content` (0600), or removed when None. Its directory
    may be read-only: it is opened for the write and closed again."""
    path = (world.agent / "runtime").resolve() / "net.json"
    mode = path.parent.stat().st_mode & 0o777
    os.chmod(path.parent, mode | 0o700)
    try:
        if path.exists():
            path.unlink()
        if content is not None:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.write(fd, content)
            os.close(fd)
    finally:
        os.chmod(path.parent, mode)
    return world.agent / "runtime" / "net.json"


def manifest(ports, allow=("api.anthropic.com",), **extra) -> bytes:
    doc = {"bridges_dir": "/run/zb-bridges", "ports": list(ports),
           "egress": {"endpoint": "127.0.0.1:3128", "allow": list(allow)}}
    doc.update(extra)
    return json.dumps(doc).encode()


def started(b, rt: Path, check, label: str) -> tuple[Path | None, list[str]]:
    """Send once; the socket directory from `AGENTNET ready` and netd's argv."""
    spawn.send(b, "hello")
    check(b.wait(lambda: any(r[:1] == ["ready"] for r in spawn.agentnet_rows(b)), 15), f"{label}: AGENTNET ready", b)
    ready = [r for r in spawn.agentnet_rows(b) if r[:1] == ["ready"]]
    sockdir = Path(ready[0][1]) if ready and len(ready[0]) > 1 else None
    launchers = spawn.netd_launchers(rt)
    check(len(launchers) == 1, f"{label}: exactly one netd launcher ({launchers})")
    return sockdir, spawn.argv_of(launchers[0]) if launchers else []


def expect_manifest_argv(argv: list[str], sockdir: Path | None, path: Path, check, label: str) -> None:
    want = ["-I", "-S", str(spawn.REPO / "agent" / "host" / spawn.NETD_SCRIPT), "--sockdir", str(sockdir),
            "--bwrap", "/usr/bin/bwrap", "--net-manifest", str(path)]
    check(argv[1:] == want, f"{label}: netd's argv carries --net-manifest after --bwrap ({argv[1:]})")


def layout(sockdir: Path | None) -> list[str]:
    return sorted(str(p.relative_to(sockdir)) for p in sockdir.rglob("*")) if sockdir else []


def case_manifest_ports(binary: Path, tmp: Path, check) -> None:
    rt = spawn.runtime_dir(tmp)
    world = own_world(binary, tmp)
    path = replace_manifest(world, manifest((40101, 40102)))
    b = spawn.launch(binary, tmp, "manifest-ports", spawn.env_for(world, rt))
    try:
        sockdir, argv = started(b, rt, check, "manifest-ports")
        expect_manifest_argv(argv, sockdir, path, check, "manifest-ports")
        check(layout(sockdir) == ["bridges", "bridges/port-40101.sock", "bridges/port-40102.sock",
                                  "egress", "egress/proxy.sock"], f"the manifest's ports are netd's bridges ({layout(sockdir)})")
    finally:
        b.stop()
    check(spawn.netd_launchers(rt) == [], "no netd remains after quit")


def case_manifest_missing(binary: Path, tmp: Path, check) -> None:
    rt = spawn.runtime_dir(tmp)
    world = own_world(binary, tmp)
    path = replace_manifest(world, None)
    b = spawn.launch(binary, tmp, "manifest-missing", spawn.env_for(world, rt))
    try:
        sockdir, argv = started(b, rt, check, "manifest-missing")
        expect_manifest_argv(argv, sockdir, path, check, "manifest-missing")
        check(layout(sockdir) == ["bridges", "bridges/port-31337.sock", "bridges/port-51091.sock",
                                  "egress", "egress/proxy.sock"], f"the built-in bridges ({layout(sockdir)})")
    finally:
        b.stop()


def case_manifest_bad(binary: Path, tmp: Path, check) -> None:
    rt = spawn.runtime_dir(tmp)
    world = own_world(binary, tmp)
    replace_manifest(world, manifest((51091,), allow=(f"*.{CANARY}.com",)))
    b = spawn.launch(binary, tmp, "manifest-bad", spawn.env_for(world, rt))
    try:
        spawn.send(b, "hello")
        check(b.wait(lambda: any(r[:1] == ["unavailable"] for r in spawn.agentnet_rows(b)), 15),
              "a refused manifest: AGENTNET unavailable", b)
        check(b.wait(lambda: ("system", spawn.UNAVAILABLE) in spawn.bubbles(b), 10),
              f"the drawer says '{spawn.UNAVAILABLE}'", b)
        check(not any(r[:1] == ["ready"] for r in spawn.agentnet_rows(b)), "netd never got ready", b)
        time.sleep(0.5)
        check(CANARY not in "\n".join(b.out + b.err), "no manifest content in any row or log", b)
    finally:
        b.stop()


CASES = {
    "manifest-ports": case_manifest_ports,
    "manifest-missing": case_manifest_missing,
    "manifest-bad": case_manifest_bad,
}


def main() -> int:
    from agent_common import run_main
    try:
        return run_main(__doc__, CASES)
    finally:
        for d in spawn.RUNTIME_DIRS:
            spawn.subprocess.run(["find", str(d), "-delete"], check=False)


if __name__ == "__main__":
    raise SystemExit(main())
