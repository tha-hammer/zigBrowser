#!/usr/bin/env python3
r"""The first read-only probe of the Win10 test box (orchestrator 2026-10-23), for the Win10 legs (FoggyReef's
WS2b.1-W10 driver, the m8 Win10 leg).

No Win10 identity marker exists in any record, so the host is identified by its pinned SSH host key: before any
contact the probe checks locally (ssh-keygen -F) that the win10-fs known_hosts holds exactly the owner-confirmed
fingerprint for 100.123.34.15, and every ssh/scp then runs with StrictHostKeyChecking against that file. The probe READS
the marker and reports it (or `absent`). It pins its transport and reads nothing from the environment.

Prints `FIELD\t<name>\t<value>` rows:
  hostkey        the pinned fingerprint, as found in known_hosts
  marker         %USERPROFILE%\zb\.gate-identity, trimmed, or `absent`
  zb_dir         `present` / `absent` (C:\Users\zbtest\zb)
  webview2_pv    the Evergreen WebView2 runtime `pv` (machine, then user), or `missing`
  c_free_bytes   free bytes on C:
  python         the first python.exe / py.exe on PATH, or `missing`
  powershell_ok  `yes` (the streamed PowerShell ran)
  os, user       [Environment]::OSVersion.Version, %USERNAME%
  cmd_if_exist   `PRESENT` / `ABSENT` from cmd.exe's `if exist "%USERPROFILE%\zb\" (...)`
  scp_legacy     --run: `not run: read-only discovery`. --scp-check: `ok` / `fail: <why>` for one `scp -O` of a
                 nonce file into C:\Users\zbtest\zb, read back
  scp_cleanup    --run: `not run`. --scp-check: `gone` / `left`; the probe file is deleted only by its guarded exact
                 path %USERPROFILE%\zb\zb-probe-<16 hex>.txt and proven absent

Two modes (NavyCanyon 13a73828):
  --run                      first-contact DISCOVERY, unconditionally read-only: the host-key pin, the streamed facts
                             and cmd.exe's `if exist`; no copy, read-back or delete, even when zb\ exists. Exit 0 when
                             every read succeeded.
  --scp-check <marker>       the separate legacy-copy check, for after zb\ and the marker are provisioned. It writes
                             nothing unless the box's marker is exactly <marker> (a plain token) and zb\ exists. Exit 0
                             only with scp_legacy=ok and scp_cleanup=gone; 1 on a failed copy, a mismatched read-back
                             or a file left behind.
Anything else exits 2 with nothing contacted. Each mode's real run needs NavyCanyon's exact-commit approval and the
orchestrator's release.

Run:  env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS -u SSH_ASKPASS_REQUIRE \
      python3 -I tests/windows/win10_probe.py --run
"""
import os
import re
import secrets
import subprocess
import sys
import tempfile

# --- pinned (tests/windows/hosts.env.example: Win10 file server; host key confirmed by the owner) ----------------
HOST, PORT, USER = "100.123.34.15", "22", "zbtest"
KEY = "/home/maceo/vms/win11-m8/zb_win_key"
KNOWN_HOSTS = "/home/maceo/vms/win10-fs/known_hosts"
HOSTKEY_FP = "SHA256:AhusOW2s/1hKVAOhriqN38c1Hn8hSiNMBrdbcRGAnF4"

PROBE_TIMEOUT_S = 120
STREAMED = 'powershell -NoProfile -NonInteractive -Command "$input | Out-String | iex"'
SCRUB = ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE")
PROBE_FIELDS = ("marker", "zb_dir", "webview2_pv", "c_free_bytes", "python", "powershell_ok", "os", "user")
_PROBE_NAME = re.compile(r"^zb-probe-[0-9a-f]{16}\.txt$")
_MARKER_ARG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_OPTS = ["-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
         "-o", f"UserKnownHostsFile={KNOWN_HOSTS}", "-o", "ConnectTimeout=15"]

_PROBE_BODY = r"""# ZB_WIN10_PROBE
$ErrorActionPreference = 'Stop'
function F($n, $v) { "FIELD`t$n`t$v" }
$zb = Join-Path $env:USERPROFILE 'zb'
$m = Join-Path $zb '.gate-identity'
F 'marker' $(if (Test-Path -LiteralPath $m -PathType Leaf) { (Get-Content -LiteralPath $m -Raw).Trim() } else { 'absent' })
F 'zb_dir' $(if (Test-Path -LiteralPath $zb -PathType Container) { 'present' } else { 'absent' })
$g = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$pv = $null
foreach ($k in @("HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$g", "HKCU:\Software\Microsoft\EdgeUpdate\Clients\$g")) {
  if (-not $pv) { $pv = (Get-ItemProperty -LiteralPath $k -Name pv -ErrorAction SilentlyContinue).pv }
}
F 'webview2_pv' $(if ($pv) { $pv } else { 'missing' })
F 'c_free_bytes' (Get-PSDrive -Name C).Free
$py = Get-Command python.exe, py.exe -ErrorAction SilentlyContinue | Select-Object -First 1
F 'python' $(if ($py) { $py.Source } else { 'missing' })
F 'powershell_ok' 'yes'
F 'os' ([Environment]::OSVersion.Version.ToString())
F 'user' $env:USERNAME
'END'
"""


class Stop(Exception):
    """A failed read: the probe stops here."""


def field(name, value):
    print(f"FIELD\t{name}\t{value}", flush=True)


def _env():
    return {k: v for k, v in os.environ.items() if k not in SCRUB}


