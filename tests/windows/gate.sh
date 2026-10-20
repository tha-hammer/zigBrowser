#!/usr/bin/env bash
# Windows two-host gate (WS0). Driven from Linux; cannot false-green.
#
# It proves each host is the host it claims to be, with an unlocked interactive session, before
# any product test runs. Two hosts: the Win11 VM (build + run) and the Windows 10 file server
# (run only). Either host unconfigured/unreachable/unhealthy fails the gate closed.
#
# Subcommands used by the Linux-side selftest (tests/windows/gate_selftest.py), which drives this
# script against fake ssh/tar/virsh on PATH:
#   --allowed-path <p>   print ALLOW/DENY for a remote path against C:\Users\<ZB_GUEST_USER>\zb
#   --selftest-stage     run only the stage-to-host step (the WS0.3/WS0.8 observation point)
#   --probe-only         probe each configured host and print its JSON; run no product tests
#
# Errors are handled explicitly (no `set -e`, to avoid the set-e-inside-if trap that bit
# tests/mac/gate.sh): functions return nonzero and callers check with `|| return 1`.
set -uo pipefail

# Whole-gate display scrub: remove the X/Wayland vars from the environment UNCONDITIONALLY at entry
# (no sentinel a caller could pre-set to skip it), so EVERY child the gate starts (python, ssh, tar,
# virsh, resolve_path.sh) inherits a display-free environment (WS0.3).
unset DISPLAY WAYLAND_DISPLAY XAUTHORITY

cd "$(git rev-parse --show-toplevel)" || { echo "gate: not in a git repo" >&2; exit 1; }
REPO="$PWD"
HERE="tests/windows"

# ---- one ssh/scp opts pair (refactor: shared by every remote step) ------------------------
KNOWN_HOSTS="${ZB_WIN_KNOWN_HOSTS:-$HERE/known_hosts}"
ssh_opts() { # NUL-delimited ssh argv; $1=key
  printf '%s\0' ssh -i "$1" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$KNOWN_HOSTS" -o BatchMode=yes -o ConnectTimeout=15 \
    -o ServerAliveInterval=10
}

# Children never carry the Linux display (WS0.3). Every remote invocation goes through this.
run_remote() { # $@ = full ssh argv (already assembled); scrubs display vars from the child
  env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY "$@"
}

