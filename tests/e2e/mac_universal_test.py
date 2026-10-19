#!/usr/bin/env python3
"""MS1 universal-build + two-arch gate assertions (plan rev 6, ed13e5e).

Runs ON a macOS build/test host (invoked by tests/mac/gate.sh over Tailscale SSH).
It proves the four MS1 behaviors and, critically, FAILS CLOSED: any missing
prerequisite, any unsatisfiable check, or zero executed assertions exits NONZERO.
A "SKIP" is never allowed to turn the gate green (MS1.4).

Behaviors:
  MS1.1  the installed binary and every bundled native component are fat Mach-O
         with BOTH slices (x86_64 + arm64).
  MS1.2  executing-arch proof (no Rosetta false-green): uname -m matches the
         expected arch; on arm64 `sysctl.proc_translated` is 0; and the running
         app reported its EXECUTING arch over the socket (passed in via
         --reported-arch by gate.sh, which does the socket round-trip). lipo
         -archs + --version alone do NOT pass — the runtime readback is required.
  MS1.3  packaging/macos/entitlements.plist exists and lists EXACTLY the keys that
         `codesign -d --entitlements -` reports on the ad-hoc-signed binary.
  MS1.4  fail-closed on missing GUI/arch/SDK/zero-assertions.

RED today: no universal artifact, no entitlements in the signature, and no
runtime arch readback exist yet, so every positive assertion fails until MS1 is
implemented. GREEN is only observable on the Mac; this file is prepared, not yet
committed, until the Intel Mac is reachable.
"""
import argparse
import plistlib
import subprocess
import sys
from pathlib import Path

ARM = "arm64"
INTEL = "x86_64"
BOTH = {ARM, INTEL}


class FailClosed(Exception):
    """Any condition that must make the gate exit nonzero (never skip-to-green)."""


class Checks:
    def __init__(self) -> None:
        self.ran = 0
        self.failures: list[str] = []

    def ok(self, cond: bool, msg: str) -> None:
        self.ran += 1
        if not cond:
            self.failures.append(msg)

    def done(self) -> int:
        # MS1.4: zero assertions is itself a fail-closed condition.
        if self.ran == 0:
            print("NOT RUN: zero assertions executed — fail closed", file=sys.stderr)
            return 3
        if self.failures:
            for f in self.failures:
                print(f"FAIL: {f}", file=sys.stderr)
            print(f"mac_universal_test: {len(self.failures)}/{self.ran} assertions failed", file=sys.stderr)
            return 1
        print(f"PASS\tmac-universal\t{self.ran} assertions")
        return 0


def _run(cmd: list[str]) -> str:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except FileNotFoundError as e:
        raise FailClosed(f"required tool missing: {cmd[0]} ({e})")
    except subprocess.TimeoutExpired:
        raise FailClosed(f"timed out: {' '.join(cmd)}")
    if out.returncode != 0:
        raise FailClosed(f"command failed ({out.returncode}): {' '.join(cmd)}\n{out.stderr.strip()}")
    return out.stdout


def lipo_archs(path: Path) -> set[str]:
    return set(_run(["lipo", "-archs", str(path)]).split())


def codesign_entitlement_keys(path: Path) -> set[str]:
    xml = _run(["codesign", "-d", "--entitlements", ":-", "--xml", str(path)])
    if not xml.strip():
        return set()
    try:
        data = plistlib.loads(xml.encode())
    except Exception as e:  # noqa: BLE001 - any parse failure is fail-closed
        raise FailClosed(f"could not parse codesign entitlements: {e}")
    return set(data.keys()) if isinstance(data, dict) else set()


def manifest_keys(entitlements: Path) -> set[str]:
    if not entitlements.is_file():
        raise FailClosed(f"entitlements manifest missing: {entitlements}")
    with entitlements.open("rb") as fh:
        data = plistlib.load(fh)
    return set(data.keys()) if isinstance(data, dict) else set()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True, help="installed universal browser binary")
    ap.add_argument("--component", action="append", default=[],
                    help="a bundled native component that must also be fat (repeatable)")
    ap.add_argument("--expect-arch", required=True, choices=sorted(BOTH),
                    help="the arch THIS host must natively execute")
    ap.add_argument("--entitlements", required=True, help="packaging/macos/entitlements.plist")
    ap.add_argument("--reported-arch", default=None,
                    help="arch the running app reported over the socket (gate.sh supplies it); "
                         "its ABSENCE fails MS1.2 closed — it is never optional")
    args = ap.parse_args()

    c = Checks()
    try:
        binary = Path(args.binary)
        if not binary.is_file():
            raise FailClosed(f"browser binary not found: {binary} (no build / wrong host)")

        # MS1.1 — universal binary + every bundled component is fat with both slices.
        c.ok(lipo_archs(binary) == BOTH, f"binary not fat with both slices: {binary}")
        for comp in args.component:
            p = Path(comp)
            if not p.is_file():
                raise FailClosed(f"declared component missing: {p}")
            c.ok(lipo_archs(p) == BOTH, f"component not fat with both slices: {p}")

        # MS1.2 — executing-arch proof; lipo alone is not enough.
        uname_m = _run(["uname", "-m"]).strip()
        norm = ARM if uname_m in ("arm64", "aarch64") else uname_m
        c.ok(norm == args.expect_arch, f"uname -m {uname_m!r} != expected {args.expect_arch!r}")
        if args.expect_arch == ARM:
            translated = _run(["sysctl", "-n", "sysctl.proc_translated"]).strip()
            c.ok(translated == "0", f"process is translated (Rosetta): proc_translated={translated!r}")
        # The runtime readback is MANDATORY — missing means fail closed, not skip.
        if args.reported_arch is None:
            raise FailClosed("MS1.2: no --reported-arch (app did not report executing arch "
                             "over the socket); lipo/--version alone cannot pass")
        c.ok(args.reported_arch == args.expect_arch,
             f"app reported arch {args.reported_arch!r} != executing {args.expect_arch!r}")

        # MS1.3 — the manifest is the single source of truth; the signature matches it exactly.
        want = manifest_keys(Path(args.entitlements))
        c.ok(bool(want), "entitlements manifest has no keys")
        got = codesign_entitlement_keys(binary)
        c.ok(got == want, f"signed entitlements {sorted(got)} != manifest {sorted(want)}")
    except FailClosed as e:
        print(f"NOT RUN / FAIL CLOSED: {e}", file=sys.stderr)
        return 2

    return c.done()


if __name__ == "__main__":
    sys.exit(main())
