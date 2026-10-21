#!/usr/bin/env python3
"""WS1.1 PE census (Linux-side, no external deps) — machine, subsystem, imported DLLs.

Used by the WS1 gate to assert the fetched Windows release exe is a clean x64 PE whose import table
stays within an allowlist (system DLLs + api-ms-win-crt-*); any vcruntime*/msvcp* import is a failure
unless the installer ships that redistributable.

CLI:
    pe_census.py <exe>                 -> prints the census JSON, exit 0
    pe_census.py --allowlist <exe>     -> as above, but exit 1 if machine != x64 or an import is forbidden
Manual PE/COFF parse (no pefile), so the gate carries no third-party dependency.
"""
import json
import struct
import sys

IMAGE_FILE_MACHINE_AMD64 = 0x8664
_SUBSYS = {1: "native", 2: "GUI", 3: "console"}

# Import DLLs that are fine in a statically-linked ReleaseSafe build.
_ALLOWED_EXACT = {
    "ntdll.dll", "kernel32.dll", "kernelbase.dll", "user32.dll", "gdi32.dll", "gdi32full.dll",
    "advapi32.dll", "ole32.dll", "oleaut32.dll", "shell32.dll", "shlwapi.dll", "shcore.dll",
    "ws2_32.dll", "crypt32.dll", "bcrypt.dll", "ncrypt.dll", "secur32.dll", "version.dll",
    "comctl32.dll", "comdlg32.dll", "dwmapi.dll", "uxtheme.dll", "winmm.dll", "imm32.dll",
    "setupapi.dll", "cfgmgr32.dll", "powrprof.dll", "userenv.dll", "ucrtbase.dll", "rpcrt4.dll",
    "dbghelp.dll", "psapi.dll", "wtsapi32.dll",
}
# Prefix allowlist (API sets + the CRT forwarders).
_ALLOWED_PREFIX = ("api-ms-win-",)
# A redistributable the installer must ship — importing it directly from the build is a failure
# unless the ship-list explicitly includes it.
_REDIST_PREFIX = ("vcruntime", "msvcp", "msvcr", "concrt")


def census(path):
    with open(path, "rb") as _f:
        data = _f.read()
    if data[:2] != b"MZ":
        raise ValueError("not a PE image (missing MZ)")
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if data[e_lfanew:e_lfanew + 4] != b"PE\0\0":
        raise ValueError("not a PE image (missing PE signature)")
    coff = e_lfanew + 4
    machine, n_sections = struct.unpack_from("<HH", data, coff)
    size_opt = struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    magic = struct.unpack_from("<H", data, opt)[0]
    pe32plus = (magic == 0x20B)
    subsystem = struct.unpack_from("<H", data, opt + 68)[0]  # Subsystem; +70 is DllCharacteristics
    n_dirs = struct.unpack_from("<I", data, opt + (108 if pe32plus else 92))[0]
    datadir = opt + (112 if pe32plus else 96)

    sections = []
    sh = opt + size_opt
    for i in range(n_sections):
        base = sh + i * 40
        vsize, vaddr, rawsize, praw = struct.unpack_from("<IIII", data, base + 8)
        sections.append((vaddr, max(vsize, rawsize), praw))

    def rva_to_off(rva):
        for vaddr, vspan, praw in sections:
            if vaddr <= rva < vaddr + vspan:
                return rva - vaddr + praw
        return None

    imports = []
    if n_dirs >= 2:
        imp_rva, imp_size = struct.unpack_from("<II", data, datadir + 8)
        off = rva_to_off(imp_rva) if imp_rva else None
        if off is not None:
            while True:
                desc = data[off:off + 20]
                if len(desc) < 20 or desc == b"\0" * 20:
                    break
                name_rva = struct.unpack_from("<I", desc, 12)[0]
                if name_rva == 0:
                    break
                noff = rva_to_off(name_rva)
                if noff is not None:
                    end = data.index(b"\0", noff)
                    imports.append(data[noff:end].decode("ascii", "replace"))
                off += 20

    imports_l = sorted({d.lower() for d in imports})
    forbidden = [d for d in imports_l if d.startswith(_REDIST_PREFIX)]
    unlisted = [d for d in imports_l
                if d not in _ALLOWED_EXACT
                and not d.startswith(_ALLOWED_PREFIX)
                and d not in forbidden]
    machine_ok = machine == IMAGE_FILE_MACHINE_AMD64
    # A single verdict string: "OK" or the first disqualifying reason (machine, then a forbidden
    # redistributable, then an unlisted import). Consumed by pe_census_selftest.py.
    if not machine_ok:
        verdict = "FAIL: machine 0x%x" % machine
    elif not pe32plus:
        verdict = "FAIL: not PE32+"
    elif forbidden:
        verdict = "FAIL: " + forbidden[0]
    elif unlisted:
        verdict = "FAIL: " + unlisted[0]
    else:
        verdict = "OK"
    return {
        "machine": machine,
        "machine_ok": machine_ok,
        "pe32plus": pe32plus,
        "subsystem": subsystem,
        "subsystem_name": _SUBSYS.get(subsystem, str(subsystem)),
        "imports": imports_l,
        "forbidden_imports": forbidden,
        "unlisted_imports": unlisted,
        "verdict": verdict,
    }


def main(argv):
    enforce = False
    args = list(argv)
    if args and args[0] == "--allowlist":
        enforce = True
        args = args[1:]
    if not args:
        print("usage: pe_census.py [--allowlist] <exe>", file=sys.stderr)
        return 2
    c = census(args[0])
    print(json.dumps(c, indent=2))
    if enforce and not (c["machine_ok"] and c["pe32plus"]
                        and not c["forbidden_imports"] and not c["unlisted_imports"]):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
