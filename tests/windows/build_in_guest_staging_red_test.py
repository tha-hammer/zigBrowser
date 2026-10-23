#!/usr/bin/env python3
r"""ong.24 RED (UNREGISTERED), NavyCanyon 82565522: tests/guest/build-in-guest.sh stages its archive in an owned,
collision-free local directory and cleans it on every exit.

Today it runs `tar -cf /tmp/zb_worktree.tar ... 2>/dev/null`: a fixed shared path two runs race on, a planted
symlink redirects, a tar error is hidden, and nothing is removed. Scope (narrow, per 82565522): collision-free LOCAL
staging through the scp source boundary; the guest-side archive/worktree is a separate bead.

The REAL script runs with a complete ong.23 configuration (TEST-NET 192.0.2.1, a temp key path, a real temp pin) and
a private TMPDIR, with recording fakes first on PATH:
  tar     writes a run-tagged archive ONLY when its -f path is inside the test's own root (else it only logs), so
          the red never writes the real /tmp/zb_worktree.tar; ZB_FAKE_TAR_FAIL writes a partial file and fails;
  scp     logs its source, the source bytes and the source directory's mode/owner at copy time (it reads only
          inside the test root);
  ssh     can fail the extract or the build call, or block the build call until signalled;
  mktemp  logs and runs /usr/bin/mktemp, or fails, or prints a chosen (bad) path;
  rm      logs and runs /usr/bin/rm ONLY for targets strictly inside the test root (else refuses), or fails, or
          does nothing;
  git     only names the cwd.
Pinned:
  - success: exactly one `mktemp -d $TMPDIR/zb-guest-stage.XXXXXXXXXX`; the archive is <stage>/zb_worktree.tar,
    the scp source is that file, its directory is 0700 and ours; afterwards the stage is gone, rm ran exactly once on
    exactly the stage, TMPDIR holds only what the test put there, and a decoy sibling is untouched; neither
    /tmp/zb_worktree.tar nor $TMPDIR/zb_worktree.tar is ever selected;
  - two sequential runs use different stages; two concurrent runs (tar slowed) copy their own tagged bytes;
  - a planted regular file, and a planted symlink -> victim, at $TMPDIR/zb_worktree.tar stay byte-identical;
  - cleanup (stage gone, rm exactly once) after a tar failure (its diagnostic kept, its status returned), an scp
    failure, an extract-ssh failure and a build-ssh failure (each status returned, no later transport call), and
    after SIGINT / SIGTERM while the build ssh blocks (rc 130 / 143). The signal cases run in a private PID
    namespace (`unshare --user --map-root-user --pid --fork --mount-proc --net`); a driver that checks it is PID 1
    there signals only the process group of the child it started;
  - a mktemp failure, and a mktemp result that is a symlink, a pre-existing non-empty directory, or a directory
    outside TMPDIR: rc 2, one `refused:` line, no tar/scp/ssh, no rm, and the target's contents untouched;
  - a cleanup failure is surfaced: rm failing, or rm "succeeding" while the stage remains, turns a successful run
    into a failure naming the stage, and keeps a prior failure's status;
  - a selector or pin refusal makes no mktemp call and leaves TMPDIR alone;
  - a source tripwire (supporting only): the stage delete is the guarded `rm -rf -- "${stage:?}"` in a named
    cleanup function on the EXIT trap, and the tar line keeps its stderr;
  - green R2 (NavyCanyon f1d64033), source only, the ong.24 block alone: mktemp, the stat/ls/dirname probes and the
    rm run as named serial steps with a stored `<name>_rc=$?`; no assignment after `||`/`&&`, no `if [!] x=$(...)`,
    and no command substitution inside a `[ ]` test.
Everything else runs inside `unshare --user --map-current-user --net`. No real host value is ever passed.

Run alone:  unshare --user --map-current-user --net python3 -I tests/windows/build_in_guest_staging_red_test.py -v
"""
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO / "tests" / "guest" / "build-in-guest.sh"
HOST = "zbtest@192.0.2.1"  # TEST-NET-1
NETNS = ["unshare", "--user", "--map-current-user", "--net", "--"]
PIDNS = ["unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc", "--net", "--"]
REAL_RM = shutil.which("rm", path="/usr/bin:/bin")
REAL_MKTEMP = shutil.which("mktemp", path="/usr/bin:/bin")
TEMPLATE_PREFIX = "zb-guest-stage."

