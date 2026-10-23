#!/usr/bin/env bash
# Windows two-host gate (WS0). Driven from Linux; cannot false-green.
#
# It proves each host is the host it claims to be, with an unlocked interactive session, before
# any product test runs. Two hosts: the Win11 VM (build + run) and the Windows 10 file server
# (run only). Either host unconfigured/unreachable/unhealthy fails the gate closed.
#
# Subcommands used by the Linux-side selftest (tests/windows/gate_selftest.py), which drives this
# script against fake ssh/tar/virsh on PATH:
#   --fence-string <p>   LEXICAL path-shape check (string normalization only; no FS access; NOT an
#                        authorization boundary). Exists for the WS0.3 python-child display-scrub
#                        observation and as a sanity diagnostic. (The reparse-resolving remote-path
#                        fence was removed — see "WS0.5: there is NO remote-path authorization fence".)
#   --selftest-stage     run only the stage-to-host step (the WS0.3/WS0.8 observation point)
#   --probe-only         probe each configured host and print its JSON; run no product tests
#   --product (or none)  readiness, then every live test in tests/windows/live_phases.txt under ZB_WIN_GATE=1;
#                        exit 0 only if each exited 0 with one `ASSERTS <n>` line, n > 0, and no skip (WS0.9)
#
# Errors are handled explicitly (no `set -e`, to avoid the set-e-inside-if trap that bit
# tests/mac/gate.sh): functions return nonzero and callers check with `|| return 1`.
set -uo pipefail

# Whole-gate display scrub: remove the X/Wayland vars from the environment UNCONDITIONALLY at entry
# (no sentinel a caller could pre-set to skip it), so EVERY child the gate starts (python, ssh, tar,
# virsh) inherits a display-free environment (WS0.3).
unset DISPLAY WAYLAND_DISPLAY XAUTHORITY

# Resolve the repo root from an EXPLICIT root (ZB_GATE_ROOT) or the Git root, and FAIL CLOSED when neither
# resolves (RoseCat 012e1bc SHOULD). Note: `cd "$(git rev-parse --show-toplevel)"` is unsafe — from an
# archive export git prints 'fatal: not a git repository' and the substitution is empty, so `cd ""` is a
# no-op that returns 0 and the `|| exit` never fires, leaving the gate in the caller's cwd. Validate that
# the resolved root actually contains this gate before cd-ing.
gate_root="${ZB_GATE_ROOT:-}"
[ -z "$gate_root" ] && gate_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$gate_root" ] || [ ! -d "$gate_root" ] || [ ! -f "$gate_root/tests/windows/gate.sh" ]; then
  echo "gate: cannot resolve a repo root — set ZB_GATE_ROOT to the export/checkout root, or run inside a git repo" >&2
  exit 1
fi
cd "$gate_root" || { echo "gate: cannot enter repo root '$gate_root'" >&2; exit 1; }
REPO="$PWD"
HERE="tests/windows"

# ---- one ssh/scp opts pair (refactor: shared by every remote step) ------------------------
# Per-host identity: each Windows host pins its OWN known_hosts (the Win11 VM and the Win10 file
# server have different host keys), so the key AND the UserKnownHostsFile are passed in per call —
# never a single shared file. StrictHostKeyChecking=yes makes a host-key mismatch a hard refusal.
ssh_opts() { # NUL-delimited ssh argv; $1=key $2=known_hosts
  printf '%s\0' ssh -i "$1" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$2" -o BatchMode=yes -o ConnectTimeout=15 \
    -o ServerAliveInterval=10
}

# Children never carry the Linux display (WS0.3). Every remote invocation goes through this.
run_remote() { # $@ = full ssh argv (already assembled); scrubs display vars from the child
  env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY "$@"
}

# ---- WS0.5: there is NO remote-path authorization fence (removed) ------------------------
# The reparse/junction-resolving remote-path fence (`--allowed-path` / `allowed_path` / resolve_path.sh)
# was REMOVED. A name-only check/use boundary cannot close the junction-swap TOCTOU — the resolver
# returned a verdict for a NAME, but any later operation reopened that name, and a component could be
# replaced by a junction in between (RoseCat security review of aebb07b/9dbad76/7ea3c95; bead
# zigBrowser-q92). There is no consumer and no boundary. A FUTURE remote file op that needs safety MUST
# use a single held-handle check-and-use (Windows plan, "Option B" — its own milestone), never a
# name-based pre-check.
#
# What remains below is `fence_str`: a PURE LEXICAL path-shape check (string normalization only, no
# filesystem access, no reparse resolution — therefore no TOCTOU and NO authorization claim). It exists
# only as the WS0.3 python-child observation point (the display-scrub seam) and as a lexical sanity
# diagnostic. It must never be used to authorize access to a path.
fence_str() { # $1 = path ; LEXICAL path-shape only (string normalization; no FS access; NOT a boundary)
  python3 - "$1" "${ZB_GUEST_USER:-}" <<'PY'
import sys, ntpath, os
# Observability for the WS0.3 selftest: record that this python child ran and any display var it
# still sees (it should see none after the whole-gate scrub).
_ran = os.environ.get("ZB_SELFTEST_RAN_LOG")
if _ran:
    open(_ran, "a").write("python\n")
_envlog = os.environ.get("ZB_SELFTEST_ENV_LOG")
if _envlog:
    with open(_envlog, "a") as _fh:
        for _v in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY"):
            if os.environ.get(_v):
                _fh.write("python %s=%s\n" % (_v, os.environ[_v]))
p, user = sys.argv[1], sys.argv[2]
if not user:
    print("DENY"); sys.exit(0)
root = ntpath.normpath(rf"C:\Users\{user}\zb")

def parts(x):
    drive, rest = ntpath.splitdrive(x)
    segs = [s for s in rest.replace('/', '\\').split('\\') if s]
    return drive.lower(), [s.lower() for s in segs]

norm = ntpath.normpath(p)
drive, _ = ntpath.splitdrive(norm)
# Must be a drive-absolute path (C:\...), never UNC (\\server\share) or drive-relative/relative.
if drive.startswith('\\\\') or not drive or not norm[len(drive):].startswith('\\'):
    print("DENY"); sys.exit(0)
rd, rc = parts(root)
pd, pc = parts(norm)
ok = (pd == rd) and (len(pc) > len(rc)) and (pc[:len(rc)] == rc)
print("ALLOW" if ok else "DENY")
PY
}

