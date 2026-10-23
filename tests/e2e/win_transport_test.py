r"""WS2.0 production transport on the Win11 VM (Windows plan rev 2.6; RoseCat 6607 #3, 6647).

`owner-only-test-win` proves the owner-only seam on synthetic paths. This test drives the PRODUCTION call
sites: the real `zigBrowser.exe <url> --automation-api` as zbtext, which must create
`%LOCALAPPDATA%\zigbrowser\`, restrict it, write `<socket>.token` and bind the AF_UNIX socket, all owner-only.

The browser runs with LOCALAPPDATA pointed at a HOSTILE base, `C:\Users\zbtext\zb\<run>\lad`, which grants
Everyone full control, inheritably (and keeps every write under zb\). Whatever the product does not restrict
inherits that grant, so a missing restriction cannot hide behind the user profile's own DACL. A control
file in that base, readable by zbother, proves the cross-user negatives are not vacuous.

  test_production_transport_is_owner_only (zbtext):
    * the browser is still running, with exactly one AF_UNIX socket `zigbrowser-automation-<hex>.sock` and
      its `.token` in `<base>\zigbrowser\` (nothing else), and no TCP listener;
    * the DACLs read back from the file system: the directory `D:P(A;OICI;FA;;;<zbtext>)`, the socket and the
      token `D:P(A;;FA;;;<zbtext>)` (protected: P, plus only Windows' own AI/AR control flags; no inherited
      ACE, no Everyone, Users, SYSTEM or Administrators);
    * zbtext itself connects to the socket and reads the 64-character token (the positive control).
  test_other_user_cannot_connect_or_read_token (zbother, a second local standard account on the VM):
    * zbother reads the control file in the hostile base (so it can reach the path);
    * zbother's AF_UNIX connect is refused (WSAEACCES) and its token read is denied (ERROR_ACCESS_DENIED).
    Without zbother this test FAILS: the cross-user negative is required (plan WS2.0 step 4). The physical
    Windows 10 machine gets no second account (rev 2); it runs only the first test.

The probe (tests/windows/transport_probe.zig) is cross-built here for x86_64-windows-gnu and copied to the VM
for each account. Skips cleanly (exit 0) when ZB_WIN11_HOST or ZB_WIN_EXE is unset, so the hostless Linux
gate stays green. Needs no Linux slot; the browser runs on the VM.

Run live:  bash tests/windows/build-on-windows.sh   # fetches zig-out/win/zigBrowser.exe
           ZB_WIN11_HOST=127.0.0.1 ZB_WIN_EXE=zig-out/win/current/zigBrowser.exe python3 -I tests/e2e/win_transport_test.py -v
"""
import json
import os
import pathlib
import re
import secrets
import shutil
import subprocess
import tempfile
import time
import unittest
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "windows"))
import live_gate  # noqa: E402  ZB_WIN_GATE=1: a missing host fails instead of skipping; prints ASSERTS <n>

REPO = pathlib.Path(__file__).resolve().parents[2]
PROBE_SRC = REPO / "tests" / "windows" / "transport_probe.zig"

EVERYONE = "S-1-1-0"
WSAEACCES = 10013
ERROR_ACCESS_DENIED = 5
TOKEN_LEN = 64
SOCK_RE = re.compile(r"^zigbrowser-automation-[0-9a-f]+\.sock$")
PROFILE_RE = re.compile(r"\A[A-Za-z]:(\\[A-Za-z0-9._-]+)+\Z")

_HTML = "<!doctype html><html><head><meta charset=\"utf-8\"><title>ZB transport</title></head><body>ws2.0</body></html>\n"

