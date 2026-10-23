"""4pa.80 slice 1 (SilverRidge a365949c): packaging/macos/relocate_agent_data.py, the layout hypothesis after the
released Stage B at d80dd3ee showed codesign refusing to sign the app because ordinary Python files sit under
Contents/Frameworks/agent-host ("code object is not signed at all ... In subcomponent: .../site-packages/jwt/*.py").

The helper keeps the logical runtime path Contents/Frameworks/agent-host (src/agent_setup.zig, token.bundled_cli(),
ms5_inventory) and moves every non-code file of it physically to Contents/Resources/agent-host/<same relative
path>, leaving only relative, bundle-internal links at the logical paths: a directory whose subtree holds no Mach-O
file and no link becomes one directory link; a mixed directory stays real, with one link per non-code file. Code is
the actual Mach-O census (magic bytes; a FAT header must name a plausible slice count), never a name or an execute
bit. Only the exact Python framework at agent-host/Python.framework is exempt, and only after validation; any other
`.framework` directory is ordinary. Every regular file left under Contents/Frameworks outside that framework must be
Mach-O.

  relocate_agent_data.py relocate <Contents>   prints sorted LINK lines and RELOCATED<TAB>files=<n><TAB>dirs=<n><TAB>
                                               links=<n>; exit 0
  relocate_agent_data.py census <Contents>     prints every non-code regular file under Contents/Frameworks outside
                                               the validated framework, then CENSUS<TAB><n>; exit 0
  refusals print "relocate_agent_data: REFUSED: <why>" on stderr, exit 2, and change nothing.

API: plan(contents) (raises RelocateError), relocate(contents, fault=None) -> summary, census(contents) -> [rel]. The
optional fault() is called before every mutating filesystem step, so a test can fail any step.

Rows:
  R1  the relocated layout: non-code files moved, pure directories as one link, mixed directories real, Mach-O and
      the Python framework untouched;
  R2  the logical namespace is unchanged: every original path resolves through Contents/Frameworks/agent-host to the
      same type, bytes and permission bits (setuid/sticky/exec included), and pre-existing internal links still are
      links with their targets;
  R3  code is the Mach-O census: a Mach-O named .txt without an exec bit stays; an executable non-Mach-O named .so,
      and a Java class file (CAFEBABE with a version, not a slice count) move;
  R4  only the exact, valid Python framework is exempt: an arbitrary x.framework is relocated; a malformed
      Python.framework (Current not 3.12, a non-Mach-O Versions/3.12/Python, an extra root entry) is refused;
  R5  links: every created link is relative and resolves inside the bundle; an absolute, escaping or looping link, a
      link that is lexically inside but escapes through another link, and a symlinked ancestor (Contents/Frameworks
      or agent-host itself), are refused, each for its own reason;
  R6  a hard link, a FIFO, a socket or a device node is refused;
  R7  an existing Contents/Resources/agent-host is refused, and so a second run on a relocated tree is refused
      ("already relocated") and changes nothing;
  R8  a case-fold collision or a Unicode-normalization collision among the moved paths is refused;
  R9  any failed step leaves the original tree exactly as it was, no temporary entry and no Resources/agent-host;
  R10 deterministic: two identical trees in different places give identical results and identical stdout;
  R11 the consumer check: through the logical path, runtime.json, zb_agent_host (the committed package, imported by
      a real Python), site-packages, the framework's .pth, token.bundled_cli() (the committed function, returning
      the logical CLI path, still executable) and every ms5_inventory agent-host path resolve;
  R12 census: 0 after relocation; the one pinned stray file of the 4pa.80 control counts as 1, by its path.
Every refusal row also checks that nothing changed (a full before/after listing).
Run (as the gate does, in a private user+mount namespace for the device row):
  cd tests/e2e && unshare --user --map-root-user --mount python3 -X dev -m unittest -v mac_relocate_agent_data_test
"""
import hashlib
import importlib.util
import os
import socket
import stat
import subprocess
import sys
import tempfile
import unicodedata
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "packaging" / "macos" / "relocate_agent_data.py"
MACHO_X86 = bytes.fromhex("cffaedfe07000001") + b"\0" * 24   # MH_MAGIC_64, x86_64
MACHO_FAT = bytes.fromhex("cafebabe00000002") + b"\0" * 24   # FAT_MAGIC, 2 slices
JAVA_CLASS = bytes.fromhex("cafebabe00000037") + b"\0" * 24  # Java class file, version 55: not a slice count
STRAY = "Frameworks/agent-host/zb-4pa80-stray.txt"            # the 4pa.80 control's pinned stray file