# ---- WS0.2 fail-closed banner ------------------------------------------------------------
no_host_configured() { # $1 = space-separated names of the missing host variable(s)
  echo "NOT RUN: no Windows host configured (missing:$1)" >&2
  echo "        both ZB_WIN10_HOST and ZB_WIN11_HOST are required for the two-host gate" >&2
}

# ---- bd zigBrowser-ong.25: every configured host's transport selectors are explicit -----------------------
# A host that is set needs its own <prefix>_PORT, _USER, _KEY and _KNOWN_HOSTS (no default, no legacy name, and
# Win10 never borrows a Win11 value). Checked before any staging, probing or session work; refused with rc 2.
require_selectors() { # $@ = host prefixes (ZB_WIN11 / ZB_WIN10); an unset host forces nothing
  local p h v n; local -a missing=()
  for p in "$@"; do
    h="${p}_HOST"
    [ -n "${!h:-}" ] || continue
    for v in PORT USER KEY KNOWN_HOSTS; do
      n="${p}_${v}"
      [ -n "${!n:-}" ] || missing+=("$n")
    done
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "gate: refused: ${missing[*]} not set for a configured host; every transport selector must be explicit" >&2
    exit 2
  fi
}

# ---- WS0.3 + WS0.8 stage-to-host ---------------------------------------------------------
# Tar the manifest and pipe it over ssh to the host's zb\runs\<id>\. The tar exit status is
# checked (pipefail); no `2>/dev/null` swallows it. StrictHostKeyChecking=yes pins the key.
selftest_stage() {
  # bd zigBrowser-ong.25 (NavyCanyon 456c9420): the transport principal is ZB_WIN11_USER at ZB_WIN11_PORT;
  # ZB_GUEST_USER stays the lexical-fence identity only and is never compared with it.
  local host="$ZB_WIN11_HOST"
  local port="$ZB_WIN11_PORT"
  local user="$ZB_WIN11_USER"
  local key="$ZB_WIN11_KEY"
  local kh="$ZB_WIN11_KNOWN_HOSTS"
  local -a SSH; mapfile -d '' SSH < <(ssh_opts "$key" "$kh")
  local manifest="$HERE/stage_manifest.txt"
  local -a files=(); mapfile -t files < <(grep -vE '^[[:space:]]*(#|$)' "$manifest" 2>/dev/null)
  # Every child (tar AND ssh) goes through run_remote so none carries the Linux display (WS0.3).
  # tar's stderr is deliberately NOT redirected, so a partial-archive error reaches the gate's
  # stderr. PIPESTATUS gives tar's own exit so we can name the failure and propagate its code.
  run_remote tar -c -C "$REPO" -f - "${files[@]}" \
    | run_remote "${SSH[@]}" -p "$port" "$user@$host" "cd zb && tar -x -f -"
  local rc_tar=${PIPESTATUS[0]} rc_ssh=${PIPESTATUS[1]}
  if [ "$rc_tar" -ne 0 ]; then
    echo "stage: tar failed (rc=$rc_tar) — partial archive, not staging" >&2
    return "$rc_tar"
  fi
  if [ "$rc_ssh" -ne 0 ]; then
    echo "stage: remote extract failed (rc=$rc_ssh)" >&2
    return "$rc_ssh"
  fi
  return 0
}

# ---- WS0.6 + WS0.7 two-host --probe-only -------------------------------------------------
probe_host() { # $1=user $2=host $3=port $4=key $5=known_hosts [$6=share_exceptions_record] -> host_probe.ps1 JSON
  # The probe script is STREAMED over ssh stdin; it is NEVER copied onto the host. This keeps the Win10
  # file server strictly read-only — nothing is written there, not even in zb\ — and needs no host shell
  # reconfiguration (works with the default cmd.exe DefaultShell, so no cmd.exe 8191-char cap applies).
  # We do NOT use `powershell -Command -`: reading commands from stdin mis-tokenizes multi-line
  # constructs and can silently drop the rest of the script (verified on the VM: empty output, exit 0,
  # on a multi-line block). `$input | Out-String | iex` reads the WHOLE piped script as one string and
  # runs it, so every multi-line construct parses correctly. -EncodedCommand is not an option either:
  # the base64 (~30 KB) exceeds the default cmd.exe command-line cap.
  local -a SSH; mapfile -d '' SSH < <(ssh_opts "$4" "$5")
  # RoseCat be655f3 (1): the owner exception must reach the REMOTE PowerShell (local `env`/ssh does not
  # carry it). When a record is given ($6), install it with a SAFE prelude prepended to the streamed probe:
  # the record is base64(UTF-8)'d and decoded at runtime into $env:ZB_WIN10_SHARE_EXCEPTIONS, so no caller
  # value is ever interpolated into the ssh command or parsed as a shell/PS metacharacter. Win10 only.
  local prelude=""
  if [ -n "${6:-}" ]; then
    local b64; b64=$(printf '%s' "$6" | base64 -w0)
    prelude="\$env:ZB_WIN10_SHARE_EXCEPTIONS = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$b64'))"
  fi
  { [ -n "$prelude" ] && printf '%s\n' "$prelude"; cat "$HERE/host_probe.ps1"; } | \
    run_remote "${SSH[@]}" -p "$3" "$1@$2" \
    'powershell -NoProfile -NonInteractive -Command "$input | Out-String | iex"'
}

