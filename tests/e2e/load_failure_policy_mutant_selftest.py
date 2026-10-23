#!/usr/bin/env python3
"""bd zigBrowser-4pa.55 (SilverRidge 58c6543 items 2-3): the registered 4pa.55 proofs reject the old semantics.

Each case writes a production mutant to a private temporary directory (the repository is never edited), runs the
REAL oracle against it, and requires it to fail at exactly the named rows:
- Zig policy (src/load_failure_policy.zig) under the real tests/load_failure_policy_test.zig, through `zig test`
  with a fresh local cache per case:
  - control, unmutated: all 7 tests pass (the harness itself works);
  - Q quit-all, the pre-4pa.55 rule (every untagged failure exits): exactly the 5 rows below fail;
  - A arm-all, the pre-4pa.55 timer (every load arms the exit timer): exactly the 4 rows below fail.
- Shim call sites (src/wkwebview_shim.m) under tests/e2e/mac_load_exit_timer_binding_test.py:
  - ML loadURI: guard drop (the helper's zb_load_exit_timer_armed guard becomes YES): B2;
  - ML2 loadURI: schedules its own unguarded timer again: B1 and B3;
  - MR reloadBypassingCache: arms unconditionally again (ca4ab28's form): B1 and B3;
  - MT onNavigationTimeout: quits on every expiry again (ca4ab28's form): B4.
Each substitution must occur exactly once, so a drifted source fails here instead of passing vacuously.
Run: python3 tests/e2e/load_failure_policy_mutant_selftest.py --zig ZIG --global-cache-dir DIR
     (registered: zig build test-load-failure-policy)
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import mac_load_exit_timer_binding_test as binding  # noqa: E402

POLICY = ROOT / "src" / "load_failure_policy.zig"
POLICY_TEST = ROOT / "tests" / "load_failure_policy_test.zig"
ZIG_TIMEOUT_SEC = 600

ROW_1_3 = "rows 1-3: after the primary window's first finish, a failed untagged load is recorded, not an exit"
ROW_4 = "row 4: a recovery reload arms no exit timer and its failure is recorded, whatever the window's history"
ROW_POPUP = "a policy-opened or popup window never exits and arms no exit timer"
ROW_PROPERTY = "property: exit iff untagged primary initial non-recovery load, over all 16 states; the timer matches it"
ROW_ABI = "the C ABI reads any nonzero int as true, as the shim's BOOLs and ints pass it"

ZIG_CASES = [
    ("control", None, None, []),
    ("Q quit-all", "    return if (exitEligible(load)) .exit else .record;\n", "    return .exit;\n",
     [ROW_1_3, ROW_4, ROW_POPUP, ROW_PROPERTY, ROW_ABI]),
    ("A arm-all", "pub fn exitTimerArmed(load: Load) bool {\n    return exitEligible(load);\n",
     "pub fn exitTimerArmed(load: Load) bool {\n    _ = load;\n    return true;\n",
     [ROW_1_3, ROW_4, ROW_POPUP, ROW_PROPERTY]),
]

UNGUARDED = """  self.timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:ZB_NAVIGATION_TIMEOUT_SECONDS
                                                       target:self
                                                     selector:@selector(onNavigationTimeout:)
                                                     userInfo:nil
                                                      repeats:NO];