_LOG = '{ printf "%s" "$(basename "$0")"; printf " %q" "$@"; printf "\\n"; } >> "$ZB_FAKE_LOG"\n'
_FAKES = {
    "git": _LOG + '[ "$*" = "rev-parse --show-toplevel" ] && pwd\nexit 0\n',
    "tar": _LOG + r'''out=""; prev=""
for a in "$@"; do { [ "$prev" = "-cf" ] || [ "$prev" = "-f" ]; } && out="$a"; prev="$a"; done
case "$out" in
  "$ZB_FAKE_ROOT"/*..*|"$ZB_FAKE_ROOT"/) printf 'TAR-OUTSIDE %q\n' "$out" >> "$ZB_FAKE_LOG"; exit 0 ;;
  "$ZB_FAKE_ROOT"/*) ;;
  *) printf 'TAR-OUTSIDE %q\n' "$out" >> "$ZB_FAKE_LOG"; exit 0 ;;
esac
[ -n "${ZB_FAKE_TAR_SLEEP:-}" ] && sleep "$ZB_FAKE_TAR_SLEEP"
if [ -n "${ZB_FAKE_TAR_FAIL:-}" ]; then printf 'partial' > "$out"; echo "fake tar: write error on $out" >&2; exit 4; fi
printf 'archive %s\n' "${ZB_RUN_TAG:-run}" > "$out"
exit 0
''',
    "scp": _LOG + r'''args=("$@"); src=""
for ((i = 1; i < ${#args[@]}; i++)); do case "${args[$i]}" in *@*:*) src="${args[$((i - 1))]}" ;; esac; done
case "$src" in
  "$ZB_FAKE_ROOT"/*)
    if [ -f "$src" ]; then printf 'SCPSRC %q %q\n' "$src" "$(cat -- "$src")" >> "$ZB_FAKE_LOG"
    else printf 'SCPSRC %q MISSING\n' "$src" >> "$ZB_FAKE_LOG"; fi
    d=$(dirname -- "$src"); printf 'SCPDIR %s %s\n' "$(stat -c %a -- "$d")" "$(stat -c %u -- "$d")" >> "$ZB_FAKE_LOG" ;;
  *) printf 'SCPSRC-OUTSIDE %q\n' "$src" >> "$ZB_FAKE_LOG" ;;
esac
exit "${ZB_FAKE_SCP_RC:-0}"
''',
    "ssh": _LOG + r'''case "$*" in
  *"tar -xf"*) exit "${ZB_FAKE_EXTRACT_RC:-0}" ;;
  *"zig build"*)
    if [ -n "${ZB_FAKE_BUILD_BLOCK:-}" ]; then : > "$ZB_FAKE_BUILD_BLOCK"; exec sleep 30; fi
    exit "${ZB_FAKE_BUILD_RC:-0}" ;;
esac
exit 0
''',
    "mktemp": _LOG + r'''if [ -n "${ZB_FAKE_MKTEMP_FAIL:-}" ]; then echo "fake mktemp: No space left on device" >&2; exit 1; fi
if [ -n "${ZB_FAKE_MKTEMP_LIE:-}" ]; then printf 'MKTEMP_OUT %q\n' "$ZB_FAKE_MKTEMP_LIE" >> "$ZB_FAKE_LOG"; printf '%s\n' "$ZB_FAKE_MKTEMP_LIE"; exit 0; fi
out=$(@MKTEMP@ "$@") || exit $?
printf 'MKTEMP_OUT %q\n' "$out" >> "$ZB_FAKE_LOG"; printf '%s\n' "$out"
''',
    "rm": _LOG + r'''[ -n "${ZB_FAKE_RM_FAIL:-}" ] && { echo "fake rm: cannot remove: Operation not permitted" >&2; exit 1; }
[ -n "${ZB_FAKE_RM_NOOP:-}" ] && exit 0
for a in "$@"; do
  case "$a" in -*) continue ;; esac
  r=$(realpath -m -- "$a")
  case "$r" in "$ZB_FAKE_ROOT"/?*) ;; *) printf 'RM-REFUSED %q\n' "$a" >> "$ZB_FAKE_LOG"; echo "fake rm: refused outside the test root: $a" >&2; exit 1 ;; esac
done
exec @RM@ "$@"
''',
}

