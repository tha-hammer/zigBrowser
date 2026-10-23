#!/usr/bin/env python3
"""MS2a.3 part B direct oracle — the profile-dir error string is accounted like every returned C string.

RoseCat 6798 #2: `zb_app_set_profile_dir`, given a non-UTF-8 --profile-dir, returns an error C string that
its caller (app.zig applyProfileDir) frees via the now-accounting `zb_automation_free`. If that string were a
plain `strdup`, the free would decrement the ownership counter with no matching increment, driving it
NEGATIVE and making the whole part-B instrumentation false. This exercises that exact seam directly (no
browser launch — the invalid-profile-dir path exits the app before the socket) with a tiny C harness linked
against the shim dylib, reading the balance through `zb_automation_debug_strings_live`:
  - at rest the balance is 0;
  - after the invalid set, an error string exists AND the balance is baseline+1 (the alloc was ACCOUNTED);
  - after freeing it via zb_automation_free, the balance is EXACTLY back to baseline (0).
Mutant: make the error a plain `strdup` (untracked) -> after the set the balance stays at baseline (not +1),
and after the free it is baseline-1 (negative) -> red.

A compiled harness (not ctypes): the shim is built with `-undefined dynamic_lookup` and references four host
symbols (zb_ipc_dispatch, zb_policy_decide, and since 4pa.55 zb_load_failure_action and zb_load_exit_timer_armed)
that a standalone dlopen cannot resolve. The harness DEFINES those as no-ops and links the shim, so @executable_path/../Frameworks resolves it when run next to zigBrowser.

Runs ON a Mac; pure in-process, no window, no xvfb.
"""
import argparse
import subprocess
import sys
from pathlib import Path

from mac_term_teardown import run_term_only  # noqa: E402

SKIP_EXIT = 77

HARNESS_C = r"""
#include <stdio.h>
/* The HOST symbols the shim references via -undefined dynamic_lookup; never called on this path. */
void zb_ipc_dispatch(void) {}
void zb_policy_decide(void) {}
void zb_load_failure_action(void) {}
void zb_load_exit_timer_armed(void) {}
extern int  zb_automation_debug_strings_live(void);
extern int  zb_app_set_profile_dir(const char *dir, char **out_err);
extern void zb_automation_free(char *p);
int main(void) {
    const char bad[] = { (char)0xff, (char)0xfe, '-', 'b', 'a', 'd', 0 };  /* not valid UTF-8 -> NSString nil */
    int base = zb_automation_debug_strings_live();
    char *err = NULL;
    int rc = zb_app_set_profile_dir(bad, &err);
    int had_err = (err != NULL);
    int after_set = zb_automation_debug_strings_live();
    zb_automation_free(err);
    int after_free = zb_automation_debug_strings_live();
    printf("base=%d rc=%d had_err=%d after_set=%d after_free=%d\n", base, rc, had_err, after_set, after_free);
    int ok = (base == 0) && (rc != 0) && had_err && (after_set == base + 1) && (after_free == base);
    return ok ? 0 : 1;
}
"""


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    args = ap.parse_args()
    browser = Path(args.browser).resolve()
    if not browser.is_file():
        eprint(f"SKIP: binary not found: {browser}")
        return SKIP_EXIT
    dylib = (browser.parent / ".." / "Frameworks" / "libwkwebview_shim.dylib").resolve()
    if not dylib.is_file():
        eprint(f"SKIP: shim dylib not found at {dylib}")
        return SKIP_EXIT

    # Build + run the harness NEXT TO zigBrowser so the shim's @executable_path/../Frameworks install name
    # resolves. The binary is a single fixed path we created, so removing it is a guarded, exact-path delete.
    src = browser.parent / "zb_stracct_harness.c"
    exe = browser.parent / "zb_stracct_harness"
    rc = 1
    try:
        src.write_text(HARNESS_C)
        build = subprocess.run(["xcrun", "clang", "-o", str(exe), str(src), str(dylib)],
                               capture_output=True, text=True)
        if build.returncode != 0:
            print("FAIL\tms2a-str-accounting-harness-build-failed")
            eprint(build.stderr.strip()[-800:])
            return 1
        run = run_term_only([str(exe)], 30)  # a timeout stops the harness with SIGTERM only (3ui.7)
        eprint(f"harness: {run.stdout.strip()}  stderr={run.stderr.strip()[-200:]}")
        if run.returncode != 0:
            print("FAIL\tms2a-str-accounting")
            eprint("the profile-dir error alloc is not accounted exactly once "
                   "(expected base=0, rc!=0, had_err=1, after_set=1, after_free=0)")
            return 1
        rc = 0
    except subprocess.TimeoutExpired:
        print("FAIL\tms2a-str-accounting-timeout")
        return 1
    finally:
        for p in (exe, src):
            try:
                if p.name.startswith("zb_stracct_harness") and p.exists():
                    p.unlink()
            except OSError:
                pass

    print("PASS\tms2a-str-accounting")
    return rc


if __name__ == "__main__":
    sys.exit(main())
