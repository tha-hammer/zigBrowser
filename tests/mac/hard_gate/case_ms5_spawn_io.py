"""BlackRobin 7108 seam 1 in the hard-gate sequence (RoseCat cf01d66): zb_agent_spawn_group_io, the browser's netd
spawn, re-proven on each Mac before Mac launch is armed. It compiles tests/mac/spawn_group_io_test.c with
src/agent_spawn_posix.c (read at their repo-relative paths, so the staging copies them in the repo's layout) into
this case's scratch, runs it in its own bounded group, and requires the exact result of the manual gate
tests/mac/ms5_spawn_io_gate.sh:

- every one of the 12 rows ok, and no FAIL row: exactly fds 0 1 2 (census past a planted fd 300) in the pipes,
  inherit and same-fd cases; own group; stdin round-trip; exit on stdin EOF / SHUT_WR within 2 s; the four EINVALs;
- the last line exactly "PASS\\tms5-spawn-io\\t4 cases", and exit 0.

A missing source, a compiler failure or a timeout is a FAIL, never a skip."""
import os
from pathlib import Path

NAME = "ms5-spawn-io"
ROOT = Path(__file__).resolve().parents[3]
SOURCES = (ROOT / "tests" / "mac" / "spawn_group_io_test.c", ROOT / "src" / "agent_spawn_posix.c")
HEADER = ROOT / "src" / "agent_spawn_posix.h"
ROWS = 12


def run(h):
    missing = [str(p) for p in (*SOURCES, HEADER) if not p.is_file()]
    if not h.check(not missing, f"the seam-1 sources are staged (missing: {missing})"):
        return
    exe = os.path.join(h.scratch, "spawn_io_test")
    env = {"PATH": "/usr/bin:/bin", "LANG": "C"}
    code, out, err = h.spawn_group(["/usr/bin/xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-I", str(HEADER.parent),
                                    *map(str, SOURCES), "-o", exe], env=env, timeout=120)
    if not h.check(code == 0 and os.path.isfile(exe), f"spawn_group_io_test compiles (exit {code}: {err[-400:]!r})"):
        return
    code, out, err = h.spawn_group([exe], env=env, timeout=60)
    lines = out.decode("utf-8", "replace").splitlines()
    oks = [l for l in lines if l.startswith("  ok   ")]
    fails = [l for l in lines if l.startswith("  FAIL ") or l.startswith("FAIL")]
    h.check(not fails, f"no seam-1 row fails ({fails})")
    h.check(len(oks) == ROWS, f"all {ROWS} seam-1 rows are ok (got {len(oks)})")
    h.check(code == 0 and lines[-1:] == ["PASS\tms5-spawn-io\t4 cases"],
            f"the seam-1 test passes all 4 cases (exit {code}, last line {lines[-1:]!r})")