# VM-side runner, as zbtext: launch the browser against the hostile base, wait for its socket, read
# everything back, publish ready.json, then hold the browser open until the test drops `release`.
_RUNNER = r"""
$ErrorActionPreference = 'Stop'
$dir  = $args[0]
$hold = [int]$args[1]
$lad  = Join-Path $dir 'lad'
$zb   = Join-Path $lad 'zigbrowser'
$probe = Join-Path $dir 'probe.exe'
New-Item -ItemType Directory -Force -Path $lad | Out-Null
# The hostile base: Everyone full control, inherited by anything the product leaves unrestricted.
& icacls $lad /grant '*S-1-1-0:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed: $LASTEXITCODE" }
[IO.File]::WriteAllText((Join-Path $lad 'control.txt'), 'control')
$env:LOCALAPPDATA = $lad
$env:XDG_DATA_HOME = Join-Path $dir 'data'
$url = 'file:///' + ((Join-Path $dir 'test.html') -replace '\\','/')
$p = Start-Process -FilePath (Join-Path $dir 'zigBrowser.exe') -ArgumentList $url,'--automation-api' `
     -PassThru -NoNewWindow -RedirectStandardError (Join-Path $dir 'err.txt') -RedirectStandardOutput (Join-Path $dir 'out.txt')
$null = $p.Handle  # cache the handle now, or PowerShell reports a null ExitCode later
function Probe([string[]]$a) { $o = & $probe @a; return ($o | Out-String | ConvertFrom-Json) }
try {
  $deadline = (Get-Date).AddSeconds(45)
  $socks = @()
  while ((Get-Date) -lt $deadline -and -not $p.HasExited) {
    if (Test-Path -LiteralPath $zb) {
      $socks = @(Get-ChildItem -LiteralPath $zb -Force | Where-Object { $_.Name -like '*.sock' })
      if ($socks.Count -ge 1) { break }
    }
    Start-Sleep -Milliseconds 200
  }
  # bind -> listen -> restrict is synchronous in server.start; give it a moment past the bind.
  Start-Sleep -Seconds 2
  $names = @(); if (Test-Path -LiteralPath $zb) { $names = @(Get-ChildItem -LiteralPath $zb -Force | ForEach-Object { $_.Name }) }
  # TCP and TCPv6 listeners owned by the browser (netstat: a standard user cannot reach CIM).
  $tcp = @(netstat -ano | Select-String -Pattern '^\s*TCP\s.*\sLISTENING\s+(\d+)\s*$' |
           Where-Object { $_.Matches[0].Groups[1].Value -eq "$($p.Id)" }).Count
  $tcp_total = @(netstat -ano | Select-String -Pattern '^\s*TCP\s.*\sLISTENING\s+\d+\s*$').Count
  $r = [ordered]@{ alive = (-not $p.HasExited); names = $names; tcp_listeners = $tcp; tcp_total = $tcp_total; zb = $zb; lad = $lad
                   sid = (Probe @('sid')); dir = (Probe @('sddl', $zb)) }
  if ($socks.Count -ge 1) {
    $sock = $socks[0].FullName
    $r.sock = $sock; $r.token = "$sock.token"
    $r.sock_sddl = Probe @('sddl', $sock)
    $r.token_sddl = Probe @('sddl', "$sock.token")
    $r.connect = Probe @('connect', $sock)
    $r.read = Probe @('read', "$sock.token")
  }
  if ($p.HasExited) { $r.exit = $p.ExitCode }
  $r.stderr = [string](Get-Content (Join-Path $dir 'err.txt') -Raw -ErrorAction SilentlyContinue)
  $r.stdout = [string](Get-Content (Join-Path $dir 'out.txt') -Raw -ErrorAction SilentlyContinue)
  [IO.File]::WriteAllText((Join-Path $dir 'ready.json'), ($r | ConvertTo-Json -Compress -Depth 6))
  $until = (Get-Date).AddSeconds($hold)
  while ((Get-Date) -lt $until -and -not (Test-Path -LiteralPath (Join-Path $dir 'release'))) { Start-Sleep -Milliseconds 200 }
} finally {
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2
}
"""


def _owner_only(sddl, ace):
    """None when `sddl` is protected (P, plus only Windows' AI/AR control flags) and holds exactly `ace`."""
    if not sddl.startswith("D:") or "(" not in sddl:
        return f"not a DACL with ACEs: {sddl!r}"
    flags, aces = sddl[2:sddl.index("(")], sddl[sddl.index("("):]
    if "P" not in flags:
        return f"DACL not protected (flags {flags!r}): {sddl!r}"
    rest = flags
    while rest:
        if rest.startswith("P"):
            rest = rest[1:]
        elif rest[:2] in ("AI", "AR"):
            rest = rest[2:]
        else:
            return f"unexpected DACL control flags {flags!r}: {sddl!r}"
    if aces != ace:
        return f"ACEs {aces!r} != exactly {ace!r}"
    return None