_SIGNAL_DRIVER = r"""
import json, os, signal, subprocess, sys, time
spec = json.loads(sys.argv[1])
if os.getpid() != 1:
    print("DRIVER not PID 1 of a private namespace: refusing to signal anything"); sys.exit(3)
with open(spec["out"], "w") as out, open(spec["err"], "w") as err:
    p = subprocess.Popen(["bash", spec["script"]], cwd=spec["cwd"], env=spec["env"], stdout=out, stderr=err,
                         stdin=subprocess.DEVNULL, start_new_session=True)
    deadline = time.time() + 30
    while not os.path.exists(spec["ready"]) and time.time() < deadline and p.poll() is None:
        time.sleep(0.05)
    ready = os.path.exists(spec["ready"])
    if ready and p.poll() is None and p.pid > 1:
        os.killpg(p.pid, getattr(signal, spec["signal"]))
    try:
        rc = p.wait(timeout=30)
    except subprocess.TimeoutExpired:
        if p.pid > 1:
            os.killpg(p.pid, signal.SIGKILL)
        rc = p.wait()
print("DRIVER " + json.dumps({"ready": ready, "rc": rc}))
"""


class _World:
    def __init__(self, td: pathlib.Path):
        self.td = td.resolve()
        self.bin = self.td / "bin"; self.bin.mkdir()
        for name, body in _FAKES.items():
            path = self.bin / name
            path.write_text("#!/usr/bin/env bash\n" + body.replace("@MKTEMP@", REAL_MKTEMP).replace("@RM@", REAL_RM))
            path.chmod(0o755)
        self.tmp = self.td / "tmp"; self.tmp.mkdir()
        self.work = self.td / "work"; self.work.mkdir()
        self.pin = self.td / "known_hosts"; self.pin.write_text("192.0.2.1 ssh-ed25519 AAAA\n")
        # a decoy sibling with the same prefix, and an unrelated decoy: neither may be touched
        self.decoy = self.tmp / (TEMPLATE_PREFIX + "decoy"); self.decoy.mkdir()
        (self.decoy / "keep").write_text("decoy\n")
        (self.tmp / "other.txt").write_text("other\n")
        self.before = self.snapshot()

    def env(self, log: pathlib.Path, **over):
        env = {"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.td), "TMPDIR": str(self.tmp), "LANG": "C.UTF-8",
               "ZB_FAKE_LOG": str(log), "ZB_FAKE_ROOT": str(self.td),
               "ZB_GUEST_HOST": HOST, "ZB_GUEST_KEY": str(self.td / "explicit_key"),
               "ZB_GUEST_KNOWN_HOSTS": str(self.pin)}
        for k, v in over.items():
            if v is None:
                env.pop(k, None)
            else:
                env[k] = v
        return env

    def snapshot(self):
        out = {}
        for p in sorted(self.tmp.rglob("*")):
            rel = str(p.relative_to(self.tmp))
            if p.is_symlink():
                out[rel] = ("link", os.readlink(p))
            elif p.is_dir():
                out[rel] = ("dir", "")
            else:
                out[rel] = ("file", p.read_bytes())
        return out


def _read_log(log: pathlib.Path):
    rows = []
    for line in log.read_text().splitlines():
        try:
            rows.append(shlex.split(line))
        except ValueError:
            rows.append(line.split())
    return rows