# ---- WS0.1 in-console session helper (VM ONLY) -------------------------------------------
# A network (SSH) logon cannot read the console's input-desktop lock state, so interactive_session/locked
# come from session_probe.ps1, which must run IN the console session. The gate writes a fresh per-run
# NONCE to the VM, triggers the pre-registered console scheduled task (zb-session-probe), and waits for a
# session.json carrying that exact nonce (bounded timeout). host_probe then trusts interactive/locked only
# when session.json's nonce matches nonce.txt. This is VM-only: the read-only file server runs no helper,
# so run_session_probe is never called against it and nothing is written there.
SESSION_TIMEOUT="${ZB_SESSION_TIMEOUT:-60}"
run_session_probe() { # $1=user $2=host $3=port $4=key $5=known_hosts $6=nonce $7=expected session_probe.ps1 sha256
  local -a SSH; mapfile -d '' SSH < <(ssh_opts "$4" "$5")
  # Pin-verify the externally-provisioned console task BEFORE triggering, using the SAME verify_task.ps1 the
  # live negative tests exercise (single source of truth). It sets $ZB_VERIFY=OK or a TASK_* reason; we only
  # write the nonce + trigger + poll when $ZB_VERIFY -eq 'OK'. A tampered/absent/non-interactive task fails
  # closed. The header sets verify_task.ps1's inputs (task name, staged script path, expected SHA-256).
  local header verify tail ps
  header="\$env:ZB_TASK_NAME='zb-session-probe'; \$env:ZB_STAGED_PATH=(Join-Path \$env:USERPROFILE 'zb\\session_probe.ps1'); \$env:ZB_STAGED_SHA='__SHA__'"
  verify=$(cat "$HERE/verify_task.ps1")
  tail=$(cat <<'PS'
if ($ZB_VERIFY -ne 'OK') { exit 0 }   # verify_task.ps1 already printed VERIFY=TASK_*; the gate treats any non-OK as failure
$dir = Join-Path $env:USERPROFILE 'zb\runs\session'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Set-Content -LiteralPath (Join-Path $dir 'nonce.txt') -Value '__NONCE__' -NoNewline -Encoding ascii
Remove-Item -LiteralPath (Join-Path $dir 'session.json') -ErrorAction SilentlyContinue
try { schtasks /Run /TN 'zb-session-probe' | Out-Null } catch { Write-Output ('RESULT=TRIGGER_FAILED ' + $_.Exception.Message); exit 0 }
$deadline = (Get-Date).AddSeconds(__TIMEOUT__)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 1500
  $sj = Join-Path $dir 'session.json'
  if (Test-Path -LiteralPath $sj) {
    try {
      $s = Get-Content -LiteralPath $sj -Raw | ConvertFrom-Json
      if ("$($s.nonce)" -eq '__NONCE__') { Write-Output ('RESULT=OK interactive=' + $s.interactive_session + ' locked=' + $s.locked); exit 0 }
    } catch {}
  }
}
Write-Output 'RESULT=TIMEOUT'
PS
)
  ps="$header"$'\n'"$verify"$'\n'"$tail"
  ps=${ps//__NONCE__/$6}
  ps=${ps//__TIMEOUT__/$SESSION_TIMEOUT}
  ps=${ps//__SHA__/$7}
  run_remote timeout "$((SESSION_TIMEOUT + 25))" "${SSH[@]}" -p "$3" "$1@$2" \
    'powershell -NoProfile -NonInteractive -Command "$input | Out-String | iex"' <<<"$ps"
}

# RoseCat be655f3 (2): the one owner-approved Win10 share exception (single source of truth for the pin
# check AND the schema validator). Unset ZB_WIN10_SHARE_EXCEPTIONS means no exception.
ZB_FS_EXC_PINNED='K:\=exFAT, no ACL possible; owner accepted 2026-10-21'

validate_probes() { # $1=vm_json $2=fs_pre $3=fs_post ; ALLOW to stdout, fail reason to stderr
  python3 - "$1" "$2" "$3" "${ZB_WIN11_MARKER:-}" "$ZB_WIN10_USER" "${ZB_WIN10_MARKER:-}" "$ZB_WIN11_USER" "${ZB_WIN10_LISTEN:-${ZB_WIN10_HOST:-}}" "$ZB_FS_EXC_PINNED" <<'PY'
import sys, json, math, ntpath
vm, fs_pre, fs_post, win11_marker, win10_user, win10_marker, win11_user, win10_listen, fs_exc_pinned = sys.argv[1:10]
# The one approved exception as (path, reason); exact match only.
_pe = fs_exc_pinned.split("=", 1)
PIN_PATH, PIN_REASON = (_pe[0], _pe[1]) if len(_pe) == 2 else (fs_exc_pinned, "")
def _build_int(x):
    try: return int(str(x or "0").strip())
    except ValueError: return 0
def _is_finite_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)
def _is_abs_win_path(p):
    # Drive-absolute (C:\...), never UNC/relative/drive-relative. Mirrors the WS0.5 path fence.
    if not isinstance(p, str) or not p.strip(): return False
    n = ntpath.normpath(p)
    drive, _ = ntpath.splitdrive(n)
    return bool(drive) and not drive.startswith("\\\\") and n[len(drive):].startswith("\\")
def load(s, who):
    try:
        return json.loads(s)
    except Exception:
        sys.stderr.write("FAIL: probe (%s) returned bad JSON\n" % who); sys.exit(1)
v = load(vm, "win11"); a = load(fs_pre, "win10 pre"); b = load(fs_post, "win10 post")

# WS0.6: the VM's identity marker must match the pinned nonce (missing/empty/wrong => wrong host).
m = v.get("identity_marker")
if not m or m != win11_marker:
    sys.stderr.write("wrong host: Win11 identity_marker does not match ZB_WIN11_MARKER\n"); sys.exit(1)

# WS0.1/0.2 readiness (fail CLOSED): the VM must present the complete schema-2 probe, an ACTIVE and
# UNLOCKED interactive console session, x64, and its snapshot marker. A missing/mistyped field is a
# refusal, never silently treated as ready.
if v.get("schema") != 2:
    sys.stderr.write("win11: probe schema is %r, expected 2\n" % v.get("schema")); sys.exit(1)
if v.get("native_arch") != "x64":
    sys.stderr.write("win11: native_arch is %r, expected x64\n" % v.get("native_arch")); sys.exit(1)
if v.get("interactive_session") is not True:
    sys.stderr.write("win11: no active interactive session (interactive_session=%r)\n" % v.get("interactive_session")); sys.exit(1)
if v.get("locked") is not False:
    sys.stderr.write("win11: session is locked or its lock state is unknown (locked=%r)\n" % v.get("locked")); sys.exit(1)
cu11 = v.get("console_user")
if not isinstance(cu11, str) or not cu11.strip():
    sys.stderr.write("win11: console_user missing or empty\n"); sys.exit(1)
if cu11.split("\\")[-1].lower() != win11_user.lower():
    sys.stderr.write("win11: console_user %r is not %s (a real operator may be at the console)\n" % (cu11, win11_user)); sys.exit(1)
if str(v.get("test_user", "")).split("\\")[-1].lower() != win11_user.lower():
    sys.stderr.write("win11: test_user %r is not %s\n" % (v.get("test_user"), win11_user)); sys.exit(1)
if _build_int(v.get("os_build")) < 22621:
    sys.stderr.write("win11: os_build %r is below the Windows 11 22H2 floor (22621)\n" % v.get("os_build")); sys.exit(1)
if not isinstance(v.get("webview2_pv"), str) or not v.get("webview2_pv").strip():
    sys.stderr.write("win11: webview2_pv missing or empty\n"); sys.exit(1)
# VM free-space bar is 10 GB, not 20: the KVM host disk is ~97% full so the VM image cannot grow, and a
# zigBrowser build plus the WebView2 runtime fit comfortably in ~13 GB (orchestrator decision 2026-10-20;
# see the plan's WS0 free-space note). The physical file server keeps the 20 GB bar (it has ample disk).
if not _is_finite_num(v.get("free_gb")) or v.get("free_gb") < 10:
    sys.stderr.write("win11: free_gb %r is not a finite number >= 10\n" % v.get("free_gb")); sys.exit(1)
vm_root_expected = "C:\\Users\\%s\\zb" % win11_user
if not isinstance(v.get("root"), str) or v.get("root").strip().rstrip("\\").lower() != vm_root_expected.lower():
    sys.stderr.write("win11: root %r is not the pinned %r\n" % (v.get("root"), vm_root_expected)); sys.exit(1)
# snapshot_marker is NOT an in-VM probe field — a file inside the VM proves only that someone wrote a
# file, not that a rollback snapshot exists. The gate proves it host-side with read-only virsh (see
# probe_only); the physical file server has no VM snapshot and is explicitly not_applicable.

# WS0 is fail CLOSED: before ANY comparison, every file-server field we judge on must be present and
# well-typed on BOTH probes. Malformed/missing data must be rejected, never silently coerced to a value
# that compares "undisturbed". A bare `name or []` would let None/""/"bad"/["22"] masquerade as empty.
def _is_listener_list(x):
    # Typed listeners: each is {port, pid} (both ints) so WS0.7 can tell benign ephemeral churn by a known
    # process from a real disturbance (bead zigBrowser-bdq). A bare int list, None, or strings are rejected.
    if not isinstance(x, list): return False
    for l in x:
        if not isinstance(l, dict): return False
        p, q = l.get("port"), l.get("pid")
        if not (isinstance(p, int) and not isinstance(p, bool) and 0 <= p <= 65535): return False
        if not (isinstance(q, int) and not isinstance(q, bool) and q >= 0): return False
    return True
def _is_share_list(x):
    # Typed shares: each is {name, path}, name NONEMPTY and path a DRIVE-ABSOLUTE, normalized Windows
    # path (never relative/UNC — a relative share path is malformed and must not pass). This detects a
    # rename/alias (same path, new share name) and refuses an empty-string or relative identity.
    if not isinstance(x, list): return False
    for s in x:
        if not (isinstance(s, dict) and isinstance(s.get("name"), str) and s.get("name").strip()): return False
        if not _is_abs_win_path(s.get("path")): return False
    return True
def _no_dup_shares(x, who):
    # No duplicate share names and no duplicate served paths (an alias of either is a disturbance risk).
    names = [str(s.get("name")).strip().lower() for s in x]
    paths = [ntpath.normpath(str(s.get("path"))).lower() for s in x]
    if len(set(names)) != len(names):
        sys.stderr.write("file-server (%s): duplicate share name in %s\n" % (who, names)); sys.exit(1)
    if len(set(paths)) != len(paths):
        sys.stderr.write("file-server (%s): duplicate served path in %s\n" % (who, paths)); sys.exit(1)
def _share_key(s):
    return (str(s.get("name")).strip().lower(), ntpath.normpath(str(s.get("path"))).lower())
def require_schema(probe, who):
    # identity: the physical file server is pinned by its SSH host key ALONE (StrictHostKeyChecking=yes +
    # the pinned known_hosts), per the orchestrator's read-only rule — no nonce file is ever written there,
    # so there is no identity_marker to check. The host-key pin is enforced by ssh before this probe runs.
    if not isinstance(probe.get("groups"), list):
        sys.stderr.write("file-server (%s): groups missing or not a list\n" % who); sys.exit(1)
    cu = probe.get("console_user")
    if not isinstance(cu, str) or not cu.strip():
        sys.stderr.write("file-server (%s): console_user missing or empty\n" % who); sys.exit(1)
    if not isinstance(probe.get("zbtest_write_paths"), list):
        sys.stderr.write("file-server (%s): zbtest_write_paths missing or not a list\n" % who); sys.exit(1)
    # WS0.7 (RoseCat be655f3 (3)): absent_paths and share_exceptions MUST be present and well-formed on
    # BOTH probes — a missing/malformed value must never become an empty pass. Paths are drive-absolute,
    # unique, and members of the reported shares; each exception is exactly {path, reason} with a nonempty
    # reason and must equal the one approved record.
    share_paths = set()
    for s in (probe.get("shares") or []):
        if isinstance(s, dict) and s.get("path") is not None:
            share_paths.add(ntpath.normpath(str(s.get("path"))).lower())
    ap = probe.get("absent_paths")
    if not isinstance(ap, list):
        sys.stderr.write("file-server (%s): absent_paths missing or not a list\n" % who); sys.exit(1)
    seen_ap = set()
    for p in ap:
        if not _is_abs_win_path(p):
            sys.stderr.write("file-server (%s): absent_paths entry %r is not a drive-absolute path\n" % (who, p)); sys.exit(1)
        k = ntpath.normpath(str(p)).lower()
        if k in seen_ap:
            sys.stderr.write("file-server (%s): duplicate absent_paths entry %r\n" % (who, p)); sys.exit(1)
        seen_ap.add(k)
        if k not in share_paths:
            sys.stderr.write("file-server (%s): absent_paths entry %r is not a served share\n" % (who, p)); sys.exit(1)
    se = probe.get("share_exceptions")
    if not isinstance(se, list):
        sys.stderr.write("file-server (%s): share_exceptions missing or not a list\n" % who); sys.exit(1)
    seen_se = set()
    for ex in se:
        if not isinstance(ex, dict) or set(ex.keys()) != {"path", "reason"}:
            sys.stderr.write("file-server (%s): share_exceptions entry must be an object with exactly {path, reason}: %r\n" % (who, ex)); sys.exit(1)
        if not isinstance(ex.get("reason"), str) or not ex["reason"].strip():
            sys.stderr.write("file-server (%s): share_exceptions entry has an empty reason: %r\n" % (who, ex)); sys.exit(1)
        k = ntpath.normpath(str(ex.get("path"))).lower()
        if k in seen_se:
            sys.stderr.write("file-server (%s): duplicate share_exceptions path %r\n" % (who, ex.get("path"))); sys.exit(1)
        seen_se.add(k)
        if k not in share_paths:
            sys.stderr.write("file-server (%s): excepted path %r is not a served share\n" % (who, ex.get("path"))); sys.exit(1)
        if (str(ex.get("path")), str(ex.get("reason"))) != (PIN_PATH, PIN_REASON):
            sys.stderr.write("file-server (%s): share exception %r is not the one approved record (%s=%s)\n" % (who, ex, PIN_PATH, PIN_REASON)); sys.exit(1)
    if not _is_listener_list(probe.get("listeners")):
        sys.stderr.write("file-server (%s): listeners missing or not a list of {port, pid} objects\n" % who); sys.exit(1)
    # No FIXED baseline listener set: the real file server's listeners (135/445/5040/5357, dynamic RPC
    # 49664+, 139, 22, high service ports) vary by host and have no 3389, and the WS0.7 rule is only that
    # the listener set is UNCHANGED pre vs post (checked below). A pinned/overridable baseline here was
    # both wrong for this host and ambiently weakenable (RoseCat 50a4c5b #1; orchestrator real-FS check).
    fw = probe.get("fw_rules_hash")
    if not isinstance(fw, str) or not fw.strip():
        sys.stderr.write("file-server (%s): fw_rules_hash missing or empty\n" % who); sys.exit(1)
    # WS0-completion: the complete schema-2 fields the file-server fence judges on.
    if probe.get("schema") != 2:
        sys.stderr.write("file-server (%s): probe schema is %r, expected 2\n" % (who, probe.get("schema"))); sys.exit(1)
    if not _is_share_list(probe.get("shares")):
        sys.stderr.write("file-server (%s): shares missing, or a share has an empty name or a non-absolute path\n" % who); sys.exit(1)
    _no_dup_shares(probe.get("shares"), who)
    if str(probe.get("test_user", "")).split("\\")[-1].lower() != win10_user.lower():
        sys.stderr.write("file-server (%s): test_user %r is not %s\n" % (who, probe.get("test_user"), win10_user)); sys.exit(1)
    if probe.get("native_arch") != "x64":
        sys.stderr.write("file-server (%s): native_arch %r, expected x64\n" % (who, probe.get("native_arch"))); sys.exit(1)
    if _build_int(probe.get("os_build")) < 19045:
        sys.stderr.write("file-server (%s): os_build %r is below the Windows 10 22H2 floor (19045)\n" % (who, probe.get("os_build"))); sys.exit(1)
    # root and free_gb are NOT applicable on the physical file server (orchestrator real-FS check): the
    # read-only rule means C:\Users\<user>\zb is never created there, and the box gets no writes so its
    # free space is irrelevant (C: was ~0 GB). Both are VM-only requirements. The probe may still report
    # them for visibility, but the gate does not judge the file server on them.
    # sshd network fence: ListenAddress must be EXACTLY the pinned tailnet address (not just a non-wildcard),
    # and AllowUsers must be EXACTLY the test user — enforce the values, not just the list type.
    sl = probe.get("sshd_listen")
    if not isinstance(sl, list) or not sl or not all(isinstance(a, str) and a.strip() for a in sl):
        sys.stderr.write("file-server (%s): sshd_listen missing, empty, or not a list of nonempty strings\n" % who); sys.exit(1)
    if not win10_listen.strip():
        sys.stderr.write("file-server (%s): no expected ListenAddress configured (set ZB_WIN10_LISTEN or ZB_WIN10_HOST)\n" % who); sys.exit(1)
    if {a.strip() for a in sl} != {win10_listen.strip()}:
        sys.stderr.write("file-server (%s): sshd ListenAddress %r is not exactly the pinned tailnet address [%s]\n" % (who, sl, win10_listen.strip())); sys.exit(1)
    au = probe.get("sshd_allowusers")
    if not isinstance(au, list):
        sys.stderr.write("file-server (%s): sshd_allowusers missing or not a list\n" % who); sys.exit(1)
    au_users = set()
    for e in au:
        au_users |= {u.strip().split("\\")[-1].lower() for u in str(e).split() if u.strip()}
    if au_users != {win10_user.lower()}:
        sys.stderr.write("file-server (%s): sshd AllowUsers %r is not exactly [%s]\n" % (who, au, win10_user)); sys.exit(1)
    # interactive_session / locked are not_applicable on the physical file server: it runs no GUI and no
    # in-console helper under the read-only rule. console_user (network-safe, checked above) proves the
    # test user owns its console; an active unlocked interactive session is the VM's requirement, not the FS's.
require_schema(a, "pre"); require_schema(b, "post")

# WS0.7: the file server must be undisturbed.
FORBIDDEN = {"administrators", "backup operators", "remote desktop users", "remote management users"}
names = {str(g.get("name", "")).split("\\")[-1].strip().lower() for g in a.get("groups", [])}
bad = sorted(names & FORBIDDEN)
if bad:
    sys.stderr.write("file-server: zbtest is in a forbidden group: %s\n" % bad); sys.exit(1)
# WS0.7 (owner decision 2026-10-21): a writable served path fails in EITHER the pre or the post probe, so
# an absent-volume share that LATER exists and is writable is still caught. Absent-volume paths and the
# owner's exact-match exceptions are printed (never silently passed); a writable path NOT excepted fails.
for who2, probe2 in (("pre", a), ("post", b)):
    for p in (probe2.get("absent_paths") or []):
        sys.stderr.write("file-server (%s): NOTE share path on an ABSENT volume (not writable now): %s\n" % (who2, p))
    for ex in (probe2.get("share_exceptions") or []):
        sys.stderr.write("file-server (%s): NOTE excepted writable share %s — %s\n"
                         % (who2, ex.get("path"), ex.get("reason")))
    wpx = probe2.get("zbtest_write_paths")
    if wpx:
        sys.stderr.write("file-server (%s): zbtest can write to %s\n" % (who2, wpx[0])); sys.exit(1)
cu = str(a.get("console_user", "")).split("\\")[-1].lower()
if cu != win10_user.lower():
    sys.stderr.write("file-server: console user is %r, not %s\n" % (a.get("console_user"), win10_user)); sys.exit(1)
# WS0.7 listeners pre/post, by PID-OWNERSHIP (bead zigBrowser-bdq), so genuine OS dynamic-port churn does
# not false-fail while a real disturbance still does. SERVICE ports (< 49152) are compared as a strict SET
# — any added/dropped service port is a disturbance. EPHEMERAL ports (>= 49152) may churn, but ONLY among
# processes that already owned a pre-run listener: a post ephemeral listener owned by a pid with NO pre
# listener (e.g. a product service that started) is a disturbance. (No blanket high-port exemption — a new
# process binding a high port still fails. See thoughts/.../2026-10-20-ws07-file-server-field-design.md.)
EPH = 49152
pre_svc = sorted(l["port"] for l in a.get("listeners") if l["port"] < EPH)
post_svc = sorted(l["port"] for l in b.get("listeners") if l["port"] < EPH)
if pre_svc != post_svc:
    sys.stderr.write("file-server: service listener ports changed %s -> %s\n" % (pre_svc, post_svc)); sys.exit(1)
pre_pids = {l["pid"] for l in a.get("listeners")}
intruders = sorted({(l["port"], l["pid"]) for l in b.get("listeners") if l["port"] >= EPH and l["pid"] not in pre_pids})
if intruders:
    sys.stderr.write("file-server: ephemeral listener from a process with no pre-run listener: %s\n" % intruders); sys.exit(1)
if a.get("fw_rules_hash") != b.get("fw_rules_hash"):
    sys.stderr.write("file-server: firewall rules changed between pre and post\n"); sys.exit(1)
# WS0.7: the served shares themselves must be undisturbed pre/post (names/root paths), not just writable.
pre_shares = sorted(map(_share_key, a.get("shares"))); post_shares = sorted(map(_share_key, b.get("shares")))
if pre_shares != post_shares:
    sys.stderr.write("file-server: served shares changed %s -> %s\n" % (pre_shares, post_shares)); sys.exit(1)
print("ALLOW")
PY
}

probe_only() { # WS0.6 (VM identity) + WS0.7 (file-server fence) across both hosts
  local domain="${ZB_WIN11_DOMAIN:-win11-m8}"
  local state; state=$(virsh domstate "$domain" 2>/dev/null)
  if [ "$state" != "running" ]; then
    echo "NOT RUN: Win11 VM $domain is ${state:-unknown}" >&2
    return 1
  fi
  # WS0.6 snapshot readiness (host-side, read-only; the gate NEVER creates or reverts — the user takes
  # snapshots, only while the VM is shut off). The EXPECTED clean-baseline snapshot name must be pinned
  # (ZB_WIN11_SNAPSHOT, e.g. zb-clean-provisioned); that exact name must exist AND have been taken while
  # shut off. An arbitrary unrelated snapshot is not enough. The physical file server has no VM snapshot:
  # that is not_applicable, handled by never running this check against it (only the Win11 VM domain).
  local want="${ZB_WIN11_SNAPSHOT:-}"
  if [ -z "$want" ]; then
    echo "NOT RUN: ZB_WIN11_SNAPSHOT is not set — pin the expected clean-baseline snapshot name" >&2
    return 1
  fi
  if ! virsh snapshot-list "$domain" --name 2>/dev/null | sed '/^[[:space:]]*$/d' | grep -qxF "$want"; then
    echo "NOT RUN: Win11 VM $domain has no snapshot named '$want' (the expected clean baseline)" >&2
    return 1
  fi
  local sinfo sstate screated
  sinfo=$(virsh snapshot-info "$domain" "$want" 2>/dev/null)
  sstate=$(printf '%s\n' "$sinfo" | sed -n 's/^State:[[:space:]]*//p' | tr -d '[:space:]')
  if [ "$sstate" != "shutoff" ]; then
    echo "NOT RUN: Win11 VM snapshot '$want' was taken in state '${sstate:-unknown}', not shutoff" >&2
    return 1
  fi
  # The creation time is NOT in snapshot-info on this host (it prints only Name/Domain/Current/State/
  # Location/Parent); it lives in snapshot-dumpxml as <creationTime>EPOCH</creationTime> (Unix seconds).
  screated=$(virsh snapshot-dumpxml "$domain" "$want" 2>/dev/null \
             | sed -n 's/.*<creationTime>\([^<]*\)<\/creationTime>.*/\1/p' | head -n1 | tr -d '[:space:]')
  if [ -z "$screated" ]; then
    echo "NOT RUN: Win11 VM snapshot '$want' has no <creationTime> in virsh snapshot-dumpxml (cannot confirm the baseline)" >&2
    return 1
  fi
  # It must be a REAL numeric epoch — not just nonempty — so a malformed value cannot pass as evidence.
  if ! printf '%s' "$screated" | grep -Eq '^[0-9]+$'; then
    echo "NOT RUN: Win11 VM snapshot '$want' <creationTime> '$screated' is not a numeric epoch" >&2
    return 1
  fi
  echo "WS0.6: Win11 snapshot '$want' state=$sstate created_epoch=$screated ($(date -d @"$screated" 2>/dev/null))" >&2
  local vm_json fs_pre fs_post
  # Per-host key + known_hosts, each host's own explicit ZB_WIN11_* / ZB_WIN10_* (bd zigBrowser-ong.25; checked by
  # require_selectors before this runs). The VM and the file server pin DIFFERENT host keys.
  local vm_key="$ZB_WIN11_KEY"
  local vm_kh="$ZB_WIN11_KNOWN_HOSTS"
  # The Win10 file server may use the same private key file as the VM, but only through its own explicit
  # ZB_WIN10_KEY: it never borrows a Win11 value (bd zigBrowser-ong.25).
  local fs_key="$ZB_WIN10_KEY"
  local fs_kh="$ZB_WIN10_KNOWN_HOSTS"
  # RoseCat be655f3 (2): the owner approved exactly ONE share exception. Pin it: ZB_WIN10_SHARE_EXCEPTIONS,
  # if set, MUST equal this record EXACTLY (no extra/duplicate/other-path/malformed entries) before any SSH;
  # unset means no exception. Only this record is carried to Win10 (via probe_host's base64 prelude).
  local fs_exc="${ZB_WIN10_SHARE_EXCEPTIONS:-}"
  if [ -n "$fs_exc" ] && [ "$fs_exc" != "$ZB_FS_EXC_PINNED" ]; then
    echo "NOT RUN: ZB_WIN10_SHARE_EXCEPTIONS must equal the one approved record exactly:" >&2
    echo "         $ZB_FS_EXC_PINNED" >&2
    return 1
  fi
  # WS0.1: trigger the in-console session helper on the VM with a fresh per-run nonce and AWAIT a
  # nonce-matching session.json (bounded). No manual console step. If it does not return OK, fail closed
  # before any probe — a VM with no fresh, nonce-correlated session result is not ready.
  local nonce sres sess_sha
  nonce="ws0-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}${RANDOM}"
  sess_sha=$(sha256sum "$HERE/session_probe.ps1" | awk '{print $1}')
  sres=$(run_session_probe "$ZB_WIN11_USER" "$ZB_WIN11_HOST" "$ZB_WIN11_PORT" "$vm_key" "$vm_kh" "$nonce" "$sess_sha")
  echo "WS0.1: VM session-probe -> $sres" >&2
  case "$sres" in
    *RESULT=OK*) : ;;
    *) echo "NOT RUN: VM in-console session helper did not return a fresh nonce-matching result ($sres)" >&2; return 1 ;;
  esac
  # EXPLICIT transport rc checks: an unreachable host or an ssh host-key refusal (StrictHostKeyChecking=yes
  # => rc 255) must fail the gate HERE, before any success row is accepted — never rely on empty JSON failing
  # later in validation. (probe_host's rc is ssh's rc.)
  local rc
  vm_json=$(probe_host "$ZB_WIN11_USER" "$ZB_WIN11_HOST" "$ZB_WIN11_PORT" "$vm_key" "$vm_kh"); rc=$?
  [ "$rc" -ne 0 ] && { echo "NOT RUN: Win11 probe transport failed (ssh rc=$rc — unreachable or host-key refusal)" >&2; return 1; }
  fs_pre=$(probe_host "$ZB_WIN10_USER" "$ZB_WIN10_HOST" "$ZB_WIN10_PORT" "$fs_key" "$fs_kh" "$fs_exc"); rc=$?
  [ "$rc" -ne 0 ] && { echo "NOT RUN: Win10 probe transport failed (ssh rc=$rc — unreachable or host-key refusal)" >&2; return 1; }
  # A full gate runs the product tests here; --probe-only re-probes to catch any change (WS0.7).
  fs_post=$(probe_host "$ZB_WIN10_USER" "$ZB_WIN10_HOST" "$ZB_WIN10_PORT" "$fs_key" "$fs_kh" "$fs_exc"); rc=$?
  [ "$rc" -ne 0 ] && { echo "NOT RUN: Win10 re-probe transport failed (ssh rc=$rc)" >&2; return 1; }
  validate_probes "$vm_json" "$fs_pre" "$fs_post" >/dev/null || return 1
  printf 'WIN11 %s\nWIN10 %s\n' "$vm_json" "$fs_post"
  return 0
}

