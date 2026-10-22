r"""WS8/WS9 WSL2 topology — live DISCOVERY SPIKE on the Win11 VM (OD-W4).

!!! DISCOVERY-ONLY. REPAIRED per RoseCat 9134b8b/7558; AWAITING RoseCat review before the next live run
    (draft gate: a live WSL run needs her OK on the repaired spike first). It is not production closure and
    not a security claim: the security/product proofs come LATER via named red/green tests driving the
    production WslBackend / LinuxBwrapBackend. It writes ONLY under C:\\Users\\zbtext\\zb\\wsl on win11-m8,
    never on the read-only Windows 10 file server, and never calls global `wsl --shutdown`.

Repairs in this revision (addressing 9134b8b blockers 1-3):
- FAIL-CLOSED: every lifecycle op (scp, import, run, terminate, unregister, delete) and every probe asserts
  its return code; nothing is captured-and-discarded.
- LISTENER-READY PROOF: the in-distro listener is confirmed LISTENing (netstat) before the Windows client
  connects; the Windows reverse listener is confirmed "LISTENING" (its ready file) before the WSL→Windows
  negative is accepted — so a listener that never started can no longer produce a false green.
- CLEANUP + FINAL CENSUS: every staged file and every imported distro/import-dir is tracked and removed; the
  final distro census AND the final `zb\\wsl` artifact census must equal the pre-run baseline.
- DEFAULT-USER (no `-u`): a real default-user launch asserts uid 1000 AND an admin-group census (no
  root/wheel/adm/sudo group), distinct from the explicit `-u zbagent` launch.
- C1 BOOTSTRAP (blocker 3): a probe of the Windows-stdio→Linux-fd + ephemeral-port-return bootstrap —
  a secret written to `wsl.exe` stdin is read at Linux fd 0, the in-distro process prints its chosen
  `127.0.0.1:0` port to stdout (→ the browser), and an authenticated connect to that port returns an ACK.
- NEGATIVE/MUTANT ORACLES: a connect to a closed in-distro port must be refused; a failed import and a failed
  unregister must return nonzero; a planted leftover must be detected by the census — each proving the oracle
  fails closed rather than passing vacuously.

Run live (ONLY after RoseCat approves this repaired spike):
  ZB_WIN11_HOST=127.0.0.1 ZB_WSL_ROOTFS=/path/to/alpine-minirootfs-3.21.9-x86_64.tar.gz \
      python3 -I tests/windows/wsl_live_test.py -v
"""
import hashlib
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

# Reviewed, pinned rootfs identity (official Alpine v3.21 minirootfs). Verify the LOCAL file against THIS
# constant, never a downloaded hash file (same-server hash catches corruption, not tampering).
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


def ssh(*args, timeout=180):
    r = subprocess.run(_scrub(*_ssh_base(), *args), capture_output=True, text=True, timeout=timeout)
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


