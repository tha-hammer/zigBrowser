r"""WS8/WS9 WSL2 topology — live DISCOVERY SPIKE on the Win11 VM (OD-W4).

!!! DISCOVERY-ONLY / DO NOT RERUN (RoseCat 9134b8b / 7558 / 7561). This spike's executable oracle is
    KNOWN-DEFECTIVE and MUST NOT be rerun or cited as gate evidence until it is repaired and reviewed:
    teardown ignores every terminate/unregister/delete return code and performs NO final census; the
    staged scripts copied into C:\\Users\\zbtext\\zb\\wsl are never removed; many probe return codes are
    captured but never asserted; and the reverse "firewall-blocked" row never proves the Windows listener
    started (a listener that never started yields the same green). The exact non-root facts it reported
    were observed with an EXPLICIT `-u zbagent` launch only — it did NOT prove default-user selection.
    Repairs required before any rerun: fail-closed on every rc; prove the Windows listener ready before the
    reverse negative; a no-`-u` default-user + admin-group census; remove every staged artifact; assert a
    final distro/import/process/listener/staged-file census equal to baseline; and add the
    Windows-stdio/pipe -> Linux-fd + ephemeral-port-return (C1) probe. Nothing here is a security claim.

This is a discovery spike, NOT the production WS8/WS9 closure. It establishes the topology facts the
owner asked for before committing the WSL2 re-plan (RoseCat 119108c / 7516 / affd577). The security and
product claims (full bwrap confinement, control-channel auth, egress, lifetime under concurrency, setup
state machine, fail-closed) are proven LATER by named red/green tests driving the production
`WslBackend` / `LinuxBwrapBackend`, not by this script. See the "WS8/WS9 acceptance matrix" in the plan.

UNREGISTERED (live-only). It imports a tiny PINNED Alpine minirootfs as the standard Windows user (no
admin), creates a dedicated NON-ROOT Linux user, configures wsl.conf, proves each topology fact as a
PASS/FAIL row, then tears everything down with a guarded delete. It writes ONLY under
C:\Users\zbtext\zb\wsl on win11-m8 and never touches the Windows 10 file server.

Hygiene (RoseCat 7516 #1 / affd577): baseline distro census (rc-checked), refuse name collisions, app-owned
`zb-test-*` names + a per-run dir, apply wsl.conf with a PER-DISTRO `wsl --terminate` and NEVER a global
`wsl --shutdown`, pin distros alive with keepalive sessions during probes (WSL idle-terminates a distro and
its background listeners once the last session exits), check every lifecycle return code and fail closed,
unregister only our marked distros, assert final census == baseline, and clean the local scratch. On an
opted-in host (ZB_WIN11_HOST set) a missing/again-mismatched rootfs is a FAILURE, not a skip.

Corrected facts (affd577): the probes launch as a dedicated NON-ROOT uid (not WSL default root); the
transport binds EXACTLY 127.0.0.1:0 and moves a canary with an ACK (not a bare connect to either of
two addresses); IPv6 and a hostile co-tenant row are included; every return code fails closed.

Measured on win11-m8 (WSL 3.0.3.0, kernel 6.18.54.1, build 26200), 2026-10-21 (AzureRidge):
  P1 import + full per-user lifecycle run with no admin.
  P2 automount off => /mnt/c is not a mountpoint; Windows FS unreachable.
  P3 appendWindowsPath=false => no /mnt on PATH; interop.enabled=false is PARTIAL (WSLInterop binfmt stays
     registered; runtime `echo 0 > .../WSLInterop` hard-disables it).
  P4 non-root launch: default + explicit `-u zbagent` => uid 1000, no sudo/doas, CapEff=0, 0 setuid
     binaries, /etc write denied; unprivileged userns + bubblewrap work AS that non-root user.
  P5 two distros share ONE utility VM (boot_id) + ONE net namespace (eth0/gateway); separate mount/PID ns.
  P6 transport: a 127.0.0.1:0 (and ::1:0) listener in the distro is reachable from Windows via
     localhostForwarding (ACK + canary move), IPv4 and IPv6; a hostile co-tenant distro reaches the same
     127.0.0.1 listener (shared net ns) => app-layer auth is MANDATORY; WSL->Windows is firewall-blocked.
  P7 per-run process-group kill leaves a co-tenant session alive; `wsl --terminate` kills the whole distro.

Run live:
  ZB_WIN11_HOST=127.0.0.1 ZB_WSL_ROOTFS=/path/to/alpine-minirootfs-3.21.9-x86_64.tar.gz \
      python3 -I tests/windows/wsl_live_test.py -v
"""
import hashlib
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