# ---- WS0.5 remote-path fence -------------------------------------------------------------
# Two layers:
#  1. STRING normalization — allowed(path) is true only if the normalized path is a strict
#     sub-path of the user's root, compared component-wise (so C:\Users\u\zbEVIL is NOT under
#     C:\Users\u\zb). ntpath normalizes Windows paths (slashes, .., drive, UNC) on Linux.
#  2. REPARSE/junction resolution — a junction under zb\ can resolve OUTSIDE the root while the
#     string still looks inside. When a resolver is configured (ZB_RESOLVE_CMD; on a host it maps
#     a path to its real resolved target), the resolved path must ALSO pass the string fence.
fence_str() { # $1 = path ; prints ALLOW or DENY for the STRING fence only
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

# The production reparse resolver (maps a path to its real on-host target, resolving junctions).
# ZB_RESOLVE_CMD only REPLACES it (for the selftest); it is never a way to skip resolution.
ZB_DEFAULT_RESOLVE_CMD="$HERE/resolve_path.sh"

allowed_path() { # $1 = path ; prints ALLOW or DENY. Resolution is MANDATORY and fails CLOSED.
  local p="$1"
  # Layer 1: the named lexical string fence.
  [ "$(fence_str "$p")" = "ALLOW" ] || { echo DENY; return 0; }
  # Layer 2: ALWAYS resolve reparse points (a junction under zb\ can target outside the root).
  local resolver="${ZB_RESOLVE_CMD:-$ZB_DEFAULT_RESOLVE_CMD}"
  local out rc
  out=$("$resolver" "$p" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then echo "allowed-path: resolver failed/missing (rc=$rc)" >&2; echo DENY; return 0; fi
  if [ -z "$out" ]; then echo "allowed-path: resolver returned empty output" >&2; echo DENY; return 0; fi
  case "$out" in *$'\n'*) echo "allowed-path: resolver returned multiline/malformed output" >&2; echo DENY; return 0 ;; esac
  [ "$(fence_str "$out")" = "ALLOW" ] || { echo "allowed-path: resolved path escapes the root" >&2; echo DENY; return 0; }
  echo ALLOW
}

# ---- WS0.2 fail-closed banner ------------------------------------------------------------
no_host_configured() { # $1 = space-separated names of the missing host variable(s)
  echo "NOT RUN: no Windows host configured (missing:$1)" >&2
  echo "        both ZB_WIN10_HOST and ZB_WIN11_HOST are required for the two-host gate" >&2
}

# ---- WS0.3 + WS0.8 stage-to-host ---------------------------------------------------------
# Tar the manifest and pipe it over ssh to the host's zb\runs\<id>\. The tar exit status is
# checked (pipefail); no `2>/dev/null` swallows it. StrictHostKeyChecking=yes pins the key.
selftest_stage() {
  local host="${ZB_WIN11_HOST:-${ZB_WIN10_HOST:-}}"
  local port="${ZB_WIN11_PORT:-22}"
  local user="${ZB_GUEST_USER:-}"
  local key="${ZB_WIN_KEY:-/home/maceo/vms/win11-m8/zb_win_key}"
  local -a SSH; mapfile -d '' SSH < <(ssh_opts "$key")
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
probe_host() { # $1=user $2=host $3=port -> prints the host's host_probe.ps1 JSON (display-scrubbed)
  local key="${ZB_WIN_KEY:-/home/maceo/vms/win11-m8/zb_win_key}"
  local -a SSH; mapfile -d '' SSH < <(ssh_opts "$key")
  run_remote "${SSH[@]}" -p "$3" "$1@$2" \
    "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File zb\\host_probe.ps1"
}

validate_probes() { # $1=vm_json $2=fs_pre $3=fs_post ; ALLOW to stdout, fail reason to stderr
  python3 - "$1" "$2" "$3" "${ZB_WIN11_MARKER:-}" "${ZB_WIN10_USER:-zbtest}" "${ZB_WIN10_MARKER:-}" "${ZB_WIN11_USER:-zbtext}" <<'PY'
import sys, json
vm, fs_pre, fs_post, win11_marker, win10_user, win10_marker, win11_user = sys.argv[1:8]
def _build_int(x):
    try: return int(str(x or "0").strip())
    except ValueError: return 0
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
if str(v.get("test_user", "")).split("\\")[-1].lower() != win11_user.lower():
    sys.stderr.write("win11: test_user %r is not %s\n" % (v.get("test_user"), win11_user)); sys.exit(1)
if _build_int(v.get("os_build")) < 22621:
    sys.stderr.write("win11: os_build %r is below the Windows 11 22H2 floor (22621)\n" % v.get("os_build")); sys.exit(1)
if not isinstance(v.get("webview2_pv"), str) or not v.get("webview2_pv").strip():
    sys.stderr.write("win11: webview2_pv missing or empty\n"); sys.exit(1)
if not isinstance(v.get("free_gb"), (int, float)) or isinstance(v.get("free_gb"), bool) or v.get("free_gb") < 20:
    sys.stderr.write("win11: free_gb %r is below 20\n" % v.get("free_gb")); sys.exit(1)
# snapshot_marker is NOT an in-VM probe field — a file inside the VM proves only that someone wrote a
# file, not that a rollback snapshot exists. The gate proves it host-side with read-only virsh (see
# probe_only); the physical file server has no VM snapshot and is explicitly not_applicable.

# WS0 is fail CLOSED: before ANY comparison, every file-server field we judge on must be present and
# well-typed on BOTH probes. Malformed/missing data must be rejected, never silently coerced to a value
# that compares "undisturbed". A bare `name or []` would let None/""/"bad"/["22"] masquerade as empty.
def _is_port_list(x):
    return isinstance(x, list) and all(isinstance(p, int) and not isinstance(p, bool) and 0 <= p <= 65535 for p in x)
def require_schema(probe, who):
    # identity: the file server must present the pinned Win10 marker (missing/empty/wrong => wrong host).
    mk = probe.get("identity_marker")
    if not mk or mk != win10_marker:
        sys.stderr.write("file-server (%s): identity_marker does not match ZB_WIN10_MARKER\n" % who); sys.exit(1)
    if not isinstance(probe.get("groups"), list):
        sys.stderr.write("file-server (%s): groups missing or not a list\n" % who); sys.exit(1)
    cu = probe.get("console_user")
    if not isinstance(cu, str) or not cu.strip():
        sys.stderr.write("file-server (%s): console_user missing or empty\n" % who); sys.exit(1)
    if not isinstance(probe.get("zbtest_write_paths"), list):
        sys.stderr.write("file-server (%s): zbtest_write_paths missing or not a list\n" % who); sys.exit(1)
    if not _is_port_list(probe.get("listeners")):
        sys.stderr.write("file-server (%s): listeners missing or not a list of ports\n" % who); sys.exit(1)
    fw = probe.get("fw_rules_hash")
    if not isinstance(fw, str) or not fw.strip():
        sys.stderr.write("file-server (%s): fw_rules_hash missing or empty\n" % who); sys.exit(1)
    # WS0-completion: the complete schema-2 fields the file-server fence judges on.
    if probe.get("schema") != 2:
        sys.stderr.write("file-server (%s): probe schema is %r, expected 2\n" % (who, probe.get("schema"))); sys.exit(1)
    if not isinstance(probe.get("shares"), list):
        sys.stderr.write("file-server (%s): shares missing or not a list\n" % who); sys.exit(1)
    if str(probe.get("test_user", "")).split("\\")[-1].lower() != win10_user.lower():
        sys.stderr.write("file-server (%s): test_user %r is not %s\n" % (who, probe.get("test_user"), win10_user)); sys.exit(1)
    if probe.get("native_arch") != "x64":
        sys.stderr.write("file-server (%s): native_arch %r, expected x64\n" % (who, probe.get("native_arch"))); sys.exit(1)
    if _build_int(probe.get("os_build")) < 19045:
        sys.stderr.write("file-server (%s): os_build %r is below the Windows 10 22H2 floor (19045)\n" % (who, probe.get("os_build"))); sys.exit(1)
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
wp = a.get("zbtest_write_paths")
if wp:
    sys.stderr.write("file-server: zbtest can write to %s\n" % wp[0]); sys.exit(1)
cu = str(a.get("console_user", "")).split("\\")[-1].lower()
if cu != win10_user.lower():
    sys.stderr.write("file-server: console user is %r, not %s\n" % (a.get("console_user"), win10_user)); sys.exit(1)
# The FULL listening-port set must be identical pre/post. No range exemption: a persistent listener on a
# high/"ephemeral" port is still a disturbance (a product service binding 50000 would otherwise slip past).
# Tolerating genuine OS dynamic-port churn needs ownership/PID identity, tracked as a plan item — not by
# discarding every high-port signal here. See thoughts/.../2026-10-20-ws07-file-server-field-design.md.
pre_ports = sorted(a.get("listeners")); post_ports = sorted(b.get("listeners"))
if pre_ports != post_ports:
    sys.stderr.write("file-server: listening ports changed %s -> %s\n" % (pre_ports, post_ports)); sys.exit(1)
if a.get("fw_rules_hash") != b.get("fw_rules_hash"):
    sys.stderr.write("file-server: firewall rules changed between pre and post\n"); sys.exit(1)
# WS0.7: the served shares themselves must be undisturbed pre/post (names/root paths), not just writable.
if sorted(a.get("shares")) != sorted(b.get("shares")):
    sys.stderr.write("file-server: served shares changed %s -> %s\n" % (sorted(a.get("shares")), sorted(b.get("shares")))); sys.exit(1)
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
  screated=$(printf '%s\n' "$sinfo" | sed -n 's/^Creation Time:[[:space:]]*//p')
  if [ "$sstate" != "shutoff" ]; then
    echo "NOT RUN: Win11 VM snapshot '$want' was taken in state '${sstate:-unknown}', not shutoff" >&2
    return 1
  fi
  echo "WS0.6: Win11 snapshot '$want' state=$sstate created='${screated:-unknown}'" >&2
  local vm_json fs_pre fs_post
  vm_json=$(probe_host "${ZB_WIN11_USER:-zbtext}" "$ZB_WIN11_HOST" "${ZB_WIN11_PORT:-2222}")
  fs_pre=$(probe_host "${ZB_WIN10_USER:-zbtest}" "$ZB_WIN10_HOST" "${ZB_WIN10_PORT:-22}")
  # A full gate runs the product tests here; --probe-only re-probes to catch any change (WS0.7).
  fs_post=$(probe_host "${ZB_WIN10_USER:-zbtest}" "$ZB_WIN10_HOST" "${ZB_WIN10_PORT:-22}")
  validate_probes "$vm_json" "$fs_pre" "$fs_post" >/dev/null || return 1
  printf 'WIN11 %s\nWIN10 %s\n' "$vm_json" "$fs_post"
  return 0
}

# ---- orchestration -----------------------------------------------------------------------
# Sub-commands that do NOT need the full two-host set:
case "${1:-}" in
  --fence-string)
    # The named LEXICAL seam (string normalization only), used by the WS0.5 property corpus.
    fence_str "${2:-}"
    exit 0
    ;;
  --allowed-path)
    # Full fence: lexical + MANDATORY reparse resolution (fails closed).
    allowed_path "${2:-}"
    exit 0
    ;;
  --selftest-stage)
    # Stages to the Win11 host only; needs just that one host variable.
    if [ -z "${ZB_WIN11_HOST:-}" ]; then
      echo "gate: --selftest-stage needs ZB_WIN11_HOST" >&2
      exit 1
    fi
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

case "${1:-}" in
  --probe-only)
    # WS0.6 (VM identity) + WS0.7 (file-server fence), both hosts. Live run needs the real probe +
    # the .gate-identity nonce; hermetically it runs against the selftest's fake ssh/virsh.
    probe_only
    exit $?
    ;;
  "")
    echo "gate: two-host run not implemented yet (needs the Win10 host); WS0 foundation only" >&2
    exit 2
    ;;
  *)
    echo "gate: unknown argument: $1" >&2
    exit 2
    ;;
esac
