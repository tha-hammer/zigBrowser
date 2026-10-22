r"""WS8/WS9 WSL2 topology — live DISCOVERY SPIKE on the Win11 VM (OD-W4).

!!! DISCOVERY-ONLY. NOT RUN; AWAITING RoseCat review of this repair before any live run (draft gate). It is
    NOT a closure or a security claim — the security/product proofs come LATER via named red/green tests
    driving the production WslBackend / LinuxBwrapBackend. It writes ONLY under a unique per-run directory
    beneath C:\\Users\\zbtext\\zb\\wsl on win11-m8, never on the read-only Windows 10 file server, and never
    calls global `wsl --shutdown`.

This commit ADDRESSES the six 6e9f989-review defects (in code; not yet reviewed or run):
- cleanup now runs EVERY step best-effort (each wrapped, errors accumulate) and fails the test at the end if
  anything failed — it can no longer abort part-way;
- distro/artifact ownership is recorded BEFORE the import attempt, so a partial/failed import is still
  censused and cleaned;
- the Windows listener is stopped PID-reuse-safely: only when the PID's command line still matches this run's
  `run-<nonce>\winlisten.ps1` (same identity check in the survival census);
- local teardown terminates ONLY our own tracked Popen handles (reuse-safe; no numeric `os.kill`), with a
  pid>1 guard;
- the C1 secret reaches neither disk nor argv/env: it is fed over stdin to the bootstrap AND the no-leak
  census reads its pattern from stdin (never interpolated into a PowerShell/ssh command line);
- the `::1` readiness check matches the exact `::1:<port>` row.

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


def _scrub(*cmd):
    return ["env", "-u", "DISPLAY", "-u", "WAYLAND_DISPLAY", "-u", "XAUTHORITY", *cmd]


def _ssh_base():
    return ["ssh", "-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", f"UserKnownHostsFile={KH}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=25",
            "-o", "ConnectionAttempts=3", "-p", PORT, f"{USER}@{HOST}"]


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


class WslTopologyLive(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not ROOTFS or not os.path.isfile(ROOTFS):
            raise AssertionError("ZB_WSL_ROOTFS unset/missing on an opted-in host — point it at the pinned Alpine minirootfs")
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
        self.localdir = tempfile.mkdtemp(prefix="wsllive-")
        self.staged = set()
        self.keepalives = []
        self.imported = []
        self.win_listener_pid = None
        self.baseline_distros = census_distros()
        for n in (self.na, self.nb):
            if n in self.baseline_distros:
                raise AssertionError(f"collision: marked distro {n} already exists; refusing to run")
        # Refuse a pre-existing run dir (no shared-name overwrite), then create it.
        rc, out, _ = ssh("cmd", "/c", f"if exist {self.run_win} (echo EXISTS) else (echo NEW)")
        self.assertEqual(rc, 0, "run-dir probe failed")
        self.assertIn("NEW", out, f"per-run dir {self.run_win} already exists; refusing to run")
        rc, _, e = ssh("cmd", "/c", f"mkdir {self.run_win}")
        self.assertEqual(rc, 0, f"mkdir run dir failed: {e}")
        self.addCleanup(self._cleanup_and_census)  # ALWAYS runs, fails closed

    def _cleanup_and_census(self):
        # (a) EVERY step is best-effort and cannot abort the rest: each is wrapped, errors accumulate, and the
        # test fails at the end if anything failed. (c)/(d) teardown is PID-reuse-safe and uses no numeric
        # local kills — only our own Popen handles, verified by identity on the Windows side.
        errs = []

        def step(label, fn):
            try:
                return fn()
            except Exception as ex:  # never let one failure skip the remaining cleanup
                errs.append(f"{label}: {ex}")
                return None

        # (d) local teardown: terminate ONLY our own tracked Popen children by handle (reuse-safe; no numeric
        # os.kill). A valid child has an int pid > 1; reap it.
        for p in self.keepalives:
            def _kill(p=p):
                if not isinstance(getattr(p, "pid", None), int) or p.pid <= 1:
                    return
                p.terminate()
                try:
                    p.wait(timeout=10)
                except Exception:
                    p.kill(); p.wait(timeout=10)
            step("keepalive terminate", _kill)

        # (c) PID-reuse-safe Windows listener stop: only stop a PID whose process command line is OUR
        # per-run winlisten.ps1 (a reused PID with a different command line is left alone).
        if self.win_listener_pid:
            marker = f"run-{self.rand}\\\\winlisten.ps1"
            step("stop win listener", lambda: ssh("powershell", "-NoProfile", "-Command",
                 f"$p=Get-CimInstance Win32_Process -Filter \"ProcessId={self.win_listener_pid}\" -ErrorAction SilentlyContinue; "
                 f"if ($p -and $p.CommandLine -match '{marker}') {{ Stop-Process -Id {self.win_listener_pid} -Force -ErrorAction SilentlyContinue }}; exit 0"))

        # Unregister only distros that are actually registered now (a never-registered partial import is skipped,
        # not a spurious failure); a present-but-failing unregister IS an error.
        _, present = (0, [])
        res = step("list distros", census_distros)
        present = res if res is not None else []
        for n in self.imported:
            if n not in present:
                continue
            step(f"terminate {n}", lambda n=n: self._cleanup_rc("terminate", n, ssh("wsl", "--terminate", n), errs))
            step(f"unregister {n}", lambda n=n: self._cleanup_rc("unregister", n, ssh("wsl", "--unregister", n), errs))
        step("rmdir run dir", lambda: self._cleanup_rc("rmdir run dir", self.run_win,
             ssh("cmd", "/c", f"if exist {self.run_win} rmdir /s /q {self.run_win}"), errs))

        # postflight census: distros back to baseline, run dir gone, no leftover (identity-checked) win listener
        final = step("final distro census", census_distros)
        if final is not None and final != self.baseline_distros:
            errs.append(f"final distro census {final} != baseline {self.baseline_distros}")
        res = step("run-dir gone probe", lambda: ssh("cmd", "/c", f"if exist {self.run_win} (echo LEFT) else (echo GONE)"))
        if res is not None and (res[0] != 0 or "GONE" not in res[1]):
            errs.append(f"run dir not gone (rc={res[0]}, out={res[1]!r})")
        if self.win_listener_pid:
            marker = f"run-{self.rand}\\\\winlisten.ps1"
            res = step("win listener survival", lambda: ssh("powershell", "-NoProfile", "-Command",
                 f"$p=Get-CimInstance Win32_Process -Filter \"ProcessId={self.win_listener_pid}\" -ErrorAction SilentlyContinue; "
                 f"if ($p -and $p.CommandLine -match '{marker}') {{'ALIVE'}} else {{'DEAD'}}"))
            if res is not None and "DEAD" not in res[1]:
                errs.append(f"windows reverse listener pid {self.win_listener_pid} survived (identity-matched)")
        shutil.rmtree(self.localdir, ignore_errors=True)
        if errs:
            raise AssertionError("cleanup/postflight census failed: " + " | ".join(errs))

    @staticmethod
    def _cleanup_rc(label, target, result, errs):
        rc, _, e = result
        if rc != 0:
            errs.append(f"{label} {target} rc={rc}: {e.strip()}")

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
        p = ssh_bg("wsl", "-d", distro, "-u", "root", "-e", "/bin/sleep", "150")
        self.keepalives.append(p)
        return p

    def _import(self, distro):
        # (b) record ownership BEFORE the attempt, so a partial/failed import is still censused + cleaned.
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
        rc, _, _ = ssh("cmd", "/c",
                       f"wsl --import zb-test-{self.rand}-nope {self.run_win}\\nope {self.run_win}\\does-not-exist.tar.gz --version 2")
        self.assertNotEqual(rc, 0, "a failed import must return nonzero (oracle)")
        # clean a partial dir if the failed import created one
        ssh("cmd", "/c", f"if exist {self.run_win}\\nope rmdir /s /q {self.run_win}\\nope")
        rc, _, _ = ssh("wsl", "--unregister", f"zb-test-{self.rand}-absent")
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
        m = re.search(r"READY pid=(\d+) 0\.0\.0\.0:39002", ol)
        self.assertIsNotNone(m, f"the Windows reverse listener must prove READY with a pid before the negative: {ol}")
        self.win_listener_pid = int(m.group(1))
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
        self.assertEqual(c1.get("got_secret"), secret, f"secret must arrive at Linux fd0 via wsl stdin: {c1}")
        self.assertTrue(int(c1.get("port", 0)) > 0, f"the ephemeral port must return on stdout: {c1}")
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
# the port + the received secret to stdout, then accepts one authed conn. The secret never reaches this file.
_C1BOOT_WRITER = r"""#!/bin/sh
cat > /home/zbagent/c1boot.py <<'PY'
import socket,sys
secret=sys.stdin.readline().strip()
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",0)); s.listen(1); port=s.getsockname()[1]
sys.stdout.write("PORT=%d GOT=%s\n"%(port,secret)); sys.stdout.flush()
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
$res=@{{ got_secret=''; port=0; ack=''; exited=$false; error='' }}
try {{
  $p=[Diagnostics.Process]::Start($psi)
  $p.StandardInput.WriteLine($secret); $p.StandardInput.Flush()
  $line=$p.StandardOutput.ReadLine()
  if ($line -match 'PORT=(\\d+) GOT=(\\S+)') {{ $res.port=[int]$Matches[1]; $res.got_secret=$Matches[2] }}
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
if($ready){ Write-Output ("READY pid=" + $p.Id + " 0.0.0.0:39002") } else { Write-Output 'NOT_READY' }
"""


if __name__ == "__main__":
    if not HOST:
        sys.stderr.write("ZB_WIN11_HOST unset — WSL2 live topology spike skipped (exit 77)\n")
        sys.exit(77)
    unittest.main(verbosity=2)