# Reviewed, pinned rootfs identity (official Alpine v3.21 minirootfs). Verify the LOCAL file against
# THIS constant, never against a downloaded .sha256 (same-server hash catches corruption, not tampering).
ROOTFS_NAME = "alpine-minirootfs-3.21.9-x86_64.tar.gz"
ROOTFS_SHA256 = "3d5912d47e004ac77746d63ab848abd9e37164465cf1c866eb574bc526135012"

HOST = os.environ.get("ZB_WIN11_HOST")
PORT = os.environ.get("ZB_WIN11_PORT", "2222")
USER = os.environ.get("ZB_WIN11_USER", "zbtext")
KEY = os.environ.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key")
KH = os.environ.get("ZB_WIN_KNOWN_HOSTS", "/home/maceo/vms/win11-m8/known_hosts")
ROOTFS = os.environ.get("ZB_WSL_ROOTFS")

NONROOT = "zbagent"  # the dedicated non-root Linux identity the production agent will run as


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
    """Backgrounded ssh (e.g. a keepalive sleep) pinning a distro alive. Returns a Popen to reap."""
    return subprocess.Popen(_scrub(*_ssh_base(), *args),
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def scp(local, remote, timeout=180):
    base = ["scp", "-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", f"UserKnownHostsFile={KH}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=25",
            "-o", "ConnectionAttempts=3", "-P", PORT, local, f"{USER}@{HOST}:{remote}"]
    return subprocess.run(_scrub(*base), capture_output=True, text=True, timeout=timeout).returncode


def census():
    """(rc, sorted distro list). rc != 0 is a hard failure, never 'empty baseline'."""
    rc, out, _ = ssh("wsl", "-l", "-q")
    return rc, sorted(x.strip() for x in out.replace("\r", "").split("\n") if x.strip())


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
        # On an opted-in host a missing/mismatched rootfs is a FAILURE, not a skip (affd577).
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
        cls.tar_remote = f"{cls.base}\\{cls.rand}.tar.gz"
        rc, _, _ = ssh("cmd", "/c", f"if not exist {cls.base} mkdir {cls.base}")
        assert rc == 0, "could not create install base dir"
        rc, base_list = census()
        assert rc == 0, f"baseline `wsl -l -q` failed rc={rc}"
        cls.baseline = base_list
        for n in (cls.na, cls.nb):
            if n in cls.baseline:
                raise AssertionError(f"collision: marked distro {n} already exists; refusing to run")
        cls.localdir = tempfile.mkdtemp(prefix="wsllive-")
        cls.keepalives = []
        cls.facts = {}

    @classmethod
    def tearDownClass(cls):
        for p in getattr(cls, "keepalives", []):
            try:
                p.terminate(); p.wait(timeout=10)
            except Exception:
                try: p.kill()
                except Exception: pass
        r = getattr(cls, "rand", "")
        for n in (getattr(cls, "na", ""), getattr(cls, "nb", "")):
            if n:
                ssh("wsl", "--terminate", n)
                ssh("wsl", "--unregister", n)
        if r:
            ssh("cmd", "/c",
                f"(if exist {cls.base}\\zb-test-{r}-a rmdir /s /q {cls.base}\\zb-test-{r}-a) & "
                f"(if exist {cls.base}\\zb-test-{r}-b rmdir /s /q {cls.base}\\zb-test-{r}-b) & "
                f"(if exist {cls.tar_remote} del /q {cls.tar_remote})")
        if getattr(cls, "localdir", None):
            shutil.rmtree(cls.localdir, ignore_errors=True)

    def _stage(self, name, text):
        p = os.path.join(self.localdir, name)
        with open(p, "w", newline="\n") as f:
            f.write(text)
        self.assertEqual(scp(p, f"zb/wsl/{name}"), 0, f"scp {name}")

    def _stage_crlf(self, name, text):
        p = os.path.join(self.localdir, name)
        with open(p, "w", newline="\r\n") as f:
            f.write(text)
        self.assertEqual(scp(p, f"zb/wsl/{name}"), 0, f"scp {name}")

    def _run(self, distro, script_remote, user=None):
        u = f"-u {user} " if user else ""
        ps = (f"Get-Content -Raw $env:USERPROFILE\\zb\\wsl\\{script_remote} | "
              f"wsl -d {distro} {u}-e /bin/sh")
        rc, out, err = ssh("powershell", "-NoProfile", "-Command", ps)
        return rc, out, err

    def _pin(self, distro):
        p = ssh_bg("wsl", "-d", distro, "-u", "root", "-e", "/bin/sleep", "120")
        self.keepalives.append(p)
        return p

    def test_wsl_topology(self):
        na, nb, base = self.na, self.nb, self.base
        self.assertEqual(scp(ROOTFS, f"zb/wsl/{self.rand}.tar.gz"), 0, "scp rootfs")
        # --- import both distros as the standard (non-admin) Windows user ---
        for n in (na, nb):
            rc, o, e = ssh("cmd", "/c", f"wsl --import {n} {base}\\{n} {self.tar_remote} --version 2")
            self.assertTrue("completed successfully" in o or rc == 0, f"import {n} failed rc={rc}: {o}{e}")
        self.facts["P1_import_no_admin"] = "ok"

        # --- setup: dedicated non-root user + wsl.conf (automount/interop off, default=non-root) + tools ---
        self._stage("setup.sh", _SETUP_SH)
        for n in (na, nb):
            rc, o, e = self._run(n, "setup.sh", user="root")
            self.assertIn("SETUP_DONE", o, f"setup {n} failed: {o}{e}")
            self.assertIn("ADDUSER_RC=0", o, f"adduser {n}: {o}")
            self.assertIn("APK_RC=0", o, f"apk {n}: {o}")
            self.assertEqual(ssh("wsl", "--terminate", n)[0], 0, f"terminate {n}")

        # --- P2/P3: automount/interop/PATH authoritative probe on A (default user = non-root) ---
        self._stage("auth.sh", _AUTH_SH)
        rc, o, e = self._run(na, "auth.sh")  # no -u: default user must be the non-root one
        a = kv(o)
        self.facts.update({f"P2P3_{k}": v for k, v in a.items()})
        self.assertEqual(a.get("MNT_C_MOUNTPOINT"), "no", f"automount off: {o}")
        self.assertEqual(a.get("PATH_HAS_MNT"), "0", f"appendWindowsPath=false: {o}")
        self.assertEqual(a.get("BINFMT"), "present", f"interop=false leaves WSLInterop registered (measured): {o}")

        # --- P4: non-root identity + userns/bwrap AS that user (explicit -u and the default) ---
        self._stage("nonroot.sh", _NONROOT_SH)
        rc, o, e = self._run(na, "nonroot.sh", user=NONROOT)
        nr = kv(o)
        self.facts.update({f"P4_{k}": v for k, v in nr.items()})
        self.assertTrue(nr.get("ID", "").startswith("1000:"), f"explicit -u {NONROOT} must be uid 1000: {o}")
        self.assertEqual(nr.get("DEFAULT_UID"), "1000", f"wsl.conf default user must be non-root: {o}")
        self.assertEqual(nr.get("SUDO"), "absent", f"no sudo: {o}")
        self.assertEqual(nr.get("DOAS"), "absent", f"no doas: {o}")
        self.assertEqual(nr.get("WRITE_ETC"), "denied", f"must not write /etc: {o}")
        self.assertEqual(nr.get("CAPEFF"), "0000000000000000", f"no effective caps: {o}")
        self.assertEqual(nr.get("SETUID_COUNT"), "0", f"no setuid binaries: {o}")
        self.assertTrue(nr.get("USERNS", "").startswith("ok"), f"unprivileged userns as non-root: {o}")
        self.assertTrue(nr.get("BWRAP", "").startswith("ok"), f"bwrap as non-root: {o}")

        # --- P5: shared utility VM / namespaces across two distros ---
        self._stage("ident.sh", _IDENT_SH)
        _, oa, _ = self._run(na, "ident.sh", user="root")
        _, ob, _ = self._run(nb, "ident.sh", user="root")
        ia, ib = kv(oa), kv(ob)
        self.facts["P5_boot_equal"] = str(ia.get("BOOT_ID") == ib.get("BOOT_ID"))
        self.facts["P5_netns_equal"] = str(ia.get("NS_NET") == ib.get("NS_NET"))
        self.facts["P5_pidns_differ"] = str(ia.get("NS_PID") != ib.get("NS_PID"))
        self.assertEqual(ia.get("BOOT_ID"), ib.get("BOOT_ID"), "two distros share one utility VM")
        self.assertEqual(ia.get("NS_NET"), ib.get("NS_NET"), "two distros share one net namespace")
        self.assertNotEqual(ia.get("NS_PID"), ib.get("NS_PID"), "each distro has its own PID namespace")

        # --- P6: transport, exact bind + ACK/canary + IPv6 + hostile co-tenant + reverse blocked ---
        self._pin(na); self._pin(nb)
        time.sleep(4)  # let the pinned sessions boot the distros
        self._stage("listen.sh", _LISTEN_SH)
        self._stage("readrx.sh", _READRX_SH)
        self._stage_crlf("wtcp.ps1", _WIN_TCP_PS1)
        self._stage_crlf("winlisten.ps1", _WIN_LISTEN_PS1)
        self._stage_crlf("winlaunch.ps1", _WIN_LAUNCH_PS1)
        # start the listener in A as the non-root user
        _, lo, _ = self._run(na, "listen.sh", user=NONROOT)
        ports = kv(lo)
        self.assertIn("LO", ports, f"listener did not report ports: {lo}")
        self.assertEqual(ports.get("LISTEN"), "yes", f"listener not confirmed LISTENing: {lo}")
        p_lo, p_any, p_v6 = ports["LO"], ports["ANY"], ports["V6"]
        self.facts["P6_ports"] = f"lo={p_lo} any={p_any} v6={p_v6}"
        # Windows -> WSL on the EXACT 127.0.0.1 and ::1 ports, require ACK. The spec is staged to a file
        # (not an argv) so the ssh->cmd layer cannot eat its '|'/';' characters.
        spec = f"127.0.0.1|{p_lo}|w-lo;127.0.0.1|{p_any}|w-any;::1|{p_v6}|w-v6"
        self._stage("wtcp_spec.txt", spec + "\n")
        rc, ow, ew = ssh("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                         f"{base}\\wtcp.ps1")
        self.facts["P6_win_to_wsl"] = ow.replace("\n", " | ").strip()
        self.assertIn(f"127.0.0.1:{p_lo} = ok ack=ACK:w-lo", ow, f"Win->WSL 127.0.0.1 listener must work with ACK: {ow}")
        self.assertIn(f"::1:{p_v6} = ok ack=ACK:w-v6", ow, f"Win->WSL ::1 listener must work with ACK: {ow}")
        # hostile co-tenant distro B -> A's 127.0.0.1 listener (shared net ns => auth mandatory).
        # A and B share no filesystem, so A's ports are substituted into B's script here.
        self._stage("cotenant.sh", _COTENANT_SH.format(lo=p_lo, any=p_any, v6=p_v6))
        rc, oc, ec = self._run(nb, "cotenant.sh", user=NONROOT)
        self.facts["P6_hostile_cotenant"] = oc.replace("\n", " | ").strip()
        self.assertIn("co->lo=ok", oc, f"a co-tenant distro reaching the 127.0.0.1 listener proves auth is mandatory: {oc}")
        # verify the listener actually RECEIVED the moved canaries (bytes crossed, not just a connect)
        _, rx, _ = self._run(na, "readrx.sh", user=NONROOT)
        self.facts["P6_listener_rx"] = rx.replace("\n", " | ").strip()
        self.assertIn("canary=b'w-lo'", rx, f"listener must have received the Windows canary: {rx}")
        self.assertIn("canary=b'B-co->lo'", rx, f"listener must have received the co-tenant canary: {rx}")
        # WSL -> Windows reverse (firewall-blocked) + a TEST-NET decoy, both must fail-closed
        ssh("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", f"{base}\\winlaunch.ps1")
        gw = ia.get("GW", "")
        self._stage("revclient.sh", _REVCLIENT_SH.format(gw=gw))
        rc, orv, erv = self._run(na, "revclient.sh", user=NONROOT)
        self.facts["P6_wsl_to_windows"] = orv.replace("\n", " | ").strip()
        self.assertIn("gw->win=fail", orv, f"WSL->Windows must be firewall-blocked by default: {orv}")
        self.assertIn("testnet=fail", orv, f"a TEST-NET decoy must be unreachable: {orv}")

        print("\n==== WSL2 topology measured facts (win11-m8) ====")
        for k in sorted(self.facts):
            print(f"{k}={self.facts[k]}")


# ---- staged scripts (streamed to the distro / Windows; never parsed by cmd) ----
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

_NONROOT_SH = r"""#!/bin/sh
echo "ID=$(id -u):$(id -un)"
echo "DEFAULT_UID=$(id -u)"
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

# Listener binds EXACTLY 127.0.0.1:0 + 0.0.0.0:0 + ::1:0, writes its ports, stays up 90s, records the
# moved canary per endpoint and returns an ACK. Started as the non-root user; the distro is pinned alive.
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
open("/tmp/ports","w").write("LO=%d ANY=%d V6=%d\n"%(p_lo,p_any,p6))
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

# Co-tenant reads A's ports from the shared Windows-staged file (A and B share no fs, so the ports are
# passed by re-reading /tmp/ports — but that is A-local; instead the harness substitutes them here).
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

_READRX_SH = r"""#!/bin/sh
cat /tmp/rx 2>/dev/null
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

_WIN_TCP_PS1 = """$spec = (Get-Content -Raw (Join-Path $env:USERPROFILE 'zb\\wsl\\wtcp_spec.txt')).Trim()
foreach($t in ($spec -split ';')){
  $f = $t -split '\\|'; $h=$f[0]; $p=[int]$f[1]; $canary=$f[2]
  try {
    $ip=[Net.IPAddress]::Parse($h)
    $c=New-Object Net.Sockets.TcpClient($ip.AddressFamily)
    $iar=$c.BeginConnect($ip,$p,$null,$null)
    if(-not $iar.AsyncWaitHandle.WaitOne(3000)){ Write-Output "W->WSL ${h}:${p} = timeout"; $c.Close(); continue }
    $c.EndConnect($iar); $s=$c.GetStream()
    $b=[Text.Encoding]::ASCII.GetBytes($canary); $s.Write($b,0,$b.Length); $s.Flush()
    $buf=New-Object byte[] 64; $s.ReadTimeout=3000; $n=$s.Read($buf,0,64)
    Write-Output ("W->WSL ${h}:${p} = ok ack=" + [Text.Encoding]::ASCII.GetString($buf,0,$n)); $c.Close()
  } catch { Write-Output "W->WSL ${h}:${p} = fail: $($_.Exception.Message)" }
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
Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $base 'winlisten.ps1'),'0.0.0.0','39002',(Join-Path $base 'l0.txt') -WindowStyle Hidden
Start-Sleep -Seconds 2
"""


if __name__ == "__main__":
    if not HOST:
        sys.stderr.write("ZB_WIN11_HOST unset — WSL2 live topology spike skipped (exit 77)\n")
        sys.exit(77)
    unittest.main(verbosity=2)