class WinTransport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.host = os.environ.get("ZB_WIN11_HOST")
        cls.exe = os.environ.get("ZB_WIN_EXE")
        cls.tmp = None
        if not cls.host or not cls.exe or not pathlib.Path(cls.exe).is_file():
            return
        cls.tmp = tempfile.mkdtemp(prefix="zb-ws20-")
        cls.probe = os.path.join(cls.tmp, "probe.exe")
        build = subprocess.run(
            ["env", "-u", "DISPLAY", "-u", "WAYLAND_DISPLAY", "-u", "XAUTHORITY", "zig", "build-exe", str(PROBE_SRC),
             "-target", "x86_64-windows-gnu", "-O", "ReleaseSafe", "-lshell32", "-ladvapi32", "-lws2_32",
             f"-femit-bin={cls.probe}"], cwd=cls.tmp, capture_output=True, text=True, timeout=600)
        if build.returncode != 0:
            raise RuntimeError(f"probe build failed: {build.stderr}")
        with open(os.path.join(cls.tmp, "test.html"), "w", encoding="utf-8") as f:
            f.write(_HTML)
        with open(os.path.join(cls.tmp, "run.ps1"), "w", encoding="utf-8") as f:
            f.write(_RUNNER)

    @classmethod
    def tearDownClass(cls):
        if cls.tmp:
            shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        if not self.host:
            live_gate.skip_or_fail(self, "ZB_WIN11_HOST unset — live VM transport test skipped")
        if not self.exe or not pathlib.Path(self.exe).is_file():
            live_gate.skip_or_fail(self, "ZB_WIN_EXE unset or missing — set it to a built zigBrowser.exe")
        self.port = os.environ.get("ZB_WIN11_PORT", "2222")
        self.user = os.environ.get("ZB_WIN11_USER", "zbtext")
        self.other = os.environ.get("ZB_WIN11_OTHER_USER", "zbother")
        self.key = os.environ.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key")
        self.kh = os.environ.get("ZB_WIN_KNOWN_HOSTS", "/home/maceo/vms/win11-m8/known_hosts")

    # ---- transport (BatchMode: a refused key fails at once, never a prompt) ----------------------------
    def _opts(self):
        return ["-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=3"]

    def _env(self):
        env = {k: v for k, v in os.environ.items() if k not in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY")}
        env["SSH_ASKPASS_REQUIRE"] = "never"
        return env

    def _ssh_argv(self, user, *args):
        return ["ssh", *self._opts(), "-p", self.port, f"{user}@{self.host}", *args]

    def _ssh(self, user, *args, timeout=180):
        return subprocess.run(self._ssh_argv(user, *args), capture_output=True, text=True, timeout=timeout,
                              env=self._env(), stdin=subprocess.DEVNULL)

    def _scp(self, user, local, remote):
        # -O: the legacy scp protocol. The Win10 box's sshd has no sftp subsystem, which scp uses by default
        # (bd zigBrowser-ong.12; the harness is fixed, never the host's sshd).
        return subprocess.run(["scp", "-O", *self._opts(), "-P", self.port, local, f"{user}@{self.host}:{remote}"],
                              capture_output=True, text=True, timeout=180, env=self._env(), stdin=subprocess.DEVNULL)

    def _profile(self, user):
        """The account's real profile directory (Windows may name it C:\\Users\\<user>.<suffix>)."""
        # sshd's own cmd.exe runs this; a nested `cmd /c echo` returns the path with a stray trailing quote.
        r = self._ssh(user, "echo %USERPROFILE%", timeout=60)
        self.assertEqual(r.returncode, 0, f"USERPROFILE of {user} failed: {r.stderr}")
        profile = r.stdout.strip().splitlines()[-1].strip()
        # Interpolated into `cmd /c` paths below: only a drive and plain path characters, no spaces or metacharacters.
        self.assertRegex(profile, PROFILE_RE, f"USERPROFILE of {user} is not a plain path: {profile!r}")
        return profile

    def _probe_as(self, user, remote_probe, *args):
        r = self._ssh(user, remote_probe, *args)
        self.assertEqual(r.returncode, 0, f"probe as {user} failed: {r.stdout}\n{r.stderr}")
        return json.loads(r.stdout.strip().splitlines()[-1])

    # ---- one browser launch, held open while the checks run ---------------------------------------------
    def _launch(self):
        rel = f"zb/ws20-{os.getpid()}-{secrets.token_hex(4)}"
        win = f"{self._profile(self.user)}\\{rel}".replace("/", "\\")
        mk = self._ssh(self.user, "cmd", "/c", f"mkdir {win}")
        self.assertEqual(mk.returncode, 0, f"mkdir failed: {mk.stderr}")
        self.addCleanup(self._remove, self.user, win)
        for local, name in ((self.exe, "zigBrowser.exe"), (self.probe, "probe.exe"),
                            (os.path.join(self.tmp, "test.html"), "test.html"),
                            (os.path.join(self.tmp, "run.ps1"), "run.ps1")):
            r = self._scp(self.user, local, f"{rel}/{name}")
            self.assertEqual(r.returncode, 0, f"scp {name} failed: {r.stderr}")
        runner = subprocess.Popen(
            self._ssh_argv(self.user, "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                           "-File", f"{win}\\run.ps1", win, "240"),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, text=True, env=self._env())
        self.addCleanup(self._release, runner, win)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if runner.poll() is not None:
                out, err = runner.communicate()
                self.fail(f"runner exited {runner.returncode} before ready: {out}\n{err}")
            got = self._ssh(self.user, "cmd", "/c", f"if exist {win}\\ready.json type {win}\\ready.json")
            text = got.stdout.lstrip("\ufeff").strip()
            if got.returncode == 0 and text:
                return win, json.loads(text)
            time.sleep(1)
        self.fail("the runner never published ready.json")

    def _release(self, runner, win):
        self._ssh(self.user, "cmd", "/c", f"type nul > {win}\\release")
        try:
            runner.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            runner.kill()
            runner.communicate()

    def _remove(self, user, win):
        for _ in range(5):
            r = self._ssh(user, "cmd", "/c", f"if exist {win} rmdir /s /q {win}")
            gone = self._ssh(user, "cmd", "/c", f"if exist {win} (echo present) else (echo gone)")
            if "gone" in gone.stdout:
                return
            time.sleep(2)

    def _assert_started(self, r):
        self.assertTrue(r["alive"], f"the browser exited (code {r.get('exit')}): {r!r}")
        self.assertIn("sock", r, f"no socket appeared in {r['zb']}: {r!r}")

    # ---- the tests --------------------------------------------------------------------------------------
    def test_production_transport_is_owner_only(self):
        win, r = self._launch()
        self._assert_started(r)
        self.assertTrue(r["sid"]["ok"], r["sid"])
        sid = r["sid"]["sid"]
        sock_name = r["sock"].rsplit("\\", 1)[-1]
        self.assertRegex(sock_name, SOCK_RE)
        self.assertEqual(sorted(r["names"]), sorted([sock_name, sock_name + ".token"]),
                         f"exactly one AF_UNIX socket and its token, nothing else, in {r['zb']}")
        # tcp_total > 0 shows the netstat parse sees the host's listeners at all (sshd listens on 22).
        self.assertGreater(r["tcp_total"], 0, "netstat parse saw no TCP listener at all; the check would be vacuous")
        self.assertEqual(r["tcp_listeners"], 0, "the browser must not listen on TCP")
        for what, got, ace in (("directory", r["dir"], f"(A;OICI;FA;;;{sid})"),
                               ("socket", r["sock_sddl"], f"(A;;FA;;;{sid})"),
                               ("token", r["token_sddl"], f"(A;;FA;;;{sid})")):
            self.assertTrue(got["ok"], f"{what} DACL readback failed: {got}")
            self.assertIsNone(_owner_only(got["sddl"], ace), f"{what} is not owner-only")
            self.assertNotIn(EVERYONE, got["sddl"], f"{what} still grants Everyone (the hostile base leaked)")
        self.assertEqual(r["connect"], {"ok": True}, "zbtext must connect to its own socket")
        self.assertEqual(r["read"], {"ok": True, "len": TOKEN_LEN}, "zbtext must read its own token")

    def test_other_user_cannot_connect_or_read_token(self):
        alive = self._ssh(self.other, "cmd", "/c", "whoami", timeout=60)
        if alive.returncode != 0:
            self.fail(f"{self.other} is not reachable over ssh (rc {alive.returncode}: {alive.stderr.strip()}); "
                      "the cross-user negative is required (plan WS2.0 step 4): the user creates the account")
        win, r = self._launch()
        self._assert_started(r)
        orel = f"zb/ws20-{os.getpid()}-{secrets.token_hex(4)}"
        owin = f"{self._profile(self.other)}\\{orel}".replace("/", "\\")
        mk = self._ssh(self.other, "cmd", "/c", f"mkdir {owin}")
        self.assertEqual(mk.returncode, 0, f"mkdir as {self.other} failed: {mk.stderr}")
        self.addCleanup(self._remove, self.other, owin)
        cp = self._scp(self.other, self.probe, f"{orel}/probe.exe")
        self.assertEqual(cp.returncode, 0, f"scp probe as {self.other} failed: {cp.stderr}")
        probe = f"{owin}\\probe.exe"

        other_sid = self._probe_as(self.other, probe, "sid")
        self.assertTrue(other_sid["ok"], other_sid)
        self.assertNotEqual(other_sid["sid"], r["sid"]["sid"], "zbother must be a different account")
        control = self._probe_as(self.other, probe, "read", f"{r['lad']}\\control.txt")
        self.assertEqual(control, {"ok": True, "len": len("control")},
                         f"{self.other} must reach the hostile base, or the negatives below prove nothing")
        conn = self._probe_as(self.other, probe, "connect", r["sock"])
        self.assertEqual(conn, {"ok": False, "wsa": WSAEACCES}, f"{self.other} must not connect to the socket")
        read = self._probe_as(self.other, probe, "read", r["token"])
        self.assertEqual(read, {"ok": False, "err": ERROR_ACCESS_DENIED}, f"{self.other} must not read the token")


if __name__ == "__main__":
    live_gate.main()
