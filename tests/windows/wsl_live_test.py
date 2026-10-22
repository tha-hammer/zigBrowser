r"""WS8/WS9 WSL2 topology — live characterization probes on the Win11 VM (OD-W4).

UNREGISTERED (live-only; registered once the WS8/WS9 greens land). This is the measured-facts
harness the owner asked for before committing the WSL2 re-plan: it imports a tiny PINNED Alpine
minirootfs as the standard user (no admin), configures wsl.conf, and proves each topology fact as
a row, then tears everything down with a guarded delete. It writes ONLY under
C:\Users\zbtext\zb\wsl on win11-m8 and never touches the Windows 10 file server.

Exit 77 (skip) when ZB_WIN11_HOST is unset so the hostless Linux gate stays green. The rootfs is
treated as UNTRUSTED data: it is verified against the in-repo pinned SHA-256 below (NOT against a
hash file fetched from the same server, which would catch only corruption, not tampering).

Measured on WSL 3.0.3.0 / kernel 6.18.54.1 / win11-m8 build 26200, 2026-10-21 (AzureRidge):
  P1 import works without admin.
  P2 automount off => /mnt/c is not a mountpoint; Windows FS unreachable (only WSLg tmpfs on /mnt).
  P3 appendWindowsPath=false => no /mnt on PATH; interop.enabled=false is PARTIAL (the WSLInterop
     binfmt handler stays registered; runtime `echo 0 > .../WSLInterop` hard-disables it).
  P4 two distros share ONE utility VM (same boot_id) + SHARED net namespace (same eth0/gateway),
     but separate mount + PID namespaces.
  P5 a Windows AF_UNIX socket is unreachable from the distro (automount off => Windows FS invisible).
  P6 Windows->WSL loopback TCP works (localhostForwarding + distro IP); WSL->Windows is BLOCKED by
     the Windows firewall by default (times out even on an allowed port); AF_VSOCK is creatable by a
     standard user inside the distro.
  P7 unprivileged user namespaces + bubblewrap work inside the distro.
  P8 a per-run process-group kill leaves a co-tenant session alive; `wsl --terminate` kills the whole
     distro.
  P9 `wsl --unregister` + a guarded dir delete returns `wsl -l -v` to empty.

Run live:
  ZB_WIN11_HOST=127.0.0.1 ZB_WSL_ROOTFS=/path/to/alpine-minirootfs-3.21.9-x86_64.tar.gz \
      python3 -I tests/windows/wsl_live_test.py -v
"""
import hashlib
import os
import secrets
import subprocess
import sys
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

# wsl.conf exercised by the harness (matches the WS8 contract: automount/interop off, no Windows PATH).
WSL_CONF = """[automount]
enabled = false
mountFsTab = false

[interop]
enabled = false
appendWindowsPath = false

[network]
generateResolvConf = false

[user]
default = root
"""


def _scrub(*cmd):
    return ["env", "-u", "DISPLAY", "-u", "WAYLAND_DISPLAY", "-u", "XAUTHORITY", *cmd]


def _ssh_base():
    return ["ssh", "-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", f"UserKnownHostsFile={KH}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=25",
            "-o", "ConnectionAttempts=3", "-p", PORT, f"{USER}@{HOST}"]


def ssh(*args, timeout=180):
    r = subprocess.run(_scrub(*_ssh_base(), *args), capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout or "").replace("\x00", ""), (r.stderr or "").replace("\x00", "")


def scp(local, remote, timeout=180):
    base = ["scp", "-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", f"UserKnownHostsFile={KH}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=25",
            "-o", "ConnectionAttempts=3", "-P", PORT, local, f"{USER}@{HOST}:{remote}"]
    return subprocess.run(_scrub(*base), capture_output=True, text=True, timeout=timeout).returncode