def load():
    if not SCRIPT.is_file():
        raise AssertionError("packaging/macos/relocate_agent_data.py is missing (4pa.80 slice 1)")
    spec = importlib.util.spec_from_file_location("relocate_agent_data", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def write(path, data, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())
    os.chmod(path, mode)


def build(root: Path) -> Path:
    """A staged-like .app Contents: the stager's agent-host layout, with the tricky files of R3/R4."""
    c = root / "zigBrowser.app" / "Contents"
    write(c / "MacOS" / "zigBrowser", MACHO_FAT, 0o755)
    write(c / "Frameworks" / "libwkwebview_shim.dylib", MACHO_FAT, 0o755)
    write(c / "Resources" / "AppIcon.icns", "icon")
    write(c / "Info.plist", "<plist/>")
    a = c / "Frameworks" / "agent-host"
    v = a / "Python.framework" / "Versions" / "3.12"
    write(v / "Python", MACHO_FAT, 0o755)
    write(v / "bin" / "python3.12", MACHO_FAT, 0o755)
    write(v / "lib" / "python3.12" / "os.py", "import sys\n")
    write(v / "lib" / "python3.12" / "lib-dynload" / "_json.cpython-312-darwin.so", MACHO_FAT, 0o755)
    write(v / "lib" / "python3.12" / "site-packages" / "zb_agent_host_sdk.pth",
          (REPO / "packaging" / "macos" / "agent_host_sdk.pth").read_bytes())
    write(v / "Resources" / "Info.plist", "<plist/>")
    write(v / "include" / "python3.12" / "Python.h", "/* */\n")
    os.symlink("include/python3.12", v / "Headers")
    # the root of the real python.org 3.12.10 Payload: Headers, Python, Resources, Versions/{3.12,Current}
    os.symlink("3.12", a / "Python.framework" / "Versions" / "Current")
    os.symlink("Versions/Current/Headers", a / "Python.framework" / "Headers")
    os.symlink("Versions/Current/Python", a / "Python.framework" / "Python")
    os.symlink("Versions/Current/Resources", a / "Python.framework" / "Resources")
    pkg = REPO / "agent" / "host" / "zb_agent_host"
    for src in sorted(pkg.rglob("*")):   # as ms5_inventory.package_files: every regular file, no __pycache__
        if src.is_file() and not src.is_symlink() and "__pycache__" not in src.parts:
            write(a / "zb_agent_host" / src.relative_to(pkg), src.read_bytes(), stat.S_IMODE(src.stat().st_mode))
    write(a / "runtime.json", '{"lock_sha256": "00"}\n')
    sp = a / "site-packages"
    write(sp / "claude_agent_sdk" / "__init__.py", "")
    write(sp / "claude_agent_sdk" / "_bundled" / "claude", MACHO_FAT, 0o755)
    write(sp / "jwt" / "__init__.py", "from .utils import X\n")
    write(sp / "jwt" / "utils.py", "X = 1\n")
    write(sp / "jwt" / "setuid_data.bin", "odd", 0o4755)   # permission bits must survive the move
    write(sp / "rpds" / "__init__.py", "")
    write(sp / "rpds" / "rpds.cpython-312-darwin.so", MACHO_X86, 0o755)
    write(sp / "rpds-0.1.dist-info" / "RECORD", "rpds/__init__.py,,\n")
    write(sp / "oddly_named.txt", MACHO_X86, 0o644)           # Mach-O, no exec bit: code
    write(sp / "script.so", "#!/bin/sh\n", 0o755)             # executable, named .so, not Mach-O: data
    write(sp / "Foo.class", JAVA_CLASS, 0o644)                # CAFEBABE but a Java class: data
    write(sp / "fake.framework" / "Versions" / "A" / "data.txt", "not exempt")
    os.symlink("jwt", sp / "jwt_alias")                       # a pre-existing internal link
    return c


def listing(c: Path) -> list:
    """Every entry under the .app, relative: type, permission bits, link target, content hash."""
    app = c.parent
    out = []
    for dirpath, dirnames, filenames in os.walk(app):
        dirnames.sort()
        for name in sorted(dirnames + filenames):
            p = Path(dirpath) / name
            st = os.lstat(p)
            rel = str(p.relative_to(app))
            if stat.S_ISLNK(st.st_mode):
                out.append((rel, "l", os.readlink(p)))
            elif stat.S_ISDIR(st.st_mode):
                out.append((rel, "d", oct(stat.S_IMODE(st.st_mode))))
            elif stat.S_ISREG(st.st_mode):
                out.append((rel, "f", oct(stat.S_IMODE(st.st_mode)), st.st_nlink, hashlib.sha256(p.read_bytes()).hexdigest()))
            else:   # FIFO, socket, device: never opened
                out.append((rel, "other", oct(st.st_mode)))
    return out


def logical(c: Path, before: list) -> list:
    """The original entries as seen through the logical paths after relocation (links followed)."""
    app = c.parent
    out = []
    for e in before:
        p = app / e[0]
        if e[1] == "l":
            out.append((e[0], "l", os.readlink(p)) if p.is_symlink() else (e[0], "NOT A LINK"))
        elif e[1] == "d":
            out.append((e[0], "d", oct(stat.S_IMODE(os.stat(p).st_mode))) if p.is_dir() else (e[0], "NOT A DIR"))
        else:
            out.append((e[0], "f", oct(stat.S_IMODE(os.stat(p).st_mode)), os.stat(p).st_nlink,
                        hashlib.sha256(p.read_bytes()).hexdigest()) if p.is_file() else (e[0], "MISSING"))
    return out


def run_cli(*args):
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True)


