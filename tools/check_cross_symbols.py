#!/usr/bin/env python3
"""N12: cross-platform link check without the platform SDKs.

`zig build cross-check` compiles src/main.zig to an object file for each
non-GTK target (no C shim, no SDK, no link). This script lists the `zb_*`
C symbols such an object leaves undefined and checks that the target's shim
source defines every one of them. A GTK-only symbol (zb_automation_*,
zb_cookies_*, zb_native_*, ...) reaching a Windows or macOS build would fail
its real link; this catches it on Linux.

usage: check_cross_symbols.py <object> <shim source> [<object> <shim> ...]
Reads COFF (plain and /bigobj) and 64-bit Mach-O objects. Exit 1 on a
missing definition, 2 on an unreadable object.
"""

from __future__ import annotations

import re
import struct
import sys
from pathlib import Path


def coff_undefined(data: bytes) -> set[str]:
    bigobj = len(data) >= 4 and struct.unpack_from("<HH", data, 0) == (0, 0xFFFF)
    if bigobj:
        # ANON_OBJECT_HEADER_BIGOBJ: 32-bit section numbers, 20-byte symbols.
        symtab, nsyms = struct.unpack_from("<II", data, 48)
        entry, section_fmt = 20, "<i"
    else:
        symtab, nsyms = struct.unpack_from("<II", data, 8)
        entry, section_fmt = 18, "<h"
    strtab = symtab + nsyms * entry
    names: set[str] = set()
    i = 0
    while i < nsyms:
        off = symtab + i * entry
        raw = data[off : off + 8]
        if raw[:4] == b"\0\0\0\0":
            (str_off,) = struct.unpack_from("<I", raw, 4)
            end = data.index(b"\0", strtab + str_off)
            name = data[strtab + str_off : end].decode()
        else:
            name = raw.rstrip(b"\0").decode()
        (section,) = struct.unpack_from(section_fmt, data, off + 12)
        storage_class, aux = struct.unpack_from("<BB", data, off + entry - 2)
        if section == 0 and storage_class == 2:  # undefined, IMAGE_SYM_CLASS_EXTERNAL
            names.add(name)
        i += 1 + aux
    return names


def macho_undefined(data: bytes) -> set[str]:
    (ncmds,) = struct.unpack_from("<I", data, 16)
    off = 32
    names: set[str] = set()
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x2:  # LC_SYMTAB
            symoff, nsyms, stroff, _ = struct.unpack_from("<IIII", data, off + 8)
            for i in range(nsyms):
                strx, n_type = struct.unpack_from("<IB", data, symoff + i * 16)
                if (n_type & 0x0E) == 0 and (n_type & 0x01):  # N_UNDF, N_EXT
                    end = data.index(b"\0", stroff + strx)
                    names.add(data[stroff + strx : end].decode())
        off += size
    return names


def undefined_zb_symbols(path: Path) -> set[str]:
    data = path.read_bytes()
    if struct.unpack_from("<I", data, 0)[0] == 0xFEEDFACF:
        raw = macho_undefined(data)
    elif struct.unpack_from("<H", data, 0)[0] in (0x8664, 0xAA64) or struct.unpack_from("<HH", data, 0) == (0, 0xFFFF):
        raw = coff_undefined(data)
    else:
        raise ValueError(f"{path}: not a COFF or 64-bit Mach-O object")
    # Mach-O prefixes C symbols with "_".
    return {n.lstrip("_") for n in raw if n.lstrip("_").startswith("zb_")}


# A definition: a top-level line (no indent) naming zb_x( that is not a
# declaration ending in ';' before the body opens.
DEFINITION = re.compile(r'^(?:extern\s+"C"\s+)?[A-Za-z_][\w\s\*]*?\b(zb_\w+)\s*\(([^;{]*)(\{|$)', re.M)


def defined_zb_symbols(shim: Path) -> set[str]:
    text = shim.read_text(encoding="utf-8")
    found = set()
    for match in DEFINITION.finditer(text):
        name = match.group(1)
        rest = text[match.end(2) :]
        # The next ';' or '{' after the parameter list decides it.
        brace, semi = rest.find("{"), rest.find(";")
        if brace != -1 and (semi == -1 or brace < semi):
            found.add(name)
    return found


def main(argv: list[str]) -> int:
    if len(argv) < 2 or len(argv) % 2:
        print(__doc__, file=sys.stderr)
        return 2
    missing_any = False
    for obj, shim in zip(argv[0::2], argv[1::2]):
        try:
            needed = undefined_zb_symbols(Path(obj))
        except (OSError, ValueError, struct.error) as exc:
            print(f"cross-check: {exc}", file=sys.stderr)
            return 2
        defined = defined_zb_symbols(Path(shim))
        missing = sorted(needed - defined)
        label = Path(obj).name
        print(f"cross-check {label}: needs {sorted(needed)} from {Path(shim).name}")
        if missing:
            missing_any = True
            print(f"cross-check {label}: MISSING in {Path(shim).name}: {missing}", file=sys.stderr)
    return 1 if missing_any else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
