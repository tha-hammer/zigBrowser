#!/usr/bin/env python3
"""GREEN, REGISTERED (SilverRidge 0b4c44bd item D): macOS signal delivery never runs Objective-C,
block, dispatch, allocation, or retention work from a raw POSIX signal handler.

The production shim must ignore SIGHUP/SIGINT/SIGTERM at the POSIX disposition and consume them with dispatch
signal sources on the main queue. SIGHUP keeps reload semantics; SIGINT and SIGTERM keep the reviewed cancelled
exit semantics. The exact production signal slice is syntax-compiled as Objective-C/ARC for x86_64 and arm64
macOS targets. An embedded restoration of the old raw ``handle_signal`` implementation must be rejected.

Run: python3 -X dev tests/e2e/mac_signal_delivery_test.py [shim path]
"""
from __future__ import annotations

import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHIM = ROOT / "src" / "wkwebview_shim.m"
BEGIN = "// ZB_SIGNAL_DELIVERY_BEGIN"
END = "// ZB_SIGNAL_DELIVERY_END"
SIGNALS = ("SIGINT", "SIGTERM", "SIGHUP")
SOURCE_FOR_SIGNAL = {
    "SIGINT": "g_sigint_source",
    "SIGTERM": "g_sigterm_source",
    "SIGHUP": "g_sighup_source",
}
failures: list[str] = []

PRELUDE = r"""
typedef signed char BOOL;
typedef unsigned long uintptr_t;
typedef void (^dispatch_block_t)(void);
typedef void *dispatch_queue_t;
typedef void *dispatch_source_t;
typedef void (*zb_sighandler_t)(int);
#define YES ((BOOL)1)
#define NO ((BOOL)0)
#define NULL ((void *)0)
#define SIGINT 2
#define SIGHUP 1
#define SIGTERM 15
#define SIG_DFL ((zb_sighandler_t)0)
#define SIG_IGN ((zb_sighandler_t)1)
#define ZB_EXIT_CANCELLED 130
#define DISPATCH_SOURCE_TYPE_SIGNAL ((const void *)1)
extern zb_sighandler_t signal(int, zb_sighandler_t);
extern dispatch_queue_t dispatch_get_main_queue(void);
extern dispatch_source_t dispatch_source_create(const void *, uintptr_t, unsigned long, dispatch_queue_t);
extern void dispatch_source_set_event_handler(dispatch_source_t, dispatch_block_t);
extern void dispatch_source_cancel(dispatch_source_t);
extern void dispatch_resume(dispatch_source_t);
@interface ZBAppHost
- (void)reloadMainWindowBypassingCache:(BOOL)bypassCache;
- (void)requestExit:(int)code;
@end
"""

OLD_HANDLER = r"""
static void handle_signal(int signo) {
  ZBAppHost *app = g_active_app;
  if (app == nil) {
    _exit(signo == SIGINT ? ZB_EXIT_CANCELLED : ZB_EXIT_SUCCESS);
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if (signo == SIGHUP) {
      [app reloadMainWindowBypassingCache:NO];
    } else {
      [app requestExit:ZB_EXIT_CANCELLED];
    }
  });
}
"""


def bad(message: str) -> None:
    failures.append(message)


def function_body(source: str, name: str) -> str | None:
    match = re.search(r"\b(?:static\s+)?void\s+" + re.escape(name) + r"\s*\([^)]*\)\s*\{", source)
    if match is None:
        return None
    start = match.end() - 1
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start + 1:index]
    return None


def signal_region(source: str) -> str | None:
    if source.count(BEGIN) != 1 or source.count(END) != 1:
        return None
    start = source.index(BEGIN) + len(BEGIN)
    stop = source.index(END, start)
    return source[start:stop]


