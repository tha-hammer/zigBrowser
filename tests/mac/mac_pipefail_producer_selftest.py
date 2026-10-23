#!/usr/bin/env python3
"""RED, UNREGISTERED (bd zigBrowser-3ui.16): producer output must be completed and its status checked
before a matching predicate can stop reading it.

The six production decisions are extracted from the real scripts and executed as bounded hostless
drivers. The gates themselves are never run: in particular, this test NEVER invokes
ms6_5_reaper_gate.sh. For each decision a fake producer runs twice:

* late: write the matching first line, pause so `grep -q` exits, then write a later line and exit 0;
* error: write the same complete matching output, then exit 23.

A correct consumer waits for the complete output, rejects a nonzero producer status, and only then
searches the captured text. The baseline `producer | grep -q` closes the pipe after the first line;
the fake producer receives SIGPIPE before its completion marker and the production decision misses the
Mach-O, forbidden launcher, URL dependency, or shared host.

Covered call sites (late + error, twelve rows):
  P1 ms5_relocate_gate.sh  file -b census
  P2 ms5_stage_gate.sh     file -b census
  P3 ms5_deps_gate.sh      file -b census
  P4 ms5_stage_gate.sh     bin/*-intel64 launcher census
  P5 mac_compile_only.sh   build.zig.zon URL-dependency refusal
  P6 ms6_5_reaper_gate.sh  shared-host refusal (extracted pre-contact block only)

Run: python3 tests/mac/mac_pipefail_producer_selftest.py [repo root]
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

SCRIPTS = {
    "relocate": "tests/mac/ms5_relocate_gate.sh",
    "stage": "tests/mac/ms5_stage_gate.sh",
    "deps": "tests/mac/ms5_deps_gate.sh",
    "compile": "tests/mac/mac_compile_only.sh",
    "reaper": "tests/mac/ms6_5_reaper_gate.sh",
}

PRODUCER = r'''#!/usr/bin/python3
import os
import signal
import sys
import time
from pathlib import Path

signal.signal(signal.SIGPIPE, signal.SIG_DFL)
log = Path(os.environ["ZB_PRODUCER_LOG"])
with log.open("a") as stream:
    stream.write("start\n")
os.write(1, (os.environ["ZB_PRODUCER_FIRST"] + "\n").encode())
time.sleep(0.20)
os.write(1, (os.environ["ZB_PRODUCER_LATE"] + "\n").encode())
with log.open("a") as stream:
    stream.write("complete\n")
if os.environ["ZB_PRODUCER_MODE"] == "error":
    raise SystemExit(23)
'''


def one(text: str, needle: str, label: str) -> int:
    count = text.count(needle)
    if count != 1:
        raise ValueError(f"{label}: want one anchor {needle!r}, found {count}")
    return text.index(needle)


def line_start(text: str, pos: int) -> int:
    return text.rfind("\n", 0, pos) + 1


def after_line(text: str, pos: int) -> int:
    end = text.find("\n", pos)
    if end < 0:
        raise ValueError("anchor has no following line")
    return end + 1


def region(text: str, start_anchor: str, end_anchor: str, label: str) -> str:
    start = line_start(text, one(text, start_anchor, label))
    end = line_start(text, one(text, end_anchor, label))
    if start >= end:
        raise ValueError(f"{label}: reversed anchors")
    return text[start:end]


def extract(root: Path) -> dict[str, str]:
    source = {name: (root / path).read_text() for name, path in SCRIPTS.items()}
    blocks: dict[str, str] = {}
    blocks["relocate-file"] = region(source["relocate"], "unsigned=0", "# 4. and 5. the runtime proof", "P1")
    blocks["stage-file"] = region(source["stage"], "thin=0; while IFS= read -r f; do",
                                   '/usr/bin/python3 - "$d/repo" "$A"', "P2")
    blocks["deps-file"] = region(source["deps"], "thin=0; while IFS= read -r f; do",
                                  "/usr/bin/python3 -I packaging/macos/relocate_python_framework.py", "P3")

    stage = source["stage"]
    fat_at = one(stage, "for c in Python.framework/Versions/3.12/bin/python3.12", "P4")
    start = stage.find("\ndone\n", fat_at)
    if start < 0:
        raise ValueError("P4: the fat-component loop has no closing done")
    start += len("\ndone\n")
    end = line_start(stage, one(stage, "thin=0; while IFS= read -r f; do", "P4"))
    blocks["stage-launcher"] = stage[start:end]

    compile_text = source["compile"]
    odd = one(compile_text, "a shipped path holds a symlink or special entry", "P5")
    start = after_line(compile_text, odd)
    end = line_start(compile_text, one(compile_text, 'grep -q \'"mac-compile-only"\'', "P5"))
    blocks["compile-url"] = compile_text[start:end]

    blocks["reaper-shared"] = region(source["reaper"],
                                      'shared="$HOME/.ntm/zb-release/shared-mac-hosts"',
                                      'stage=$(mktemp -d', "P6")

    forbidden = ("ssh ", "scp ", "curl ", "SIGKILL", "reaper_gate", "./reaper")
    for label, block in blocks.items():
        hits = [word for word in forbidden if word in block]
        if hits:
            raise ValueError(f"{label}: extracted block crosses a contact/destructive boundary: {hits}")
        if not block.strip():
            raise ValueError(f"{label}: extracted an empty block")
    return blocks


def driver(label: str, block: str, case: Path, mode: str) -> tuple[str, int, str, str]:
    fake = case / "fakebin"
    tree = case / "tree"
    if label == "relocate-file":
        pre = f'''set -uo pipefail
PATH={fake}:/usr/bin:/bin
V={tree}; mkdir -p "$V"; : > "$V/candidate"
unsigned=0
ok() {{ printf 'ok %s\n' "$*"; }}
bad() {{ printf 'bad %s\n' "$*"; }}
'''
        post = '''printf 'OBS unsigned=%s\n' "$unsigned"
[ "$unsigned" -eq 1 ]
'''
        return pre + block + post, 0, "Mach-O 64-bit executable", "file metadata complete"
    if label == "stage-file":
        pre = f'''set -uo pipefail
PATH={fake}:/usr/bin:/bin
A={tree}; mkdir -p "$A"; : > "$A/candidate"
fails=0
'''
        want_thin = 1 if mode == "late" else 0
        post = f'''printf 'OBS thin=%s fails=%s\n' "$thin" "$fails"
[ "$thin" -eq {want_thin} ] && [ "$fails" -eq 1 ]
'''
        return pre + block + post, 0, "Mach-O 64-bit executable", "file metadata complete"
    if label == "deps-file":
        pre = f'''set -uo pipefail
PATH={fake}:/usr/bin:/bin
A={tree}; mkdir -p "$A"; : > "$A/candidate"
fails=0
ok() {{ printf 'ok %s\n' "$*"; }}
bad() {{ printf 'bad %s\n' "$*"; fails=$((fails+1)); }}
'''
        want_thin = 1 if mode == "late" else 0
        post = f'''printf 'OBS thin=%s fails=%s\n' "$thin" "$fails"
[ "$thin" -eq {want_thin} ] && [ "$fails" -eq 1 ]
'''
        return pre + block + post, 0, "Mach-O 64-bit executable", "file metadata complete"
    if label == "stage-launcher":
        bindir = tree / "Python.framework/Versions/3.12/bin"
        pre = f'''set -uo pipefail
PATH={fake}:/usr/bin:/bin
A={tree}; mkdir -p {bindir}
fails=0
'''
        post = '''printf 'OBS fails=%s\n' "$fails"
[ "$fails" -eq 1 ]
'''
        return pre + block + post, 0, "python3-intel64", "python3"
    if label == "compile-url":
        pre = f'''set -uo pipefail
PATH={fake}:/usr/bin:/bin
cd {case}
printf '// clean fixture\n' > build.zig.zon
fail() {{ printf 'REFUSED %s\n' "$*"; exit 42; }}
'''
        return pre + block + "exit 0\n", 42, '.url = "https://example.invalid/archive.tar.gz",', "}"
    if label == "reaper-shared":
        home = case / "home"
        pre = f'''set -uo pipefail
PATH={fake}:/usr/bin:/bin
HOME={home}; mkdir -p "$HOME/.ntm/zb-release"
: > "$HOME/.ntm/zb-release/shared-mac-hosts"
INTEL_HOST=user@intel.example
ARM_HOST=user@arm.example
disabled() {{ printf 'REFUSED %s\n' "$*"; exit 42; }}
'''
        return pre + block + "exit 0\n", 42, "intel.example", "unrelated.example"
    raise AssertionError(label)


def install_fakes(case: Path) -> Path:
    fake = case / "fakebin"
    fake.mkdir()
    for name in ("file", "ls", "sed"):
        path = fake / name
        path.write_text(PRODUCER)
        path.chmod(0o700)
    (fake / "lipo").write_text("#!/bin/bash\nprintf 'x86_64\\n'\n")
    (fake / "lipo").chmod(0o700)
    (fake / "codesign").write_text("#!/bin/bash\nexit 1\n")
    (fake / "codesign").chmod(0o700)
    return fake


def run_case(label: str, block: str, mode: str, parent: Path) -> tuple[bool, str]:
    case = parent / f"{label}-{mode}"
    case.mkdir()
    install_fakes(case)
    script, want_rc, first, late = driver(label, block, case, mode)
    script_path = case / "driver.sh"
    script_path.write_text(script)
    log = case / "producer.log"
    env = {
        "PATH": f"{case / 'fakebin'}:/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "TMPDIR": str(case),
        "ZB_PRODUCER_LOG": str(log),
        "ZB_PRODUCER_FIRST": first,
        "ZB_PRODUCER_LATE": late,
        "ZB_PRODUCER_MODE": mode,
    }
    try:
        proc = subprocess.run(["/bin/bash", str(script_path)], cwd=case, env=env,
                              capture_output=True, text=True, timeout=10, check=False)
    except subprocess.TimeoutExpired as exc:
        return False, f"timed out: {exc}"
    events = log.read_text().splitlines() if log.exists() else []
    good = proc.returncode == want_rc and events == ["start", "complete"]
    detail = (f"rc={proc.returncode}, want={want_rc}, producer={events!r}"
              f"\nstdout={proc.stdout[-500:]!r}\nstderr={proc.stderr[-500:]!r}")
    return good, detail


def main(argv: list[str]) -> int:
    root = Path(argv[1]).resolve() if len(argv) > 1 else ROOT
    try:
        blocks = extract(root)
    except (OSError, ValueError) as exc:
        print(f"FAIL mac-pipefail-producer-selftest extraction: {exc}")
        return 1

    failures = 0
    with tempfile.TemporaryDirectory(prefix="zb-pipefail-producer-") as tmp:
        parent = Path(tmp)
        for label, block in blocks.items():
            for mode in ("late", "error"):
                good, detail = run_case(label, block, mode, parent)
                if good:
                    print(f"PASS {label}-{mode}")
                else:
                    failures += 1
                    print(f"FAIL {label}-{mode}: {detail}")
    if failures:
        print(f"FAIL mac-pipefail-producer-selftest {failures}/12 row(s)")
        return 1
    print("PASS mac-pipefail-producer-selftest 12/12 rows")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
