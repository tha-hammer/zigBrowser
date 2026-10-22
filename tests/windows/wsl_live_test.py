r"""WS8/WS9 WSL2 topology — live DISCOVERY SPIKE on the Win11 VM (OD-W4).

!!! DISCOVERY-ONLY. NOT RUN; AWAITING RoseCat review of this repair before any live run (draft gate). It is
    NOT a closure or a security claim — the security/product proofs come LATER via named red/green tests
    driving the production WslBackend / LinuxBwrapBackend. It writes ONLY under a unique per-run directory
    beneath C:\\Users\\zbtext\\zb\\wsl on win11-m8, never on the read-only Windows 10 file server, and never
    calls global `wsl --shutdown`.

This commit ADDRESSES the six acc13ea / Agent-Mail-7616 blockers (in code; not yet reviewed or run). No
local signal, no raw-PID stop, and no check/use race remains:
- (1) NO local `Popen.terminate()`/`kill()` anywhere. The in-distro keepalive is a `wsl -d <distro> sleep`;
  cleanup ends it REMOTE-FIRST (`wsl --terminate <distro>` kills the in-distro sleep), then only reaps each
  keepalive handle with a bounded `wait()` — a signal is never sent. A keepalive that does not exit within
  the bound is recorded (its remote `sleep` is itself bounded, so it is a bounded natural exit, never an
  orphan held open by us).
- (2) The Windows reverse listener is NEVER `Stop-Process`'d. It self-exits on its own 20 s bound; cleanup
  only CENSUSES it by identity (its PID's command line must still be this run's `run-<nonce>\winlisten.ps1`)
  with a bounded natural-exit wait. A reused PID whose command line no longer matches is classified NOT_OURS
  and left alone — there is no enumerate-then-kill race.
- (3) A census FAILURE during cleanup no longer skips teardown: `plan_distro_cleanup` attempts EVERY owned
  distro when the census is unavailable (instead of `present=[]`), and `rmtree` runs checked (no
  `ignore_errors`), so a leftover is surfaced, not swallowed.
- (4) The deliberately-failed negative import records its nonce names in the owned list BEFORE the attempt,
  so a partial registration is censused and cleaned by the same postflight that proves the happy path.
- (5) The C1 canary travels in NO result or diagnostic: `c1boot.py` prints only `PORT=<p>` (never the
  secret), the JSON carries no `got_secret`, and no assertion message contains it. Correct stdin->fd0
  delivery is proven TRANSITIVELY by the authed `ACK` (the child ACKs iff the token presented on the
  returned port equals the secret it read from fd0). The no-leak scan still reads its pattern from stdin,
  never from argv/env.
- (6) An OFFLINE injected-failure suite (`WslSpikeOracle`, runs with NO VM) proves: a raising cleanup step
  still reaches every later step; a census failure still plans teardown for every owned distro; a reused PID
  is classified NOT_OURS; and the staged scripts never contain the canary.
- A listener that starts but misses READY now still records its PID (winlaunch emits `pid=` on both
  branches), so a not-ready listener is still censused.

This commit also closes the three c101b1e follow-up gaps (still NOT run):
- (c101b1e #1) the FULL prospective name set (`-a`/`-b`/`-nope`/`-absent`) is reserved and checked against
  the baseline in setUp BEFORE any import/unregister; `may_destroy()` gates EVERY destructive op (import,
  terminate, unregister, in cleanup too), so a planted/pre-existing name is blocked from all of them.
- (c101b1e #2) `_await_listener_gone` returns a tagged GONE|NOT_OURS result, fails CLOSED on UNREADABLE and
  on any ssh/census error (the CIM query emits a deterministic `GONE`/`UNREADABLE`/`CMD=<cmdline>` token).
- (c101b1e #3 / mail 7680 #3) `_reap_no_signal` is a reaped-or-fail contract: SSH carries dead-peer bounds
  (`ServerAliveInterval=5`/`CountMax=3`) and the reap waits through the FULL known remote bound
  (`REAP_BOUND_S` = the in-distro `sleep` bound + the dead-peer bound + slack) before raising, so even across
  a connection failure the local ssh client exits and is reaped; it never returns while the handle may be
  alive and never signals a host pid. Additionally the LIVE run is refused unless launched inside a private
  PID-namespace backstop (`unshare --user --map-current-user --pid --fork --kill-child --mount-proc`, which
  runs the test as PID 1 and sets `ZB_WSL_PIDNS_BACKSTOP=1`); setUpClass fails closed otherwise.
All of these have offline `WslSpikeOracle` rows.

C1 stdio/pipe-to-fd bootstrap probe (design embodied in `test_wsl_topology`): the Windows parent launches
`wsl.exe -d <distro> -u zbagent -e python3 c1boot.py` with redirected stdin/stdout; the capability secret is
written to the child's stdin (Windows parent pipe -> wsl.exe stdin -> Linux fd 0), the child binds an
EPHEMERAL 127.0.0.1 port and returns it on stdout (Linux fd 1 -> wsl.exe stdout -> Windows parent), and the
parent then dials that port and presents the secret; the child's `ACK` (vs `DENY`) proves the one-shot
inherited-pipe capability handshake carried the secret across the Windows/Linux boundary without it ever
touching argv, env, or disk. This is the C1 (one-shot inherited-pipe capability bootstrap) direction,
distinct from the OAuth fd-3 flow.

The spike still must be reviewed and explicitly approved by RoseCat before it is ever run; until then it is
not gate evidence. DO NOT RUN before that approval.
"""
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOTFS_NAME = "alpine-minirootfs-3.21.9-x86_64.tar.gz"
ROOTFS_SHA256 = "3d5912d47e004ac77746d63ab848abd9e37164465cf1c866eb574bc526135012"

HOST = os.environ.get("ZB_WIN11_HOST")
PORT = os.environ.get("ZB_WIN11_PORT", "2222")
USER = os.environ.get("ZB_WIN11_USER", "zbtext")
KEY = os.environ.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key")
KH = os.environ.get("ZB_WIN_KNOWN_HOSTS", "/home/maceo/vms/win11-m8/known_hosts")
ROOTFS = os.environ.get("ZB_WSL_ROOTFS")

NONROOT = "zbagent"
ADMIN_GROUPS = {"root", "wheel", "adm", "sudo"}

# Keepalive / reap bounds (c101b1e #3 / mail 7680 #3). The in-distro keepalive `sleep` is bounded; a dead SSH
# peer is bounded by ServerAlive (interval*countmax ~= 15 s) so the LOCAL ssh client cannot hang forever even
# across a connection failure; the reap then waits through the FULL known remote bound before failing.
KEEPALIVE_SLEEP_S = 150
SSH_DEAD_PEER_S = 15  # ServerAliveInterval=5 * ServerAliveCountMax=3
# The reap bound is strictly greater than the remote `sleep` PLUS the SSH dead-peer bound, so the local ssh
# client is GUARANTEED to exit (and thus be reaped) within the wait, even across a connection failure — the
# keepalive can never outlive the reap. The 45 s margin keeps this invariant comfortable.
REAP_BOUND_S = KEEPALIVE_SLEEP_S + SSH_DEAD_PEER_S + 45


