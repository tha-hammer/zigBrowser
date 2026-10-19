#!/usr/bin/env python3
"""MS1.1 non-executable resource-compatibility oracle (plan:396-401; RoseCat 5974).

The universal app's non-executable resources must be byte-compatible across the two
per-arch trees BEFORE `lipo -create` combines the executables. This is the routable
entry point the MS1 green (packaging/macos/build-dmg.sh) runs on the x86_64 and arm64
build trees: it digests each declared resource in both trees and calls the pure
`mac_universal_test.resource_compat` oracle, which REFUSES a mismatch. Fail-closed.

    python3 tests/e2e/mac_resource_compat.py \
        --manifest packaging/macos/universal_components.json <x86_64_tree> <arm64_tree>

The pure oracle is pinned off-Mac by tests/e2e/mac_universal_census_test.py.
"""
import argparse
import hashlib
import sys
from pathlib import Path

import mac_universal_test as mu


def digest_tree(root: str, required: list) -> dict[str, str]:
    """rel-path -> sha256 for each declared resource present under `root`.
    A resource missing here surfaces as a resource_compat failure (not a silent skip)."""
    out: dict[str, str] = {}
    for res in required:
        p = Path(root) / res["path"]
        if p.is_file() and not p.is_symlink():
            out[res["path"]] = hashlib.sha256(p.read_bytes()).hexdigest()
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True, help="packaging/macos/universal_components.json")
    ap.add_argument("tree_a", help="the first per-arch build tree root")
    ap.add_argument("tree_b", help="the second per-arch build tree root")
    args = ap.parse_args()

    c = mu.Checks()
    try:
        inv = mu.load_inventory(Path(args.manifest))
        required = inv["resources"]
        if not required:
            # Nothing declared to compare is not a pass: the contract requires the
            # resource set to be exercised (fail closed, mirrors the inventory rule).
            raise mu.FailClosed("no non-executable resources declared to compare")
        a = digest_tree(args.tree_a, required)
        b = digest_tree(args.tree_b, required)
        mu.resource_compat(a, b, required, c)
    except mu.FailClosed as e:
        print(f"NOT RUN / FAIL CLOSED: {e}", file=sys.stderr)
        return 2
    return c.done()


if __name__ == "__main__":
    sys.exit(main())
