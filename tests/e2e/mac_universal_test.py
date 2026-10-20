#!/usr/bin/env python3
"""MS1 universal-build + two-arch gate assertions (plan rev 6, ed13e5e).

Runs ON a macOS build/test host (invoked by tests/mac/gate.sh over Tailscale SSH).
It proves the four MS1 behaviors and, critically, FAILS CLOSED: any missing
prerequisite, any unsatisfiable check, or zero executed assertions exits NONZERO.
A "SKIP" is never allowed to turn the gate green (MS1.4).

Behaviors:
  MS1.1  a COMPLETE component census (no false-green): the bundle is scanned for
         EVERY Mach-O and each must be fat (x86_64 + arm64), so an unlisted
         single-arch binary cannot sneak through; and every required role in the
         inventory (packaging/macos/universal_components.json) must be present AT
         ITS EXACT PATH PATTERN, so a stray `python3`/`claude`/`zb-claude` in the
         wrong place cannot satisfy a role. Probing fails CLOSED: if `file` cannot
         classify a bundled file, the whole census is rejected (never dropped).
         The inventory must be nonempty; a zero-Mach-O bundle is itself
         fail-closed. Non-executable resources must be present, and their
         byte-compatibility across the two per-arch trees is checked by the pure
         `resource_compat` oracle before `lipo -create` (plan:396-401) — the green
         packaging step routes both trees through it (tests/e2e/mac_resource_compat.py).
  MS1.2  executing-arch proof (no Rosetta false-green): uname -m matches the
         expected arch; on arm64 `sysctl.proc_translated` is 0; and the running
         app reported its EXECUTING arch over the socket (passed in via
         --reported-arch by gate.sh, which does the socket round-trip). lipo
         -archs + --version alone do NOT pass — the runtime readback is required.
  MS1.3  packaging/macos/entitlements.plist exists and lists EXACTLY the keys that
         `codesign -d` reports on the ad-hoc-signed binary.
  MS1.4  fail-closed on missing GUI/arch/SDK/zero-assertions.

The census logic (`census_scan`, `component_census`, `resource_compat`) is pure so
it can be exercised off-Mac with fixtures (tests/e2e/mac_universal_census_test.py):
a probe failure, a missing/wrong-located component, a single-arch component, an
empty bundle/inventory, and a mismatched resource must each fail.
"""
import argparse
import fnmatch
import json
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


def path_matches(rel: str, pattern: str) -> bool:
    """Segment-wise glob match: the path and the pattern must have the SAME number of
    '/'-separated segments and each segment must fnmatch, so a `*` NEVER crosses a '/'
    and a wrong-DEPTH decoy cannot satisfy a role (RoseCat 5977 SHOULD 1). `PurePath.
    full_match` would do this but is 3.13+; this works on the Mac's python3.9."""
    rel_parts = rel.split("/")
    pat_parts = pattern.split("/")
    return len(rel_parts) == len(pat_parts) and all(
        fnmatch.fnmatch(rp, pp) for rp, pp in zip(rel_parts, pat_parts))


def probe_archs(path: str, run=None):
    """FAIL-CLOSED Mach-O probe. Returns the arch set if `path` is Mach-O, None if it
    is definitively NOT Mach-O, and raises FailClosed if `file` cannot classify it
    (nonzero rc, any stderr, a 'cannot open' message, or a timeout — a wedged probe
    must not hang, MS1.4/RoseCat 5977 SHOULD 2) — an unprobeable file must reject the
    census, never silently drop out of it (RoseCat 5974)."""
    def _default(cmd):
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    runner = run or _default
    try:
        r = runner(["file", "-b", "--", str(path)])
    except subprocess.TimeoutExpired:
        raise FailClosed(f"timed out probing file type of {path} (a wedged probe must not hang)")
    out = (r.stdout or "")
    err = (r.stderr or "")
    if r.returncode != 0 or err.strip() or "cannot open" in out.lower() or "error" in err.lower():
        raise FailClosed(f"could not probe file type of {path} (rc={r.returncode}): "
                         f"{out.strip()} {err.strip()}".strip())
    if "Mach-O" not in out:
        return None
    return lipo_archs(Path(path))


def census_scan(entries, probe) -> dict[str, set[str]]:
    """Pure scan: `entries` is [(rel, abspath), ...]; `probe` maps an abspath to its
    arch set, None (not Mach-O), or raises FailClosed (unprobeable). A probe failure
    PROPAGATES, rejecting the whole bundle. Returns {rel: archs} for the Mach-O found."""
    found: dict[str, set[str]] = {}
    for rel, ab in entries:
        archs = probe(ab)
        if archs is not None:
            found[rel] = archs
    return found


def scan_macho(root: Path, probe=probe_archs) -> dict[str, set[str]]:
    """Every real (non-symlink) file under `root`, probed fail-closed. Scanning the
    WHOLE bundle — not a caller-supplied list — makes the census complete."""
    entries = [(str(p.relative_to(root)), str(p))
               for p in sorted(root.rglob("*")) if p.is_file() and not p.is_symlink()]
    return census_scan(entries, probe)