"""
SHIM_CASES = [
    ("ML loadURI: guard drop",
     "  if (zb_load_exit_timer_armed([self isPrimaryWindow], self.app.primaryFinished, self.recoveryLoad)) {\n"
     "    self.timeoutTimer = [NSTimer",
     "  if (YES) {\n    self.timeoutTimer = [NSTimer", {"B2"}),
    ("ML2 loadURI: own unguarded timer",
     "  [self armLoadExitTimer];\n  NSURL *url = [NSURL URLWithString:uri];",
     "  [self.timeoutTimer invalidate];\n" + UNGUARDED + "  NSURL *url = [NSURL URLWithString:uri];", {"B1", "B3"}),
    ("MR reloadBypassingCache: unconditional arm",
     "  [self armLoadExitTimer];\n  self.currentNav = bypassCache",
     "  [self.timeoutTimer invalidate];\n" + UNGUARDED + "  self.currentNav = bypassCache", {"B1", "B3"}),
    ("MT onNavigationTimeout: quits on every expiry",
     "  int action = zb_load_failure_action(0, [self isPrimaryWindow], self.app.primaryFinished, self.recoveryLoad);\n"
     "  self.recoveryLoad = NO;\n"
     "  if (action == ZB_LOADFAIL_EXIT) [self.app requestExit:ZB_EXIT_TIMEOUT];\n",
     "  [self.app requestExit:ZB_EXIT_TIMEOUT];\n", {"B4"}),
]


def mutate(text: str, old: str | None, new: str | None) -> str:
    if old is None:
        return text
    n = text.count(old)
    if n != 1:
        raise ValueError(f"the mutant's source text occurs {n} times, want exactly 1")
    return text.replace(old, new)


def run_zig_case(args, work: Path, name, old, new):
    """(rc, [failed test names], output) of the real policy test against the (mutated) policy source."""
    case = work / re.sub(r"\W+", "-", name)
    case.mkdir()
    policy = case / "load_failure_policy.zig"
    policy.write_text(mutate(POLICY.read_text(), old, new))
    argv = ["timeout", "-k", "10", str(ZIG_TIMEOUT_SEC), args.zig, "test", "-lc", "-I", str(ROOT / "src"),
            "--dep", "load_failure_policy", f"-Mroot={POLICY_TEST}", f"-Mload_failure_policy={policy}",
            "--cache-dir", str(case / "zig-cache"), "--global-cache-dir", args.global_cache_dir]
    proc = subprocess.run(argv, cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = proc.stdout.decode("utf-8", "replace")
    # "N/7 load_failure_policy_test.test.<name>...OK"; a failure prints its message (or FAIL) after the "...".
    results = re.findall(r"^\d+/\d+ load_failure_policy_test\.test\.(.+?)\.\.\.(.*)$", out, re.M)
    failed = [test for test, rest in results if rest != "OK" and not rest.startswith("SKIP")]
    return proc.returncode, failed, out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zig", required=True)
    ap.add_argument("--global-cache-dir", required=True)
    args = ap.parse_args()
    fails = 0

    def bad(msg):
        nonlocal fails
        fails += 1
        print(f"FAIL {msg}")

    shim_text = binding.SHIM.read_text()
    real = binding.check(shim_text)
    if real:
        bad(f"the real shim does not pass the binding oracle: {real}")
    for name, old, new, want in SHIM_CASES:
        try:
            problems = binding.check(mutate(shim_text, old, new))
        except ValueError as e:
            bad(f"shim mutant {name}: {e}")
            continue
        rows = {p.split()[0] for p in problems}
        if rows != want:
            bad(f"shim mutant {name}: failed rows {sorted(rows)}, want {sorted(want)}: {problems}")
        else:
            print(f"ok   shim mutant {name}: red at {', '.join(sorted(rows))}")

    work = Path(tempfile.mkdtemp(prefix="zb-lfp-mutants-"))
    try:
        for name, old, new, want in ZIG_CASES:
            try:
                rc, failed, out = run_zig_case(args, work, name, old, new)
            except ValueError as e:
                bad(f"zig mutant {name}: {e}")
                continue
            if want:
                if rc == 0 or sorted(failed) != sorted(want):
                    bad(f"zig mutant {name}: rc {rc}, failed {failed}, want rc != 0 and exactly {want}\n{out[-2000:]}")
                else:
                    print(f"ok   zig mutant {name}: rc {rc}, red at {len(failed)} named rows: " + "; ".join(failed))
            elif rc != 0 or failed or "All 7 tests passed." not in out:
                bad(f"zig {name}: rc {rc}, failed {failed}: the unmutated policy must pass all 7 tests\n{out[-2000:]}")
            else:
                print(f"ok   zig {name}: all 7 tests pass")
    finally:
        if work.name.startswith("zb-lfp-mutants-") and work.parent == Path(tempfile.gettempdir()):
            shutil.rmtree(work, ignore_errors=True)

    if fails:
        print(f"FAIL load-failure-policy-mutants {fails} case(s)")
        return 1
    print(f"PASS load-failure-policy-mutants {len(SHIM_CASES)} shim and {len(ZIG_CASES) - 1} zig mutants red, control green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
