#!/usr/bin/env python3
"""Merges the two per-arch macOS site-packages trees into ONE universal2 tree (MS5 fat agent-host; JadeBeacon 7206,
BlueBeaver 7197, 7221). Both trees come from agent/host/uv.lock (packaging/macos/build_site_packages.sh); measured,
they differ only in thin Mach-O, WHEEL Tag lines, RECORDs and CycloneDX SBOMs. The rule is strict:

- the two trees hold exactly the same relative file paths; no symlink anywhere;
- a byte-identical file is copied once, with its mode;
- a thin x86_64 Mach-O and a thin arm64 Mach-O at one path become `lipo -create <x86> <arm> -output <out>` (their
  slices keep their own signatures); any other differing Mach-O pairing is refused;
- *.dist-info/WHEEL: only `Tag:` lines may differ; the merged WHEEL keeps every line and both arches' Tag lines;
- *.dist-info/sboms/<name>.json that differ are kept per arch, as <name>.x86_64.json and <name>.arm64.json;
- *.dist-info/RECORD is regenerated over the paths the x86_64 RECORD lists (the arm64 RECORD must list the same):
  sha256 (urlsafe base64, no padding) and size of the merged file, `<RECORD>,,` for itself, a split SBOM as its two
  names; a listed path missing from the merged tree is refused;
- every other difference is refused, naming the path. `out` must not exist, and a failed merge leaves nothing.
Boundaries (RoseCat 7230): every entry is lstat()ed first, so a symlink, FIFO or other non-regular entry is refused
without being opened; the two sides' permission bits must agree; a RECORD row must be a plain relative path (no
leading "/", no empty, "." or ".." segment) listed once, with exactly one row for the RECORD itself; a failing lipo
is reported with its path. No RECORD row is ever read outside the merged tree.

usage: merge_universal_tree.py <x86_64 tree> <arm64 tree> <out>   (runs on the Mac, under /usr/bin/python3 3.9)"""
import base64
import csv
import hashlib
import io
import os
import shutil
import stat
import subprocess
import sys
import tempfile

