#!/usr/bin/env python3
"""Relocates the staged python.org framework (MS5; the user approved relocation). The python.org CPython 3.12 build
loads /Library/Frameworks/Python.framework/Versions/3.12/... by absolute path from its executables, its Python
library, lib/*.dylib and lib-dynload extensions; staged inside the app it cannot start, and relocating only some of
them lets dyld fall back to a foreign library (measured 2026-10-21 on both Macs).

usage: relocate_python_framework.py [--check] <.../Python.framework/Versions/3.12>
- default: rewrite every Mach-O's install id and load commands under that root to @loader_path-relative paths, refuse
  any foreign absolute path, confirm none is left, then re-sign every Mach-O ad hoc, inside-out (preserving
  entitlements, requirements, flags and runtime), Resources/Python.app last as a bundle. The Developer-ID re-sign is
  packaging's, later.
- --check: report every id or load path still under /Library/Frameworks/Python.framework or absolute outside /usr/lib/
  and /System/; exit 1 if any.

Runs under the Mac's /usr/bin/python3 (3.9), before the staged interpreter can. plan() and problems() are pure (tested
off-Mac by tests/e2e/mac_relocate_test.py); the rest shells out to otool, install_name_tool and codesign."""
import os
import subprocess
import sys

OLD_ROOT = "/Library/Frameworks/Python.framework/Versions/3.12"
SYSTEM = ("/usr/lib/", "/System/")
RELATIVE = ("@rpath/", "@loader_path/", "@executable_path/")
MACHO_MAGIC = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
               b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
APP_EXE = "Resources/Python.app/Contents/MacOS/Python"


def plan(files, old_root):
    """install_name_tool argv lists (paths relative to the version root) for `files` ({rel: {"id", "deps"}})."""
    cmds = []
    for rel in sorted(files):
        own = files[rel].get("id")
        if own and own.startswith(old_root + "/"):
            cmds.append(["install_name_tool", "-id", "@loader_path/" + os.path.basename(rel), rel])
        for dep in files[rel].get("deps", []):
            if dep == own or dep.startswith(RELATIVE) or dep.startswith(SYSTEM):
                continue
            if not dep.startswith(old_root + "/"):
                raise ValueError(f"{rel}: foreign load path {dep} (only system paths may stay absolute)")
            target = dep[len(old_root) + 1:]
            if target not in files:
                raise ValueError(f"{rel}: {dep} names {target}, which is not in the framework tree")
            new = "@loader_path/" + os.path.relpath(target, os.path.dirname(rel) or ".")
            cmds.append(["install_name_tool", "-change", dep, new, rel])
    return cmds


def problems(files, old_root):
    """Every id or load path still pointing at the framework's old home, or absolute outside the system."""
    out = []
    for rel in sorted(files):
        paths = ([files[rel]["id"]] if files[rel].get("id") else []) + list(files[rel].get("deps", []))
        for path in paths:
            if path.startswith("/Library/Frameworks/Python.framework") or (
                    path.startswith("/") and not path.startswith(SYSTEM)):
                out.append(f"{rel}: {path}")
    return out


def _is_macho(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) in MACHO_MAGIC
    except OSError:
        return False


def parse_otool(output):
    """The install names in `otool -D` / `otool -L` output, every architecture slice merged, in order: only entries that
    are paths (absolute or @-relative). `otool -D` prints the id unindented, `-L` indents its entries. The file headers
    ("<file>:" or "<file> (architecture x):") and notes such as "<file> (architecture arm64): is an LLVM bit-code
    file" (measured on arm64 for config-3.12-darwin/python.o) are not install names."""
    entries = []
    for line in output.splitlines():
        entry = line.strip().split(" (compatibility version")[0].strip()
        if line.rstrip().endswith(":") or "(architecture " in line or not entry.startswith(("/", "@")):
            continue
        if entry not in entries:
            entries.append(entry)
    return entries


def _otool_entries(flag, path):
    return parse_otool(subprocess.run(["otool", flag, path], capture_output=True, text=True, check=True).stdout)


def scan(root):
    """{rel: {"id", "deps"}} for every regular Mach-O file under root (symlinks are not followed)."""
    files = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path) or name.endswith((".o", ".a")) or not _is_macho(path):
                continue  # object files and archives are never loaded (config-3.12-darwin/python.o)
            rel = os.path.relpath(path, root)
            ids = _otool_entries("-D", path)
            files[rel] = {"id": ids[0] if ids else None, "deps": _otool_entries("-L", path)}
    return files


def _sign(path):
    subprocess.run(["codesign", "--force", "--sign", "-",
                    "--preserve-metadata=entitlements,requirements,flags,runtime", path],
                   check=True, capture_output=True)


def relocate(root):
    files = scan(root)
    for cmd in plan(files, OLD_ROOT):
        subprocess.run(cmd[:-1] + [os.path.join(root, cmd[-1])], check=True, capture_output=True)
    left = problems(scan(root), OLD_ROOT)
    if left:
        raise ValueError("absolute paths left after relocation:\n  " + "\n  ".join(left))
    # Inside-out: every Mach-O but the bundles' main executables, deepest first; then Python.app as a bundle; then
    # the framework version itself as a bundle, whose main executable is Python (verifying Python checks that seal).
    for rel in sorted(files, key=lambda r: (-r.count(os.sep), r)):
        if rel not in (APP_EXE, "Python"):
            _sign(os.path.join(root, rel))
    if APP_EXE in files:
        _sign(os.path.join(root, "Resources", "Python.app"))
    _sign(root)


def main(argv):
    check = argv[:1] == ["--check"]
    args = argv[1:] if check else argv
    if len(args) != 1 or not os.path.isdir(args[0]):
        print("usage: relocate_python_framework.py [--check] <.../Python.framework/Versions/3.12>", file=sys.stderr)
        return 2
    root = os.path.realpath(args[0])
    if check:
        left = problems(scan(root), OLD_ROOT)
        for p in left:
            print(p)
        return 1 if left else 0
    try:
        relocate(root)
    except (ValueError, subprocess.CalledProcessError) as exc:
        detail = exc.stderr if isinstance(exc, subprocess.CalledProcessError) else ""
        print(f"relocate_python_framework: {exc} {detail or ''}".rstrip(), file=sys.stderr)
        return 1
    print(f"relocated {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