def load_inventory(path: Path) -> dict:
    if not path.is_file():
        raise FailClosed(f"component inventory missing: {path}")
    with path.open("rb") as fh:
        data = json.load(fh)
    comps = data.get("components") or []
    resources = data.get("resources") or []
    # MS1.1: the inventory must be nonempty — an empty required set would let a green
    # pass with nothing checked (the false-green RoseCat 5968 blocked).
    if not comps:
        raise FailClosed(f"component inventory lists no required components: {path}")
    for comp in comps:
        if not comp.get("path_glob"):
            raise FailClosed(f"inventory component without a 'path_glob' (SHOULD, 5974): {comp}")
    return {"components": comps, "resources": resources}


def component_census(macho_archs: dict[str, set[str]], inventory: dict,
                     resource_present, c: Checks) -> None:
    """Pure census (MS1.1). `macho_archs`: every bundled Mach-O -> its arch slices.
    `resource_present`: rel-path -> bool. Fails closed on an empty bundle, any
    non-fat Mach-O, any required role absent AT ITS PATH PATTERN, or any missing
    declared resource."""
    c.ok(bool(macho_archs), "no Mach-O found in the bundle (nothing to verify — fail closed)")
    for rel, archs in sorted(macho_archs.items()):
        c.ok(archs == BOTH, f"not fat (both slices): {rel} has {sorted(archs) or 'none'}")
    rels = list(macho_archs)
    for comp in inventory["components"]:
        glob = comp["path_glob"]
        # Match the full relative path pattern, not just a basename: a same-named
        # Mach-O in the wrong location does NOT satisfy the role (SHOULD, 5974).
        present = any(path_matches(rel, glob) for rel in rels)
        c.ok(present, f"required component {comp.get('role', glob)!r} not a fat Mach-O "
                      f"at its expected location {glob!r}")
    for res in inventory["resources"]:
        c.ok(resource_present(res["path"]),
             f"required resource {res.get('role', res['path'])!r} missing: {res['path']}")


# MS1.1 resource-phase policy (RoseCat 5995/6002): an empty resource inventory is a typed,
# fail-closed state, not a skip. It is accepted ONLY for the EXACT browser-only MS1 bundle —
# milestone `MS1` AND exactly one component, the browser, at the fixed browser path, AND no
# resources. Checking the `--milestone` label alone was a bypass: an MS5-shaped manifest
# (python-runtime/claude-cli, no resources) relabeled MS1 wrongly passed (RoseCat 6002). Every
# other shape with no resources — MS5, an extra/non-browser component, an unknown label — fails
# closed, so the empty-allowed exception cannot be confused with deleting the resource check.
MS1_MILESTONE = "MS1"
MS1_BROWSER_GLOB = "bin/zigBrowser"
MS1_SHIM_GLOB = "Frameworks/libwkwebview_shim.dylib"
# The exact MS1 component set with no resources (RoseCat 6002, extended for the MS1b shim dylib):
# the browser exe plus the WKWebView ObjC shim dylib, nothing else.
MS1_COMPONENT_GLOBS = {MS1_BROWSER_GLOB, MS1_SHIM_GLOB}


def resource_phase(milestone: str, inventory: dict, tree_a: dict[str, str],
                   tree_b: dict[str, str], c: Checks) -> None:
    """The typed phase gate around `resource_compat`, taking the WHOLE inventory. With no
    declared resources, pass ONLY for the exact browser+shim MS1 bundle (milestone MS1 + exactly the
    two components {browser at bin/zigBrowser, shim dylib at Frameworks/libwkwebview_shim.dylib} + no
    resources); otherwise fail closed. With resources, run the two-tree oracle. The green invokes
    this at every milestone (MS1 included — CALLED, not skipped), so the empty-allowed state is
    explicit, shape-checked and mutation-resistant."""
    required = inventory.get("resources") or []
    if not required:
        comps = inventory.get("components") or []
        globs = [x.get("path_glob") for x in comps]
        exact_ms1_set = len(comps) == len(MS1_COMPONENT_GLOBS) and set(globs) == MS1_COMPONENT_GLOBS
        c.ok(milestone == MS1_MILESTONE and exact_ms1_set,
             f"an empty resource inventory is accepted only for the exact browser+shim MS1 bundle "
             f"(milestone {MS1_MILESTONE} + exactly the components {sorted(MS1_COMPONENT_GLOBS)} + no "
             f"resources); got milestone={milestone!r}, components={globs}")
        return
    resource_compat(tree_a, tree_b, required, c)