def source_problems(source: str, label: str) -> list[str]:
    problems: list[str] = []
    calls = re.findall(
        r"signal\(\s*(SIGINT|SIGTERM|SIGHUP)\s*,\s*(SIG_IGN|SIG_DFL|[A-Za-z_][A-Za-z0-9_]*)\s*\)",
        source,
    )
    for signo in SIGNALS:
        handlers = [handler for signal_name, handler in calls if signal_name == signo]
        if handlers.count("SIG_IGN") != 1 or handlers.count("SIG_DFL") != 1:
            problems.append(f"{label}: {signo} must have exactly one SIG_IGN install and one SIG_DFL restore, got {handlers!r}")
        for handler in (item for item in handlers if item not in ("SIG_IGN", "SIG_DFL")):
            body = function_body(source, handler)
            unsafe = []
            if body is None:
                unsafe.append("uninspectable body")
            else:
                checks = (
                    ("[", "Objective-C messaging"),
                    ("^", "block creation"),
                    ("dispatch_", "dispatch call"),
                    ("g_active_app", "Objective-C object access/retention"),
                )
                unsafe.extend(description for token, description in checks if token in body)
                if re.search(r"\b(?:malloc|calloc|realloc|free|alloc|new|retain|release|autorelease)\b", body or ""):
                    unsafe.append("allocation/retention")
            problems.append(f"{label}: {signo} installs custom raw handler {handler}")
            if unsafe:
                problems.append(f"{label}: raw handler {handler} performs unsafe work: {', '.join(unsafe)}")

    region = signal_region(source)
    if region is None:
        problems.append(f"{label}: missing one bounded {BEGIN}/{END} production region")
        return problems
    if re.search(r"\bsigaction\s*\(", region):
        problems.append(f"{label}: dispatch-source delivery must not install a custom sigaction handler")

    required = (
        "dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL",
        "dispatch_get_main_queue()",
        "dispatch_source_set_event_handler(source, ^",
        "dispatch_resume(source);",
        "dispatch_source_cancel(",
        "[app reloadMainWindowBypassingCache:NO]",
        "[app requestExit:ZB_EXIT_CANCELLED]",
        "g_sigint_source = zb_make_signal_source(SIGINT, app);",
        "g_sigterm_source = zb_make_signal_source(SIGTERM, app);",
        "g_sighup_source = zb_make_signal_source(SIGHUP, app);",
    )
    for text in required:
        if text not in region:
            problems.append(f"{label}: production signal region is missing {text!r}")
    if region.count("dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL") != 1:
        problems.append(f"{label}: signal sources must share one reviewed constructor")
    if "if (signo == SIGHUP)" not in region:
        problems.append(f"{label}: SIGHUP must be distinguished from the exit signals")
    normalized = " ".join(region.split())
    exact_behavior = (
        "if (signo == SIGHUP) { [app reloadMainWindowBypassingCache:NO]; } else { "
        "[app requestExit:ZB_EXIT_CANCELLED]; }"
    )
    if exact_behavior not in normalized:
        problems.append(f"{label}: the SIGHUP reload and SIGINT/SIGTERM exit branches are not exactly bound")

    cleanup = function_body(source, "zb_remove_signal_sources")
    if cleanup is None:
        problems.append(f"{label}: missing inspectable zb_remove_signal_sources cleanup")
    else:
        for signo, global_name in SOURCE_FOR_SIGNAL.items():
            unit = re.compile(
                r"if\s*\(\s*" + re.escape(global_name) + r"\s*!=\s*NULL\s*\)\s*\{\s*"
                r"dispatch_source_cancel\(\s*" + re.escape(global_name) + r"\s*\)\s*;\s*"
                + re.escape(global_name) + r"\s*=\s*NULL\s*;\s*\}\s*"
                r"signal\(\s*" + signo + r"\s*,\s*SIG_DFL\s*\)\s*;"
            )
            if len(unit.findall(cleanup)) != 1:
                problems.append(
                    f"{label}: {signo} cleanup must be one guarded cancel of {global_name}, then clear that "
                    "global, then restore SIG_DFL"
                )
            if len(re.findall(r"dispatch_source_cancel\(\s*" + re.escape(global_name) + r"\s*\)", cleanup)) != 1:
                problems.append(f"{label}: {signo} cleanup must cancel {global_name} exactly once")
            if len(re.findall(r"\b" + re.escape(global_name) + r"\s*=\s*NULL\s*;", cleanup)) != 1:
                problems.append(f"{label}: {signo} cleanup must clear {global_name} exactly once")
        if cleanup.count("dispatch_source_cancel(") != 3:
            problems.append(f"{label}: cleanup must contain exactly three dispatch-source cancels")
        if len(re.findall(r"signal\(\s*(?:SIGINT|SIGTERM|SIGHUP)\s*,\s*SIG_DFL\s*\)", cleanup)) != 3:
            problems.append(f"{label}: cleanup must contain exactly three default-disposition restores")

    install = source.find("if (!zb_install_signal_sources(host))")
    active = source.find("g_active_app = host;")
    window = source.find("ZbWindow *window = zb_window_new", active + 1)
    if active < 0 or install < active or window < install:
        problems.append(f"{label}: signal sources must install after the active app and before the first window")
    if source.count("zb_remove_signal_sources();") != 3:
        problems.append(
            f"{label}: cleanup must run exactly on partial install, first-window failure and normal loop exit"
        )
    source_compact = " ".join(source.split())
    paths = (
        ("partial-install", r"if \(g_sigint_source == NULL \|\| g_sigterm_source == NULL \|\| "
                            r"g_sighup_source == NULL\) \{ zb_remove_signal_sources\(\); return NO; \}"),
        ("first-window", r"if \(window == NULL\) \{ zb_remove_signal_sources\(\);"),
        ("normal-loop-exit", r"\[application run\]; zb_auto_on_loop_ended\(\); .*? "
                             r"zb_remove_signal_sources\(\); g_active_app = nil;"),
    )
    for path_name, pattern in paths:
        if re.search(pattern, source_compact) is None:
            problems.append(f"{label}: cleanup is not bound to {path_name}")
    if install >= 0 and window >= 0 and "zb_remove_signal_sources();" in source[install:window]:
        problems.append(f"{label}: signal sources are dropped before the first window")
    return problems