# ---- WS0.9 product run (fail on skip) ----------------------------------------------------
# The one phase list, also read by build.zig's `windows-live` aggregate. After the readiness probe, every entry runs
# as `ZB_WIN_GATE=1 python3 -I <file>` (D.1: under the gate a skip is a failure). An entry passes only on exit 0
# with exactly one `ASSERTS <n>` line, n > 0, and no reported skip. Zero entries is zero rows: a failure (rule 7).
PHASES="$HERE/live_phases.txt"
LIVE_TIMEOUT="${ZB_LIVE_TEST_TIMEOUT:-1800}"

judge_live() { # $1=rc $2=stdout file $3=stderr file ; prints the ASSERTS count (pass) or the reason (fail)
  local rc="$1" asserts
  [ "$rc" -eq 77 ] && { echo "skipped (exit 77)"; return 1; }
  grep -Eqs 'skipped=[1-9]|^SKIP\b' "$2" "$3" && { echo "skipped (it reported a skip)"; return 1; }
  [ "$rc" -ne 0 ] && { echo "failed (exit $rc)"; return 1; }
  asserts=$(grep -E '^ASSERTS\b' "$2")
  [ -z "$asserts" ] && { echo "printed no ASSERTS line"; return 1; }
  if [ "$(printf '%s\n' "$asserts" | wc -l)" -ne 1 ] || [[ ! "$asserts" =~ ^ASSERTS\ ([0-9]{1,9})$ ]]; then
    echo "printed a malformed ASSERTS line: $(printf '%s' "$asserts" | tr '\n' '|' | head -c 200)"; return 1
  fi
  [ "$((10#${BASH_REMATCH[1]}))" -le 0 ] && { echo "printed ASSERTS 0 (zero assertions)"; return 1; }
  echo "$((10#${BASH_REMATCH[1]}))"
}

