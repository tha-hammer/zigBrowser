#!/usr/bin/env python3
"""MS2b — pure parity between the router's accepted key names and the macOS shim's key map (RoseCat 6426).

Wiring nativeKey/nativeText exposes EVERY name in `router.native_key_names`; a name the router accepts but
the shim does not map is a silent `internal` failure in the field. This test derives both sets FROM SOURCE
— it does not hand-copy a list into the test — and asserts they are exactly equal:

  - the router set: the string literals in `native_key_names` (src/automation/router.zig);
  - the shim set:   the dictionary KEYS of the `named` and `mods` maps in `zb_dom_key_to_ns`
                    (src/wkwebview_shim.m).

A key added to one side but not the other (either direction) fails the test. Pure text analysis, no
browser — runs anywhere, registered in the MS2b gate.
"""
import argparse
import re
import sys
from pathlib import Path


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def router_names(root: Path) -> set[str]:
    src = (root / "src/automation/router.zig").read_text()
    m = re.search(r"pub const native_key_names = \[_\]\[\]const u8\{(.*?)\};", src, re.S)
    if not m:
        raise AssertionError("native_key_names array not found in router.zig")
    return set(re.findall(r'"([^"]+)"', m.group(1)))


def shim_keys(root: Path) -> set[str]:
    src = (root / "src/wkwebview_shim.m").read_text()
    keys: set[str] = set()
    for dict_name in ("named", "mods"):
        # `    named = @{ ... };`  — the Objective-C dictionary literal.
        m = re.search(dict_name + r"\s*=\s*@\{(.*?)\};", src, re.S)
        if not m:
            raise AssertionError(f"{dict_name} dictionary not found in wkwebview_shim.m")
        # Dictionary KEYS are `@"Name":` (followed by a colon); values like @"\r" are not keys.
        keys |= set(re.findall(r'@"([^"]+)"\s*:', m.group(1)))
    return keys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")  # accepted for gate uniformity; unused
    ap.add_argument("--root", default=None)
    args = ap.parse_args()
    root = Path(args.root) if args.root else Path(__file__).resolve().parents[2]

    failures: list[str] = []
    try:
        router = router_names(root)
        shim = shim_keys(root)
    except AssertionError as exc:
        print("FAIL\tms2b-key-table-parity")
        eprint(f"  {exc}")
        return 1

    missing_in_shim = router - shim
    extra_in_shim = shim - router
    if missing_in_shim:
        failures.append(f"router names with NO shim mapping (field 'internal' error): {sorted(missing_in_shim)}")
    if extra_in_shim:
        failures.append(f"shim map has keys the router never accepts: {sorted(extra_in_shim)}")
    if len(router) < 20:
        failures.append(f"router set suspiciously small ({len(router)}), parse likely broke: {sorted(router)}")

    if failures:
        print("FAIL\tms2b-key-table-parity")
        for f in failures:
            eprint(f"  {f}")
        return 1
    print(f"PASS\tms2b-key-table-parity\t({len(router)} names)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