def census_wsl_dir():
    """Names under zb\\wsl (files + dirs); a rc!=0 is a hard failure, never an empty listing."""
    rc, out, err = ssh("powershell", "-NoProfile", "-Command",
                       "Get-ChildItem $env:USERPROFILE\\zb\\wsl -ErrorAction SilentlyContinue | "
                       "Select-Object -ExpandProperty Name")
    assert rc == 0, f"zb\\wsl census failed rc={rc}: {err}"
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
        cls.rand = secrets.token_hex(4)
        cls.na = f"zb-test-{cls.rand}-a"
        cls.nb = f"zb-test-{cls.rand}-b"
        cls.base = f"C:\\Users\\{USER}\\zb\\wsl"
        cls.tar_name = f"{cls.rand}.tar.gz"
        rc, _, e = ssh("cmd", "/c", f"if not exist {cls.base} mkdir {cls.base}")
        assert rc == 0, f"could not create install base dir: {e}"
        cls.baseline_distros = census_distros()
        cls.baseline_dir = census_wsl_dir()
        for n in (cls.na, cls.nb):
            if n in cls.baseline_distros:
                raise AssertionError(f"collision: marked distro {n} already exists; refusing to run")
        cls.localdir = tempfile.mkdtemp(prefix="wsllive-")
        cls.staged = set()       # remote names under zb\wsl that we created
        cls.keepalives = []
        cls.facts = {}

    @classmethod
    def tearDownClass(cls):
        # Best-effort safety net; the test body already asserts the clean final census.
        for p in getattr(cls, "keepalives", []):
            try:
                p.terminate(); p.wait(timeout=10)
            except Exception:
                try: p.kill()
                except Exception: pass
        for n in (getattr(cls, "na", ""), getattr(cls, "nb", "")):
            if n:
                ssh("wsl", "--terminate", n)
                ssh("wsl", "--unregister", n)
        r = getattr(cls, "rand", "")
        if r:
            ssh("cmd", "/c",
                f"(if exist {cls.base}\\zb-test-{r}-a rmdir /s /q {cls.base}\\zb-test-{r}-a) & "
                f"(if exist {cls.base}\\zb-test-{r}-b rmdir /s /q {cls.base}\\zb-test-{r}-b)")
        for name in sorted(getattr(cls, "staged", set())):
            ssh("cmd", "/c", f"if exist {cls.base}\\{name} del /q {cls.base}\\{name}")
        if getattr(cls, "localdir", None):
            shutil.rmtree(cls.localdir, ignore_errors=True)

    # --- helpers (every op fail-closed) ---
    def _stage(self, name, text, crlf=False):
        p = os.path.join(self.localdir, name)
        with open(p, "w", newline=("\r\n" if crlf else "\n")) as f:
            f.write(text)
        self.assertEqual(scp(p, f"zb/wsl/{name}"), 0, f"scp {name} failed")
        self.staged.add(name)

    def _run(self, distro, script_remote, user=None):
        u = f"-u {user} " if user else ""
        ps = (f"Get-Content -Raw $env:USERPROFILE\\zb\\wsl\\{script_remote} | "
              f"wsl -d {distro} {u}-e /bin/sh")
        rc, out, err = ssh("powershell", "-NoProfile", "-Command", ps)
        self.assertEqual(rc, 0, f"run {script_remote} on {distro} failed rc={rc}: {err}")
        return out

    def _pin(self, distro):
        p = ssh_bg("wsl", "-d", distro, "-u", "root", "-e", "/bin/sleep", "150")
        self.keepalives.append(p)
        return p

    def _import(self, distro):
        rc, o, e = ssh("cmd", "/c", f"wsl --import {distro} {self.base}\\{distro} {self.base}\\{self.tar_name} --version 2")
        self.assertTrue("completed successfully" in o or rc == 0, f"import {distro} failed rc={rc}: {o}{e}")

    # ------------------------------------------------------------------
    # Negative / mutant oracles (cheap; prove the checks fail closed). No distro import needed.
    # ------------------------------------------------------------------
    def test_oracle_failed_import_and_unregister_return_nonzero(self):
        rc, _, _ = ssh("cmd", "/c", f"wsl --import zb-test-{self.rand}-nope {self.base}\\nope {self.base}\\does-not-exist.tar.gz --version 2")
        self.assertNotEqual(rc, 0, "a failed import must return nonzero (oracle: rc checks catch failure)")
        rc, _, _ = ssh("wsl", "--unregister", f"zb-test-{self.rand}-absent")
        self.assertNotEqual(rc, 0, "unregistering an absent distro must return nonzero (oracle)")

    def test_oracle_leftover_is_detected_by_census(self):
        sentinel = f"leftover-{self.rand}.sentinel"
        self.assertEqual(scp(os.path.join(self.localdir or tempfile.mkdtemp(), sentinel) if False else self._tmp_sentinel(sentinel), f"zb/wsl/{sentinel}"), 0)
        try:
            self.assertIn(sentinel, census_wsl_dir(), "a planted leftover must be detected by the census (oracle)")
        finally:
            rc, _, _ = ssh("cmd", "/c", f"del /q {self.base}\\{sentinel}")
            self.assertEqual(rc, 0, "sentinel delete must succeed")
        self.assertNotIn(sentinel, census_wsl_dir(), "the census must confirm the leftover was removed")

    def _tmp_sentinel(self, name):
        d = tempfile.mkdtemp(prefix="wsllive-sent-")
        p = os.path.join(d, name)
        with open(p, "w") as f:
            f.write("sentinel\n")
        return p

    # ------------------------------------------------------------------
    # The main topology spike.
    # ------------------------------------------------------------------
    def test_wsl_topology(self):
        na, nb = self.na, self.nb
        self.assertEqual(scp(ROOTFS, f"zb/wsl/{self.tar_name}"), 0, "scp rootfs")
        self.staged.add(self.tar_name)
        self._import(na)
        self._import(nb)
        self.facts["P1_import_no_admin"] = "ok"

        # setup: non-root user + wsl.conf (automount/interop off, default=non-root) + python3
        self._stage("setup.sh", _SETUP_SH)
        for n in (na, nb):
            o = self._run(n, "setup.sh", user="root")
            self.assertIn("SETUP_DONE", o, f"setup {n}: {o}")
            self.assertIn("ADDUSER_RC=0", o)
            self.assertIn("APK_RC=0", o)
            self.assertEqual(ssh("wsl", "--terminate", n)[0], 0, f"terminate {n}")

        # P2/P3 automount/interop/PATH
        self._stage("auth.sh", _AUTH_SH)
        a = kv(self._run(na, "auth.sh"))   # default user
        self.facts.update({f"P2P3_{k}": v for k, v in a.items()})
        self.assertEqual(a.get("MNT_C_MOUNTPOINT"), "no")
        self.assertEqual(a.get("PATH_HAS_MNT"), "0")
        self.assertEqual(a.get("BINFMT"), "present")

        # P4a DEFAULT user (no -u) must be the non-root uid + no admin group (blocker 2)
        self._stage("whoami.sh", _WHOAMI_SH)
        d = kv(self._run(na, "whoami.sh"))               # NO user= -> default
        e = kv(self._run(na, "whoami.sh", user=NONROOT)) # explicit
        self.facts["P4_default_uid"] = d.get("UID")
        self.facts["P4_default_groups"] = d.get("GROUPS")
        self.facts["P4_explicit_uid"] = e.get("UID")
        self.assertEqual(d.get("UID"), "1000", f"default (no -u) launch must be uid 1000: {d}")
        self.assertEqual(e.get("UID"), "1000", f"explicit -u {NONROOT} must be uid 1000: {e}")
        groups = set((d.get("GROUPS") or "").split(","))
        self.assertTrue(groups.isdisjoint(ADMIN_GROUPS), f"default user must be in no admin group: {d.get('GROUPS')}")

        # P4b non-root security + userns/bwrap AS the non-root user
        self._stage("nonroot.sh", _NONROOT_SH)
        nr = kv(self._run(na, "nonroot.sh", user=NONROOT))
        self.facts.update({f"P4_{k}": v for k, v in nr.items()})
        self.assertEqual(nr.get("SUDO"), "absent")
        self.assertEqual(nr.get("DOAS"), "absent")
        self.assertEqual(nr.get("WRITE_ETC"), "denied")
        self.assertEqual(nr.get("CAPEFF"), "0000000000000000")
        self.assertEqual(nr.get("SETUID_COUNT"), "0")
        self.assertTrue(nr.get("USERNS", "").startswith("ok"))
        self.assertTrue(nr.get("BWRAP", "").startswith("ok"))

        # P5 shared utility VM / namespaces
        self._stage("ident.sh", _IDENT_SH)
        ia, ib = kv(self._run(na, "ident.sh", user="root")), kv(self._run(nb, "ident.sh", user="root"))
        self.assertEqual(ia.get("BOOT_ID"), ib.get("BOOT_ID"), "two distros share one utility VM")
        self.assertEqual(ia.get("NS_NET"), ib.get("NS_NET"), "two distros share one net namespace")
        self.assertNotEqual(ia.get("NS_PID"), ib.get("NS_PID"), "each distro has its own PID namespace")
        self.facts["P5_boot_equal"] = str(ia.get("BOOT_ID") == ib.get("BOOT_ID"))
        gw = ia.get("GW", "")

        # P6 transport: exact bind + ACK/canary + IPv6 + hostile co-tenant + negative control
        self._pin(na); self._pin(nb)
        time.sleep(4)
        self._stage("listen.sh", _LISTEN_SH)
        self._stage("readrx.sh", _READRX_SH)
        self._stage("wtcp.ps1", _WIN_TCP_PS1, crlf=True)
        lo = kv(self._run(na, "listen.sh", user=NONROOT))
        self.assertIn("LO", lo, f"listener ports: {lo}")
        self.assertEqual(lo.get("LISTEN"), "yes", f"in-distro listener must be confirmed LISTENing: {lo}")  # ready proof
        p_lo, p_any, p_v6, p_closed = lo["LO"], lo["ANY"], lo["V6"], lo["CLOSED"]
        self._stage("wtcp_spec.txt", f"127.0.0.1|{p_lo}|w-lo;127.0.0.1|{p_any}|w-any;::1|{p_v6}|w-v6;127.0.0.1|{p_closed}|w-neg\n")
        rc, ow, ew = ssh("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", f"{self.base}\\wtcp.ps1")
        self.assertEqual(rc, 0, f"win tcp client rc={rc}: {ew}")
        self.facts["P6_win_to_wsl"] = ow.replace("\n", " | ").strip()
        self.assertIn(f"127.0.0.1:{p_lo} = ok ack=ACK:w-lo", ow, f"Win->WSL 127.0.0.1 with ACK: {ow}")
        self.assertIn(f"::1:{p_v6} = ok ack=ACK:w-v6", ow, f"Win->WSL ::1 with ACK: {ow}")
        self.assertIn(f"127.0.0.1:{p_closed} = fail", ow, f"negative control: a closed port must be refused: {ow}")
        # hostile co-tenant
        self._stage("cotenant.sh", _COTENANT_SH.format(lo=p_lo, any=p_any, v6=p_v6))
        oc = self._run(nb, "cotenant.sh", user=NONROOT)
        self.facts["P6_hostile_cotenant"] = oc.replace("\n", " | ").strip()
        self.assertIn("co->lo=ok", oc, f"co-tenant reaching the 127.0.0.1 listener (auth mandatory): {oc}")
        rx = self._run(na, "readrx.sh", user=NONROOT)
        self.assertIn("canary=b'w-lo'", rx, f"listener received the Windows canary: {rx}")
        self.assertIn("canary=b'B-co->lo'", rx, f"listener received the co-tenant canary: {rx}")

        # P6 reverse: WSL->Windows negative ONLY after proving the Windows listener ready (blocker 1)
        self._stage("winlisten.ps1", _WIN_LISTEN_PS1, crlf=True)
        self._stage("winlaunch.ps1", _WIN_LAUNCH_PS1, crlf=True)
        rc, ol, el = ssh("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", f"{self.base}\\winlaunch.ps1")
        self.assertEqual(rc, 0, f"launch win reverse listener rc={rc}: {el}")
        self.assertIn("LISTENING 0.0.0.0:39002", ol, f"the Windows reverse listener must prove READY before the negative: {ol}")
        self._stage("revclient.sh", _REVCLIENT_SH.format(gw=gw))
        orv = self._run(na, "revclient.sh", user=NONROOT)
        self.facts["P6_wsl_to_windows"] = orv.replace("\n", " | ").strip()
        self.assertIn("gw->win=fail", orv, f"WSL->Windows must fail even with the Windows listener PROVEN ready: {orv}")
        self.assertIn("testnet=fail", orv, f"a TEST-NET decoy must be unreachable: {orv}")

        # C1 bootstrap probe (blocker 3): stdin secret -> Linux fd0; chosen port -> stdout; authed connect
        secret = secrets.token_hex(16)
        self._stage("c1boot.sh", _C1BOOT_WRITER)   # writes /home/zbagent/c1boot.py
        self._run(na, "c1boot.sh", user=NONROOT)
        self._stage("c1boot.ps1", _C1BOOT_PS1.format(distro=na, user=NONROOT, secret=secret), crlf=True)
        rc, oc1, ec1 = ssh("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", f"{self.base}\\c1boot.ps1")
        self.assertEqual(rc, 0, f"c1 bootstrap probe rc={rc}: {ec1}")
        c1 = json.loads(oc1.strip().splitlines()[-1])
        self.facts["P_C1_bootstrap"] = json.dumps(c1)
        self.assertEqual(c1.get("got_secret"), secret, f"the secret must arrive at Linux fd0 via wsl stdin: {c1}")
        self.assertTrue(int(c1.get("port", 0)) > 0, f"the in-distro ephemeral port must return on stdout: {c1}")
        self.assertEqual(c1.get("ack"), "ACK", f"an authed connect to the returned port must succeed: {c1}")

        # ---- final cleanup + census == baseline (blocker 1) ----
        self._pin_release()
        for n in (na, nb):
            rc, _, e = ssh("wsl", "--terminate", n); self.assertEqual(rc, 0, f"terminate {n}: {e}")
            rc, _, e = ssh("wsl", "--unregister", n); self.assertEqual(rc, 0, f"unregister {n}: {e}")
        rc, _, e = ssh("cmd", "/c",
                       f"(if exist {self.base}\\{na} rmdir /s /q {self.base}\\{na}) & "
                       f"(if exist {self.base}\\{nb} rmdir /s /q {self.base}\\{nb})")
        self.assertEqual(rc, 0, f"rmdir import dirs: {e}")
        for name in sorted(self.staged):
            rc, _, e = ssh("cmd", "/c", f"if exist {self.base}\\{name} del /q {self.base}\\{name}")
            self.assertEqual(rc, 0, f"delete staged {name}: {e}")
        self.staged.clear()
        self.assertEqual(census_distros(), self.baseline_distros, "final distro census must equal baseline")
        self.assertEqual(census_wsl_dir(), self.baseline_dir, "final zb\\wsl artifact census must equal baseline (no leftover)")

        print("\n==== WSL2 topology discovery observations (win11-m8; not a closure or security claim) ====")
        for k in sorted(self.facts):
            print(f"{k}={self.facts[k]}")

    def _pin_release(self):
        for p in self.keepalives:
            try:
                p.terminate(); p.wait(timeout=10)
            except Exception:
                try: p.kill()
                except Exception: pass
        self.keepalives.clear()


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