def ssh(command, stdin_text=None):
    argv = ["ssh", *_OPTS, "-p", PORT, f"{USER}@{HOST}", command]
    try:
        if stdin_text is None:
            return subprocess.run(argv, env=_env(), capture_output=True, text=True, timeout=PROBE_TIMEOUT_S,
                                  stdin=subprocess.DEVNULL)
        return subprocess.run(argv, env=_env(), capture_output=True, text=True, timeout=PROBE_TIMEOUT_S,
                              input=stdin_text)
    except (subprocess.TimeoutExpired, OSError) as e:
        raise Stop(f"ssh failed: {type(e).__name__}: {e}")


def check_hostkey():
    """Local only: the known_hosts entry for HOST must be exactly the pinned fingerprint."""
    try:
        r = subprocess.run(["ssh-keygen", "-F", HOST, "-l", "-f", KNOWN_HOSTS], env=_env(), capture_output=True,
                           text=True, timeout=30, stdin=subprocess.DEVNULL)
    except (subprocess.TimeoutExpired, OSError) as e:
        raise Stop(f"ssh-keygen failed: {type(e).__name__}: {e}")
    fps = [t for l in r.stdout.splitlines() if l and not l.startswith("#") for t in l.split() if t.startswith("SHA256:")]
    if r.returncode != 0 or fps != [HOSTKEY_FP]:
        raise Stop(f"known_hosts {KNOWN_HOSTS} does not hold exactly the pinned host key {HOSTKEY_FP} for {HOST}: "
                   f"rc={r.returncode} {fps}")
    field("hostkey", HOSTKEY_FP)


def read_facts():
    r = ssh(STREAMED, stdin_text=_PROBE_BODY)
    lines = [l.strip("\r") for l in r.stdout.split("\n") if l.strip()]
    if r.returncode != 0 or not lines or lines[-1] != "END":
        raise Stop(f"read probe rc={r.returncode} without an END line: {r.stdout[-300:]!r} {r.stderr.strip()[:300]}")
    facts = {}
    for line in lines[:-1]:
        row = line.split("\t")
        if len(row) != 3 or row[0] != "FIELD" or row[1] not in PROBE_FIELDS or row[1] in facts:
            raise Stop(f"read probe answered an unexpected line {line!r}")
        facts[row[1]] = row[2]
    if set(facts) != set(PROBE_FIELDS):
        raise Stop(f"read probe missed fields {sorted(set(PROBE_FIELDS) - set(facts))}")
    for name in PROBE_FIELDS:
        field(name, facts[name])
    return facts


def cmd_if_exist():
    r = ssh('if exist "%USERPROFILE%\\zb\\" (echo PRESENT) else (echo ABSENT)')
    answer = r.stdout.strip()
    if r.returncode != 0 or answer not in ("PRESENT", "ABSENT"):
        raise Stop(f"cmd.exe if-exist answered rc={r.returncode} {answer!r}")
    field("cmd_if_exist", answer)


def probe_path(name):
    """The ONLY remote path this probe ever writes or deletes."""
    if not _PROBE_NAME.fullmatch(name):
        raise Stop(f"refused: {name!r} is not a probe file name")
    return "%USERPROFILE%\\zb\\" + name


def exists(path):
    r = ssh(f'if exist "{path}" (echo PRESENT) else (echo ABSENT)')
    answer = r.stdout.strip()
    if r.returncode != 0 or answer not in ("PRESENT", "ABSENT"):
        raise Stop(f"existence check of {path} answered rc={r.returncode} {answer!r}")
    return answer == "PRESENT"


def scp_legacy():
    """One legacy-protocol copy into zb\\, read back, then the guarded delete. Returns (scp result, cleanup)."""
    name = f"zb-probe-{secrets.token_hex(8)}.txt"
    path = probe_path(name)
    content = "zb-win10-probe " + name
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write(content + "\n")
        local = f.name
    try:
        try:
            cp = subprocess.run(["scp", *_OPTS, "-O", "-P", PORT, local, f"{USER}@{HOST}:zb/{name}"], env=_env(),
                                capture_output=True, text=True, timeout=PROBE_TIMEOUT_S, stdin=subprocess.DEVNULL)
            result = "ok" if cp.returncode == 0 else f"fail: scp rc={cp.returncode} {cp.stderr.strip()[:200]}"
        except (subprocess.TimeoutExpired, OSError) as e:
            result = f"fail: scp {type(e).__name__}"
    finally:
        os.unlink(local)
    if result == "ok":
        back = ssh(f'type "{path}"')
        if back.returncode != 0 or back.stdout.strip() != content:
            result = f"fail: read back rc={back.returncode} {back.stdout.strip()[:120]!r}"
    if exists(path):
        ssh(f'del /q "{probe_path(name)}"')
    return result, ("left" if exists(path) else "gone")


def main(argv):
    if argv == ["--run"]:
        want = None
    elif len(argv) == 2 and argv[0] == "--scp-check" and _MARKER_ARG.fullmatch(argv[1]) and ".." not in argv[1]:
        want = argv[1]
    else:
        print("win10_probe: refusing without exactly `--run` or `--scp-check <marker>` (each needs NavyCanyon's"
              " exact-commit approval and the orchestrator's release); nothing contacted", file=sys.stderr)
        return 2
    try:
        check_hostkey()
        facts = read_facts()
        cmd_if_exist()
        if want is None:  # discovery: read-only, whatever the box holds
            field("scp_legacy", "not run: read-only discovery")
            field("scp_cleanup", "not run")
            return 0
        if facts["marker"] != want:
            raise Stop(f"marker {facts['marker']!r} is not the literal {want!r}: nothing written")
        if facts["zb_dir"] != "present":
            raise Stop("no zb dir: nothing written")
        result, cleanup = scp_legacy()
        field("scp_legacy", result)
        field("scp_cleanup", cleanup)
        return 0 if (result == "ok" and cleanup == "gone") else 1
    except Stop as e:
        print(f"STOPPED\t{e}", flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