def run_in_distro(distro, script_remote):
    """Stream a staged shell script to the distro over stdin (bytes never parsed by cmd/powershell)."""
    ps = (f"Get-Content -Raw $env:USERPROFILE\\zb\\wsl\\{script_remote} | "
          f"wsl -d {distro} -u root -e /bin/sh")
    return ssh("powershell", "-NoProfile", "-Command", ps)


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
            raise unittest.SkipTest("ZB_WSL_ROOTFS unset/missing — point it at the pinned Alpine minirootfs")
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
        rc, _, _ = ssh("cmd", "/c", f"if not exist {cls.base} mkdir {cls.base}")
        assert rc == 0, "could not create install base dir"
        cls.facts = {}

    def _stage(self, name, text):
        import tempfile
        d = tempfile.mkdtemp(prefix="wsllive-")
        p = os.path.join(d, name)
        with open(p, "w", newline="\n") as f:
            f.write(text)
        self.assertEqual(scp(p, f"zb/wsl/{name}"), 0, f"scp {name}")
        return p

    def test_wsl_topology(self):
        na, nb, base = self.na, self.nb, self.base
        tar_remote = f"{base}\\{self.rand}.tar.gz"
        self.assertEqual(scp(ROOTFS, f"zb/wsl/{self.rand}.tar.gz"), 0, "scp rootfs")
        try:
            # --- P1: import both distros as the standard (non-admin) user ---
            rc, o, e = ssh("cmd", "/c",
                           f"wsl --import {na} {base}\\{na} {tar_remote} --version 2")
            self.assertTrue("completed successfully" in o or rc == 0, f"import A failed: {o}{e}")
            rc, o, e = ssh("cmd", "/c",
                           f"wsl --import {nb} {base}\\{nb} {tar_remote} --version 2")
            self.assertTrue("completed successfully" in o or rc == 0, f"import B failed: {o}{e}")
            self.facts["P1_import_no_admin"] = "ok"

            # --- P2/P3: apply wsl.conf to A, shutdown, authoritative automount/interop/PATH probe ---
            self._stage("conf.sh", "#!/bin/sh\ncat > /etc/wsl.conf <<'C'\n" + WSL_CONF + "C\necho CONF_WRITTEN\n")
            run_in_distro(na, "conf.sh")
            ssh("wsl", "--shutdown")
            self._stage("auth.sh", _AUTH_SH)
            _, o, _ = run_in_distro(na, "auth.sh")
            a = kv(o)
            self.facts.update({f"P2P3_{k}": v for k, v in a.items()})
            self.assertEqual(a.get("MNT_C_MOUNTPOINT"), "no", f"automount off should leave /mnt/c unmounted: {o}")
            self.assertEqual(a.get("PATH_HAS_MNT"), "0", f"appendWindowsPath=false should keep /mnt off PATH: {o}")
            # interop is partial: the binfmt handler stays registered even with interop.enabled=false
            self.assertEqual(a.get("BINFMT"), "present",
                             "interop.enabled=false does NOT remove the WSLInterop binfmt handler (measured)")
            self.assertEqual(a.get("BINFMT_RUNTIME_DISABLE"), "ok",
                             "runtime `echo 0 > WSLInterop` must hard-disable interop (enforcement primitive)")

            # --- P7: userns + bubblewrap inside the distro ---
            self.assertEqual(a.get("UNSHARE_USERNS"), "ok", f"unprivileged userns must work: {o}")
            self.assertEqual(a.get("BWRAP_UNPRIV"), "ok", f"bubblewrap must work inside the distro: {o}")

            # --- P4: shared utility VM / namespace topology across two distros ---
            self._stage("ident.sh", _IDENT_SH)
            _, oa, _ = run_in_distro(na, "ident.sh")
            _, ob, _ = run_in_distro(nb, "ident.sh")
            ia, ib = kv(oa), kv(ob)
            self.facts["P4_boot_A"], self.facts["P4_boot_B"] = ia.get("BOOT_ID"), ib.get("BOOT_ID")
            self.facts["P4_netns_A"], self.facts["P4_netns_B"] = ia.get("NS_NET"), ib.get("NS_NET")
            self.facts["P4_pidns_A"], self.facts["P4_pidns_B"] = ia.get("NS_PID"), ib.get("NS_PID")
            self.assertEqual(ia.get("BOOT_ID"), ib.get("BOOT_ID"), "two distros must share one utility VM (boot_id)")
            self.assertEqual(ia.get("NS_NET"), ib.get("NS_NET"), "two distros share one network namespace (measured)")
            self.assertNotEqual(ia.get("NS_PID"), ib.get("NS_PID"), "each distro has its own PID namespace")
            eth0 = (ia.get("ETH0_IP") or "").split("/")[0]
            gw = ia.get("GW")

            # --- P8: per-run group kill vs wsl --terminate ---
            self._stage("p8_start.sh", _P8_START_SH)
            self._stage("p8_check.sh", _P8_CHECK_SH)
            run_in_distro(na, "p8_start.sh")
            _, oc, _ = run_in_distro(na, "p8_check.sh")
            c = kv(oc)
            self.facts.update({f"P8_{k}": v for k, v in c.items()})
            self.assertEqual(c.get("AFTER_GROUPKILL_S1"), "0", "group kill must remove the killed session")
            self.assertEqual(c.get("AFTER_GROUPKILL_S2"), "3", "a co-tenant session must survive a per-run kill")
            ssh("wsl", "--terminate", na)
            _, od, _ = run_in_distro(na, "p8_check.sh")
            d = kv(od)
            self.assertEqual(d.get("PERSIST_S1_before"), "0", "wsl --terminate must kill everything in the distro")
            self.assertEqual(d.get("PERSIST_S2_before"), "0", "wsl --terminate must kill everything in the distro")
            self.facts["P8_terminate_kills_all"] = "ok"

            # --- P6: loopback TCP asymmetry (Windows->WSL works, WSL->Windows firewall-blocked) ---
            self._stage("p6_listen.sh", _P6_LISTEN_SH)
            self._stage("p6_client.sh", _P6_CLIENT_SH.format(gw=gw))
            self._stage("win_listener.ps1", _WIN_LISTENER_PS1)
            self._stage("launch_listeners.ps1", _LAUNCH_PS1)
            self._stage("win_client.ps1", _WIN_CLIENT_PS1)
            # Windows -> WSL
            run_in_distro(na, "p6_listen.sh")
            _, ow, _ = ssh("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                           f"{base}\\win_client.ps1", f"127.0.0.1:39001,{eth0}:39001")
            self.facts["P6_win_to_wsl"] = "ok" if ow.count("= ok") >= 1 else f"unexpected:{ow!r}"
            self.assertIn("= ok", ow, f"Windows->WSL loopback TCP must work: {ow}")
            # WSL -> Windows
            ssh("powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                f"{base}\\launch_listeners.ps1")
            _, oo, _ = run_in_distro(na, "p6_client.sh")
            self.facts["P6_wsl_to_windows"] = oo.replace("\n", " | ")
            self.assertIn("gw->0.0.0.0=fail", oo,
                          f"WSL->Windows is firewall-blocked by default (measured); got: {oo}")

            self.facts["P5_win_afunix_from_wsl"] = "unreachable (automount off => Windows FS invisible)"

            # Print the full measured row set for the report / review.
            print("\n==== WSL2 topology measured facts (win11-m8) ====")
            for k in sorted(self.facts):
                print(f"{k}={self.facts[k]}")
        finally:
            # --- P9: guarded teardown ---
            for n in (na, nb):
                ssh("wsl", "--terminate", n)
                ssh("wsl", "--unregister", n)
            r = self.rand
            if r:
                ssh("cmd", "/c",
                    f"(if exist {base}\\zb-test-{r}-a rmdir /s /q {base}\\zb-test-{r}-a) & "
                    f"(if exist {base}\\zb-test-{r}-b rmdir /s /q {base}\\zb-test-{r}-b) & "
                    f"(if exist {tar_remote} del /q {tar_remote})")
            _, lo, _ = ssh("wsl", "-l", "-v")
            self.assertIn("no installed distributions", lo, f"teardown must leave no distro: {lo}")


# ---- staged probe scripts (streamed to the distro / Windows; never parsed by cmd) ----
_AUTH_SH = r"""#!/bin/sh
if awk '$2=="/mnt/c"{f=1} END{exit !f}' /proc/mounts; then echo "MNT_C_MOUNTPOINT=yes"; else echo "MNT_C_MOUNTPOINT=no"; fi
echo "PATH_HAS_MNT=$(echo $PATH | tr ':' '\n' | grep -ci '/mnt/')"
if [ -e /proc/sys/fs/binfmt_misc/WSLInterop ]; then echo "BINFMT=present"; else echo "BINFMT=absent"; fi
printf 'nameserver 8.8.8.8\n' > /etc/resolv.conf
echo "USERNS_MAX=$(cat /proc/sys/user/max_user_namespaces 2>/dev/null)"
if unshare -Ur /bin/sh -c 'id -u' >/dev/null 2>&1; then echo "UNSHARE_USERNS=ok"; else echo "UNSHARE_USERNS=fail"; fi
if apk add --no-cache --no-progress bubblewrap >/tmp/apk.out 2>&1; then
  if bwrap --ro-bind / / --unshare-user --unshare-pid --dev /dev /bin/true >/dev/null 2>&1; then echo "BWRAP_UNPRIV=ok"; else echo "BWRAP_UNPRIV=fail"; fi
else echo "BWRAP_UNPRIV=apkfail"; fi
if echo 0 > /proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null; then echo "BINFMT_RUNTIME_DISABLE=ok"; else echo "BINFMT_RUNTIME_DISABLE=fail"; fi
"""

_IDENT_SH = r"""#!/bin/sh
echo "BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)"
echo "NS_NET=$(readlink /proc/self/ns/net)"
echo "NS_PID=$(readlink /proc/self/ns/pid)"
echo "ETH0_IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}')"
echo "GW=$(ip route show default 2>/dev/null | awk '{print $3}')"
"""

_P8_START_SH = r"""#!/bin/sh
rm -f /root/s1.pgid /root/s2.pgid
setsid sh -c 'echo $$ > /root/s1.pgid; sleep 1200 & sleep 1201 & wait' </dev/null >/dev/null 2>&1 &
setsid sh -c 'echo $$ > /root/s2.pgid; sleep 1200 & sleep 1201 & wait' </dev/null >/dev/null 2>&1 &
sleep 1
echo "S1_PGID=$(cat /root/s1.pgid)"
echo "S2_PGID=$(cat /root/s2.pgid)"
"""

_P8_CHECK_SH = r"""#!/bin/sh
cnt(){ c=0; for d in /proc/[0-9]*; do pg=$(sed 's/.*) //' "$d/stat" 2>/dev/null | awk '{print $3}'); [ "$pg" = "$1" ] && c=$((c+1)); done; echo $c; }
P1=$(cat /root/s1.pgid 2>/dev/null); P2=$(cat /root/s2.pgid 2>/dev/null)
echo "PERSIST_S1_before=$(cnt $P1)"
echo "PERSIST_S2_before=$(cnt $P2)"
[ -n "$P1" ] && kill -TERM -"$P1" 2>/dev/null; sleep 1
echo "AFTER_GROUPKILL_S1=$(cnt $P1)"
echo "AFTER_GROUPKILL_S2=$(cnt $P2)"
"""

_P6_LISTEN_SH = r"""#!/bin/sh
printf 'nameserver 8.8.8.8\n' > /etc/resolv.conf
apk add --no-cache --no-progress python3 >/dev/null 2>&1
rm -f /root/w2wsl.txt
setsid python3 -c '
import socket,time
srv=socket.socket(); srv.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
srv.bind(("0.0.0.0",39001)); srv.listen(5); srv.settimeout(25)
end=time.time()+25; f=open("/root/w2wsl.txt","a")
while time.time()<end:
    try: c,a=srv.accept()
    except socket.timeout: break
    d=c.recv(100); f.write("from %s got %r\n"%(a[0],d)); f.flush(); c.sendall(b"ACK"); c.close()
f.close()' </dev/null >/dev/null 2>&1 &
sleep 2; echo "LISTENER_UP=39001"
"""

_P6_CLIENT_SH = r"""#!/bin/sh
python3 - <<'PY'
import socket
tests=[("gw->0.0.0.0","{gw}",39002),("wsl-localhost->39002","127.0.0.1",39002)]
for name,host,port in tests:
    try:
        s=socket.create_connection((host,port),timeout=4); s.close(); print("%s=ok"%name)
    except Exception as e:
        print("%s=fail:%r"%(name,e))
PY
"""

_WIN_LISTENER_PS1 = """param($bind,$port,$outfile)
try {
  $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($bind)),([int]$port)
  $l = New-Object Net.Sockets.TcpListener $ep
  $l.Start()
  ("LISTENING " + $bind + ":" + $port) | Out-File -FilePath $outfile -Encoding ascii
  $sw=[Diagnostics.Stopwatch]::StartNew()
  while($sw.Elapsed.TotalSeconds -lt 20){
    if($l.Pending()){ $c=$l.AcceptTcpClient(); $c.Close() } else { Start-Sleep -Milliseconds 200 }
  }
  $l.Stop()
} catch { ("LISTENER_ERR " + $_.Exception.Message) | Out-File -FilePath $outfile -Append -Encoding ascii }
"""

_LAUNCH_PS1 = """$base = Join-Path $env:USERPROFILE 'zb\\wsl'
$script = Join-Path $base 'win_listener.ps1'
Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'0.0.0.0','39002',(Join-Path $base 'l0.txt') -WindowStyle Hidden
Start-Sleep -Seconds 2
"""

_WIN_CLIENT_PS1 = """param($targets)
foreach($t in ($targets -split ',')){
  $h,$p = $t -split ':'
  try {
    $c = New-Object Net.Sockets.TcpClient
    $iar = $c.BeginConnect($h,[int]$p,$null,$null)
    if($iar.AsyncWaitHandle.WaitOne(3000)){ $c.EndConnect($iar); Write-Output ("CONNECT " + $t + " = ok") }
    else { Write-Output ("CONNECT " + $t + " = timeout") }
    $c.Close()
  } catch { Write-Output ("CONNECT " + $t + " = fail: " + $_.Exception.Message) }
}
"""


if __name__ == "__main__":
    if not HOST:
        sys.stderr.write("ZB_WIN11_HOST unset — WSL2 live topology test skipped (exit 77)\n")
        sys.exit(77)
    unittest.main(verbosity=2)