def compile_slice(source: str, row: str) -> None:
    region = signal_region(source)
    if region is None:
        bad(f"{row}: cannot compile the missing production signal region")
        return
    zig = shutil.which("zig")
    if zig is None:
        bad(f"{row}: zig compiler is unavailable")
        return
    with tempfile.TemporaryDirectory(prefix="zb-signal-compile-") as tmp:
        unit = Path(tmp) / "signal_slice.m"
        unit.write_text(PRELUDE + region + "\n")
        for arch in ("x86_64", "arm64"):
            target = "x86_64-macos" if arch == "x86_64" else "aarch64-macos"
            want_cpu = 0x01000007 if arch == "x86_64" else 0x0100000C
            output = Path(tmp) / f"signal-{arch}.o"
            result = subprocess.run(
                [zig, "cc", "-target", target, "-x", "objective-c", "-fblocks", "-fobjc-arc", "-nostdinc", "-nostdlib",
                 "-c", str(unit), "-o", str(output)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=30,
            )
            if result.returncode != 0 or not output.is_file() or output.stat().st_size == 0:
                bad(f"{row} {arch}: signal slice does not compile: {result.stderr.decode(errors='replace')[-1200:]}")
                continue
            magic, cpu = struct.unpack_from("<II", output.read_bytes())
            if magic != 0xFEEDFACF or cpu != want_cpu:
                bad(f"{row} {arch}: compiler emitted wrong Mach-O identity magic=0x{magic:x} cpu=0x{cpu:x}")


def restored_old_handler(source: str) -> str | None:
    if source.count(BEGIN) != 1:
        return None
    mutant = source.replace(BEGIN, BEGIN + "\n" + OLD_HANDLER, 1)
    for signo in SIGNALS:
        old = f"signal({signo}, SIG_IGN);"
        if mutant.count(old) != 1:
            return None
        mutant = mutant.replace(old, f"signal({signo}, handle_signal);", 1)
    return mutant


def cleanup_mutants(source: str) -> list[tuple[str, str]]:
    """One field-isolated removal, source mismatch and clear/restore reorder per signal."""
    mutants: list[tuple[str, str]] = []
    next_source = {
        "SIGINT": "g_sigterm_source",
        "SIGTERM": "g_sighup_source",
        "SIGHUP": "g_sigint_source",
    }
    for index, (signo, global_name) in enumerate(SOURCE_FOR_SIGNAL.items(), 2):
        cancel = f"    dispatch_source_cancel({global_name});\n"
        clear = f"    {global_name} = NULL;\n  }}\n  signal({signo}, SIG_DFL);"
        if source.count(cancel) == 1:
            mutants.append((f"M{index} {signo}-cancel-removed", source.replace(cancel, "", 1)))
        if source.count(cancel) == 1:
            wrong = f"    dispatch_source_cancel({next_source[signo]});\n"
            mutants.append((f"M{index + 3} {signo}-cancel-mismatch", source.replace(cancel, wrong, 1)))
        if source.count(clear) == 1:
            reordered = f"    signal({signo}, SIG_DFL);\n    {global_name} = NULL;\n  }}"
            mutants.append((f"M{index + 6} {signo}-clear-restore-reordered", source.replace(clear, reordered, 1)))
    return mutants


def run_rows(shim: Path) -> list[str]:
    global failures
    failures = []
    try:
        source = shim.read_text()
    except OSError as error:
        return [f"S0 cannot read {shim}: {error}"]

    failures.extend(source_problems(source, "S1 production"))
    compile_slice(source, "C1/C2")

    mutant = restored_old_handler(source)
    if mutant is None:
        bad("M1 cannot construct the exact restore-old-handler mutant from the production anchors")
    else:
        mutant_problems = source_problems(mutant, "M1 restore-old-handler")
        if not any("raw handler handle_signal performs unsafe work" in problem for problem in mutant_problems):
            bad(f"M1 restored raw handler survived the unsafe-context oracle: {mutant_problems!r}")
    mutants = cleanup_mutants(source)
    if len(mutants) != 9:
        bad(f"M2-M10 constructed {len(mutants)} teardown mutants, want exactly 9")
    for label, teardown_mutant in mutants:
        mutant_problems = source_problems(teardown_mutant, label)
        if not any("cleanup" in problem for problem in mutant_problems):
            bad(f"{label} survived the per-source teardown oracle: {mutant_problems!r}")
    return list(failures)


def main(argv: list[str]) -> int:
    shim = Path(argv[1]) if len(argv) > 1 else SHIM
    problems = run_rows(shim)
    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        print(f"FAIL\tmac-signal-delivery\t{len(problems)} problem(s)")
        return 1
    print("PASS\tmac-signal-delivery\tS1-S3 C1-C2 M1-M10")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
