"""MS7 compiled two-Mac hard gate (RoseCat c6b2b32 items 2-4): ONE leg, run ON a Mac by tests/mac/ms7_appkit_gate.sh,
from the exported commit (the current directory) inside the per-run directory the launcher made.

usage: python3 -I -B tests/mac/ms7_appkit_case.py <run dir> <arch: x86_64|arm64> <zig>

Every child runs through tests/mac/hard_gate/harness.py's Harness.spawn_group: its own process group, bounded, the group
SIGKILLed exactly once after its leader exits or times out (the reviewed MS6 kill safety). Nothing is installed; every
file stays under <run dir>, which the launcher deletes.
1. Build natively (no -Dtarget: the SDK resolves), with a logging `xcrun` first on PATH that records every argv the
   build runs (the record is the evidence; it then execs /usr/bin/xcrun).
2. Preprocess the drawer and the shim with the production argv's preprocessing flags (`xcrun clang -E -fobjc-arc -I src`).
3. `nm` the executable and the shipped dylib.
4. Build the test-only probe (tests/mac/ms7_appkit_probe.m) and run the real app with it injected
   (DYLD_INSERT_LIBRARIES): a throwaway HOME and --profile-dir under <run dir>, --agent-drawer on, a local file: page,
   no credential, no live network.
5. Judge with tests/mac/ms7_appkit_check.py; print each bounded assertion and the leg's verdict as its last line:
   `PASS\tms7-appkit\t<arch>` or `FAIL\tms7-appkit\t<arch>`.
A process census (zigBrowser processes of this user) before and after must match: nothing left behind."""
import hashlib
import json
import os
import sys
from pathlib import Path

REPO = Path.cwd()
sys.path.insert(0, str(REPO / "tests/mac/hard_gate"))
sys.path.insert(0, str(REPO / "tests/mac"))
sys.path.insert(0, str(REPO / "tests/e2e"))
from harness import Harness  # noqa: E402  the reviewed group-owning spawner
import ms7_appkit_check as check  # noqa: E402

BUILD_S, TOOL_S, APP_S = 1200, 120, 240
XCRUN_LOGGER = """#!/bin/sh
{ for a in "$@"; do printf '%s\\0' "$a"; done; printf '\\001\\0'; } >> "$ZB_XCRUN_LOG"
exec /usr/bin/xcrun "$@"
"""


def say(line):
    print(line, flush=True)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def argv_records(raw):
    """The logging xcrun's records: NUL-separated arguments, each argv ended by a \\x01 field."""
    out, cur = [], []
    for field in raw.split(b"\0")[:-1]:
        if field == b"\x01":
            out.append([f.decode("utf-8", "replace") for f in cur])
            cur = []
        else:
            cur.append(field)
    return out


def own_zigbrowsers(h):
    code, out, _ = h.spawn_group(["/usr/bin/pgrep", "-x", "-U", str(os.getuid()), "zigBrowser"], timeout=TOOL_S)
    return sorted(out.split()) if code in (0, 1) else None


def symbols(h, args):
    code, out, err = h.spawn_group(["/usr/bin/nm"] + args, timeout=TOOL_S)
    if code != 0:
        return None
    return sorted({line.split()[-1].decode() for line in out.splitlines() if line.split()})


