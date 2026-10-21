"""The staged runtime's ONE .pth (27a9a62: the staged python3.12 could not import claude_agent_sdk on either Mac).

packaging/macos/agent_host_sdk.pth is one relative path line. Staging copies it into the staged framework's OWN
site-packages (<agent-host>/Python.framework/Versions/3.12/lib/python3.12/site-packages) as zb_agent_host_sdk.pth,
so the staged interpreter, -I included (-I is -E -P -s, never -S: site still processes its prefix's .pth files), puts
<agent-host>/site-packages on sys.path with no PYTHONPATH. The line is relative to the .pth's own directory, so it
holds wherever the bundle moves, and it names nothing outside the bundle. A .pth line that starts with "import" runs
code at every interpreter start: that, any other line, and any other .pth there are refused (the orchestrator's
conditions, 2026-10-21). Stdlib only; staging runs it under the Mac's /usr/bin/python3 -I.

  sdk_pth.py install <framework site-packages> <agent-host>   write the committed bytes there, then check
  sdk_pth.py check <framework site-packages> <agent-host>     exit 1 naming each problem
"""
import os
import stat
import sys
from pathlib import Path

NAME = "zb_agent_host_sdk.pth"
COMMITTED = Path(__file__).resolve().parent / "agent_host_sdk.pth"


class Refused(Exception):
    pass


def line_problem(raw, site_dir, agent):
    """Why `raw` is not one plain relative path line naming exactly <agent>/site-packages from `site_dir`, or None."""
    if not raw.endswith(b"\n") or raw.count(b"\n") != 1:
        return "not exactly one newline-terminated line"
    try:
        text = raw[:-1].decode("ascii")
    except UnicodeDecodeError:
        return "not ASCII"
    if not text or text != text.strip() or "\r" in text or "\0" in text:
        return "an empty line, surrounding whitespace, CR or NUL"
    if text.startswith(("import ", "import\t")):
        return "an import line (it runs code at every interpreter start)"
    if text.startswith("#"):
        return "a comment, not a path"
    if os.path.isabs(text) or text.startswith("~"):
        return "an absolute or home path (the line must be relative to the .pth's own directory)"
    target = os.path.realpath(os.path.join(site_dir, text))
    want = os.path.realpath(os.path.join(agent, "site-packages"))
    if target != want:
        return f"it resolves to {target}, not {want}"
    return None


def _pth_names(site_dir):
    return sorted(n for n in os.listdir(site_dir) if n.lower().endswith(".pth"))


def problems(site_dir, agent):
    """[] only when `site_dir` holds exactly one .pth, NAME: a regular, unhidden file with the committed bytes, whose
    line is a plain relative path to <agent>/site-packages."""
    try:
        names = _pth_names(site_dir)
    except OSError as e:
        return [f"{site_dir}: {e}"]
    probs = [f"a stray .pth: {n}" for n in names if n != NAME]
    path = os.path.join(site_dir, NAME)
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return probs + [f"{NAME} is missing"]
    if not stat.S_ISREG(st.st_mode):
        return probs + [f"{NAME} is not a regular file (a symlink or special entry)"]
    if getattr(st, "st_flags", 0) & getattr(stat, "UF_HIDDEN", 0):
        return probs + [f"{NAME} is flagged hidden (site skips it)"]
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as f:
        raw = f.read(4097)
    why = line_problem(raw, site_dir, agent)
    if why:
        probs.append(f"{NAME}: {why}")
    elif raw != COMMITTED.read_bytes():
        probs.append(f"{NAME} is not the committed {COMMITTED.name}")
    return probs


def install(site_dir, agent):
    """Writes the committed bytes as site_dir/NAME, then checks. Refused, with nothing written, when any .pth is
    already there or the committed line itself is not a plain path into the bundle."""
    try:
        names = _pth_names(site_dir)
    except OSError as e:
        raise Refused(f"{site_dir}: {e}") from e
    if names:
        raise Refused(f"a .pth is already there (refused, never merged): {names}")
    raw = COMMITTED.read_bytes()
    why = line_problem(raw, site_dir, agent)
    if why:
        raise Refused(f"{COMMITTED.name}: {why}")
    fd = os.open(os.path.join(site_dir, NAME), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "wb") as f:
        f.write(raw)
    probs = problems(site_dir, agent)
    if probs:
        raise Refused("; ".join(probs))


def main(argv):
    if len(argv) != 4 or argv[1] not in ("install", "check"):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        if argv[1] == "install":
            install(argv[2], argv[3])
            return 0
        probs = problems(argv[2], argv[3])
    except Refused as e:
        print(f"sdk_pth: refused: {e}", file=sys.stderr)
        return 1
    for p in probs:
        print(f"sdk_pth: {p}", file=sys.stderr)
    return 1 if probs else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
