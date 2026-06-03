#!/usr/bin/env python3
"""Slice 5 Windows MSI build/install gate over the Win11 guest."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

from slice2_common import SKIP_EXIT, eprint


DEFAULT_KEY = Path("/home/maceo/vms/win11-m8/zb_guest_key")
DEFAULT_HOST = "maceo@100.103.8.90"
REMOTE_ROOT = r"$env:USERPROFILE\zigBrowser"


def run(cmd: list[str], *, timeout: float = 120.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def skip(msg: str) -> int:
    eprint(f"SKIP: {msg}")
    return SKIP_EXIT


def parse_last_json(stdout: str) -> dict:
    for line in reversed(stdout.splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        return json.loads(line)
    raise ValueError(f"no JSON object in stdout:\n{stdout}")


def make_tarball(root: Path) -> Path:
    tmp = Path(tempfile.mkdtemp(prefix="zb-msi-sync-")) / "worktree.tar"
    includes = [
        "src",
        "build.zig",
        "build.zig.zon",
        "tests",
        "packaging/windows",
        "packaging/assets",
    ]
    with tarfile.open(tmp, "w") as tar:
        for rel in includes:
            path = root / rel
            if path.exists():
                tar.add(path, arcname=rel)
    return tmp


def ssh_base(key: Path) -> list[str]:
    return ["ssh", "-i", str(key), "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=no"]


def scp_base(key: Path) -> list[str]:
    return ["scp", "-i", str(key), "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=no"]


def sync_to_guest(root: Path, host: str, key: Path) -> bool:
    tarball = make_tarball(root)
    mkdir = run(
        ssh_base(key)
        + [
            host,
            "powershell -NoProfile -ExecutionPolicy Bypass -Command "
            "\"New-Item -ItemType Directory -Force -Path $env:USERPROFILE\\zigBrowser | Out-Null\"",
        ],
        timeout=30,
    )
    if mkdir.returncode != 0:
        eprint(mkdir.stderr.strip() or mkdir.stdout.strip())
        return False

    copied = run(scp_base(key) + [str(tarball), f"{host}:zigBrowser/zb_slice5_windows.tar"], timeout=60)
    if copied.returncode != 0:
        eprint(copied.stderr.strip() or copied.stdout.strip())
        return False

    extracted = run(
        ssh_base(key)
        + [
            host,
            "powershell -NoProfile -ExecutionPolicy Bypass -Command "
            "\"tar -xf $env:USERPROFILE\\zigBrowser\\zb_slice5_windows.tar -C $env:USERPROFILE\\zigBrowser\"",
        ],
        timeout=60,
    )
    if extracted.returncode != 0:
        eprint(extracted.stderr.strip() or extracted.stdout.strip())
        return False
    return True


def remote_powershell(host: str, key: Path, script: str, timeout: float) -> subprocess.CompletedProcess[str]:
    command = f"powershell -NoProfile -ExecutionPolicy Bypass -Command \"{script}\""
    return run(ssh_base(key) + [host, command], timeout=timeout)


def copy_back_artifacts(root: Path, host: str, key: Path) -> None:
    local_dist = root / "packaging" / "windows" / "dist"
    local_dist.mkdir(parents=True, exist_ok=True)
    remote_glob = f"{host}:zigBrowser/packaging/windows/dist/*"
    run(scp_base(key) + [remote_glob, str(local_dist)], timeout=60)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=os.environ.get("ZB_GUEST_HOST", DEFAULT_HOST))
    parser.add_argument("--key", type=Path, default=Path(os.environ.get("ZB_GUEST_KEY", str(DEFAULT_KEY))))
    parser.add_argument("--url", default="")
    parser.add_argument("--keep-installed", action="store_true")
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()

    root = repo_root()
    if not args.key.exists():
        return skip(f"missing Win11 guest key: {args.key}")
    if shutil.which("ssh") is None or shutil.which("scp") is None:
        return skip("ssh/scp are required for the Win11 guest gate")

    probe = run(ssh_base(args.key) + [args.host, "powershell -NoProfile -Command \"Test-Path C:\\Users\\maceo\\WiX314\\candle.exe; Test-Path C:\\Users\\maceo\\WiX314\\light.exe\""], timeout=20)
    if probe.returncode != 0:
        return skip(f"cannot reach Win11 guest: {probe.stderr.strip() or probe.stdout.strip()}")
    if "True" not in probe.stdout:
        return skip("WiX v3.14 is not installed at C:\\Users\\maceo\\WiX314")

    if not sync_to_guest(root, args.host, args.key):
        return 1

    build_args = "-SkipZigBuild" if args.skip_build else ""
    build_script = (
        f"cd {REMOTE_ROOT}; "
        f"& .\\packaging\\windows\\build-msi.ps1 {build_args}"
    )
    build = remote_powershell(args.host, args.key, build_script, timeout=300)
    if build.returncode != 0:
        eprint("MSI build failed")
        eprint(build.stdout)
        eprint(build.stderr)
        return 1

    try:
        build_json = parse_last_json(build.stdout)
    except (ValueError, json.JSONDecodeError) as exc:
        eprint(f"failed parsing build JSON: {exc}")
        eprint(build.stdout)
        return 1

    gate_flags = "-KeepInstalled" if args.keep_installed else ""
    url_arg = "" if not args.url else f"-Url '{args.url.replace(chr(39), chr(39) + chr(39))}'"
    gate_script = (
        f"cd {REMOTE_ROOT}; "
        f"& .\\packaging\\windows\\gate.ps1 {gate_flags} {url_arg}"
    )
    gate = remote_powershell(args.host, args.key, gate_script, timeout=180)
    if gate.returncode != 0:
        eprint("MSI install gate failed")
        eprint(gate.stdout)
        eprint(gate.stderr)
        return 1

    try:
        gate_json = parse_last_json(gate.stdout)
    except (ValueError, json.JSONDecodeError) as exc:
        eprint(f"failed parsing gate JSON: {exc}")
        eprint(gate.stdout)
        return 1

    if build_json.get("ProductVersion") != "0.1.0":
        eprint(f"wrong ProductVersion: {build_json.get('ProductVersion')}")
        return 1
    if not gate_json.get("ScreenshotNonUniform"):
        eprint("installed-app screenshot was not non-uniform")
        return 1
    if "WebView2" not in str(gate_json.get("VersionLine", "")):
        eprint(f"installed --version did not mention WebView2: {gate_json.get('VersionLine')}")
        return 1

    copy_back_artifacts(root, args.host, args.key)
    print("PASS\tmsi-install-gate")
    print(json.dumps({"build": build_json, "gate": gate_json}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