class _Case(unittest.TestCase):
    def _run(self, world, tag="run", **over):
        log = world.td / f"calls-{tag}.log"
        log.write_text("")
        env = world.env(log, ZB_RUN_TAG=tag, **over)
        proc = subprocess.run([*NETNS, "bash", str(SCRIPT)], cwd=world.work, env=env, capture_output=True, text=True,
                              timeout=120, stdin=subprocess.DEVNULL)
        return proc, _read_log(log), log

    def _detail(self, proc, rows, world=None):
        extra = f"\ntmp now: {sorted(world.snapshot())}" if world else ""
        return f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\nlog: {rows}{extra}"

    @staticmethod
    def _tool(rows, name):
        return [r for r in rows if r and r[0] == name]

    def _stage(self, rows, detail):
        made = [r for r in rows if r and r[0] == "MKTEMP_OUT"]
        self.assertEqual(len(made), 1, "exactly one stage is created" + detail)
        return made[0][1]

    def _assert_never_fixed(self, world, rows, detail):
        fixed = {"/tmp/zb_worktree.tar", str(world.tmp / "zb_worktree.tar")}
        for r in rows:
            self.assertFalse(any(a in fixed for a in r[1:]), f"a fixed archive path was selected: {r}" + detail)

    def _assert_cleaned_once(self, world, rows, stage, detail):
        self.assertFalse(os.path.lexists(stage), "the stage is removed" + detail)
        rms = self._tool(rows, "rm")
        self.assertEqual(len(rms), 1, "cleanup runs exactly once" + detail)
        self.assertEqual(rms[0][-1], stage, "rm targets exactly the stage" + detail)
        self.assertFalse([r for r in rows if r and r[0] == "RM-REFUSED"], detail)
        self.assertEqual(world.snapshot(), world.before, "TMPDIR holds only what the test put there" + detail)


class Success(_Case):
    def test_success_stages_in_a_fresh_owned_directory_and_cleans_it(self):
        with tempfile.TemporaryDirectory() as t:
            world = _World(pathlib.Path(t))
            proc, rows, _ = self._run(world, "s1")
            detail = self._detail(proc, rows, world)
            self.assertEqual(proc.returncode, 0, detail)
            mk = self._tool(rows, "mktemp")
            self.assertEqual(len(mk), 1, detail)
            self.assertIn("-d", mk[0], detail)
            self.assertIn(str(world.tmp / (TEMPLATE_PREFIX + "XXXXXXXXXX")), mk[0], detail)
            stage = self._stage(rows, detail)
            self.assertEqual(os.path.dirname(stage), str(world.tmp), detail)
            self.assertTrue(os.path.basename(stage).startswith(TEMPLATE_PREFIX), detail)
            archive = os.path.join(stage, "zb_worktree.tar")
            tar = self._tool(rows, "tar")
            self.assertEqual(len(tar), 1, detail)
            self.assertEqual(tar[0][tar[0].index("-cf") + 1], archive, "tar writes into the stage" + detail)
            src = [r for r in rows if r and r[0] == "SCPSRC"]
            self.assertEqual(src, [["SCPSRC", archive, "archive s1"]], "scp copies the staged archive" + detail)
            self.assertEqual([r for r in rows if r and r[0] == "SCPDIR"], [["SCPDIR", "700", str(os.getuid())]],
                             "the stage is 0700 and ours" + detail)
            self._assert_never_fixed(world, rows, detail)
            self._assert_cleaned_once(world, rows, stage, detail)

    def test_two_sequential_runs_use_different_stages(self):
        with tempfile.TemporaryDirectory() as t:
            world = _World(pathlib.Path(t))
            stages = []
            for tag in ("q1", "q2"):
                proc, rows, _ = self._run(world, tag)
                detail = self._detail(proc, rows, world)
                self.assertEqual(proc.returncode, 0, detail)
                stages.append(self._stage(rows, detail))
                self._assert_cleaned_once(world, rows, stages[-1], detail)
            self.assertNotEqual(stages[0], stages[1], f"{stages}")

    def test_two_concurrent_runs_copy_their_own_tagged_archives(self):
        # narrow claim (82565522): collision-free LOCAL staging through the scp source boundary
        with tempfile.TemporaryDirectory() as t:
            world = _World(pathlib.Path(t))
            procs, results = [], []
            try:
                for tag in ("cA", "cB"):
                    log = world.td / f"calls-{tag}.log"
                    log.write_text("")
                    env = world.env(log, ZB_RUN_TAG=tag, ZB_FAKE_TAR_SLEEP="1")
                    procs.append((tag, log, subprocess.Popen([*NETNS, "bash", str(SCRIPT)], cwd=world.work, env=env,
                                                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                                             stdin=subprocess.DEVNULL)))
                # collect BOTH children before asserting on either (4c1c348d)
                for tag, log, p in procs:
                    _, err = p.communicate(timeout=120)
                    results.append((tag, log, p.returncode, err))
            finally:
                for _, _, p in procs:  # only each exact child we started, never a group
                    if p.returncode is None and isinstance(p.pid, int) and p.pid > 1:
                        p.kill()
                    p.wait()
                    for f in (p.stdout, p.stderr):
                        if f and not f.closed:
                            f.close()
            stages = []
            for tag, log, rc, err in results:
                rows = _read_log(log)
                detail = f"\n[{tag}] rc={rc}\nstderr:\n{err}\nlog: {rows}"
                self.assertEqual(rc, 0, detail)
                stage = self._stage(rows, detail)
                stages.append(stage)
                src = [r for r in rows if r and r[0] == "SCPSRC"]
                self.assertEqual(src, [["SCPSRC", os.path.join(stage, "zb_worktree.tar"), f"archive {tag}"]],
                                 "each run copies its own bytes" + detail)
                self.assertFalse(os.path.lexists(stage), detail)
            self.assertNotEqual(stages[0], stages[1], f"{stages}")
            self.assertEqual(world.snapshot(), world.before)

    def test_a_planted_file_or_symlink_at_the_fixed_name_is_untouched(self):
        for kind in ("regular", "symlink"):
            with self.subTest(planted=kind), tempfile.TemporaryDirectory() as t:
                world = _World(pathlib.Path(t))
                victim = world.td / "victim.txt"
                victim.write_bytes(b"victim bytes\n")
                fixed = world.tmp / "zb_worktree.tar"
                if kind == "regular":
                    fixed.write_bytes(b"planted bytes\n")
                else:
                    fixed.symlink_to(victim)
                world.before = world.snapshot()
                proc, rows, _ = self._run(world, f"p{kind[0]}")
                detail = self._detail(proc, rows, world)
                self.assertEqual(proc.returncode, 0, detail)
                self.assertEqual(victim.read_bytes(), b"victim bytes\n", "the victim is untouched" + detail)
                self._assert_never_fixed(world, rows, detail)
                self._assert_cleaned_once(world, rows, self._stage(rows, detail), detail)