def _scrub(*cmd):
    return ["env", "-u", "DISPLAY", "-u", "WAYLAND_DISPLAY", "-u", "XAUTHORITY", *cmd]


def _ssh_base():
    return ["ssh", "-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", f"UserKnownHostsFile={KH}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=25",
            "-o", "ConnectionAttempts=3", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
            "-p", PORT, f"{USER}@{HOST}"]


def ssh(*args, timeout=180, stdin_text=None):
    r = subprocess.run(_scrub(*_ssh_base(), *args), input=stdin_text,
                       capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout or "").replace("\x00", ""), (r.stderr or "").replace("\x00", "")


def ssh_bg(*args):
    return subprocess.Popen(_scrub(*_ssh_base(), *args),
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def scp(local, remote, timeout=180):
    base = ["scp", "-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", f"UserKnownHostsFile={KH}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=25",
            "-o", "ConnectionAttempts=3", "-P", PORT, local, f"{USER}@{HOST}:{remote}"]
    return subprocess.run(_scrub(*base), capture_output=True, text=True, timeout=timeout).returncode


def census_distros():
    rc, out, err = ssh("wsl", "-l", "-q")
    assert rc == 0, f"`wsl -l -q` failed rc={rc}: {err}"
    return sorted(x.strip() for x in out.replace("\r", "").split("\n") if x.strip())


def kv(stdout):
    out = {}
    for line in stdout.splitlines():
        if "=" in line and not line.startswith(" "):
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    return out


# --- pure cleanup/decision helpers (exercised offline by WslSpikeOracle) ---
def plan_distro_cleanup(imported, present):
    """Which owned distros to attempt terminate/unregister on.

    present is the live `wsl -l -q` list, or None when that census FAILED. On a
    census failure we must NOT skip teardown (acc13ea #3): we attempt EVERY owned
    distro. When the census succeeds we attempt only those actually registered.
    """
    out = []
    for n in imported:
        if present is not None and n not in present:
            continue  # census ok and never registered -> nothing to clean
        out.append(n)
    return out


def reserved_collisions(reserved, baseline):
    """Prospective owned names (every -a/-b/-nope/-absent name this run will ever touch) that already exist in
    the baseline. ANY collision must refuse the whole run before a single import or unregister (c101b1e #1).
    """
    return [n for n in reserved if n in baseline]


def may_destroy(name, reserved, baseline):
    """A destructive op (import/terminate/unregister) is allowed ONLY for a name this run reserved that was NOT
    pre-existing in the baseline. A planted/pre-existing name is thereby blocked from every destructive op.
    """
    return name in reserved and name not in baseline


# The remote CIM producer for the listener census (bb17917 #1). `-ErrorAction Stop` + `catch` means a CIM
# query/access ERROR emits UNREADABLE (fail closed), NEVER GONE; a present process with a null/empty
# CommandLine is UNREADABLE; only genuine absence is GONE. Exactly ONE deterministic token is emitted.
LISTENER_CENSUS_PS = (
    "try {{ $p = Get-CimInstance Win32_Process -Filter \"ProcessId={pid}\" -ErrorAction Stop; "
    "if ($p) {{ if ($p.CommandLine) {{ 'CMD=' + $p.CommandLine }} else {{ 'UNREADABLE' }} }} "
    "else {{ 'GONE' }} }} catch {{ 'UNREADABLE' }}"
)


def listener_census_token(process_found, cim_error, command_line):
    """Pure model of LISTENER_CENSUS_PS (mirrors it branch-for-branch) so the whole producer->consumer path is
    tested offline. A CIM error is UNREADABLE (never GONE); a present-but-null CommandLine is UNREADABLE;
    absence is GONE; otherwise CMD=<cmdline>.
    """
    if cim_error:
        return "UNREADABLE"
    if not process_found:
        return "GONE"
    if not command_line:
        return "UNREADABLE"
    return "CMD=" + command_line


def classify_listener(pid, census_out, run_rand):
    """Identity of a possibly-reused Windows PID (acc13ea #2, c101b1e #2).

    Parses the deterministic single-token census (`GONE` / `UNREADABLE` / `CMD=<cmdline>`) into one of:
      NONE       - no PID was ever recorded;
      GONE       - the PID is not present now (naturally exited);
      OURS       - present AND its command line still names THIS run's winlisten.ps1;
      NOT_OURS   - present but a different command line (a reused PID) - never acted on;
      UNREADABLE - present but command line unreadable, or any unexpected/empty output -> caller fails closed.
    """
    if pid is None:
        return "NONE"
    first = ""
    for ln in (census_out or "").splitlines():
        if ln.strip():
            first = ln.strip()
            break
    if first == "GONE":
        return "GONE"
    if first.startswith("CMD="):
        marker = "run-%s\\winlisten.ps1" % run_rand
        return "OURS" if marker in first else "NOT_OURS"
    return "UNREADABLE"  # explicit UNREADABLE token, empty output, or anything unexpected -> fail closed


def run_best_effort(steps, errs):
    """Run every (label, fn) step; a raising step is recorded in errs and does NOT
    abort the remaining steps (acc13ea #1/#3). Returns results (None where raised).
    """
    results = []
    for label, fn in steps:
        try:
            results.append(fn())
        except Exception as ex:  # noqa: BLE001 - cleanup must continue past any failure
            errs.append("%s: %s" % (label, ex))
            results.append(None)
    return results


def count_secret_leaks(texts, secret):
    """How many of the given staged-file texts contain the canary (must be 0)."""
    return sum(1 for t in texts if secret and secret in t)


class WslTopologyLive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not HOST:
            raise unittest.SkipTest("ZB_WIN11_HOST unset — WSL2 live topology spike skipped (offline oracle still runs)")
        if not ROOTFS or not os.path.isfile(ROOTFS):
            raise unittest.SkipTest("ZB_WSL_ROOTFS unset/missing on an opted-in host — point it at the pinned Alpine minirootfs")
        # (mail 7680 #3) the live run MUST be launched inside a private PID namespace as a local backstop, so any
        # local child (keepalive ssh, etc.) is reaped with the namespace even if our own teardown fails. The
        # approved launch wrapper is:
        #   unshare --user --map-current-user --pid --fork --kill-child --mount-proc \
        #     env ZB_WSL_PIDNS_BACKSTOP=1 python3 tests/windows/wsl_live_test.py
        # With --fork --mount-proc the command runs as PID 1 of the new namespace; we require BOTH the marker
        # (documented intent) AND pid==1 (objective proof) and fail closed otherwise. No raw PID signalling is
        # ever used; this namespace is only a containment backstop.
        if os.environ.get("ZB_WSL_PIDNS_BACKSTOP") != "1" or os.getpid() != 1:
            raise AssertionError(
                "refusing the live run outside a private PID namespace backstop; launch with: "
                "unshare --user --map-current-user --pid --fork --kill-child --mount-proc "
                "env ZB_WSL_PIDNS_BACKSTOP=1 python3 tests/windows/wsl_live_test.py")
        h = hashlib.sha256()
        with open(ROOTFS, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        if h.hexdigest() != ROOTFS_SHA256:
            raise AssertionError(f"rootfs sha256 {h.hexdigest()} != pinned {ROOTFS_SHA256} (untrusted; aborting)")
        cls.wsl_root = f"C:\\Users\\{USER}\\zb\\wsl"
        rc, _, e = ssh("cmd", "/c", f"if not exist {cls.wsl_root} mkdir {cls.wsl_root}")
        assert rc == 0, f"could not create wsl root: {e}"

    def setUp(self):
        self.rand = secrets.token_hex(5)
        self.run_rel = f"zb/wsl/run-{self.rand}"           # for scp (forward slashes)
        self.run_win = f"{self.wsl_root}\\run-{self.rand}"  # for cmd/powershell
        self.na = f"zb-test-{self.rand}-a"
        self.nb = f"zb-test-{self.rand}-b"
        self.n_nope = f"zb-test-{self.rand}-nope"      # negative-import oracle target
        self.n_absent = f"zb-test-{self.rand}-absent"  # negative-unregister oracle target
        # (c101b1e #1) the FULL set of prospective owned names this run may ever touch — reserved and checked
        # against the baseline BEFORE any import or unregister; every destructive op is gated by may_destroy().
        self.reserved = [self.na, self.nb, self.n_nope, self.n_absent]
        self.localdir = tempfile.mkdtemp(prefix="wsllive-")
        self.staged = set()
        self.keepalives = []
        self.imported = []
        self.win_listener_pid = None
        self.baseline_distros = census_distros()
        collisions = reserved_collisions(self.reserved, self.baseline_distros)
        if collisions:
            raise AssertionError(f"collision: reserved distro name(s) {collisions} already exist; refusing to run")
        # Refuse a pre-existing run dir (no shared-name overwrite), then create it.
        rc, out, _ = ssh("cmd", "/c", f"if exist {self.run_win} (echo EXISTS) else (echo NEW)")
        self.assertEqual(rc, 0, "run-dir probe failed")
        self.assertIn("NEW", out, f"per-run dir {self.run_win} already exists; refusing to run")
        rc, _, e = ssh("cmd", "/c", f"mkdir {self.run_win}")
        self.assertEqual(rc, 0, f"mkdir run dir failed: {e}")
        self.addCleanup(self._cleanup_and_census)  # ALWAYS runs, fails closed

    def _cleanup_and_census(self):
        # Every step is best-effort and cannot abort the rest (run_best_effort records failures, continues).
        # No local signal and no raw-PID Stop-Process is ever issued (acc13ea #1/#2): distros are terminated
        # REMOTE-FIRST, which ends the in-distro keepalive `sleep`, then each keepalive handle is reaped with a
        # bounded wait only; the Windows listener self-exits and is merely censused by identity.
        errs = []

        # (acc13ea #3) census first; present is None on failure, which plans teardown for EVERY owned distro
        # rather than skipping it.
        present = run_best_effort([("list distros", census_distros)], errs)[0]
        must_assert = present is not None
        # (c101b1e #1) never destroy a name we did not reserve / that pre-existed, even in cleanup.
        targets = [n for n in plan_distro_cleanup(self.imported, present)
                   if may_destroy(n, self.reserved, self.baseline_distros)]

        steps = []
        # terminate each owned distro FIRST (this kills that distro's in-distro keepalive `sleep`), then
        # unregister it. A nonzero is an error only when the census confirmed the distro was present.
        for n in targets:
            steps.append((f"terminate {n}",
                          lambda n=n: self._rc("terminate", n, ssh("wsl", "--terminate", n), must_assert)))
            steps.append((f"unregister {n}",
                          lambda n=n: self._rc("unregister", n, ssh("wsl", "--unregister", n), must_assert)))
        # reap keepalives WITHOUT signalling — the remote terminate above ended their `sleep`.
        for i, p in enumerate(self.keepalives):
            steps.append((f"reap keepalive {i}", lambda p=p: self._reap_no_signal(p)))
        steps.append(("rmdir run dir",
                      lambda: self._rc("rmdir run dir", self.run_win,
                                       ssh("cmd", "/c", f"if exist {self.run_win} rmdir /s /q {self.run_win}"), True)))
        run_best_effort(steps, errs)

        # postflight: distros back to baseline, run dir gone, listener naturally exited (identity-matched).
        final = run_best_effort([("final distro census", census_distros)], errs)[0]
        if final is not None and final != self.baseline_distros:
            errs.append(f"final distro census {final} != baseline {self.baseline_distros}")
        res = run_best_effort([("run-dir gone probe",
                                lambda: ssh("cmd", "/c", f"if exist {self.run_win} (echo LEFT) else (echo GONE)"))], errs)[0]
        if res is not None and (res[0] != 0 or "GONE" not in res[1]):
            errs.append(f"run dir not gone (rc={res[0]}, out={res[1]!r})")
        if self.win_listener_pid is not None:
            run_best_effort([("listener natural-exit census", self._await_listener_gone)], errs)

        run_best_effort([("rm localdir", lambda: shutil.rmtree(self.localdir))], errs)
        if errs:
            raise AssertionError("cleanup/postflight census failed: " + " | ".join(errs))

    @staticmethod
    def _rc(label, target, result, must_assert):
        rc, _, e = result
        if must_assert and rc != 0:
            raise AssertionError(f"{label} {target} rc={rc}: {e.strip()}")

    @staticmethod
    def _reap_no_signal(p):
        # (bb17917 #2) ALWAYS reap the Popen with NO signal. The remote `sleep` (KEEPALIVE_SLEEP_S) plus the
        # SSH dead-peer bound (SSH_DEAD_PEER_S) is strictly LESS than REAP_BOUND_S, so the local ssh client is
        # guaranteed to exit within the wait and `wait()` always REAPS it — `wsl --terminate` normally ends the
        # `sleep` first so it returns at once. We never send a signal. A residual past the whole bound (made
        # unreachable by the invariant below) is contained by the outer PID-namespace backstop.
        try:
            p.wait(timeout=REAP_BOUND_S)  # blocks until the child exits; returning here means it is reaped
        except subprocess.TimeoutExpired:
            pass  # fall through to a final no-signal reap check
        if p.poll() is None:  # final no-signal reap attempt failed -> surface (never signal; backstop contains)
            raise AssertionError(f"keepalive ssh still alive past the full remote bound ({REAP_BOUND_S}s); "
                                 f"not reaped (no signal sent; PID-namespace backstop contains it)")

    def _await_listener_gone(self):
        # (c101b1e #2) Bounded wait for the self-exiting Windows listener; census by identity, never a stop.
        # Returns the terminal tag (GONE|NOT_OURS); fails CLOSED on UNREADABLE or an ssh/census error (no
        # silenced errors), and fails if it is still OURS past the bound. The CIM query emits exactly ONE
        # deterministic token so classify_listener can tell "gone" from "present-but-unreadable".
        deadline = time.time() + 30
        while time.time() < deadline:
            rc, out, e = ssh("powershell", "-NoProfile", "-Command",
                             LISTENER_CENSUS_PS.format(pid=self.win_listener_pid))
            if rc != 0:
                raise AssertionError(f"listener identity census failed rc={rc}: {e.strip()}")
            tag = classify_listener(self.win_listener_pid, out, self.rand)
            if tag in ("GONE", "NOT_OURS"):
                return tag  # naturally exited, or the PID was reused by an unrelated process (not ours)
            if tag == "UNREADABLE":
                raise AssertionError(f"listener pid {self.win_listener_pid} present but command line UNREADABLE "
                                     f"(failing closed; cannot confirm identity): {out!r}")
            time.sleep(2)  # still OURS -> natural exit pending
        raise AssertionError(f"windows reverse listener pid {self.win_listener_pid} (identity-matched) "
                             f"survived its natural-exit bound")

    # --- helpers (every op fail-closed) ---
    def _stage(self, name, text, crlf=False):
        p = os.path.join(self.localdir, name)
        with open(p, "w", newline=("\r\n" if crlf else "\n")) as f:
            f.write(text)
        self.assertEqual(scp(p, f"{self.run_rel}/{name}"), 0, f"scp {name} failed")
        self.staged.add(name)

    def _run(self, distro, script_remote, user=None):
        u = f"-u {user} " if user else ""
        ps = (f"Get-Content -Raw $env:USERPROFILE\\zb\\wsl\\run-{self.rand}\\{script_remote} | "
              f"wsl -d {distro} {u}-e /bin/sh")
        rc, out, err = ssh("powershell", "-NoProfile", "-Command", ps)
        self.assertEqual(rc, 0, f"run {script_remote} on {distro} failed rc={rc}: {err}")
        return out

    def _pin(self, distro):
        p = ssh_bg("wsl", "-d", distro, "-u", "root", "-e", "/bin/sleep", str(KEEPALIVE_SLEEP_S))
        self.keepalives.append(p)
        return p

    def _guard_destroy(self, name):
        # (c101b1e #1) a destructive op is permitted only for a reserved name that was not pre-existing.
        if not may_destroy(name, self.reserved, self.baseline_distros):
            raise AssertionError(f"refusing destructive op on non-reserved/pre-existing distro {name!r}")

    def _import(self, distro):
        # (b) record ownership BEFORE the attempt, so a partial/failed import is still censused + cleaned.
        self._guard_destroy(distro)
        if distro not in self.imported:
            self.imported.append(distro)
        rc, o, e = ssh("cmd", "/c",
                       f"wsl --import {distro} {self.run_win}\\{distro} {self.run_win}\\{self.tar_name} --version 2")
        self.assertEqual(rc, 0, f"import {distro} rc must be 0, got {rc}: {o}{e}")
        self.assertIn("completed successfully", o, f"import {distro} did not report success: {o}{e}")

    # ------------------------------------------------------------------
    # Negative / mutant oracles (cheap; prove the checks fail closed).
    # ------------------------------------------------------------------
    def test_oracle_failed_import_and_unregister_return_nonzero(self):
        # (acc13ea #4) the nonce names were reserved + baseline-checked in setUp; record them in the owned list
        # BEFORE the attempts so a partial registration is censused/cleaned, and gate each destructive op.
        nope, absent = self.n_nope, self.n_absent
        for n in (nope, absent):
            if n not in self.imported:
                self.imported.append(n)
        self._guard_destroy(nope)
        rc, _, _ = ssh("cmd", "/c",
                       f"wsl --import {nope} {self.run_win}\\nope {self.run_win}\\does-not-exist.tar.gz --version 2")
        self.assertNotEqual(rc, 0, "a failed import must return nonzero (oracle)")
        # clean a partial dir if the failed import created one
        ssh("cmd", "/c", f"if exist {self.run_win}\\nope rmdir /s /q {self.run_win}\\nope")
        self._guard_destroy(absent)
        rc, _, _ = ssh("wsl", "--unregister", absent)
        self.assertNotEqual(rc, 0, "unregistering an absent distro must return nonzero (oracle)")

    def test_oracle_leftover_is_detected_by_census(self):
        sentinel = f"leftover-{self.rand}.sentinel"
        p = os.path.join(self.localdir, sentinel)  # owned localdir (finding 6)
        with open(p, "w") as f:
            f.write("sentinel\n")
        self.assertEqual(scp(p, f"{self.run_rel}/{sentinel}"), 0)
        self.staged.add(sentinel)
        rc, out, _ = ssh("cmd", "/c", f"if exist {self.run_win}\\{sentinel} (echo PRESENT) else (echo ABSENT)")
        self.assertIn("PRESENT", out, "a planted leftover must be detected (oracle)")
        # (addCleanup will rmdir the whole run dir, so the sentinel is removed and censused)

    # ------------------------------------------------------------------
    # The main topology spike.
    # ------------------------------------------------------------------
    def test_wsl_topology(self):
        self.tar_name = f"{self.rand}.tar.gz"
        self.assertEqual(scp(ROOTFS, f"{self.run_rel}/{self.tar_name}"), 0, "scp rootfs")
        self.staged.add(self.tar_name)
        self._import(self.na)
        self._import(self.nb)
        facts = {"P1_import_no_admin": "ok"}

        self._stage("setup.sh", _SETUP_SH)
        for n in (self.na, self.nb):
            o = self._run(n, "setup.sh", user="root")
            self.assertIn("SETUP_DONE", o, f"setup {n}: {o}")
            self.assertIn("ADDUSER_RC=0", o)
            self.assertIn("APK_RC=0", o)
            self._guard_destroy(n)
            rc, _, e = ssh("wsl", "--terminate", n)
            self.assertEqual(rc, 0, f"terminate {n}: {e}")

        self._stage("auth.sh", _AUTH_SH)
        a = kv(self._run(self.na, "auth.sh"))
        facts.update({f"P2P3_{k}": v for k, v in a.items()})
        self.assertEqual(a.get("MNT_C_MOUNTPOINT"), "no")
        self.assertEqual(a.get("PATH_HAS_MNT"), "0")
        self.assertEqual(a.get("BINFMT"), "present")

        # P4a default (no -u) uid 1000 + no admin group; P4b explicit-user security + userns/bwrap
        self._stage("whoami.sh", _WHOAMI_SH)
        d = kv(self._run(self.na, "whoami.sh"))
        e = kv(self._run(self.na, "whoami.sh", user=NONROOT))
        self.assertEqual(d.get("UID"), "1000", f"default (no -u) must be uid 1000: {d}")
        self.assertEqual(e.get("UID"), "1000", f"explicit -u must be uid 1000: {e}")
        self.assertTrue(set((d.get("GROUPS") or "").split(",")).isdisjoint(ADMIN_GROUPS),
                        f"default user in no admin group: {d.get('GROUPS')}")
        facts["P4_default_uid"], facts["P4_default_groups"] = d.get("UID"), d.get("GROUPS")
        self._stage("nonroot.sh", _NONROOT_SH)
        nr = kv(self._run(self.na, "nonroot.sh", user=NONROOT))
        facts.update({f"P4_{k}": v for k, v in nr.items()})
        for key, val in (("SUDO", "absent"), ("DOAS", "absent"), ("WRITE_ETC", "denied"),
                         ("CAPEFF", "0000000000000000"), ("SETUID_COUNT", "0")):
            self.assertEqual(nr.get(key), val, f"{key}: {nr}")
        self.assertTrue(nr.get("USERNS", "").startswith("ok"))
        self.assertTrue(nr.get("BWRAP", "").startswith("ok"))

        # P5 shared utility VM / namespaces
        self._stage("ident.sh", _IDENT_SH)
        ia, ib = kv(self._run(self.na, "ident.sh", user="root")), kv(self._run(self.nb, "ident.sh", user="root"))
        self.assertEqual(ia.get("BOOT_ID"), ib.get("BOOT_ID"), "shared utility VM")
        self.assertEqual(ia.get("NS_NET"), ib.get("NS_NET"), "shared net namespace")
        self.assertNotEqual(ia.get("NS_PID"), ib.get("NS_PID"), "separate PID namespaces")
        gw = ia.get("GW", "")

        # P6 transport: exact bind + ACK/canary + IPv6 + hostile co-tenant + closed-port negative
        self._pin(self.na); self._pin(self.nb)
        time.sleep(4)
        self._stage("listen.sh", _LISTEN_SH)
        self._stage("readrx.sh", _READRX_SH)
        self._stage("wtcp.ps1", _WIN_TCP_PS1, crlf=True)
        lo = kv(self._run(self.na, "listen.sh", user=NONROOT))
        p_lo, p_any, p_v6, p_closed = lo["LO"], lo["ANY"], lo["V6"], lo["CLOSED"]
        # readiness tied to the EXACT port (a killed/wrong-port listener fails)
        self.assertEqual(lo.get("LISTEN_LO"), "yes", f"the exact 127.0.0.1:{p_lo} listener must be LISTENing: {lo}")
        self.assertEqual(lo.get("LISTEN_V6"), "yes", f"the exact [::1]:{p_v6} listener must be LISTENing: {lo}")
        self._stage("wtcp_spec.txt",
                    f"127.0.0.1|{p_lo}|w-lo;127.0.0.1|{p_any}|w-any;::1|{p_v6}|w-v6;127.0.0.1|{p_closed}|w-neg\n")
        rc, ow, ew = ssh("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                         f"{self.run_win}\\wtcp.ps1", f"{self.run_win}\\wtcp_spec.txt")
        self.assertEqual(rc, 0, f"win tcp client rc={rc}: {ew}")
        facts["P6_win_to_wsl"] = ow.replace("\n", " | ").strip()
        self.assertIn(f"127.0.0.1:{p_lo} = ok ack=ACK:w-lo", ow, f"Win->WSL 127.0.0.1 with ACK: {ow}")
        self.assertIn(f"::1:{p_v6} = ok ack=ACK:w-v6", ow, f"Win->WSL ::1 with ACK: {ow}")
        self.assertIn(f"127.0.0.1:{p_closed} = fail", ow, f"negative control (closed port refused): {ow}")
        self._stage("cotenant.sh", _COTENANT_SH.format(lo=p_lo, any=p_any, v6=p_v6))
        oc = self._run(self.nb, "cotenant.sh", user=NONROOT)
        facts["P6_hostile_cotenant"] = oc.replace("\n", " | ").strip()
        self.assertIn("co->lo=ok", oc, f"co-tenant reaching the listener (auth mandatory): {oc}")
        rx = self._run(self.na, "readrx.sh", user=NONROOT)
        self.assertIn("canary=b'w-lo'", rx, f"listener received the Windows canary: {rx}")
        self.assertIn("canary=b'B-co->lo'", rx, f"listener received the co-tenant canary: {rx}")

        # P6 reverse negative ONLY after proving the Windows listener READY + recording its PID
        self._stage("winlisten.ps1", _WIN_LISTEN_PS1, crlf=True)
        self._stage("winlaunch.ps1", _WIN_LAUNCH_PS1, crlf=True)
        rc, ol, el = ssh("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                         f"{self.run_win}\\winlaunch.ps1", self.run_win)
        self.assertEqual(rc, 0, f"launch win reverse listener rc={rc}: {el}")
        # record the PID regardless of READY, so a started-but-not-ready listener is still censused/cleaned.
        mp = re.search(r"pid=(\d+)", ol)
        if mp:
            self.win_listener_pid = int(mp.group(1))
        self.assertIsNotNone(re.search(r"READY pid=\d+ 0\.0\.0\.0:39002", ol),
                             f"the Windows reverse listener must prove READY with a pid before the negative: {ol}")
        self._stage("revclient.sh", _REVCLIENT_SH.format(gw=gw))
        orv = self._run(self.na, "revclient.sh", user=NONROOT)
        facts["P6_wsl_to_windows"] = orv.replace("\n", " | ").strip()
        self.assertIn("gw->win=fail", orv, f"WSL->Windows must fail with the Windows listener PROVEN ready: {orv}")
        self.assertIn("testnet=fail", orv, f"TEST-NET decoy unreachable: {orv}")

        # C1 bootstrap: secret via stdin (THIS test -> ssh/powershell stdin -> wsl.exe stdin -> Linux fd0)
        secret = secrets.token_hex(16)
        self._stage("c1boot.sh", _C1BOOT_WRITER)
        self._run(self.na, "c1boot.sh", user=NONROOT)
        self._stage("c1boot.ps1", _C1BOOT_PS1.format(distro=self.na, user=NONROOT), crlf=True)
        rc, oc1, ec1 = ssh("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                           f"{self.run_win}\\c1boot.ps1", stdin_text=secret + "\n")
        self.assertEqual(rc, 0, f"c1 bootstrap rc={rc}: {ec1}")
        c1 = json.loads(oc1.strip().splitlines()[-1])
        facts["P_C1_bootstrap"] = json.dumps({k: c1[k] for k in ("port", "ack") if k in c1})
        self.assertTrue(int(c1.get("port", 0)) > 0, f"the ephemeral port must return on stdout: {c1}")
        # (acc13ea #5) the secret appears in NO stdout, JSON, or diagnostic. ACK proves stdin->fd0 delivery
        # TRANSITIVELY: the child ACKs iff the token dialed on the returned port equals the secret it read
        # from fd0; a broken stdin delivery would make the child's secret differ and yield DENY, not ACK.
        self.assertEqual(c1.get("ack"), "ACK", f"authed connect to the returned port must ACK: {c1}")
        self.assertTrue(c1.get("exited"), f"the bootstrap child must exit within the bound: {c1}")
        # (e) the secret must never appear in any staged file — and the CHECK itself must not put the secret
        # in argv/env: the pattern is read from stdin, never interpolated into the PowerShell/ssh command line.
        rc, grepped, _ = ssh("powershell", "-NoProfile", "-Command",
                             f"$pat=[Console]::In.ReadLine(); (Select-String -Path {self.run_win}\\* -SimpleMatch -Pattern $pat -ErrorAction SilentlyContinue | Measure-Object).Count",
                             stdin_text=secret + "\n")
        self.assertEqual(grepped.strip(), "0", "the C1 secret must not appear in any staged file")

        print("\n==== WSL2 topology discovery observations (win11-m8; not a closure or security claim) ====")
        for k in sorted(facts):
            print(f"{k}={facts[k]}")


# ---- staged scripts ----
_SETUP_SH = """#!/bin/sh
printf 'nameserver 8.8.8.8\\nnameserver 1.1.1.1\\n' > /etc/resolv.conf
adduser -D -g '' zbagent 2>/dev/null; echo "ADDUSER_RC=$?"
cat > /etc/wsl.conf <<'C'
[automount]
enabled = false
[interop]
enabled = false
appendWindowsPath = false
[user]
default = zbagent
C
apk add --no-cache --no-progress python3 bubblewrap >/tmp/apk.out 2>&1; echo "APK_RC=$?"
echo "SETUP_DONE uid=$(id -u zbagent)"
"""

_AUTH_SH = r"""#!/bin/sh
if awk '$2=="/mnt/c"{f=1} END{exit !f}' /proc/mounts; then echo "MNT_C_MOUNTPOINT=yes"; else echo "MNT_C_MOUNTPOINT=no"; fi
echo "PATH_HAS_MNT=$(echo $PATH | tr ':' '\n' | grep -ci '/mnt/')"
if [ -e /proc/sys/fs/binfmt_misc/WSLInterop ]; then echo "BINFMT=present"; else echo "BINFMT=absent"; fi
"""

_WHOAMI_SH = r"""#!/bin/sh
echo "UID=$(id -u)"
echo "GROUPS=$(id -Gn | tr ' ' ',')"
"""

_NONROOT_SH = r"""#!/bin/sh
if unshare -Ur /bin/sh -c 'id -u' >/tmp/u.out 2>/tmp/u.err; then echo "USERNS=ok:$(cat /tmp/u.out)"; else echo "USERNS=fail:$(tr '\n' ' ' </tmp/u.err)"; fi
if bwrap --unshare-user --unshare-pid --unshare-net --ro-bind / / --dev /dev --proc /proc /usr/bin/id -u >/tmp/bw.out 2>/tmp/bw.err; then echo "BWRAP=ok:$(cat /tmp/bw.out)"; else echo "BWRAP=fail:$(tr '\n' ' ' </tmp/bw.err)"; fi
command -v sudo >/dev/null 2>&1 && echo "SUDO=present" || echo "SUDO=absent"
command -v doas >/dev/null 2>&1 && echo "DOAS=present" || echo "DOAS=absent"
if echo x > /etc/zbcanary 2>/dev/null; then echo "WRITE_ETC=ALLOWED"; rm -f /etc/zbcanary; else echo "WRITE_ETC=denied"; fi
echo "CAPEFF=$(awk '/CapEff/{print $2}' /proc/self/status)"
echo "SETUID_COUNT=$(find / -xdev -perm -4000 -type f 2>/dev/null | wc -l)"
"""

_IDENT_SH = r"""#!/bin/sh
echo "BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)"
echo "NS_NET=$(readlink /proc/self/ns/net)"
echo "NS_PID=$(readlink /proc/self/ns/pid)"
echo "GW=$(ip route show default 2>/dev/null | awk '{print $3}')"
"""

# Binds 127.0.0.1:0 + 0.0.0.0:0 + ::1:0, reserves+closes one port (negative control), writes its ports, and
# reports LISTEN state for the EXACT chosen ports (a killed/wrong-port listener => LISTEN_*=no).
_LISTEN_SH = r"""#!/bin/sh
cat > /tmp/listener.py <<'PY'
import socket,select,time
def mk(fam,addr):
    s=socket.socket(fam)
    try: s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    except Exception: pass
    s.bind(addr); s.listen(8); s.setblocking(False); return s
s_lo=mk(socket.AF_INET,("127.0.0.1",0)); p_lo=s_lo.getsockname()[1]
s_any=mk(socket.AF_INET,("0.0.0.0",0)); p_any=s_any.getsockname()[1]
try: s6=mk(socket.AF_INET6,("::1",0)); p6=s6.getsockname()[1]
except Exception: s6=None; p6=0
sc=socket.socket(socket.AF_INET); sc.bind(("127.0.0.1",0)); p_closed=sc.getsockname()[1]; sc.close()
open("/tmp/ports","w").write("LO=%d ANY=%d V6=%d CLOSED=%d\n"%(p_lo,p_any,p6,p_closed))
tag={s_lo:"lo",s_any:"any"}
if s6: tag[s6]="v6"
open("/tmp/rx","w").close()
socks=[x for x in (s_lo,s_any,s6) if x]; end=time.time()+90
while time.time()<end:
    r,_,_=select.select(socks,[],[],2)
    for srv in r:
        try: c,a=srv.accept()
        except Exception: continue
        d=c.recv(200); open("/tmp/rx","a").write("%s from=%s canary=%r\n"%(tag[srv],a[0],d))
        try: c.sendall(b"ACK:"+d)
        except Exception: pass
        c.close()
PY
setsid python3 /tmp/listener.py </dev/null >/tmp/l.log 2>&1 &
sleep 2
cat /tmp/ports 2>/dev/null | tr ' ' '\n'
P_LO=$(sed -n 's/LO=\([0-9]*\).*/\1/p' /tmp/ports); P_V6=$(sed -n 's/.*V6=\([0-9]*\).*/\1/p' /tmp/ports)
netstat -ltn 2>/dev/null | grep -q "127.0.0.1:$P_LO " && echo "LISTEN_LO=yes" || echo "LISTEN_LO=no"
netstat -ltn 2>/dev/null | grep -q "::1:$P_V6 " && echo "LISTEN_V6=yes" || echo "LISTEN_V6=no"
"""

_READRX_SH = r"""#!/bin/sh
cat /tmp/rx 2>/dev/null
"""

_COTENANT_SH = r"""#!/bin/sh
python3 - <<'PY'
import socket
specs=[(socket.AF_INET,"127.0.0.1",{lo},"co->lo"),(socket.AF_INET,"127.0.0.1",{any},"co->any"),(socket.AF_INET6,"::1",{v6},"co->v6")]
for fam,host,port,name in specs:
    try:
        s=socket.socket(fam); s.settimeout(3); s.connect((host,int(port))); s.sendall(("B-"+name).encode())
        ack=s.recv(64); s.close(); print("%s=ok ack=%r"%(name,ack))
    except Exception as e: print("%s=fail:%r"%(name,e))
PY
"""

_REVCLIENT_SH = r"""#!/bin/sh
python3 - <<'PY'
import socket
for name,host,port in [("gw->win","{gw}",39002),("testnet","192.0.2.1",443)]:
    try:
        s=socket.create_connection((host,port),timeout=4); s.close(); print("%s=ok"%name)
    except Exception as e: print("%s=fail:%r"%(name,e))
PY
"""

# C1 bootstrap: reads the secret from stdin (Linux fd 0, fed by wsl.exe's stdin), binds 127.0.0.1:0, prints
# ONLY the ephemeral port to stdout (NEVER the secret), then accepts one authed conn. The secret reaches
# neither this file, nor stdout, nor argv/env; the authed ACK transitively proves it arrived at fd 0.
_C1BOOT_WRITER = r"""#!/bin/sh
cat > /home/zbagent/c1boot.py <<'PY'
import socket,sys
secret=sys.stdin.readline().strip()
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",0)); s.listen(1); port=s.getsockname()[1]
sys.stdout.write("PORT=%d\n"%port); sys.stdout.flush()
s.settimeout(12)
try:
    c,a=s.accept(); tok=c.recv(200).decode(errors="replace").strip()
    c.sendall(b"ACK" if tok==secret else b"DENY"); c.close()
except Exception:
    pass
PY
echo WROTE
"""

# Reads the secret from ITS OWN stdin (fed by ssh from the local test), forwards it to wsl.exe stdin, reads
# the port back from wsl stdout, connects + authenticates. No secret in argv/env/file.
_C1BOOT_PS1 = """$ErrorActionPreference='Stop'
$secret = [Console]::In.ReadLine()
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName='wsl.exe'
$psi.Arguments='-d {distro} -u {user} -e /usr/bin/python3 /home/{user}/c1boot.py'
$psi.RedirectStandardInput=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.UseShellExecute=$false
$res=@{{ port=0; ack=''; exited=$false; error='' }}
try {{
  $p=[Diagnostics.Process]::Start($psi)
  $p.StandardInput.WriteLine($secret); $p.StandardInput.Flush()
  $line=$p.StandardOutput.ReadLine()
  if ($line -match 'PORT=(\\d+)') {{ $res.port=[int]$Matches[1] }}
  if ($res.port -gt 0) {{
    $c=New-Object Net.Sockets.TcpClient
    $iar=$c.BeginConnect('127.0.0.1',$res.port,$null,$null)
    if ($iar.AsyncWaitHandle.WaitOne(4000)) {{
      $c.EndConnect($iar); $s=$c.GetStream()
      $b=[Text.Encoding]::ASCII.GetBytes($secret); $s.Write($b,0,$b.Length); $s.Flush()
      $buf=New-Object byte[] 16; $s.ReadTimeout=4000; $n=$s.Read($buf,0,16); $res.ack=[Text.Encoding]::ASCII.GetString($buf,0,$n)
    }}
    $c.Close()
  }}
  $p.StandardInput.Close(); $res.exited=$p.WaitForExit(8000)
}} catch {{ $res.error=$_.Exception.Message }}
[Console]::Out.Write(($res | ConvertTo-Json -Compress))
"""

_WIN_TCP_PS1 = """$spec = (Get-Content -Raw $args[0]).Trim()
foreach($t in ($spec -split ';')){
  $f = $t -split '\\|'; $h=$f[0]; $p=[int]$f[1]; $canary=$f[2]
  try {
    $ip=[Net.IPAddress]::Parse($h)
    $c=New-Object Net.Sockets.TcpClient($ip.AddressFamily)
    $iar=$c.BeginConnect($ip,$p,$null,$null)
    if(-not $iar.AsyncWaitHandle.WaitOne(3000)){ Write-Output "${h}:${p} = timeout"; $c.Close(); continue }
    $c.EndConnect($iar); $s=$c.GetStream()
    $b=[Text.Encoding]::ASCII.GetBytes($canary); $s.Write($b,0,$b.Length); $s.Flush()
    $buf=New-Object byte[] 64; $s.ReadTimeout=3000; $n=$s.Read($buf,0,64)
    Write-Output ("${h}:${p} = ok ack=" + [Text.Encoding]::ASCII.GetString($buf,0,$n)); $c.Close()
  } catch { Write-Output "${h}:${p} = fail: $($_.Exception.Message)" }
}
"""

_WIN_LISTEN_PS1 = """param($bind,$port,$outfile)
try {
  $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($bind)),([int]$port)
  $l = New-Object Net.Sockets.TcpListener $ep; $l.Start()
  ("LISTENING " + $bind + ":" + $port) | Out-File -FilePath $outfile -Encoding ascii
  $sw=[Diagnostics.Stopwatch]::StartNew()
  while($sw.Elapsed.TotalSeconds -lt 20){ if($l.Pending()){ $c=$l.AcceptTcpClient(); $c.Close() } else { Start-Sleep -Milliseconds 200 } }
  $l.Stop()
} catch { ("LISTENER_ERR " + $_.Exception.Message) | Out-File -FilePath $outfile -Append -Encoding ascii }
"""

# Launches the reverse listener, records its PID, and proves it READY before returning (so the reverse
# negative cannot false-green on a listener that never started).
_WIN_LAUNCH_PS1 = """$run = $args[0]
$out = Join-Path $run 'l0.txt'
Remove-Item $out -ErrorAction SilentlyContinue
$p = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $run 'winlisten.ps1'),'0.0.0.0','39002',$out -WindowStyle Hidden -PassThru
$deadline=(Get-Date).AddSeconds(8); $ready=$false
while((Get-Date) -lt $deadline){ Start-Sleep -Milliseconds 200; if((Test-Path $out) -and ((Get-Content $out -Raw) -match 'LISTENING 0.0.0.0:39002')){ $ready=$true; break } }
if($ready){ Write-Output ("READY pid=" + $p.Id + " 0.0.0.0:39002") } else { Write-Output ("NOT_READY pid=" + $p.Id) }
"""


# ------------------------------------------------------------------
# OFFLINE injected-failure suite (acc13ea #6). NO VM, NO ssh — it drives the pure cleanup/decision helpers
# with crafted inputs to prove the safety properties the live paths rely on.
# ------------------------------------------------------------------
class WslSpikeOracle(unittest.TestCase):
    def test_raising_step_does_not_abort_later_steps(self):
        # a cleanup step that raises must NOT skip the steps after it (acc13ea #1/#3).
        ran = []
        errs = []
        steps = [
            ("a", lambda: ran.append("a")),
            ("boom", lambda: (_ for _ in ()).throw(RuntimeError("stop failed"))),
            ("b", lambda: ran.append("b")),
            ("c", lambda: ran.append("c")),
        ]
        results = run_best_effort(steps, errs)
        self.assertEqual(ran, ["a", "b", "c"], "every later step must still run past a raising step")
        self.assertEqual(len(errs), 1, f"the single failure must be recorded: {errs}")
        self.assertIn("boom: stop failed", errs[0])
        self.assertIsNone(results[1], "the raising step's result is recorded as None")

    def test_census_failure_still_plans_every_owned_distro(self):
        # present=None models a FAILED `wsl -l -q`; teardown must target every owned distro, not skip (acc13ea #3).
        imported = ["zb-test-x-a", "zb-test-x-b", "zb-test-x-nope"]
        self.assertEqual(plan_distro_cleanup(imported, None), imported,
                         "a census failure must plan teardown for every owned distro")

    def test_census_success_targets_only_registered(self):
        imported = ["zb-test-x-a", "zb-test-x-b"]
        present = ["zb-test-x-a", "Ubuntu"]
        self.assertEqual(plan_distro_cleanup(imported, present), ["zb-test-x-a"],
                         "with a good census, only actually-registered owned distros are targeted")

    def test_listener_identity_tags_all_cases(self):
        # (c101b1e #2) classify_listener returns one of NONE|GONE|OURS|NOT_OURS|UNREADABLE from the
        # deterministic single-token census.
        rand = "abcd1"
        ours = r"CMD=powershell ... C:\Users\zbtext\zb\wsl\run-abcd1\winlisten.ps1 0.0.0.0 39002"
        reused = r"CMD=C:\Windows\System32\notepad.exe"
        self.assertEqual(classify_listener(4242, ours, rand), "OURS")
        self.assertEqual(classify_listener(4242, reused, rand), "NOT_OURS",
                         "a reused PID with a different command line must never be treated as ours")
        self.assertEqual(classify_listener(4242, "GONE", rand), "GONE")
        self.assertEqual(classify_listener(None, ours, rand), "NONE")

    def test_listener_identity_unreadable_fails_closed(self):
        # (c101b1e #2) present-but-unreadable, empty, or any unexpected output => UNREADABLE (fail closed).
        rand = "abcd1"
        self.assertEqual(classify_listener(4242, "UNREADABLE", rand), "UNREADABLE")
        self.assertEqual(classify_listener(4242, "", rand), "UNREADABLE")
        self.assertEqual(classify_listener(4242, "unexpected noise", rand), "UNREADABLE")

    def test_listener_identity_rejects_other_run_nonce(self):
        # a concurrent sibling run's winlisten.ps1 must not match our nonce.
        other = r"CMD=... \run-ZZZZZ\winlisten.ps1 0.0.0.0 39002"
        self.assertEqual(classify_listener(4242, other, "abcd1"), "NOT_OURS")

    def test_listener_census_producer_consumer_path(self):
        # (bb17917 #1) the WHOLE producer->consumer path: a CIM error NEVER yields GONE/OURS; present-unreadable
        # is UNREADABLE; absence is GONE; identity decides OURS vs NOT_OURS.
        rand = "abcd1"
        ours = r"powershell ... C:\Users\zbtext\zb\wsl\run-abcd1\winlisten.ps1 0.0.0.0 39002"
        cases = [
            # (process_found, cim_error, command_line) -> expected final tag
            ((False, False, None), "GONE"),
            ((True, False, ours), "OURS"),
            ((True, False, r"C:\Windows\System32\notepad.exe"), "NOT_OURS"),
            ((True, False, ""), "UNREADABLE"),       # present, null/empty CommandLine
            ((True, True, ours), "UNREADABLE"),      # CIM error though the process exists -> fail closed
            ((False, True, None), "UNREADABLE"),     # CIM error -> UNREADABLE, never GONE
        ]
        for (found, err, cl), expected in cases:
            token = listener_census_token(found, err, cl)
            self.assertEqual(classify_listener(4242, token, rand), expected, (found, err, cl))

    def test_census_ps_is_fail_closed(self):
        # (bb17917 #1) the real remote producer must fail closed on a CIM error, not SilentlyContinue.
        ps = LISTENER_CENSUS_PS.format(pid=1234)
        self.assertIn("-ErrorAction Stop", ps)
        self.assertNotIn("SilentlyContinue", ps)
        self.assertIn("catch { 'UNREADABLE' }", ps)
        self.assertIn("'GONE'", ps)
        self.assertIn("'CMD='", ps)
        self.assertIn("ProcessId=1234", ps)

    def test_reap_bound_exceeds_remote_sleep(self):
        # (bb17917 #2) the invariant that guarantees always-reap: remote sleep + dead-peer bound < reap bound.
        self.assertLess(KEEPALIVE_SLEEP_S + SSH_DEAD_PEER_S, REAP_BOUND_S,
                        "the keepalive can never outlive the reap bound")

    def test_planted_name_blocks_every_destructive_op(self):
        # (c101b1e #1) a prospective name that already exists in the baseline is a collision (refuse the run),
        # and may_destroy() blocks EVERY destructive op on it; only a reserved, non-pre-existing name is allowed.
        reserved = ["zb-test-k-a", "zb-test-k-b", "zb-test-k-nope", "zb-test-k-absent"]
        baseline = ["Ubuntu", "zb-test-k-b"]  # a planted collision on one reserved name
        self.assertEqual(reserved_collisions(reserved, baseline), ["zb-test-k-b"],
                         "a planted name colliding with the baseline must be detected before any op")
        self.assertFalse(may_destroy("zb-test-k-b", reserved, baseline),
                         "a pre-existing (planted) reserved name must be blocked from every destructive op")
        self.assertFalse(may_destroy("Ubuntu", reserved, baseline),
                         "a non-reserved name must never be destroyable")
        self.assertTrue(may_destroy("zb-test-k-a", reserved, baseline),
                        "a reserved, non-pre-existing name is the only destroyable case")
        self.assertEqual(reserved_collisions(reserved, ["Ubuntu"]), [],
                         "no collision when none of the reserved names pre-exist")

    def test_reap_no_signal_contract(self):
        # (c101b1e #3) _reap_no_signal never signals a host pid; it reaps-or-fails and never returns alive.
        class _Fake:
            def __init__(self, wait_raises=False, alive_after_wait=False):
                self.wait_raises = wait_raises
                self.alive_after_wait = alive_after_wait
                self.signalled = []
                self.wait_timeout = None
            def wait(self, timeout=None):
                self.wait_timeout = timeout
                if self.wait_raises:
                    raise subprocess.TimeoutExpired(cmd="ssh", timeout=timeout)
                return 0
            def poll(self):
                return None if self.alive_after_wait else 0
            def terminate(self):
                self.signalled.append("terminate")
            def kill(self):
                self.signalled.append("kill")
        reap = WslTopologyLive._reap_no_signal
        # reaped cleanly -> returns, no signal sent, and it waited through the FULL known remote bound
        f_ok = _Fake()
        reap(f_ok)
        self.assertEqual(f_ok.signalled, [], "no signal may be sent to a host pid")
        self.assertGreaterEqual(f_ok.wait_timeout, KEEPALIVE_SLEEP_S,
                                "the reap must wait through the full known remote bound")
        # timed out but the child had exited at the boundary -> final poll reaps it -> no raise, no signal
        f_edge = _Fake(wait_raises=True, alive_after_wait=False)
        reap(f_edge)
        self.assertEqual(f_edge.signalled, [], "the always-reap path must not signal")
        # timed out AND still alive -> raise, still no signal (backstop contains it)
        f_to = _Fake(wait_raises=True, alive_after_wait=True)
        with self.assertRaises(AssertionError):
            reap(f_to)
        self.assertEqual(f_to.signalled, [], "a timed-out reap must not fall back to a signal")
        # wait() returned but handle still alive -> contract violation -> raise
        with self.assertRaises(AssertionError):
            reap(_Fake(alive_after_wait=True))

    def test_canary_never_in_staged_scripts(self):
        # no staged script template may embed a secret-shaped token; the scan must report zero leaks.
        secret = secrets.token_hex(16)
        staged = [_SETUP_SH, _AUTH_SH, _WHOAMI_SH, _NONROOT_SH, _IDENT_SH, _LISTEN_SH, _READRX_SH,
                  _COTENANT_SH, _REVCLIENT_SH, _C1BOOT_WRITER, _C1BOOT_PS1, _WIN_TCP_PS1, _WIN_LISTEN_PS1,
                  _WIN_LAUNCH_PS1]
        self.assertEqual(count_secret_leaks(staged, secret), 0,
                         "no staged template may contain the canary")
        # and the scan is real: a file that DOES contain the secret is detected.
        self.assertEqual(count_secret_leaks(["x", f"leak {secret} here"], secret), 1)

    def test_c1_boot_writer_never_prints_secret(self):
        # acc13ea #5: c1boot.py prints only PORT=, never GOT=/the secret.
        self.assertIn("PORT=%d", _C1BOOT_WRITER)
        self.assertNotIn("GOT=", _C1BOOT_WRITER)
        self.assertNotIn("got_secret", _C1BOOT_PS1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