product_run() {
  local -a tests=(); mapfile -t tests < <(grep -vE '^[[:space:]]*(#|$)' "$PHASES" 2>/dev/null)
  if [ "${#tests[@]}" -eq 0 ]; then
    echo "NOT RUN: no live tests in the phase list $PHASES (zero rows is a failure)" >&2
    return 1
  fi
  probe_only || { echo "gate: product run FAILED: readiness failed; no live test was run" >&2; return 1; }
  local work; work=$(mktemp -d "${TMPDIR:-/tmp}/zb-gate-product.XXXXXX") || { echo "gate: mktemp failed" >&2; return 1; }
  local t rc verdict total=0; local -a failed=()
  for t in "${tests[@]}"; do
    env ZB_WIN_GATE=1 timeout "$LIVE_TIMEOUT" python3 -I "$t" >"$work/out" 2>"$work/err" </dev/null; rc=$?
    sed "s|^|  [$t] |" "$work/out" "$work/err" >&2
    if verdict=$(judge_live "$rc" "$work/out" "$work/err"); then
      echo "PASS $t ASSERTS $verdict" >&2; total=$((total + verdict))
    else
      echo "FAIL $t: $verdict" >&2; failed+=("$t")
    fi
  done
  rm -rf "${work:?}"
  if [ "${#failed[@]}" -ne 0 ]; then
    echo "gate: product run FAILED: ${#failed[@]} of ${#tests[@]} live tests: ${failed[*]}" >&2
    return 1
  fi
  echo "gate: product run PASSED: ${#tests[@]} live tests, ASSERTS $total" >&2
  return 0
}

