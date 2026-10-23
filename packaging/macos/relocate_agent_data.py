#!/usr/bin/env python3
"""Keep the agent runtime's logical path Contents/Frameworks/agent-host, but move every non-code file of it physically
to Contents/Resources/agent-host/<same relative path> (4pa.80; the released Stage B at d80dd3ee showed codesign
refusing ordinary Python files under Contents/Frameworks).

usage: relocate_agent_data.py relocate <.app/Contents>
       relocate_agent_data.py census <.app/Contents>

- Code is the Mach-O census by magic bytes (a FAT header must carry a plausible slice count, so a Java class file is
  data), never a name or an execute bit. Only the exact Python framework at agent-host/Python.framework, as the
  python.org payload ships it, is exempt and stays as it is.
- A directory whose subtree holds no Mach-O file and no link moves as one and becomes one directory link; any other
  directory stays real, with one link per non-code file in it. Existing links stay where they are.
- Every created link is relative and stays inside the bundle. Bytes, permission bits and inodes move with rename().
- Refused, before any change: an existing Contents/Resources/agent-host (so a second run), a symlinked Frameworks or
  agent-host, an absolute, escaping, dangling or looping link, a hard link, a FIFO, a socket, a device node, a case-fold
  or Unicode-normalization collision, a malformed Python.framework.
- Every mutating step is journaled; a failure undoes the journal, so no half-relocated tree is left.
- relocate prints sorted LINK<TAB><logical path><TAB><target> lines and RELOCATED<TAB>files=<n><TAB>dirs=<n><TAB>
  links=<n>; census prints every non-code regular file under Contents/Frameworks outside the exempt framework, then
  CENSUS<TAB><n>. A refusal prints "relocate_agent_data: REFUSED: <why>" on stderr and exits 2.
"""
import os
import stat
import sys
import unicodedata
from pathlib import Path

AGENT = "Frameworks/agent-host"
DEST = "Resources/agent-host"
FRAMEWORK = "Python.framework"
STAGING = "Resources/.zb-agent-host-relocating"
THIN_MAGIC = {bytes.fromhex(m) for m in ("feedface", "feedfacf", "cefaedfe", "cffaedfe")}
FAT_MAGIC = {bytes.fromhex(m) for m in ("cafebabe", "cafebabf")}
MAX_FAT_ARCHS = 20  # a Java class file carries its version (>= 45) where a FAT header has its slice count


class RelocateError(Exception):
    pass


def is_macho(path: Path) -> bool:
    with open(path, "rb") as f:
        head = f.read(8)
    if head[:4] in THIN_MAGIC:
        return True
    return head[:4] in FAT_MAGIC and len(head) == 8 and 1 <= int.from_bytes(head[4:], "big") < MAX_FAT_ARCHS


def is_link_to(path: Path, target: str) -> bool:
    return path.is_symlink() and os.readlink(path) == target


def framework_problem(fw: Path) -> str:
    """'' when fw is exactly the python.org 3.12 framework layout, else why not."""
    if fw.is_symlink() or not fw.is_dir():
        return "not a real directory"
    if sorted(os.listdir(fw)) != ["Headers", "Python", "Resources", "Versions"]:
        return f"root entries {sorted(os.listdir(fw))}"
    for name in ("Headers", "Python", "Resources"):
        if not is_link_to(fw / name, f"Versions/Current/{name}"):
            return f"{name} is not a link to Versions/Current/{name}"
    versions = fw / "Versions"
    if versions.is_symlink() or sorted(os.listdir(versions)) != ["3.12", "Current"]:
        return "Versions is not exactly 3.12 and Current"
    if not is_link_to(versions / "Current", "3.12"):
        return "Versions/Current is not a link to 3.12"
    v = versions / "3.12"
    binary = v / "Python"
    if v.is_symlink() or binary.is_symlink() or not binary.is_file() or not is_macho(binary):
        return "Versions/3.12/Python is not a Mach-O file"
    return ""


def fold(rel: str) -> str:
    return unicodedata.normalize("NFD", rel).casefold()


class Scan:
    """Every entry of agent-host outside the exempt framework, without following links."""

    def __init__(self, contents: Path):
        self.contents = contents
        self.agent = contents / AGENT
        self.dirs, self.code, self.data, self.links = [], [], [], []
        self.walk(self.agent, "")

    def walk(self, d: Path, rel: str):
        for name in sorted(os.listdir(d)):
            r = f"{rel}{name}"
            p = d / name
            if r == FRAMEWORK:
                why = framework_problem(p)
                if why:
                    raise RelocateError(f"{AGENT}/{FRAMEWORK} is not the exact Python framework: {why}")
                continue
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                self.check_link(p, r)
                self.links.append(r)
            elif stat.S_ISDIR(st.st_mode):
                self.dirs.append(r)
                self.walk(p, r + "/")
            elif stat.S_ISREG(st.st_mode):
                if st.st_nlink != 1:
                    raise RelocateError(f"{AGENT}/{r}: a hard link ({st.st_nlink} names)")
                (self.code if is_macho(p) else self.data).append(r)
            else:
                kind = ("FIFO" if stat.S_ISFIFO(st.st_mode) else "socket" if stat.S_ISSOCK(st.st_mode)
                        else "device node")
                raise RelocateError(f"{AGENT}/{r}: a {kind}")

    def check_link(self, p: Path, r: str):
        target = os.readlink(p)
        if os.path.isabs(target):
            raise RelocateError(f"{AGENT}/{r}: an absolute link to {target}")
        lexical = os.path.normpath(os.path.join(os.path.dirname(r), target))
        if lexical == ".." or lexical.startswith("../"):
            raise RelocateError(f"{AGENT}/{r}: an escaping link to {target}")
        try:
            resolved = p.resolve(strict=True)
        except (OSError, RuntimeError) as e:
            raise RelocateError(f"{AGENT}/{r}: a dangling or looping link to {target} ({e})") from None
        root = self.agent.resolve(strict=True)
        if resolved != root and root not in resolved.parents:
            raise RelocateError(f"{AGENT}/{r}: an escaping link to {target}")


