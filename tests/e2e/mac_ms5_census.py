"""MS5.1c census checks beyond the MS1 census (macOS plan rev 17; RoseCat 6865, 6871).

- runtime.json is exactly tools/install_agent_runtime.sh's bytes for the repo's uv.lock;
- the staged zb_agent_host/ is EXACT: every entry is a listed regular file or a directory implied by one; anything
  else (a missing or extra file, an extra directory, any symlink, any special file) is a problem. The walk uses
  lstat only: it never follows a symlink and never opens a FIFO or device.
"""
import hashlib
import os
import stat
from pathlib import Path


def expected_runtime_json(uv_lock: bytes) -> bytes:
    return ('{"lock_sha256": "%s"}\n' % hashlib.sha256(uv_lock).hexdigest()).encode()


def runtime_json_problem(content: bytes, uv_lock: bytes):
    """None when `content` is exactly the installer's runtime.json for `uv_lock`, else a reason."""
    want = expected_runtime_json(uv_lock)
    return None if content == want else f"runtime.json is not exactly {want!r} (got {content[:120]!r})"


def package_problems(root: Path, listed: list[str]) -> list[str]:
    """Problems with the tree under `root` against `listed` (paths like "zb_agent_host/a/b.py", relative to `root`).

    Every entry below each listed top directory must be a listed regular file or a directory that a listed
    file's path implies. Uses os.lstat / os.scandir(follow_symlinks=False) only."""
    files = set(listed)
    dirs = set()
    for rel in files:
        parts = rel.split("/")
        for i in range(1, len(parts)):
            dirs.add("/".join(parts[:i]))
    tops = sorted({rel.split("/", 1)[0] for rel in files})
    problems = []
    seen = set()

    def walk(rel_dir: str):
        try:
            entries = list(os.scandir(root / rel_dir))
        except OSError as err:
            problems.append(f"cannot list {rel_dir}: {err.strerror}")
            return
        for e in sorted(entries, key=lambda e: e.name):
            rel = f"{rel_dir}/{e.name}"
            st = os.lstat(e.path)
            if stat.S_ISLNK(st.st_mode):
                problems.append(f"symlink refused: {rel}")
            elif stat.S_ISDIR(st.st_mode):
                if rel not in dirs:
                    problems.append(f"extra directory: {rel}")
                else:
                    walk(rel)
            elif stat.S_ISREG(st.st_mode):
                if rel in files:
                    seen.add(rel)
                else:
                    problems.append(f"extra file: {rel}")
            else:
                problems.append(f"special file refused: {rel}")

    for top in tops:
        try:
            st = os.lstat(root / top)
        except FileNotFoundError:
            problems.append(f"missing directory: {top}")
            continue
        if stat.S_ISLNK(st.st_mode):
            problems.append(f"symlink refused: {top}")
            continue
        if not stat.S_ISDIR(st.st_mode):
            problems.append(f"not a directory: {top}")
            continue
        walk(top)
    for rel in sorted(files - seen):
        if not any(p.startswith(f"symlink refused: {rel}") for p in problems):
            problems.append(f"missing file: {rel}")
    return problems