class FailuresStillClean(_Case):
    def test_each_failing_step_returns_its_status_and_still_cleans(self):
        cases = (
            ("tar", {"ZB_FAKE_TAR_FAIL": "1"}, 4, ("scp", "ssh")),
            ("scp", {"ZB_FAKE_SCP_RC": "7"}, 7, ("ssh",)),
            ("extract-ssh", {"ZB_FAKE_EXTRACT_RC": "5"}, 5, ()),
            ("build-ssh", {"ZB_FAKE_BUILD_RC": "6"}, 6, ()),
        )
        for name, over, want_rc, never in cases:
            with self.subTest(failing=name), tempfile.TemporaryDirectory() as t:
                world = _World(pathlib.Path(t))
                proc, rows, _ = self._run(world, f"f{name[:2]}", **over)
                detail = self._detail(proc, rows, world)
                self.assertEqual(proc.returncode, want_rc, "the failing command's status is returned" + detail)
                for tool in never:
                    self.assertEqual(self._tool(rows, tool), [], f"no {tool} after the failure" + detail)
                if name == "extract-ssh":
                    self.assertEqual(len(self._tool(rows, "ssh")), 1, "no build call after a failed extract" + detail)
                if name == "tar":
                    self.assertIn("fake tar: write error", proc.stderr, "tar's diagnostic is kept" + detail)
                self._assert_cleaned_once(world, rows, self._stage(rows, detail), detail)

    def test_sigint_and_sigterm_while_the_build_blocks_still_clean(self):
        for sig, want_rc in (("SIGINT", 130), ("SIGTERM", 143)):
            with self.subTest(signal=sig), tempfile.TemporaryDirectory() as t:
                world = _World(pathlib.Path(t))
                log = world.td / "calls-sig.log"
                log.write_text("")
                ready = world.td / "build-blocked"
                env = world.env(log, ZB_RUN_TAG="sig", ZB_FAKE_BUILD_BLOCK=str(ready))
                spec = {"script": str(SCRIPT), "cwd": str(world.work), "env": env, "ready": str(ready),
                        "signal": sig, "out": str(world.td / "sig.out"), "err": str(world.td / "sig.err")}
                drv = subprocess.run([*PIDNS, "python3", "-I", "-c", _SIGNAL_DRIVER, json.dumps(spec)],
                                     capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
                rows = _read_log(log)
                err = (world.td / "sig.err").read_text() if (world.td / "sig.err").exists() else ""
                detail = f"\ndriver rc={drv.returncode}\n{drv.stdout}\n{drv.stderr}\nscript stderr:\n{err}\nlog: {rows}" \
                         f"\ntmp now: {sorted(world.snapshot())}"
                lines = [l for l in drv.stdout.splitlines() if l.startswith("DRIVER {")]
                self.assertEqual(len(lines), 1, "the PID-1 driver ran" + detail)
                res = json.loads(lines[0][len("DRIVER "):])
                self.assertTrue(res["ready"], "the build ssh was reached and blocked" + detail)
                self.assertEqual(res["rc"], want_rc, f"{sig} exits {want_rc}" + detail)
                stage = self._stage(rows, detail)
                self.assertFalse(os.path.lexists(stage), "the stage is removed" + detail)
                rms = self._tool(rows, "rm")
                self.assertEqual(len(rms), 1, "cleanup runs exactly once" + detail)
                self.assertEqual(rms[0][-1], stage, detail)
                self.assertEqual(world.snapshot(), world.before, detail)


class StageValidation(_Case):
    def _assert_refused_unstaged(self, proc, rows, detail):
        self.assertEqual(proc.returncode, 2, "refused with rc 2" + detail)
        self.assertEqual(len([l for l in proc.stderr.splitlines() if "refused:" in l]), 1, detail)
        for tool in ("tar", "scp", "ssh", "rm"):
            self.assertEqual(self._tool(rows, tool), [], f"no {tool}" + detail)

    def test_a_mktemp_failure_is_refused_before_tar(self):
        with tempfile.TemporaryDirectory() as t:
            world = _World(pathlib.Path(t))
            proc, rows, _ = self._run(world, "mf", ZB_FAKE_MKTEMP_FAIL="1")
            detail = self._detail(proc, rows, world)
            self._assert_refused_unstaged(proc, rows, detail)
            self.assertEqual(world.snapshot(), world.before, detail)

    def test_a_bad_mktemp_result_is_refused_and_left_alone(self):
        for kind in ("symlink", "pre-existing", "outside"):
            with self.subTest(result=kind), tempfile.TemporaryDirectory() as t:
                world = _World(pathlib.Path(t))
                target = world.td / "foreign"
                target.mkdir()
                (target / "canary").write_text("canary\n")
                if kind == "symlink":
                    lie = world.tmp / (TEMPLATE_PREFIX + "LINKLINKLI")
                    lie.symlink_to(target)
                elif kind == "pre-existing":
                    lie = world.tmp / (TEMPLATE_PREFIX + "OLDOLDOLDO")
                    lie.mkdir(mode=0o700)
                    (lie / "canary").write_text("canary\n")
                else:
                    lie = target
                world.before = world.snapshot()
                proc, rows, _ = self._run(world, f"b{kind[0]}", ZB_FAKE_MKTEMP_LIE=str(lie))
                detail = self._detail(proc, rows, world)
                self._assert_refused_unstaged(proc, rows, detail)
                self.assertEqual((target / "canary").read_text(), "canary\n", detail)
                self.assertEqual(world.snapshot(), world.before, "nothing under TMPDIR is touched" + detail)

    def test_a_refusal_creates_no_stage(self):
        for name, over in (("no pin", {"ZB_GUEST_KNOWN_HOSTS": None}), ("no host", {"ZB_GUEST_HOST": None}),
                           ("pin is a directory", {"ZB_GUEST_KNOWN_HOSTS": "/"})):
            with self.subTest(refusal=name), tempfile.TemporaryDirectory() as t:
                world = _World(pathlib.Path(t))
                proc, rows, _ = self._run(world, "r", **over)
                detail = self._detail(proc, rows, world)
                self.assertEqual(proc.returncode, 2, detail)
                self.assertEqual(self._tool(rows, "mktemp"), [], "no stage before the selectors pass" + detail)
                self.assertEqual(world.snapshot(), world.before, detail)


class CleanupFailureSurfaced(_Case):
    def test_a_failed_or_incomplete_cleanup_fails_the_run(self):
        cases = (("rm fails", {"ZB_FAKE_RM_FAIL": "1"}, None), ("rm leaves the stage", {"ZB_FAKE_RM_NOOP": "1"}, None),
                 ("prior failure kept", {"ZB_FAKE_RM_FAIL": "1", "ZB_FAKE_BUILD_RC": "6"}, 6))
        for name, over, want_rc in cases:
            with self.subTest(case=name), tempfile.TemporaryDirectory() as t:
                world = _World(pathlib.Path(t))
                proc, rows, _ = self._run(world, "cf", **over)
                detail = self._detail(proc, rows, world)
                stage = self._stage(rows, detail)
                if want_rc is None:
                    self.assertNotEqual(proc.returncode, 0, "a cleanup failure fails the run" + detail)
                else:
                    self.assertEqual(proc.returncode, want_rc, "the prior failure's status is kept" + detail)
                diag = [l for l in proc.stderr.splitlines() if "cleanup" in l.lower() and stage in l]
                self.assertTrue(diag, "the cleanup failure names the stage" + detail)
                self.assertEqual(len(self._tool(rows, "rm")), 1, "cleanup runs exactly once" + detail)
                self.assertTrue(os.path.isdir(stage), "(the fake rm really left it)" + detail)


class SourceTripwire(unittest.TestCase):
    """Supporting only; the classes above are the behavioural proof."""

    def test_guarded_named_cleanup_and_visible_tar_errors(self):
        text = SCRIPT.read_text()
        self.assertIn('rm -rf -- "${stage:?}"', text)
        self.assertNotRegex(text, r'rm -rf(\s+--)?\s+"?\$\{?stage\}?"?(\s|$)')
        self.assertRegex(text, r"(?m)^cleanup\(\)\s*\{")
        self.assertRegex(text, r"(?m)^trap cleanup EXIT$")
        tar_lines = [l for l in text.splitlines() if re.search(r"\btar -c", l) and not l.lstrip().startswith("#")]
        self.assertTrue(tar_lines, text)
        self.assertFalse([l for l in tar_lines if "2>/dev/null" in l], f"tar keeps its stderr: {tar_lines}")

    def test_staging_runs_serial_steps_and_branches_on_stored_results(self):
        # f1d64033: scoped to the ong.24 block (the ong.22/ong.23 refusals above it are out of scope)
        text = SCRIPT.read_text()
        marker = "# bd zigBrowser-ong.24"
        self.assertEqual(text.count(marker), 1, "the ong.24 block is marked once")
        block = text[text.index(marker):]
        for step in ("mktemp", "stat", "ls", "dirname", "rm"):
            self.assertRegex(block, rf"(?m)^\s*{step}_rc=\$\?$", f"{step} runs as a named step with a stored status")
        code = "\n".join(l for l in block.splitlines() if not l.lstrip().startswith("#"))
        forbidden = (
            (r"(\|\||&&)\s*[A-Za-z_]\w*(\[[^\]]*\])?\+?=", "an assignment after || or &&"),
            (r"\bif\s+(!\s*)?[A-Za-z_]\w*=\$\(", "work inside an if condition"),
            (r"\[[^\]\n]*\$\(", "a command substitution inside a [ ] test"),
        )
        for pattern, what in forbidden:
            hits = [l for l in code.splitlines() if re.search(pattern, l)]
            self.assertFalse(hits, f"{what}: {hits}")


if __name__ == "__main__":
    unittest.main()