ARCH_BY_CPU = {0x01000007: "x86_64", 0x0100000C: "arm64"}
THIN_MAGIC = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe")
FAT_MAGIC = (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf")


class MergeError(ValueError):
    pass


def _files(root):
    """{rel: (path, permission bits)} of every regular file; anything else is refused before it is ever opened."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode):
                raise MergeError(f"{rel}: a symlink (refused)")
            if name in filenames and not stat.S_ISREG(st.st_mode):
                raise MergeError(f"{rel}: not a regular file (refused, never opened)")
            if name in filenames:
                out[rel] = (path, stat.S_IMODE(st.st_mode))
    return out


def _macho_kind(data):
    """'x86_64' or 'arm64' for a thin Mach-O, 'fat' for a universal one, None otherwise."""
    if data[:4] in FAT_MAGIC:
        return "fat"
    if data[:4] in THIN_MAGIC and len(data) >= 8:
        return ARCH_BY_CPU.get(int.from_bytes(data[4:8], "little"), "other")
    return None


def _in_dist_info(rel):
    parts = rel.split("/")
    return len(parts) >= 2 and parts[0].endswith(".dist-info"), parts


def _merge_wheel(rel, x, a):
    lx, la = x.decode().splitlines(), a.decode().splitlines()
    if [l for l in lx if not l.startswith("Tag:")] != [l for l in la if not l.startswith("Tag:")]:
        raise MergeError(f"{rel}: differs in more than its Tag lines")
    tags = [l for l in lx if l.startswith("Tag:")]
    extra = [l for l in la if l.startswith("Tag:") and l not in tags]
    last = max(i for i, l in enumerate(lx) if l.startswith("Tag:")) if tags else len(lx) - 1
    merged = lx[:last + 1] + extra + lx[last + 1:]
    return ("\n".join(merged) + "\n").encode()


def _sbom_names(rel):
    stem = rel[:-len(".json")]
    return f"{stem}.x86_64.json", f"{stem}.arm64.json"


def _record_paths(rel, data):
    """The paths a RECORD lists, each a plain relative path listed once, with exactly one row for itself."""
    paths = [row[0] for row in csv.reader(io.StringIO(data.decode())) if row]
    for path in paths:
        parts = path.split("/")
        if path.startswith("/") or "\\" in path or any(p in ("", ".", "..") for p in parts):
            raise MergeError(f"{rel}: row {path!r} is not a plain relative path (refused)")
    seen = set()
    for path in paths:
        if path in seen:
            raise MergeError(f"{rel}: row {path!r} is listed twice")
        seen.add(path)
    if rel not in seen:
        raise MergeError(f"{rel}: has no row for itself")
    return paths


def _record_line(stage, rel):
    with open(os.path.join(stage, rel), "rb") as f:
        data = f.read()
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
    return f"{rel},sha256={digest},{len(data)}"


def merge(x86_root, arm_root, out, run=subprocess.run):
    if os.path.lexists(out):
        raise MergeError(f"{out} already exists (refused: never merged into)")
    fx, fa = _files(x86_root), _files(arm_root)
    if set(fx) != set(fa):
        odd = sorted(set(fx) ^ set(fa))
        raise MergeError("not in both trees: " + ", ".join(odd[:10]))
    for rel in sorted(fx):
        if fx[rel][1] != fa[rel][1]:
            raise MergeError(f"{rel}: permission bits differ ({fx[rel][1]:o} vs {fa[rel][1]:o})")
    parent = os.path.dirname(os.path.abspath(out))
    work = tempfile.mkdtemp(prefix=".merge-universal-", dir=parent)
    try:
        stage = os.path.join(work, "tree")
        split, records = {}, []
        for rel in sorted(fx):
            px, pa = fx[rel][0], fa[rel][0]
            dest = os.path.join(stage, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            dist, parts = _in_dist_info(rel)
            if dist and parts[-1] == "RECORD" and len(parts) == 2:
                records.append(rel)
                continue
            with open(px, "rb") as f:
                dx = f.read()
            with open(pa, "rb") as f:
                da = f.read()
            if dx == da:
                shutil.copyfile(px, dest)
                shutil.copymode(px, dest)
                continue
            kx, ka = _macho_kind(dx), _macho_kind(da)
            if kx or ka:
                if (kx, ka) != ("x86_64", "arm64"):
                    raise MergeError(f"{rel}: cannot merge Mach-O {kx} with {ka}")
                try:
                    run(["lipo", "-create", px, pa, "-output", dest], check=True, capture_output=True)
                except subprocess.CalledProcessError as exc:
                    err = exc.stderr.decode(errors="replace").strip() if exc.stderr else exc
                    raise MergeError(f"{rel}: lipo failed: {err}") from exc
                shutil.copymode(px, dest)
            elif dist and parts[-1] == "WHEEL" and len(parts) == 2:
                with open(dest, "wb") as f:
                    f.write(_merge_wheel(rel, dx, da))
            elif dist and len(parts) >= 3 and parts[1] == "sboms" and rel.endswith(".json"):
                for name, data in zip(_sbom_names(rel), (dx, da)):
                    with open(os.path.join(stage, name), "wb") as f:
                        f.write(data)
                split[rel] = _sbom_names(rel)
            else:
                raise MergeError(f"{rel}: differs between the two arches")
        for rel in records:
            with open(fx[rel][0], "rb") as f:
                listed = _record_paths(rel, f.read())
            with open(fa[rel][0], "rb") as f:
                if sorted(_record_paths(rel, f.read())) != sorted(listed):
                    raise MergeError(f"{rel}: the two RECORDs list different paths")
            lines = []
            for path in listed:
                if path == rel:
                    lines.append(f"{rel},,")
                    continue
                for name in split.get(path, (path,)):
                    if not os.path.isfile(os.path.join(stage, name)):
                        raise MergeError(f"{rel} lists {name}, which is not in the merged tree")
                    lines.append(_record_line(stage, name))
            with open(os.path.join(stage, rel), "w") as f:
                f.write("\n".join(lines) + "\n")
        os.rename(stage, out)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv):
    if len(argv) != 3:
        print(__doc__.rsplit("usage: ", 1)[1].strip(), file=sys.stderr)
        return 2
    try:
        merge(*argv)
    except (MergeError, OSError) as exc:
        print(f"merge_universal_tree: {exc}", file=sys.stderr)
        return 1
    print(f"merged {argv[2]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