# ---- orchestration -----------------------------------------------------------------------
# Sub-commands that do NOT need the full two-host set:
case "${1:-}" in
  --fence-string)
    # LEXICAL path-shape check only (string normalization; no FS access; NOT an authorization boundary).
    fence_str "${2:-}"
    exit 0
    ;;
  --selftest-stage)
    # Stages to the Win11 host only; needs just that one host variable.
    if [ -z "${ZB_WIN11_HOST:-}" ]; then
      echo "gate: --selftest-stage needs ZB_WIN11_HOST" >&2
      exit 1
    fi
    require_selectors ZB_WIN11
    selftest_stage
    exit $?
    ;;
esac

# The full gate run and --probe-only need BOTH hosts. Fail CLOSED if EITHER is missing (WS0.2),
# naming which one(s) — a one-host gate is not a two-host gate.
missing=""
[ -z "${ZB_WIN10_HOST:-}" ] && missing="$missing ZB_WIN10_HOST"
[ -z "${ZB_WIN11_HOST:-}" ] && missing="$missing ZB_WIN11_HOST"
if [ -n "$missing" ]; then
  no_host_configured "$missing"
  exit 1
fi
require_selectors ZB_WIN11 ZB_WIN10

case "${1:-}" in
  --probe-only)
    # WS0.6 (VM identity) + WS0.7 (file-server fence), both hosts. Live run needs the real probe +
    # the .gate-identity nonce; hermetically it runs against the selftest's fake ssh/virsh.
    probe_only
    exit $?
    ;;
  ""|--product)
    # WS0.9: readiness on both hosts, then every phase-list entry under ZB_WIN_GATE=1, fail on skip.
    product_run
    exit $?
    ;;
  *)
    echo "gate: unknown argument: $1" >&2
    exit 2
    ;;
esac