class Base(unittest.TestCase):
    def setUp(self):
        self.mod = load()
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.c = build(self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def refused(self, mutate, needle):
        """mutate(c) breaks the tree; plan(), relocate() and the CLI must refuse and change nothing."""
        mutate(self.c)
        before = listing(self.c)
        with self.assertRaises(self.mod.RelocateError) as cm:
            self.mod.relocate(self.c)
        self.assertIn(needle, str(cm.exception))
        self.assertEqual(listing(self.c), before, "a refused relocate changed the tree")
        r = run_cli("relocate", str(self.c))
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("relocate_agent_data: REFUSED:", r.stderr)
        self.assertEqual(listing(self.c), before, "a refused CLI run changed the tree")


class Relocation(Base):
    def test_r1_layout(self):
        self.mod.relocate(self.c)
        a, res = self.c / "Frameworks" / "agent-host", self.c / "Resources" / "agent-host"
        for pure in ("zb_agent_host", "site-packages/jwt", "site-packages/rpds-0.1.dist-info", "site-packages/fake.framework"):
            self.assertTrue((a / pure).is_symlink(), f"{pure}: a pure directory becomes one link")
            self.assertTrue((res / pure).is_dir() and not (res / pure).is_symlink(), f"{pure}: physically in Resources")
        for mixed in ("", "site-packages", "site-packages/claude_agent_sdk", "site-packages/claude_agent_sdk/_bundled", "site-packages/rpds"):
            p = a / mixed
            self.assertTrue(p.is_dir() and not p.is_symlink(), f"{mixed or 'agent-host'}: a mixed directory stays real")
        for moved in ("runtime.json", "site-packages/claude_agent_sdk/__init__.py", "site-packages/rpds/__init__.py",
                      "site-packages/script.so", "site-packages/Foo.class"):
            self.assertTrue((a / moved).is_symlink(), f"{moved}: a non-code file becomes a link")
            self.assertTrue((res / moved).is_file() and not (res / moved).is_symlink(), f"{moved}: physically in Resources")
        for code in ("site-packages/claude_agent_sdk/_bundled/claude", "site-packages/rpds/rpds.cpython-312-darwin.so",
                     "site-packages/oddly_named.txt"):
            self.assertTrue((a / code).is_file() and not (a / code).is_symlink(), f"{code}: Mach-O stays")
            self.assertFalse((res / code).exists(), f"{code}: Mach-O is not copied to Resources")

    def test_r1_framework_untouched(self):
        fw = self.c / "Frameworks" / "agent-host" / "Python.framework"
        before = [e for e in listing(self.c) if e[0].startswith("Contents/Frameworks/agent-host/Python.framework")]
        self.mod.relocate(self.c)
        after = [e for e in listing(self.c) if e[0].startswith("Contents/Frameworks/agent-host/Python.framework")]
        self.assertEqual(after, before)
        self.assertFalse((self.c / "Resources" / "agent-host" / "Python.framework").exists())
        self.assertTrue(fw.is_dir())

    def test_r2_logical_namespace(self):
        before = listing(self.c)
        self.mod.relocate(self.c)
        self.assertEqual(logical(self.c, before), before)

    def test_r3_code_is_the_macho_census(self):
        self.mod.relocate(self.c)
        self.assertEqual(self.mod.census(self.c), [])
        a = self.c / "Frameworks" / "agent-host" / "site-packages"
        self.assertFalse((a / "oddly_named.txt").is_symlink())
        self.assertTrue((a / "script.so").is_symlink())
        self.assertTrue((a / "Foo.class").is_symlink())

    def test_r4_arbitrary_framework_is_not_exempt(self):
        self.mod.relocate(self.c)
        self.assertTrue((self.c / "Resources" / "agent-host" / "site-packages" / "fake.framework" / "Versions" / "A" / "data.txt").is_file())

    def test_r4_malformed_python_framework_refused(self):
        fw = lambda c: c / "Frameworks" / "agent-host" / "Python.framework"
        def current_elsewhere(c):
            os.unlink(fw(c) / "Versions" / "Current"); os.symlink("3.11", fw(c) / "Versions" / "Current")
        self.refused(current_elsewhere, "Python.framework")

    def test_r4_non_macho_framework_binary_refused(self):
        self.refused(lambda c: write(c / "Frameworks" / "agent-host" / "Python.framework" / "Versions" / "3.12" / "Python", "text"),
                     "Python.framework")

    def test_r4_extra_framework_root_entry_refused(self):
        self.refused(lambda c: write(c / "Frameworks" / "agent-host" / "Python.framework" / "stray.txt", "x"), "Python.framework")

    def test_r5_links_relative_inside_bundle(self):
        self.mod.relocate(self.c)
        app = self.c.parent.resolve()
        for dirpath, dirnames, filenames in os.walk(self.c / "Frameworks" / "agent-host"):
            for name in dirnames + filenames:
                p = Path(dirpath) / name
                if p.is_symlink():
                    self.assertFalse(os.path.isabs(os.readlink(p)), f"{p}: an absolute link")
                    self.assertTrue(str(p.resolve()).startswith(str(app) + os.sep), f"{p}: resolves outside the bundle")

    def test_r5_absolute_link_refused(self):
        self.refused(lambda c: os.symlink("/etc/hosts", c / "Frameworks" / "agent-host" / "site-packages" / "abs"), "an absolute link")

    def test_r5_escaping_link_refused(self):
        self.refused(lambda c: os.symlink("../../../../../../outside", c / "Frameworks" / "agent-host" / "site-packages" / "esc"), "an escaping link")

    def test_r5_looping_link_refused(self):
        def loop(c):
            sp = c / "Frameworks" / "agent-host" / "site-packages"
            os.symlink("loop_b", sp / "loop_a"); os.symlink("loop_a", sp / "loop_b")
        self.refused(loop, "looping link")

    def test_r5_escape_through_another_link_refused(self):
        def through(c):
            # lexically inside agent-host, but _bundled/up is agent-host itself, so its parent is Frameworks
            sp = c / "Frameworks" / "agent-host" / "site-packages"
            os.symlink("../../..", sp / "claude_agent_sdk" / "_bundled" / "up")
            os.symlink("../claude_agent_sdk/_bundled/up/..", sp / "jwt" / "sneak")
        self.refused(through, "an escaping link")

    def test_r5_symlinked_ancestor_refused(self):
        def ancestor(c):
            real = c / "Frameworks" / "agent-host.real"
            os.rename(c / "Frameworks" / "agent-host", real)
            os.symlink("agent-host.real", c / "Frameworks" / "agent-host")
        self.refused(ancestor, "agent-host")

    def test_r6_hard_link_refused(self):
        self.refused(lambda c: os.link(c / "Frameworks" / "agent-host" / "runtime.json",
                                       c / "Frameworks" / "agent-host" / "site-packages" / "hard.json"), "hard link")

    def test_r6_fifo_refused(self):
        self.refused(lambda c: os.mkfifo(c / "Frameworks" / "agent-host" / "site-packages" / "pipe"), "FIFO")

    def test_r6_socket_refused(self):
        def sock(c):
            d = c / "Frameworks" / "agent-host" / "site-packages"
            cwd = os.getcwd()
            os.chdir(d)
            try:
                s = socket.socket(socket.AF_UNIX); s.bind("sock"); s.close()
            finally:
                os.chdir(cwd)
        self.refused(sock, "socket")

    def test_r6_device_refused(self):
        if os.geteuid() != 0:
            self.fail("the device row needs the gate's private user+mount namespace (unshare --user --map-root-user --mount)")
        node = self.c / "Frameworks" / "agent-host" / "site-packages" / "dev"
        write(node, "")
        subprocess.run(["mount", "--bind", "/dev/null", str(node)], check=True)
        try:
            self.assertTrue(stat.S_ISCHR(os.lstat(node).st_mode))
            self.refused(lambda c: None, "device")
        finally:
            subprocess.run(["umount", str(node)], check=False)

    def test_r7_existing_destination_refused(self):
        self.refused(lambda c: (c / "Resources" / "agent-host").mkdir(), "Resources/agent-host")

    def test_r7_second_run_refused(self):
        self.mod.relocate(self.c)
        after = listing(self.c)
        r = run_cli("relocate", str(self.c))
        self.assertEqual(r.returncode, 2)
        self.assertIn("already relocated", r.stderr)
        self.assertEqual(listing(self.c), after)

    def test_r8_case_fold_collision_refused(self):
        self.refused(lambda c: (write(c / "Frameworks" / "agent-host" / "site-packages" / "jwt" / "Utils.py", "Y = 2\n")), "collision")

    def test_r8_unicode_collision_refused(self):
        def nf(c):
            d = c / "Frameworks" / "agent-host" / "site-packages" / "jwt"
            write(d / unicodedata.normalize("NFC", "café.py"), "a")
            write(d / unicodedata.normalize("NFD", "café.py"), "b")
        self.refused(nf, "collision")

    def test_r9_failed_step_leaves_the_tree(self):
        calls = []
        self.mod.relocate(build(self.root / "count"), fault=lambda: calls.append(1))
        n = len(calls)
        self.assertGreater(n, 3, "relocate must call fault() before every mutating step")
        for k in sorted({1, 2, 3, n // 2, n - 1, n}):
            with self.subTest(fail_at=k):
                root = self.root / f"f{k}"
                c = build(root)
                before = listing(c)
                seen = []
                def fault():
                    seen.append(1)
                    if len(seen) == k:
                        raise OSError(f"injected at step {k}")
                with self.assertRaises(OSError):
                    self.mod.relocate(c, fault=fault)
                self.assertEqual(listing(c), before, f"step {k}: the tree changed")
                self.assertFalse((c / "Resources" / "agent-host").exists())

    def test_r10_deterministic(self):
        c1, c2 = build(self.root / "one"), build(self.root / "two")
        r1, r2 = run_cli("relocate", str(c1)), run_cli("relocate", str(c2))
        self.assertEqual((r1.returncode, r2.returncode), (0, 0), r1.stderr + r2.stderr)
        self.assertEqual(r1.stdout, r2.stdout)
        self.assertEqual(listing(c1), listing(c2))
        self.assertRegex(r1.stdout.splitlines()[-1], r"^RELOCATED\tfiles=\d+\tdirs=\d+\tlinks=\d+$")

    def test_r11_consumer_check(self):
        self.mod.relocate(self.c)
        a = self.c / "Frameworks" / "agent-host"
        self.assertEqual((a / "runtime.json").read_text(), '{"lock_sha256": "00"}\n')
        pth = a / "Python.framework" / "Versions" / "3.12" / "lib" / "python3.12" / "site-packages" / "zb_agent_host_sdk.pth"
        line = pth.read_text().strip()
        self.assertEqual((pth.parent / line).resolve(), (a / "site-packages").resolve())
        probe = (
            "import sys, os, json\n"
            f"sys.path[:0] = [{str(a)!r}, {str(a / 'site-packages')!r}]\n"
            "import zb_agent_host.token as t, jwt\n"
            "p = t.bundled_cli()\n"
            "print(json.dumps({'cli': p, 'x': os.access(p, os.X_OK), 'token': t.__file__, 'jwt': jwt.X}))\n")
        r = subprocess.run(["/usr/bin/python3", "-I", "-c", probe], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        import json
        got = json.loads(r.stdout)
        self.assertEqual(got["cli"], str(a / "site-packages" / "claude_agent_sdk" / "_bundled" / "claude"))
        self.assertTrue(got["x"], "the bundled CLI is not executable through the logical path")
        self.assertEqual(got["token"], str(a / "zb_agent_host" / "token.py"))
        self.assertEqual(got["jwt"], 1)
        spec = importlib.util.spec_from_file_location("ms5_inventory", REPO / "packaging" / "macos" / "ms5_inventory.py")
        inv_mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(inv_mod)
        inv = inv_mod.generate(REPO)
        paths = [e.get("path_glob") or e.get("path") for k in ("components", "resources") for e in inv.get(k, [])]
        agent_paths = [p for p in paths if p and p.startswith(inv_mod.AGENT + "/")]
        self.assertGreater(len(agent_paths), 5)
        for p in agent_paths:
            self.assertTrue((self.c / p).exists(), f"inventory path {p} does not resolve through the logical layout")

    def test_r12_census(self):
        self.assertGreater(len(self.mod.census(self.c)), 0, "the staged tree has data under Frameworks")
        self.mod.relocate(self.c)
        self.assertEqual(self.mod.census(self.c), [])
        write(self.c / STRAY, "zb-4pa80-control\n")
        self.assertEqual(self.mod.census(self.c), [STRAY])
        r = run_cli("census", str(self.c))
        self.assertEqual((r.returncode, r.stdout), (0, f"{STRAY}\nCENSUS\t1\n"))


if __name__ == "__main__":
    unittest.main()