def plan(contents) -> dict:
    """The moves, without changing anything; raises RelocateError for every refusal."""
    contents = Path(contents)
    for rel in ("Frameworks", AGENT, "Resources"):
        p = contents / rel
        if p.is_symlink():
            raise RelocateError(f"{rel} is a link; refusing to relocate through it")
    if not (contents / AGENT).is_dir():
        raise RelocateError(f"{AGENT} is not a directory")
    for rel in (DEST, STAGING):
        if os.path.lexists(contents / rel):
            raise RelocateError(f"{rel} already exists: already relocated, or a stale destination")
    scan = Scan(contents)
    seen = {}
    for rel in sorted(scan.dirs + scan.code + scan.data + scan.links):
        key = fold(rel)
        if key in seen:
            raise RelocateError(f"a case-fold or Unicode-normalization collision: {seen[key]!r} and {rel!r}")
        seen[key] = rel
    impure = set()
    for rel in scan.code + scan.links:
        parts = rel.split("/")[:-1]
        impure.update("/".join(parts[:i]) for i in range(1, len(parts) + 1))
    moved_dirs = [d for d in scan.dirs if d not in impure
                  and not any(d.startswith(m + "/") for m in scan.dirs if m not in impure and m != d)]
    moved_files = [f for f in scan.data if not any(f.startswith(m + "/") for m in moved_dirs)]
    return {"dirs": sorted(moved_dirs), "files": sorted(moved_files)}


def link_target(rel: str) -> str:
    logical_parent = os.path.dirname(f"{AGENT}/{rel}")
    return os.path.relpath(f"{DEST}/{rel}", logical_parent)


def relocate(contents, fault=None) -> dict:
    """Move the planned entries; fault(), when given, is called before every mutating step."""
    contents = Path(contents)
    moves = plan(contents)
    step = fault or (lambda: None)
    journal = []  # (undo kind, path[, path]) in the order done
    staging = contents / STAGING
    try:
        if not (contents / "Resources").is_dir():
            step(); (contents / "Resources").mkdir(); journal.append(("rmdir", contents / "Resources"))
        step(); staging.mkdir(); journal.append(("rmdir", staging))
        links = []
        for rel in sorted(moves["dirs"] + moves["files"]):
            parent = staging
            for part in rel.split("/")[:-1]:
                parent = parent / part
                if not parent.exists():
                    step(); parent.mkdir(); journal.append(("rmdir", parent))
            src = contents / AGENT / rel
            step(); os.rename(src, staging / rel); journal.append(("rename", staging / rel, src))
            target = link_target(rel)
            step(); os.symlink(target, src); journal.append(("unlink", src))
            links.append((rel, target))
        step(); os.rename(staging, contents / DEST); journal.append(("rename", contents / DEST, staging))
    except BaseException:
        for entry in reversed(journal):
            if entry[0] == "rename":
                os.rename(entry[1], entry[2])
            elif entry[0] == "unlink":
                os.unlink(entry[1])
            else:
                os.rmdir(entry[1])
        raise
    return {"links": links, "files": len(moves["files"]), "dirs": len(moves["dirs"])}


def census(contents) -> list:
    """Every non-code regular file under Contents/Frameworks outside the exempt framework, relative to Contents."""
    contents = Path(contents)
    exempt = contents / AGENT / FRAMEWORK
    skip = exempt if not framework_problem(exempt) else None
    out = []
    for dirpath, dirnames, filenames in os.walk(contents / "Frameworks"):
        dirnames[:] = sorted(n for n in dirnames if Path(dirpath) / n != skip)
        for name in sorted(filenames):
            p = Path(dirpath) / name
            if stat.S_ISREG(os.lstat(p).st_mode) and not is_macho(p):
                out.append(str(p.relative_to(contents)))
    return sorted(out)


def main(argv) -> int:
    if len(argv) != 3 or argv[1] not in ("relocate", "census"):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    try:
        if argv[1] == "census":
            found = census(argv[2])
            for rel in found:
                print(rel)
            print(f"CENSUS\t{len(found)}")
            return 0
        summary = relocate(argv[2])
    except (RelocateError, OSError) as e:
        print(f"relocate_agent_data: REFUSED: {e}", file=sys.stderr)
        return 2
    for rel, target in summary["links"]:
        print(f"LINK\t{AGENT}/{rel}\t{target}")
    print(f"RELOCATED\tfiles={summary['files']}\tdirs={summary['dirs']}\tlinks={len(summary['links'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
