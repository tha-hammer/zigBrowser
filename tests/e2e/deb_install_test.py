#!/usr/bin/env python3
"""Slice 5 Linux .deb install gate: clean container installs and screenshots."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

SKIP_EXIT = 77


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)


def require_tool(name: str) -> bool:
    if shutil.which(name) is not None:
        return True
    print(f"SKIP: missing {name}", file=sys.stderr)
    return False


def main() -> int:
    repo = Path(__file__).resolve().parents[2]
    build_script = repo / "packaging/linux/build-deb.sh"
    gate_script = repo / "packaging/linux/gate.sh"
    deb = repo / "zigBrowser_0.1.0_amd64.deb"

    if not require_tool("dpkg-deb"):
        return SKIP_EXIT
    if shutil.which("docker") is None and shutil.which("podman") is None:
        print("SKIP: missing docker or podman", file=sys.stderr)
        return SKIP_EXIT

    build = run([str(build_script)], repo)
    if build.returncode != 0:
        print("FAIL\tdeb-build")
        print(build.stdout, file=sys.stderr)
        print(build.stderr, file=sys.stderr)
        return 1

    info = run(["dpkg-deb", "--info", str(deb)], repo)
    contents = run(["dpkg-deb", "--contents", str(deb)], repo)
    if info.returncode != 0 or contents.returncode != 0:
        print("FAIL\tdpkg-deb-inspect")
        print(info.stdout + info.stderr + contents.stdout + contents.stderr, file=sys.stderr)
        return 1

    info_text = info.stdout + info.stderr
    contents_text = contents.stdout + contents.stderr
    required_info = [
        "Package: zigbrowser",
        "Version: 0.1.0",
        "Architecture: amd64",
        "Depends: libwebkit2gtk-4.1-0, libgtk-3-0",
    ]
    required_paths = [
        "./usr/bin/zigBrowser",
        "./usr/share/applications/zigBrowser.desktop",
        "./usr/share/icons/hicolor/256x256/apps/zigBrowser.png",
    ]
    if not all(item in info_text for item in required_info):
        print("FAIL\tdeb-metadata")
        print(info_text, file=sys.stderr)
        return 1
    if not all(item in contents_text for item in required_paths):
        print("FAIL\tdeb-contents")
        print(contents_text, file=sys.stderr)
        return 1

    gate = run([str(gate_script), str(deb)], repo)
    if gate.returncode != 0:
        print("FAIL\tdeb-container-gate")
        print(gate.stdout, file=sys.stderr)
        print(gate.stderr, file=sys.stderr)
        return 1

    print("PASS\tdeb-install-clean-container")
    print(gate.stdout.strip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