def run(run_dir, arch, zig):
    d = Path(run_dir)
    h = Harness(str(d / "scratch"))
    os.makedirs(h.scratch, exist_ok=True)
    say(f"== ms7-appkit leg {arch} at {REPO}")
    before = own_zigbrowsers(h)
    ev = {"argv": [], "nm": {}}
    try:
        # 1. the native production build, every xcrun argv recorded
        shim_dir = d / "argv-shim"
        shim_dir.mkdir()
        logger = shim_dir / "xcrun"
        logger.write_text(XCRUN_LOGGER)
        logger.chmod(0o755)
        env = {"PATH": f"{shim_dir}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(d / "home"), "LANG": "C.UTF-8",
               "ZB_XCRUN_LOG": str(d / "xcrun.argv")}
        (d / "home").mkdir()
        code, out, err = h.spawn_group([zig, "build", "--cache-dir", str(d / "zc"), "--global-cache-dir", str(d / "zgc")],
                                       env=env, timeout=BUILD_S)
        h.check(code == 0, f"the native build succeeded ({code}): {err[-400:].decode('utf-8', 'replace')}")
        raw = (d / "xcrun.argv").read_bytes() if (d / "xcrun.argv").exists() else b""
        ev["argv"] = [check.normalize(a, str(REPO), "") for a in argv_records(raw)]
        for a in check.shim_compiles(ev["argv"]):
            say(f"== argv {digest(chr(0).join(a).encode())} {' '.join(a)}")
        exe, dylib = REPO / "zig-out/bin/zigBrowser", REPO / "zig-out/Frameworks/libwkwebview_shim.dylib"
        for f in (exe, dylib, REPO / "src/agent_drawer_mac.m", REPO / "src/wkwebview_shim.m"):
            say(f"== digest {digest(f.read_bytes()) if f.exists() else 'missing'} {f.relative_to(REPO)}")
        # 2. the preprocessor's view of the drawer and the shim
        for key, src in (("pre_drawer", "src/agent_drawer_mac.m"), ("pre_shim", "src/wkwebview_shim.m")):
            code, out, err = h.spawn_group(["/usr/bin/xcrun", "clang", "-E", "-fobjc-arc", "-I", "src", src], env=env,
                                           timeout=TOOL_S)
            ev[key] = out.decode("utf-8", "replace") if code == 0 else ""
            say(f"== preprocessed {digest(out)} {src} ({code})")
        # 3. the link census
        ev["nm"] = {"exe_undefined": symbols(h, ["-u", str(exe)]) or [],
                    "exe_defined": symbols(h, ["-gU", str(exe)]) or [],
                    "dylib_undefined": symbols(h, ["-u", str(dylib)]) or []}
        # 4. the probe, in the real app
        probe = d / "probe.dylib"
        code, _, err = h.spawn_group(["/usr/bin/xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-framework", "Cocoa",
                                      "-framework", "WebKit", "tests/mac/ms7_appkit_probe.m", "-o", str(probe)],
                                     env=env, timeout=TOOL_S)
        h.check(code == 0, f"the probe built ({code}): {err[-400:].decode('utf-8', 'replace')}")
        data = d / "probe-in"
        data.mkdir()
        for label, original in check.originals().items():
            (data / f"{label}.bin").write_bytes(original)
        (data / "page.txt").write_text(check.PAGE_TEXT)
        page = d / "page.html"
        page.write_text(f'<!doctype html><meta charset="utf-8"><p id="t">{check.PAGE_TEXT}</p>\n')
        app_env = dict(env, DYLD_INSERT_LIBRARIES=str(probe), ZB_MS7_PROBE_DIR=str(data),
                       ZB_MS7_PROBE_OUT=str(d / "probe.json"))
        code, out, err = h.spawn_group([str(exe), "--profile-dir", str(d / "profile"), "--agent-drawer", "on",
                                        page.as_uri()], env=app_env, timeout=APP_S)
        say(f"== app exited {code}")
        ev["report"] = check.load_report(d / "probe.json") if (d / "probe.json").exists() else None
    finally:
        h.close()
    for finding in check.problems(ev, arch):
        h.check(False, finding)
    h.check(True, "the evidence was judged")
    h2 = Harness(str(d / "scratch"))
    try:
        after = own_zigbrowsers(h2)
    finally:
        h2.close()
    h.check(before is not None and before == after, f"no zigBrowser left behind ({before} -> {after})")
    verdict = "PASS" if not h.failures else "FAIL"
    say(f"{verdict}\tms7-appkit\t{arch}")
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[2] not in check.ARCHES:
        say("FAIL\tms7-appkit\tusage: ms7_appkit_case.py <run dir> <x86_64|arm64> <zig>")
        sys.exit(2)
    sys.exit(run(*sys.argv[1:]))
