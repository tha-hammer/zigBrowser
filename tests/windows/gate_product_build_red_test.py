#!/usr/bin/env python3
r"""ong.9 RED (UNREGISTERED), NavyCanyon 0d549813: the product run builds and fetches its own exact-commit exe through
the real tests/windows/build-on-windows.sh before the phase list, and exports exactly that exe to every row.

Today `product_run` never builds: every phase entry reads the caller's ZB_WIN_EXE, so nothing ties the tested exe to
the commit and an unattended run is impossible.

Pinned (0d549813):
  - LOCAL preflight before vm_readiness (which already contacts Win11): a nonempty phase list; any PRESENCE of
    ZB_WIN_EXE (even empty) refused, rc 2; the repository top level and the full `HEAD^{commit}` sha resolved (a git
    failure is a refusal); the physical top level equal to ZB_GATE_ROOT; `git status --porcelain
    --untracked-files=all` empty (ignored files stay ignored). Each refusal makes no ssh/scp call at all;
  - the order: VM session < VM probe < stage < build < fetch < Win10 session < Win10 pre probe < first row < last
    row < Win10 post probe;
  - the build is the REAL driver, for the full sha, in ReleaseSafe, staging THIS repository (the staged archive
    holds this root's unique marker), isolated from ambient build/toolchain/deadline/selftest overrides and from a
    bait ZB_BUILD_COMMIT;
  - every row sees one identical absolute ZB_WIN_EXE inside the run's own zb-gate-product.* work directory, an MZ
    file whose adjacent .sha is the full sha; a missing exe, a mismatched .sha or an exe resolving outside the work
    directory is refused before any row (a narrowly scoped fake driver, committed into the repo, emits those three);
  - a stage, build, fetch or non-PE failure of the real driver stops the run before any Win10 contact and any row;
  - the work directory is gone after every path: build failure, a bad exe, Win10 session, pre-probe and
    product-pre failure, and the normal end (checked right after the gate returns);
  - guards: a healthy run passes; an ignored file does not dirty the tree; --probe-only makes no stage, build or
    fetch call; an unset host is named.

The REAL gate.sh and the REAL build-on-windows.sh run from a temporary git repository (the gate root) holding the
gate's own files, a phase list of fake live tests and a unique marker, all committed; every piece of fake state (fake
bin, logs, HOME, TMPDIR) lives OUTSIDE that repository. The fakes: gate_twohost_selftest's ssh/virsh with the ong.8
order prefix, plus a build prefix (the driver's stage ssh saves the streamed archive, its build ssh decodes the
-EncodedCommand), and an scp that writes an `MZ` file (or fails, or writes a non-PE file). TEST-NET hosts only;
fake_transport.problem is checked on every ssh/scp argv.

R2 (NavyCanyon b3f95193): a real-driver failure names its exact propagated rc (stage 5, build 6, fetch 7, non-PE 3);
two successful runs against the same repository and TMPDIR get two distinct owned work directories and executables,
and a pre-existing decoy sibling stays byte-identical; a fake `rm` intercepts ONLY the exact
$TMPDIR/zb-gate-product.* target (delegating every other rm, the real driver's included) so the gate makes exactly one
cleanup attempt on exactly its own directory, and a failed or no-op removal fails an otherwise successful run (naming
the cleanup) or is reported beside an earlier build/Win10 failure, which keeps its own diagnostic.

R3 (NavyCanyon b5776a41): the build-side fakes (the driver's stage/build ssh and its scp) take NO test variable: their
log and control paths are absolute paths outside the repository, embedded when the fixture is written, and the
harness writes per-run control files there. Each records its own environment, and a passing build's child env must
hold exactly the ZB_* names ZB_WIN11_{HOST,PORT,USER,KEY,KNOWN_HOSTS}, ZB_BUILD_COMMIT, ZB_WIN_EXE and ZB_BUILD_MODE,
with no ZB_FAKE_*, ZB_SELFTEST_*, legacy or Win10 selector, display or askpass name. The gate-side Win11/Win10 fakes
and the scoped cleanup wrapper are unchanged.

Run alone:  unshare --user --map-current-user --net python3 -I tests/windows/gate_product_build_red_test.py -v
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import uuid

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gate_twohost_selftest as gts  # noqa: E402
import gate_win10_product_red_test as g8  # noqa: E402

GIT = shutil.which("git", path="/usr/bin:/bin")
GATE_FILES = (*gts._GATE_FILES, "build-on-windows.sh")
BUILD_FAILED = "the Win11 build/fetch failed"
BAD_EXE = "the built exe"

# Before the ong.8 prefix: answer (and record) build-on-windows.sh's own stage and build ssh calls. b5776a41: no test
# variable crosses the build boundary, so @CTL@/@RAN@/@ORDER@/@SSHLOG@ are absolute paths (outside the repository)
# written in when the fixture is created; per-run behaviour comes from control files the harness writes in @CTL@.
_BUILD_PREFIX = r'''
__a="$*"
__ran0=0
if [ -s '@RAN@' ]; then __ran0=$(grep -c . '@RAN@'); fi
case "$__a" in
  *"tar -x -f -"*)
    printf 'ARGV: %s\n' "$*" >> '@SSHLOG@'
    printf 'win11 stage ran=%s nonce=\n' "$__ran0" >> '@ORDER@'
    env > '@CTL@/env-stage'
    cat > '@CTL@/stage.tar'
    __rc=0; [ -f '@CTL@/stage_rc' ] && __rc=$(cat '@CTL@/stage_rc')
    exit "$__rc" ;;
  *"-EncodedCommand "*)
    printf 'ARGV: %s\n' "$*" >> '@SSHLOG@'
    printf 'win11 build ran=%s nonce=\n' "$__ran0" >> '@ORDER@'
    env > '@CTL@/env-build'
    printf '%s' "${__a##*-EncodedCommand }" | base64 -d | iconv -f UTF-16LE -t UTF-8 > '@CTL@/build.ps1'
    __rc=0; [ -f '@CTL@/build_rc' ] && __rc=$(cat '@CTL@/build_rc')
    exit "$__rc" ;;
esac
'''
_SCP = r'''#!/usr/bin/env bash
printf 'ARGV: %s\n' "$*" >> '@SSHLOG@'
__ran0=0
if [ -s '@RAN@' ]; then __ran0=$(grep -c . '@RAN@'); fi
printf 'win11 fetch ran=%s nonce=\n' "$__ran0" >> '@ORDER@'
env > '@CTL@/env-fetch'
dest="${@: -1}"
if [ -f '@CTL@/scp_rc' ]; then exit "$(cat '@CTL@/scp_rc')"; fi
if [ -f '@CTL@/scp_nonpe' ]; then printf 'XXnot a pe\n' > "$dest"; else printf 'MZ fake zigBrowser.exe\n' > "$dest"; fi
exit 0
'''
# Test controls the harness turns into control files (never environment) for the build-side fakes.
_CONTROLS = {"ZB_FAKE_STAGE_RC": "stage_rc", "ZB_FAKE_BUILD_RC": "build_rc", "ZB_FAKE_SCP_RC": "scp_rc",
             "ZB_FAKE_SCP_NONPE": "scp_nonpe"}
# b5776a41: the build child's ZB_* names, exactly.
BUILD_CHILD_ZB = {"ZB_WIN11_HOST", "ZB_WIN11_PORT", "ZB_WIN11_USER", "ZB_WIN11_KEY", "ZB_WIN11_KNOWN_HOSTS",
                  "ZB_BUILD_COMMIT", "ZB_WIN_EXE", "ZB_BUILD_MODE"}
BUILD_CHILD_FORBIDDEN = {"DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE"}
# Intercepts ONLY removal of an exact direct child $ZB_FAKE_RM_TMP/zb-gate-product.*; every other rm is delegated.
_RM = r'''#!/usr/bin/env bash
hit=""
if [ -n "${ZB_FAKE_RM_TMP:-}" ]; then
  tmp=$(realpath -m -- "$ZB_FAKE_RM_TMP")
  for a in "$@"; do
    case "$a" in -*) continue ;; esac
    r=$(realpath -m -- "$a")
    if [ "$(dirname -- "$r")" = "$tmp" ]; then
      case "$(basename -- "$r")" in zb-gate-product.*) hit="$r" ;; esac
    fi
  done
fi
if [ -n "$hit" ]; then
  printf 'RM %s\n' "$hit" >> "$ZB_FAKE_RM_LOG"
  case "${ZB_FAKE_RM_MODE:-}" in
    fail) echo "fake rm: cannot remove '$hit': Operation not permitted" >&2; exit 1 ;;
    noop) exit 0 ;;
  esac
fi
exec /usr/bin/rm "$@"
'''
CLEANUP = "cleanup"  # the gate's cleanup-failure diagnostic names the cleanup and the work directory
# A fake live row: records what it was given.
_ROW = r'''
import json, os, sys
exe = os.environ.get("ZB_WIN_EXE")
rec = {"row": os.path.basename(__file__), "exe": exe, "set": "ZB_WIN_EXE" in os.environ}
if exe:
    rec["exists"] = os.path.isfile(exe)
    rec["real"] = os.path.realpath(exe)
    try:
        rec["mz"] = open(exe, "rb").read(2) == b"MZ"
        rec["sha"] = open(exe + ".sha").read().strip()
    except OSError as e:
        rec["err"] = str(e)
with open(os.environ["ZB_FAKE_RAN_LOG"], "a") as fh:
    fh.write(json.dumps(rec) + "\n")
print("ASSERTS 1")
'''
# Narrow fake drivers (0d549813, decision 3), only for postconditions the real driver cannot emit. Each is committed.
_FAKE_DRIVERS = {
    "bad_sha": '#!/usr/bin/env bash\nset -u\nd=$(dirname "$ZB_WIN_EXE"); mkdir -p "$d"\n'
               'printf "MZ fake\\n" > "$ZB_WIN_EXE"; printf "%s\\n" 0000000000000000000000000000000000000000 > "$ZB_WIN_EXE.sha"\n',
    "missing": '#!/usr/bin/env bash\nexit 0\n',
    "outside": '#!/usr/bin/env bash\nset -u\no="@OUTSIDE@/g"; mkdir -p "$o"; b=$(basename "$ZB_WIN_EXE")\n'
               'printf "MZ fake\\n" > "$o/$b"; printf "%s\\n" "$ZB_BUILD_COMMIT" > "$o/$b.sha"\n'
               'c=$(dirname "$ZB_WIN_EXE"); mkdir -p "$(dirname "$c")"; ln -sfn "$o" "$c"\n',
}
_POISON = {"ZB_ZIG": "C:\\poison\\zig.exe", "ZB_WEBVIEW2_INCLUDE": "C:\\poison\\inc", "ZB_WEBVIEW2_LIB": "C:\\poison\\lib",
           "ZB_WINRT_INCLUDE": "C:\\poison\\winrt", "ZB_BUILD_MODE": "Debug",
           "ZB_BUILD_COMMIT": "1111111111111111111111111111111111111111", "ZB_STAGE_TIMEOUT": "0",
           "ZB_BUILD_TIMEOUT": "0", "ZB_FETCH_TIMEOUT": "0", "ZB_SELFTEST_CUT_PUBLISH": "1",
           "ZB_PUBLISH_LOCK_WAIT": "0", "ZB_WIN_KEY": "/nonexistent/poison", "ZB_WIN_KNOWN_HOSTS": "/nonexistent/poison",
           "DISPLAY": ":99", "WAYLAND_DISPLAY": "poison", "XAUTHORITY": "/nonexistent/poison",
           "SSH_ASKPASS": "/nonexistent/poison", "SSH_ASKPASS_REQUIRE": "force"}


def _git(root, *args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update({"HOME": str(root.parent / "githome"), "GIT_CONFIG_NOSYSTEM": "1"})
    return subprocess.run([GIT, "-C", str(root), "-c", "user.name=zb", "-c", "user.email=zb@example.invalid",
                           "-c", "commit.gpgsign=false", *args], env=env, capture_output=True, text=True,
                          timeout=60, stdin=subprocess.DEVNULL)


class _World:
    def __init__(self, td: pathlib.Path, rows=(("a_test.py", ""), ("b_test.py", "")), driver=None, sub=False):
        self.td = td
        for d in ("bin", "home", "tmp", "githome", "outside", "ctl"):
            (td / d).mkdir()
        self.ctl = td / "ctl"
        self.ran = td / "ran.log"; self.ran.write_text("")
        self.order = td / "order.log"; self.order.write_text("")
        self.sshlog = td / "guard-ssh.log"

        def bake(s):
            return (s.replace("@CTL@", str(self.ctl)).replace("@RAN@", str(self.ran))
                    .replace("@ORDER@", str(self.order)).replace("@SSHLOG@", str(self.sshlog)))
        (td / "bin" / "ssh").write_text("#!/usr/bin/env bash\n" + bake(_BUILD_PREFIX) + g8._ORDER_PREFIX + gts._SSH_STUB)
        (td / "bin" / "virsh").write_text("#!/usr/bin/env bash\n" + gts._VIRSH_STUB)
        (td / "bin" / "scp").write_text(bake(_SCP))
        (td / "bin" / "rm").write_text(_RM)
        for f in ("ssh", "virsh", "scp", "rm"):
            (td / "bin" / f).chmod(0o755)
        self.repo = td / "repo"
        self.root = self.repo / "sub" if sub else self.repo
        (self.root / "tests" / "windows" / "fake").mkdir(parents=True)
        for name in GATE_FILES:
            shutil.copy2(gts.GATE.parent / name, self.root / "tests" / "windows" / name)
        if driver:
            p = self.root / "tests" / "windows" / "build-on-windows.sh"
            p.write_text(_FAKE_DRIVERS[driver].replace("@OUTSIDE@", str(td / "outside")))
            p.chmod(0o755)
        rels = []
        for name, _ in rows:
            rel = f"tests/windows/fake/{name}"
            (self.root / rel).write_text(_ROW)
            rels.append(rel)
        (self.root / "tests" / "windows" / "live_phases.txt").write_text("# fake phases\n" + "".join(r + "\n" for r in rels))
        self.marker = f"marker-{uuid.uuid4().hex}"
        (self.root / self.marker).write_text("this repository\n")
        (self.repo / ".gitignore").write_text("ignored/\n")
        for args in (("init", "-q"), ("add", "-A"), ("commit", "-q", "-m", "fixture")):
            r = _git(self.repo, *args)
            assert r.returncode == 0, (args, r.stdout, r.stderr)
        self.sha = _git(self.repo, "rev-parse", "--verify", "HEAD^{commit}").stdout.strip()
        self.stage_tar = self.ctl / "stage.tar"
        self.build_ps = self.ctl / "build.ps1"
        self.rmlog = td / "rm.log"; self.rmlog.write_text("")

    def env(self, extra=None):
        env = {
            "ZB_GATE_ROOT": str(self.root), "ZB_FAKE_RAN_LOG": str(self.ran), "ZB_SELFTEST_ORDER_LOG": str(self.order),
            "ZB_FAKE_RM_TMP": str(self.td / "tmp"), "ZB_FAKE_RM_LOG": str(self.rmlog),
            "PATH": f"{self.td / 'bin'}:/usr/bin:/bin", "HOME": str(self.td / "home"), "TMPDIR": str(self.td / "tmp"),
            "LANG": "C.UTF-8",
            "ZB_WIN11_HOST": gts.FAKE_WIN11_HOST, "ZB_WIN11_PORT": "2222", "ZB_WIN11_DOMAIN": "win11-m8",
            "ZB_WIN11_USER": "zbtext", "ZB_WIN11_MARKER": gts.VM_MARKER, "ZB_WIN11_SNAPSHOT": "pre-4dr-toolchain-2026-10-20",
            "ZB_WIN10_HOST": gts.FAKE_WIN10_HOST, "ZB_WIN10_PORT": "22", "ZB_WIN10_USER": "zbtest",
            "ZB_WIN10_MARKER": gts.FS_MARKER,
            "ZB_WIN11_KEY": str(self.td / "k"), "ZB_WIN11_KNOWN_HOSTS": str(self.td / "k"),
            "ZB_WIN10_KEY": str(self.td / "k"), "ZB_WIN10_KNOWN_HOSTS": str(self.td / "k"),
            "ZB_SELFTEST_WIN10_CALLS": str(self.td / "win10.calls"), "ZB_SELFTEST_SSH_LOG": str(self.sshlog),
            "ZB_SELFTEST_PROBE_WIN11": gts._vm_probe(), "ZB_SELFTEST_PROBE_WIN10": gts._fs_probe(),
        }
        env.update(extra or {})
        return {k: v for k, v in env.items() if v is not None}


class _Case(gts._TwoHostCase):
    def gate(self, world, extra=None, args=("--product",), check_leak=True):
        extra = dict(extra or {})
        for name in (*_CONTROLS.values(), "env-stage", "env-build", "env-fetch"):
            (world.ctl / name).unlink(missing_ok=True)
        for var, name in _CONTROLS.items():  # build-side controls go to files, never to the gate's environment
            if var in extra:
                (world.ctl / name).write_text(extra.pop(var))
        env = world.env(extra)
        before = {x.name for x in (world.td / "tmp").glob("zb-gate-product.*")}
        self._check_transport(env, before=True)
        proc = subprocess.run(["bash", str(world.root / "tests" / "windows" / "gate.sh"), *args], cwd=world.td,
                              env=env, capture_output=True, text=True, timeout=180, stdin=subprocess.DEVNULL)
        self._check_transport(env)
        if check_leak:
            leaked = sorted({x.name for x in (world.td / "tmp").glob("zb-gate-product.*")} - before)
            self.assertEqual(leaked, [], f"the gate left its work directory behind{self.detail(proc, world)}")
        return proc

    @staticmethod
    def rm_targets(world):
        return [l.split(" ", 1)[1] for l in world.rmlog.read_text().splitlines() if l.startswith("RM ")]

    @staticmethod
    def plant_decoy(world):
        decoy = world.td / "tmp" / "zb-gate-product.decoy"
        decoy.mkdir()
        (decoy / "keep").write_bytes(b"decoy bytes\n")
        return decoy

    def assertDecoyIntact(self, decoy, detail=""):
        self.assertTrue(decoy.is_dir() and (decoy / "keep").read_bytes() == b"decoy bytes\n",
                        "the pre-existing decoy sibling is untouched" + detail)

    @staticmethod
    def rows(world):
        return [json.loads(l) for l in world.ran.read_text().splitlines() if l.strip()]

    @staticmethod
    def order(world):
        out = []
        for l in world.order.read_text().splitlines():
            if l.strip():
                host, kind, ran = l.split()[:3]
                out.append((host, kind, int(ran.split("=", 1)[1])))
        return out

    def assertBuildChildEnvIsExact(self, world, detail=""):
        files = sorted(world.ctl.glob("env-*"))
        self.assertEqual([f.name for f in files], ["env-build", "env-fetch", "env-stage"],
                         "every build-side call recorded its environment" + detail)
        for f in files:
            names = {l.split("=", 1)[0] for l in f.read_text().splitlines() if "=" in l}
            zb = {n for n in names if n.startswith("ZB_")}
            self.assertEqual(zb, BUILD_CHILD_ZB, f"{f.name}: the build child's ZB_* names" + detail)
            self.assertEqual(names & BUILD_CHILD_FORBIDDEN, set(), f"{f.name}: display/askpass reached the build" + detail)

    def detail(self, proc, world):
        return (f"\nrc={proc.returncode}\nstdout:\n{proc.stdout[-3000:]}\nstderr:\n{proc.stderr[-4000:]}"
                f"\nrows: {self.rows(world)}\norder: {self.order(world)}")

    def assertRefusedLocally(self, proc, world, needle):
        d = self.detail(proc, world)
        self.assertEqual(proc.returncode, 2, "a local preflight refusal is rc 2" + d)
        self.assertIn(needle, proc.stderr, d)
        self.assertEqual(self.order(world), [], "no ssh/scp before the local preflight passes" + d)
        self.assertFalse(world.sshlog.exists() and world.sshlog.read_text().strip(), "no transport call" + d)
        self.assertEqual(self.rows(world), [], d)

    def assertStopsBeforeWin10(self, proc, world, needle):
        d = self.detail(proc, world)
        self.assertNotEqual(proc.returncode, 0, d)
        self.assertIn(needle, proc.stderr, d)
        self.assertEqual(self.rows(world), [], "no live row" + d)
        self.assertEqual([o for o in self.order(world) if o[0] == "win10"], [], "no Win10 contact" + d)


class LocalPreflight(_Case):
    def test_a_caller_zb_win_exe_is_refused_even_when_empty(self):
        for value in ("", "/somewhere/zigBrowser.exe"):
            with self.subTest(ZB_WIN_EXE=value), tempfile.TemporaryDirectory() as t:
                w = _World(pathlib.Path(t))
                self.assertRefusedLocally(self.gate(w, {"ZB_WIN_EXE": value}), w, "ZB_WIN_EXE")

    def test_a_dirty_tree_is_refused(self):
        for kind in ("tracked edit", "untracked file", "staged new file"):
            with self.subTest(dirt=kind), tempfile.TemporaryDirectory() as t:
                w = _World(pathlib.Path(t))
                if kind == "tracked edit":
                    (w.root / w.marker).write_text("edited\n")
                elif kind == "untracked file":
                    (w.root / "tests" / "windows" / "fake" / "helper.py").write_text("x = 1\n")
                else:
                    (w.root / "new.txt").write_text("n\n")
                    assert _git(w.repo, "add", "new.txt").returncode == 0
                self.assertRefusedLocally(self.gate(w), w, "not clean")

    def test_a_git_failure_is_a_refusal(self):
        for kind in ("not a repository", "no commit", "corrupt index"):
            with self.subTest(git=kind), tempfile.TemporaryDirectory() as t:
                w = _World(pathlib.Path(t))
                if kind == "not a repository":
                    shutil.rmtree(w.repo / ".git")
                elif kind == "no commit":
                    shutil.rmtree(w.repo / ".git")
                    assert _git(w.repo, "init", "-q").returncode == 0
                else:
                    (w.repo / ".git" / "index").write_bytes(b"not an index")
                self.assertRefusedLocally(self.gate(w), w, "refused:")

    def test_a_gate_root_that_is_not_the_repository_top_level_is_refused(self):
        with tempfile.TemporaryDirectory() as t:
            w = _World(pathlib.Path(t), sub=True)
            self.assertRefusedLocally(self.gate(w), w, "top level")


class BuildAndFetch(_Case):
    def test_the_order_is_vm_build_fetch_then_win10_then_rows(self):
        with tempfile.TemporaryDirectory() as t:
            w = _World(pathlib.Path(t))
            proc = self.gate(w)
            d = self.detail(proc, w)
            self.assertEqual(proc.returncode, 0, d)
            kinds = [(h, k) for h, k, _ in self.order(w)]
            want = [("win11", "session"), ("win11", "probe"), ("win11", "stage"), ("win11", "build"),
                    ("win11", "fetch"), ("win10", "session"), ("win10", "probe"), ("win10", "probe")]
            self.assertEqual(kinds, want, d)
            self.assertEqual([r for h, k, r in self.order(w) if k == "probe" and h == "win10"], [0, 2],
                             "the Win10 pre probe precedes the rows and the post probe follows them" + d)
            self.assertTrue(all(r == 0 for h, k, r in self.order(w) if k in ("stage", "build", "fetch")), d)

    def test_every_row_gets_the_same_owned_exact_commit_exe(self):
        with tempfile.TemporaryDirectory() as t:
            w = _World(pathlib.Path(t))
            proc = self.gate(w)
            d = self.detail(proc, w)
            self.assertEqual(proc.returncode, 0, d)
            rows = self.rows(w)
            self.assertEqual(len(rows), 2, d)
            self.assertTrue(all(r["exe"] for r in rows), "every row is given a ZB_WIN_EXE" + d)
            exes = {r["exe"] for r in rows}
            self.assertEqual(len(exes), 1, "every row sees the same ZB_WIN_EXE" + d)
            exe = exes.pop()
            self.assertTrue(os.path.isabs(exe), d)
            tmp = os.path.realpath(w.td / "tmp")
            for r in rows:
                self.assertTrue(r["exists"] and r["mz"], d)
                self.assertEqual(r["sha"], w.sha, "the .sha is the full HEAD sha" + d)
                rel = os.path.relpath(r["real"], tmp)
                self.assertTrue(rel.startswith("zb-gate-product.") and not rel.startswith(".."),
                                "the exe resolves inside the run's own work directory" + d)
            self.assertIn(f"gate: built {w.sha} -> {exe}", proc.stderr, d)

    def test_the_build_is_this_repository_at_the_full_sha_in_releasesafe(self):
        with tempfile.TemporaryDirectory() as t:
            w = _World(pathlib.Path(t))
            proc = self.gate(w)
            d = self.detail(proc, w)
            self.assertEqual(proc.returncode, 0, d)
            self.assertTrue(w.stage_tar.is_file() and w.build_ps.is_file(), "the gate staged and built" + d)
            with tarfile.open(w.stage_tar) as tf:
                names = tf.getnames()
            self.assertTrue(any(n.endswith(w.marker) for n in names), "the staged archive is this repository" + d)
            ps = w.build_ps.read_text()
            self.assertIn(f"run-{w.sha}", ps, d)
            self.assertIn("'-Doptimize=ReleaseSafe'", ps, d)
            self.assertBuildChildEnvIsExact(w, d)

    def test_ambient_build_overrides_cannot_reach_the_build(self):
        with tempfile.TemporaryDirectory() as t:
            w = _World(pathlib.Path(t))
            proc = self.gate(w, _POISON)
            d = self.detail(proc, w)
            self.assertEqual(proc.returncode, 0, "poisoned build/toolchain/deadline/selftest values change nothing" + d)
            self.assertTrue(w.build_ps.is_file(), "the gate built" + d)
            ps = w.build_ps.read_text()
            self.assertNotIn("poison", ps, d)
            self.assertIn("'-Doptimize=ReleaseSafe'", ps, d)
            self.assertIn(f"run-{w.sha}", ps, "a bait ZB_BUILD_COMMIT is not the build" + d)
            self.assertEqual({r["sha"] for r in self.rows(w)}, {w.sha}, d)
            self.assertBuildChildEnvIsExact(w, d)

    def test_a_real_driver_failure_stops_before_win10_and_any_row(self):
        for what, extra, rc in (("stage", {"ZB_FAKE_STAGE_RC": "5"}, 5), ("build", {"ZB_FAKE_BUILD_RC": "6"}, 6),
                                ("fetch", {"ZB_FAKE_SCP_RC": "7"}, 7), ("non-PE", {"ZB_FAKE_SCP_NONPE": "1"}, 3)):
            with self.subTest(failing=what), tempfile.TemporaryDirectory() as t:
                w = _World(pathlib.Path(t))
                # b3f95193: the exact propagated driver rc, never a discarded or hard-coded status
                self.assertStopsBeforeWin10(self.gate(w, extra), w, f"{BUILD_FAILED} (rc={rc})")

    def test_a_bad_published_exe_is_refused_before_any_row(self):
        for driver in ("bad_sha", "missing", "outside"):
            with self.subTest(driver=driver), tempfile.TemporaryDirectory() as t:
                w = _World(pathlib.Path(t), driver=driver)
                self.assertStopsBeforeWin10(self.gate(w), w, BAD_EXE)


class OwnedPerInvocation(_Case):
    def test_two_runs_use_two_distinct_owned_work_directories(self):
        # b3f95193: the publish path belongs to THIS invocation, not to any matching-looking directory
        with tempfile.TemporaryDirectory() as t:
            w = _World(pathlib.Path(t))
            decoy = self.plant_decoy(w)
            tmp = os.path.realpath(w.td / "tmp")
            seen = []
            for n in (1, 2):
                for log in (w.ran, w.order, w.rmlog):
                    log.write_text("")
                proc = self.gate(w)
                d = self.detail(proc, w) + f"\nrun {n}"
                self.assertEqual(proc.returncode, 0, d)
                rows = self.rows(w)
                self.assertTrue(rows and all(r["exe"] for r in rows), d)
                self.assertTrue(all(r["exists"] and r["mz"] and r["sha"] == w.sha for r in rows), d)
                real = rows[0]["real"]
                work = os.path.join(tmp, os.path.relpath(real, tmp).split(os.sep)[0])
                self.assertTrue(os.path.basename(work).startswith("zb-gate-product.") and work != str(decoy), d)
                self.assertEqual(self.rm_targets(w), [work], "exactly one cleanup, of exactly this run's directory" + d)
                self.assertFalse(os.path.lexists(work), "this run's work directory is gone" + d)
                self.assertDecoyIntact(decoy, d)
                seen.append((real, work))
            self.assertNotEqual(seen[0][0], seen[1][0], f"two runs, two executables: {seen}")
            self.assertNotEqual(seen[0][1], seen[1][1], f"two runs, two work directories: {seen}")


class CleanupFailureSurfaced(_Case):
    def test_a_failed_or_no_op_cleanup_is_reported_and_keeps_an_earlier_failure(self):
        cases = (
            ("success, rm fails", {"ZB_FAKE_RM_MODE": "fail"}, None),
            ("success, rm leaves the directory", {"ZB_FAKE_RM_MODE": "noop"}, None),
            ("build failure, rm fails", {"ZB_FAKE_RM_MODE": "fail", "ZB_FAKE_STAGE_RC": "5"}, f"{BUILD_FAILED} (rc=5)"),
            ("Win10 session failure, rm leaves the directory",
             {"ZB_FAKE_RM_MODE": "noop", "ZB_SELFTEST_SESSION_RESULT_WIN10": "RESULT=TIMEOUT"}, g8.SESSION_STOP),
        )
        for what, extra, earlier in cases:
            with self.subTest(case=what), tempfile.TemporaryDirectory() as t:
                w = _World(pathlib.Path(t))
                decoy = self.plant_decoy(w)
                proc = self.gate(w, extra, check_leak=False)
                d = self.detail(proc, w) + f"\nrm: {self.rm_targets(w)}"
                left = sorted(str(x) for x in (w.td / "tmp").glob("zb-gate-product.*") if x != decoy)
                self.assertNotEqual(proc.returncode, 0, "a cleanup failure is a failure" + d)
                self.assertEqual(len(left), 1, "the fake rm really left exactly the owned directory" + d)
                self.assertEqual(self.rm_targets(w), [os.path.realpath(left[0])], "exactly one cleanup attempt" + d)
                diag = [l for l in proc.stderr.splitlines() if CLEANUP in l and os.path.realpath(left[0]) in l]
                self.assertTrue(diag, "the cleanup failure is reported, naming the work directory" + d)
                if earlier:
                    self.assertIn(earlier, proc.stderr, "the earlier failure keeps its own diagnostic" + d)
                else:
                    self.assertNotIn("product run PASSED", proc.stderr, d)
                self.assertDecoyIntact(decoy, d)
                shutil.rmtree(left[0])  # the harness removes its own exact leftover


class CleanupOnEveryPath(_Case):
    def test_the_work_directory_is_gone_after_an_early_win10_failure(self):
        bad_pre = json.loads(gts._fs_probe()); bad_pre["free_gb"] = 1.0
        cases = {"Win10 session": {"ZB_SELFTEST_SESSION_RESULT_WIN10": "RESULT=TIMEOUT"},
                 "Win10 pre-probe transport": {"ZB_SELFTEST_FAIL_WIN10": "255"},
                 "product-pre": {"ZB_SELFTEST_PROBE_WIN10": json.dumps(bad_pre)}}
        for what, extra in cases.items():
            with self.subTest(failing=what), tempfile.TemporaryDirectory() as t:
                w = _World(pathlib.Path(t))
                proc = self.gate(w, extra)  # the leak check runs inside gate()
                d = self.detail(proc, w)
                self.assertNotEqual(proc.returncode, 0, d)
                self.assertEqual(self.rows(w), [], d)
                self.assertIn(("win11", "fetch"), [(h, k) for h, k, _ in self.order(w)], "the build ran first" + d)


class Guards(_Case):
    def test_an_ignored_file_does_not_dirty_the_tree(self):
        with tempfile.TemporaryDirectory() as t:
            w = _World(pathlib.Path(t))
            (w.repo / "ignored").mkdir()
            (w.repo / "ignored" / "cache.bin").write_text("c\n")
            proc = self.gate(w, {"ZB_FAKE_STAGE_RC": "5"})
            self.assertNotIn("not clean", proc.stderr, self.detail(proc, w))

    def test_probe_only_makes_no_build_call(self):
        with tempfile.TemporaryDirectory() as t:
            w = _World(pathlib.Path(t))
            proc = self.gate(w, args=("--probe-only",))
            d = self.detail(proc, w)
            self.assertEqual(proc.returncode, 0, d)
            self.assertEqual([k for _, k, _ in self.order(w) if k in ("stage", "build", "fetch")], [], d)

    def test_an_unset_host_is_named(self):
        for var in ("ZB_WIN11_HOST", "ZB_WIN10_HOST"):
            with self.subTest(unset=var), tempfile.TemporaryDirectory() as t:
                w = _World(pathlib.Path(t))
                proc = self.gate(w, {var: None})
                d = self.detail(proc, w)
                self.assertNotEqual(proc.returncode, 0, d)
                self.assertIn("no Windows host configured", proc.stderr, d)
                self.assertEqual(self.order(w), [], d)


if __name__ == "__main__":
    unittest.main()