def resource_compat(tree_a: dict[str, str], tree_b: dict[str, str],
                    required: list, c: Checks) -> None:
    """Pure two-tree oracle (MS1.1, plan:396-401; RoseCat 5974). `tree_a`/`tree_b` map
    a resource rel-path to its content digest, one per arch. Each required
    non-executable resource must be present in BOTH per-arch trees and byte-identical,
    else it is incompatible and must REFUSE before `lipo -create`. The green packaging
    step (build-dmg.sh via mac_resource_compat.py) runs this on the two arch trees."""
    for res in required:
        path = res["path"]
        a, b = tree_a.get(path), tree_b.get(path)
        c.ok(a is not None, f"resource {path!r} ({res.get('role', path)}) missing from the first arch tree")
        c.ok(b is not None, f"resource {path!r} ({res.get('role', path)}) missing from the second arch tree")
        c.ok(a is not None and b is not None and a == b,
             f"resource {path!r} differs across arches (incompatible before lipo): {a!r} != {b!r}")


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


# MS1.3 least-privilege (MS1b plan, orchestrator): com.apple.security.cs.disable-library-validation
# lets a hardened process load a dylib signed by a different team. It is allowed ONLY in ad-hoc
# dev/test builds (a hardened dev exe loading the ad-hoc shim dylib); a RELEASE build must never
# ship it (MS9's real Developer ID signs exe+dylib under one team, so library validation passes
# without it). This rule fails a release manifest OR a release signed binary that contains it.
DISABLE_LIBVAL = "com.apple.security.cs.disable-library-validation"


def release_least_privilege(manifest_keys_set, signed_keys_set, c: Checks) -> None:
    """MS1.3: the release entitlements must not disable library validation (dev/test only)."""
    c.ok(DISABLE_LIBVAL not in manifest_keys_set,
         f"release entitlements manifest must not contain {DISABLE_LIBVAL} (ad-hoc dev/test only)")
    c.ok(DISABLE_LIBVAL not in signed_keys_set,
         f"release signed binary must not carry {DISABLE_LIBVAL} (ad-hoc dev/test only)")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True, help="installed universal browser binary")
    ap.add_argument("--bundle-root", required=True,
                    help="the install/bundle root scanned for the component census (MS1.1)")
    ap.add_argument("--components-manifest", required=True,
                    help="packaging/macos/universal_components.json (the required inventory)")
    ap.add_argument("--expect-arch", required=True, choices=sorted(BOTH),
                    help="the arch THIS host must natively execute")
    ap.add_argument("--entitlements", required=True, help="packaging/macos/entitlements.plist")
    ap.add_argument("--signed-binary", default=None,
                    help="an ad-hoc-SIGNED copy of the universal binary for the MS1.3 `codesign -d` "
                         "check (static; never run). MS1 RUNS the unsigned --binary (MS1.1/MS1.2); "
                         "running a signed binary is proved by MS1b, not MS1. Defaults to --binary.")
    ap.add_argument("--reported-arch", default=None,
                    help="arch the running app reported over the socket (gate.sh supplies it); "
                         "its ABSENCE fails MS1.2 closed — it is never optional")
    args = ap.parse_args()

    c = Checks()
    try:
        binary = Path(args.binary)
        if not binary.is_file():
            raise FailClosed(f"browser binary not found: {binary} (no build / wrong host)")

        # MS1.1 — complete, fail-closed component census over the whole bundle.
        root = Path(args.bundle_root)
        if not root.is_dir():
            raise FailClosed(f"bundle root not a directory: {root}")
        inventory = load_inventory(Path(args.components_manifest))
        macho = scan_macho(root)
        component_census(macho, inventory, lambda rel: (root / rel).is_file(), c)

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
        # The span's build.exec_arch is zig's cpu tag ("aarch64"/"x86_64"); normalize it to the
        # gate's arch names ("arm64"/"x86_64") the same way uname -m is normalized above.
        reported_norm = ARM if args.reported_arch in ("arm64", "aarch64") else args.reported_arch
        c.ok(reported_norm == args.expect_arch,
             f"app reported arch {args.reported_arch!r} (normalized {reported_norm!r}) != "
             f"executing {args.expect_arch!r}")

        # MS1.3 — the manifest is the single source of truth; the SIGNED binary's entitlements
        # match it exactly. This is a STATIC `codesign -d` check (the signed binary is never run;
        # MS1 runs the unsigned --binary above). MS1 does NOT prove a signed binary runs — MS1b does.
        signed = Path(args.signed_binary) if args.signed_binary else binary
        if not signed.is_file():
            raise FailClosed(f"signed binary not found: {signed}")
        want = manifest_keys(Path(args.entitlements))
        c.ok(bool(want), "entitlements manifest has no keys")
        got = codesign_entitlement_keys(signed)
        c.ok(got == want, f"signed entitlements {sorted(got)} != manifest {sorted(want)}")
        # MS1.3 least-privilege: the release manifest/binary must not disable library validation.
        release_least_privilege(want, got, c)
    except FailClosed as e:
        print(f"NOT RUN / FAIL CLOSED: {e}", file=sys.stderr)
        return 2

    return c.done()


if __name__ == "__main__":
    sys.exit(main())
