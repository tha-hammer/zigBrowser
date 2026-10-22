"""MS5.1b on a Mac (macOS plan; RoseCat's linked-skills resolution, "keep skipping", mail 5458), under the STAGED
pinned runtime: the staged python3.12 imports the staged zb_agent_host, and the real setup.provision builds an agent
home (the token route off: no CLI is run, no sandbox is entered) from a SAI source this case writes in its own scratch:
- ~/.claude/settings.json ({}), skills/demo/SKILL.md, and a dependency tree skills/demo/node_modules/pkg/index.js
  whose bytes name the source HOME (copied verbatim, never rewritten or scanned);
- four links that resolve outside their item, each target holding a distinct binary canary (NUL and 0xff around a
  marker): skills/demo/assets (a directory), skills/demo/notes.md (a file), skills/demo/node_modules/evil (inside the
  dependency tree) and skills/demo/up -> ../../.. (relative, up into the source HOME).
Checks: the staged host and interpreter; setup provisions the home; each link is skipped with setup's warning and is
not in the home; a fail-closed census of the whole home (every entry lstat'ed, a symlink never followed, any other
entry that is not a regular file or a directory a finding, a regular file that cannot be opened O_NOFOLLOW or read a
finding) finds no canary bytes, no marker in any name and no finding; the dependency tree is copied byte for byte.
Every path is under the real path of the scratch (macOS /tmp is a link to private/tmp; 8413992).
Kill safety: this case starts no process and sends no signal (provision runs no CLI with the route off). It reads
no other case file. Linux proof with fakes: tests/e2e/ms5_1b_hard_gate_case_test.py. PENDING its kill-safety review
(tests/mac/hard_gate_pending/): on approval it moves into tests/mac/hard_gate/ with its MANIFEST.json entry."""
import contextlib
import io
import os
import stat
import sys

NAME = "ms5.1b-skipped-links"
MARKERS = ("ZB-MS51B-DIR", "ZB-MS51B-FILE", "ZB-MS51B-DEP", "ZB-MS51B-HOME")
LINKS = ("skills/demo/assets", "skills/demo/notes.md", "skills/demo/node_modules/evil", "skills/demo/up")


def _canary(marker):
    return b"\x00" + marker.encode() + b"\xff"


def _census(root):
    """(canary hits, marker names, findings, regular files read) under `root`, failing closed."""
    found, names, findings, files = [], [], [], 0
    for top, dirs, filenames in os.walk(root, followlinks=False, onerror=lambda e: findings.append(("walk", repr(e)))):
        for name in dirs + filenames:
            path = os.path.join(top, name)
            rel = os.path.relpath(path, root)
            if any(m in name for m in MARKERS):
                names.append(rel)
            if name in dirs:
                continue
            st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode):
                continue  # never followed
            if not stat.S_ISREG(st.st_mode):
                findings.append((rel, "not a regular file"))
                continue
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                with os.fdopen(fd, "rb") as f:
                    data = f.read()
            except OSError as exc:
                findings.append((rel, f"unreadable: {exc.strerror}"))
                continue
            files += 1
            found += [(rel, m) for m in MARKERS if m.encode() in data]
    return found, names, findings, files


def run(h):
    prefix = h.prefix
    if not h.check(bool(prefix) and os.path.isdir(os.path.join(prefix or "", "zb_agent_host")),
                   f"the staged agent-host is present (ZB_HG_PREFIX={prefix!r})"):
        return
    if not h.check(bool(h.python) and os.path.realpath(sys.executable) == os.path.realpath(h.python),
                   f"this case runs under the staged interpreter ({sys.executable} vs {h.python})"):
        return
    sys.path.insert(0, prefix)
    from zb_agent_host import options, setup  # the staged tree's own modules

    scratch = os.path.realpath(h.scratch)
    source_home = os.path.join(scratch, "user")
    source = os.path.join(source_home, ".claude")
    demo = os.path.join(source, "skills", "demo")
    os.makedirs(os.path.join(demo, "node_modules", "pkg"), 0o700)
    with open(os.path.join(source, "settings.json"), "w") as f:
        f.write("{}\n")
    with open(os.path.join(demo, "SKILL.md"), "w") as f:
        f.write("demo\n")
    module_body = f"require('/usr/../x'); const home = '{source_home}/y'; // /srv/z\n".encode()
    with open(os.path.join(demo, "node_modules", "pkg", "index.js"), "wb") as f:
        f.write(module_body)
    outside = os.path.join(scratch, "outside")
    os.makedirs(os.path.join(outside, "dir"), 0o700)
    os.mkdir(os.path.join(outside, "dep"), 0o700)
    for path, marker in ((os.path.join(outside, "dir", f"{MARKERS[0]}.bin"), MARKERS[0]),
                         (os.path.join(outside, "file.md"), MARKERS[1]),
                         (os.path.join(outside, "dep", "index.js"), MARKERS[2]),
                         (os.path.join(source_home, f"{MARKERS[3]}.txt"), MARKERS[3])):
        with open(path, "wb") as f:
            f.write(_canary(marker))
    os.symlink(os.path.join(outside, "dir"), os.path.join(demo, "assets"))
    os.symlink(os.path.join(outside, "file.md"), os.path.join(demo, "notes.md"))
    os.symlink(os.path.join(outside, "dep"), os.path.join(demo, "node_modules", "evil"))
    os.symlink("../../..", os.path.join(demo, "up"))

    home = options.AgentHome(os.path.join(scratch, "data", "zigbrowser", "agent-home"))
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            setup.provision(home=home, source=source, source_home=source_home, source_path="/usr/bin:/bin",
                            python=h.python, select_token_route=False, cli=h.cli)
        made = None
    except Exception as exc:  # noqa: BLE001 - reported as the check's own evidence
        made = repr(exc)
    if not h.check(made is None, f"setup provisions the home ({made or 'ok'}; stderr tail {err.getvalue()[-300:]!r})"):
        return
    for rel in LINKS:
        h.check(f"skipped {rel}: it links outside" in err.getvalue()
                and not os.path.lexists(os.path.join(str(home.root), ".claude", rel)),
                f"skipped {rel} with setup's warning, and it is not in the home")
    found, names, findings, files = _census(str(home.root))
    h.check(files > 10 and (found, names, findings) == ([], [], []),
            f"no canary bytes, marker names or census findings anywhere in the home ({files} files read; "
            f"hits {found[:4]}, names {names[:4]}, findings {findings[:4]})")
    copied = os.path.join(str(home.root), ".claude", "skills", "demo", "node_modules", "pkg", "index.js")
    try:
        with open(copied, "rb") as f:
            same = f.read() == module_body
    except OSError:
        same = False
    h.check(same, "the dependency tree beside the skipped link is copied byte for byte")
