#!/usr/bin/env python3
"""No Windows source of ours uses `min` or `max` where the MSVC SDK's macros would expand (hermetic, Linux).

The Windows SDK's minwindef.h (pulled in by <windows.h> on the MSVC target the Win11 VM builds) defines the
function-like macros min(a,b) and max(a,b) unless NOMINMAX is set. The MinGW headers this repo's Linux checks use do
not define them for C++, so `std::min(a, b)` compiled here and broke the VM build: webview2_shim.cpp:1246
"expected unqualified-id" (WS2b.1 leg 1 at 61a72c8, release f28c52a).

For every source under src/ that includes <windows.h> (and, for webview2_shim.cpp, its WS2a.3 slice build too),
this preprocesses the file twice for x86_64-windows-gnu with zig: as is, and with minwindef.h-style min/max macros
forced in (-include). The WebView2 and WRL headers are empty stand-ins (preprocessing needs no types). The file's
own lines must come out identical: a line that differs is a place where one of the macros expanded, which the MSVC
build cannot compile. A planted std::min must be reported, so the check cannot pass by finding nothing.

Run:  python3 -I tests/windows/msvc_minmax_test.py [--zig <zig>]
"""
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
STAND_INS = ("wrl.h", "WebView2.h", "WebView2EnvironmentOptions.h")
MINMAX = ("#ifndef min\n#define min(a,b) (((a) < (b)) ? (a) : (b))\n#endif\n"
          "#ifndef max\n#define max(a,b) (((a) > (b)) ? (a) : (b))\n#endif\n")  # as minwindef.h, without NOMINMAX
BUILDS = {"src/webview2_shim.cpp": ((), ("-DZB_WS2A3_SEAMS",))}

ZIG = "zig"
if "--zig" in sys.argv:
    i = sys.argv.index("--zig")
    ZIG = sys.argv[i + 1]
    del sys.argv[i:i + 2]


def windows_sources():
    return sorted(p for p in (REPO / "src").iterdir()
                  if p.suffix in (".c", ".cpp") and re.search(r"^\s*#\s*include\s*<windows\.h>", p.read_text(
                      encoding="utf-8", errors="replace"), re.M))


def own_lines(path, extra):
    """{source line number: text} of `path`'s own lines after preprocessing with `extra` flags."""
    with tempfile.TemporaryDirectory(prefix="zb-minmax-") as stub:
        for name in STAND_INS:
            pathlib.Path(stub, name).write_text("/* stand-in: the SDK is not on Linux */\n")
        lang = ["-std=c++17"] if path.suffix == ".cpp" else ["-std=c11"]
        cmd = [ZIG, "c++" if path.suffix == ".cpp" else "cc", "-target", "x86_64-windows-gnu", *lang, "-E",
               "-I", stub, "-I", str(REPO / "src"), *extra, str(path)]
        proc = subprocess.run(cmd, cwd=stub, capture_output=True, text=True, timeout=300)
    if proc.returncode != 0:
        raise AssertionError(f"preprocessing failed ({' '.join(cmd)}):\n{proc.stderr[-3000:]}")
    marker = re.compile(r'^# (\d+) "([^"]*)"')
    lines, keep, n = {}, False, 0
    for line in proc.stdout.splitlines():
        m = marker.match(line)
        if m:
            n, keep = int(m.group(1)), pathlib.Path(m.group(2)).name == path.name
            continue
        if keep:
            if line.strip():
                lines[n] = line
            n += 1
    return lines


def expansions(path, defines=()):
    """Source lines of `path` where the forced min/max macros changed the preprocessed text."""
    with tempfile.TemporaryDirectory(prefix="zb-minmax-h-") as d:
        header = pathlib.Path(d, "zb_msvc_minmax.h")
        header.write_text(MINMAX)
        plain = own_lines(path, list(defines))
        forced = own_lines(path, [*defines, "-include", str(header)])
    return sorted(n for n in set(plain) | set(forced) if plain.get(n) != forced.get(n))


class MsvcMinMax(unittest.TestCase):
    def test_the_check_reports_a_planted_std_min(self):
        with tempfile.TemporaryDirectory(prefix="zb-minmax-plant-") as d:
            plant = pathlib.Path(d, "plant.cpp")
            plant.write_text("#include <windows.h>\nint ok(int a, int b) { return a < b ? a : b; }\n"
                             "int bad(int a, int b) { return std::min(a, b); }\n")
            self.assertEqual(expansions(plant), [3], "a std::min on line 3 must be reported")

    def test_the_scan_covers_the_windows_sources(self):
        names = {p.name for p in windows_sources()}
        self.assertTrue({"webview2_shim.cpp", "agent_secrets_win.cpp"} <= names, f"scan found only {sorted(names)}")

    def test_no_windows_source_expands_the_msvc_min_max_macros(self):
        found = {}
        for path in windows_sources():
            rel = path.relative_to(REPO).as_posix()
            for defines in BUILDS.get(rel, ((),)):
                hits = expansions(path, defines)
                if hits:
                    found[f"{rel} {' '.join(defines) or '(product)'}"] = hits
        self.assertFalse(found, f"min/max used where the MSVC SDK macros expand (lines): {found}; "
                                f"write the comparison out, or (std::min)(a, b)")


if __name__ == "__main__":
    unittest.main()
