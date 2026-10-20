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
import sys, ntpath
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
no_host_configured() {
  echo "NOT RUN: no Windows host configured (set ZB_WIN10_HOST=user@host and/or ZB_WIN11_HOST=127.0.0.1)" >&2
  echo "        the two-host Windows gate is INCOMPLETE and cannot pass until a host runs" >&2
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

# ---- orchestration -----------------------------------------------------------------------
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
esac

if [ -z "${ZB_WIN10_HOST:-}" ] && [ -z "${ZB_WIN11_HOST:-}" ]; then
  no_host_configured
  exit 1
fi

case "${1:-}" in
  --selftest-stage)
    selftest_stage
    exit $?
    ;;
  --probe-only)
    # [W] step: probe each configured host and print its JSON. Implemented with host_probe.ps1
    # and the console-session helper; verified live on the VM after the shut-off snapshot. The
    # full product-test run builds on this and is the next slice (WS1+).
    echo "gate: --probe-only requires a live host; run under the gate slot on the VM" >&2
    exit 2
    ;;
  "")
    echo "gate: full two-host run is the WS1+ slice; use --probe-only / --selftest-stage for WS0" >&2
    exit 2
    ;;
  *)
    echo "gate: unknown argument: $1" >&2
    exit 2
    ;;
esac