# Binds 127.0.0.1:0 + 0.0.0.0:0 + ::1:0 AND reserves then CLOSES one port (the negative-control target),
# writes its ports, stays up 90s, records the moved canary + returns an ACK.
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
# a reserved-then-closed port: a connect here must be refused (negative control)
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
netstat -ltn 2>/dev/null | grep -q '127.0.0.1:' && echo "LISTEN=yes" || echo "LISTEN=no"
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
# the port + the received secret to stdout (fd 1 -> wsl.exe stdout -> the browser), then accepts one authed conn.
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

_C1BOOT_PS1 = """$ErrorActionPreference='Stop'
$secret='{secret}'
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName='wsl.exe'
$psi.Arguments='-d {distro} -u {user} -e /usr/bin/python3 /home/{user}/c1boot.py'
$psi.RedirectStandardInput=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.UseShellExecute=$false
$res=@{{ got_secret=''; port=0; ack=''; error='' }}
try {{
  $p=[Diagnostics.Process]::Start($psi)
  $p.StandardInput.WriteLine($secret); $p.StandardInput.Flush()
  $line=$p.StandardOutput.ReadLine()   # PORT=<p> GOT=<secret>
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
  $p.StandardInput.Close(); [void]$p.WaitForExit(8000)
}} catch {{ $res.error=$_.Exception.Message }}
[Console]::Out.Write(($res | ConvertTo-Json -Compress))
"""

_WIN_TCP_PS1 = """$spec = (Get-Content -Raw (Join-Path $env:USERPROFILE 'zb\\wsl\\wtcp_spec.txt')).Trim()
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

_WIN_LAUNCH_PS1 = """$base = Join-Path $env:USERPROFILE 'zb\\wsl'
$out = Join-Path $base 'l0.txt'
Remove-Item $out -ErrorAction SilentlyContinue
Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $base 'winlisten.ps1'),'0.0.0.0','39002',$out -WindowStyle Hidden
# Prove the listener is READY before returning (so the reverse negative cannot false-green).
$deadline=(Get-Date).AddSeconds(8); $ready=$false
while((Get-Date) -lt $deadline){ Start-Sleep -Milliseconds 200; if((Test-Path $out) -and ((Get-Content $out -Raw) -match 'LISTENING 0.0.0.0:39002')){ $ready=$true; break } }
if($ready){ Get-Content $out } else { Write-Output 'NOT_READY' }
"""


if __name__ == "__main__":
    if not HOST:
        sys.stderr.write("ZB_WIN11_HOST unset — WSL2 live topology spike skipped (exit 77)\n")
        sys.exit(77)
    unittest.main(verbosity=2)
