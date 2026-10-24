#!/usr/bin/env bash
# Registered hostless argv oracle (SilverRidge a8bac4d6, 353222dc): every production Mac ssh/scp construction must
# ignore both user and system ssh configuration by passing the two real arguments `-F none`.  This oracle augments
# the existing executing transport fixtures rather than parsing production source: their ssh/scp stubs record NUL-
# delimited argv from the real scripts, including the exact-commit launchers.  It retains their full direct-command
# census, configured-host, pinned-known-hosts, BatchMode, IdentitiesOnly, no-askpass and non-vacuity checks, and adds:
#   F1 every recorded call has exactly one two-argument `-F none` before its first positional operand;
#   F2 every recorded call has exactly one `-i`, whose following argv element is the configured fake key.
#   F3 both generated parser branches reject late, wrong, missing, duplicate and attached `-F` forms for ssh/scp.
# The direct fixture covers every independent Mac ssh/scp construction, evaluating (never running) the destructive
# ms6_5 reaper.  The two MS5 fixtures cover their separately-driven construction sites.  The shared fixture drives
# both build-on-mac.sh's private ssh argv and mac_gate_lib.sh's mac_ssh_opts/mac_scp_opts through build-dmg.sh.
# No Mac, browser, display client or signal.  HOME/TMPDIR are private; every real script runs behind recording stubs
# in a private user/network namespace.  Run: bash tests/mac/mac_ssh_config_none_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_SSH_CONFIG_NONE_SELFTEST_INNER:-}" != 1 ]; then
  ZB_SSH_CONFIG_NONE_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi

ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-ssh-config-none-selftest-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-ssh-config-none-selftest-??????) rm -rf -- "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

# Make private, instrumented copies of already-registered hostless fixtures.  Exact replacement counts make any
# fixture-parser drift fail closed.  Production scripts are never changed here.
instrument() { # instrument <kind: direct|shared> <source> <destination>
  local kind=$1 src=$2 dst=$3
  python3 - "$kind" "$src" "$dst" <<'PY'
from pathlib import Path
import sys

kind, src, dst = sys.argv[1:]
text = Path(src).read_text()

def once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"instrumentation anchor {label!r}: found {count}, want 1")
    text = text.replace(old, new)

guard = r'''zb_config_none_before_operand() { # argv: tool, then its arguments
  local -a argv=("$@") configs=()
  local j
  for ((j = 1; j < ${#argv[@]}; j++)); do
    case "${argv[j]}" in
      -F)
        [ $((j + 1)) -lt "${#argv[@]}" ] || return 1
        configs+=("${argv[j+1]}"); j=$((j + 1)) ;;
      -i|-o)
        [ $((j + 1)) -lt "${#argv[@]}" ] || return 1
        j=$((j + 1)) ;;
      --) break ;;
      -*) ;;
      *) break ;;
    esac
  done
  [ "${#configs[@]}" -eq 1 ] && [ "${configs[0]}" = none ]
}

zb_config_none_controls() { # prove this generated branch rejects non-isolating placements and forms
  local label=$1 tool control_bad=0
  for tool in ssh scp; do
    if [ "$tool" = ssh ]; then
      zb_config_none_before_operand ssh -F none -i /fake -o BatchMode=yes user@host true \
        || { printf 'FAIL F3: %s valid ssh argv was rejected\n' "$label"; control_bad=$((control_bad + 1)); }
      zb_config_none_before_operand ssh -i /fake -o BatchMode=yes user@host true -F none \
        && { printf 'FAIL F3: %s accepted late ssh -F none\n' "$label"; control_bad=$((control_bad + 1)); }
      zb_config_none_before_operand ssh -F user.conf -i /fake user@host true \
        && { printf 'FAIL F3: %s accepted wrong ssh -F value\n' "$label"; control_bad=$((control_bad + 1)); }
      zb_config_none_before_operand ssh -i /fake -F \
        && { printf 'FAIL F3: %s accepted missing ssh -F value\n' "$label"; control_bad=$((control_bad + 1)); }
      zb_config_none_before_operand ssh -F none -F none -i /fake user@host true \
        && { printf 'FAIL F3: %s accepted duplicate ssh -F pairs\n' "$label"; control_bad=$((control_bad + 1)); }
      zb_config_none_before_operand ssh -Fnone -i /fake user@host true \
        && { printf 'FAIL F3: %s accepted attached ssh -Fnone\n' "$label"; control_bad=$((control_bad + 1)); }
    else
      zb_config_none_before_operand scp -F none -i /fake -o BatchMode=yes /local user@host:path \
        || { printf 'FAIL F3: %s valid scp argv was rejected\n' "$label"; control_bad=$((control_bad + 1)); }
      zb_config_none_before_operand scp -i /fake -o BatchMode=yes /local user@host:path -F none \
        && { printf 'FAIL F3: %s accepted late scp -F none\n' "$label"; control_bad=$((control_bad + 1)); }
      zb_config_none_before_operand scp -F user.conf -i /fake /local user@host:path \
        && { printf 'FAIL F3: %s accepted wrong scp -F value\n' "$label"; control_bad=$((control_bad + 1)); }
      zb_config_none_before_operand scp -i /fake -F \
        && { printf 'FAIL F3: %s accepted missing scp -F value\n' "$label"; control_bad=$((control_bad + 1)); }
      zb_config_none_before_operand scp -F none -F none -i /fake /local user@host:path \
        && { printf 'FAIL F3: %s accepted duplicate scp -F pairs\n' "$label"; control_bad=$((control_bad + 1)); }
      zb_config_none_before_operand scp -Fnone -i /fake /local user@host:path \
        && { printf 'FAIL F3: %s accepted attached scp -Fnone\n' "$label"; control_bad=$((control_bad + 1)); }
    fi
  done
  if [ "$control_bad" -eq 0 ]; then ok "F3 $label parser rejects late/wrong/missing/duplicate/attached ssh and scp forms"
  else bad "F3 $label parser accepted $control_bad invalid form(s)"; fi
}
'''

def install_guard(anchor: str, label: str) -> None:
    global text
    once(anchor, guard + "\n" + anchor, f"{label} guard insertion")
    final = text.rfind('\nif [ "$fails" -eq 0 ]; then')
    if final < 0:
        raise SystemExit(f"instrumentation anchor {label!r}: final verdict not found")
    text = text[:final] + f"\nzb_config_none_controls {label}\n" + text[final:]

if kind == "direct":
    once(
        'tool=${a[0]} host= skip= strict=() khf=() batch=() ident=() pos=()',
        'tool=${a[0]} host= skip= strict=() khf=() batch=() ident=() identity=() pos=()',
        "direct argv reset",
    )
    once(
        '-i|-F|-p|-P|-l|-c|-J) skip=1; continue ;;',
        '-i) identity+=("${a[j+1]:-}"); skip=1; continue ;;\n'
        '        -F) skip=1; continue ;;\n'
        '        -p|-P|-l|-c|-J) skip=1; continue ;;',
        "direct option parser",
    )
    needle = '[ "${ident[*]}" = yes ] || bad "H3: $where IdentitiesOnly is \'${ident[*]}\', want yes"'
    once(
        needle,
        needle + '\n'
        '    [ "${#identity[@]}" -eq 1 ] && [ "${identity[0]}" = "$T/fake_mac_key" ] '
        '|| bad "F2: $where identity is \'${identity[*]}\', want the configured fake key"\n'
        '    zb_config_none_before_operand "${a[@]}" '
        '|| bad "F1: $where lacks exactly one option-position -F none"',
        "direct assertions",
    )
    for anchor in ("check_calls() {", "check() {", "declare -A seen=()"):
        if text.count(anchor) == 1:
            install_guard(anchor, "direct")
            break
    else:
        raise SystemExit("instrumentation anchor 'direct guard': no checker anchor found")
elif kind == "shared":
    once(
        'tool=${a[0]} skip= strict=() khf=() batch=() ident=()',
        'tool=${a[0]} host= skip= strict=() khf=() batch=() ident=() identity=() pos=()',
        "shared argv reset",
    )
    once(
        'case "${a[j]}" in -o) opt=${a[j+1]:-}; skip=1 ;; -o?*) opt=${a[j]#-o} ;; '
        '-i|-F|-p|-P|-l|-c|-J) skip=1; continue ;; *) continue ;; esac',
        'case "${a[j]}" in -o) opt=${a[j+1]:-}; skip=1 ;; -o?*) opt=${a[j]#-o} ;; '
        '-i) identity+=("${a[j+1]:-}"); skip=1; continue ;; '
        '-F) skip=1; continue ;; '
        '-p|-P|-l|-c|-J) skip=1; continue ;; -*) continue ;; *) pos+=("${a[j]}"); continue ;; esac',
        "shared option parser",
    )
    once(
        'where="$label call $i ($tool)"',
        'if [ "$tool" = ssh ]; then host=${pos[0]:-}; else\n'
        '      for p in "${pos[@]}"; do case "$p" in *:*) if [ -z "$host" ]; then host=${p%%:*}; '
        'elif [ "${p%%:*}" != "$host" ]; then host=mixed; fi ;; esac; done\n'
        '    fi\n'
        '    where="$label call $i ($tool $host)"\n'
        '    [ "$host" = "$HOST" ] || [ "$host" = "$ARM" ] || bad "F2: $where is not a configured host"',
        "shared host",
    )
    needle = '[ "${ident[*]}" = yes ] || bad "T2: $where IdentitiesOnly is \'${ident[*]}\', want yes"'
    once(
        needle,
        needle + '\n'
        '    [ "${#identity[@]}" -eq 1 ] && [ "${identity[0]}" = "$T/fake_mac_key" ] '
        '|| bad "F2: $where identity is \'${identity[*]}\', want the configured fake key"\n'
        '    zb_config_none_before_operand "${a[@]}" '
        '|| bad "F1: $where lacks exactly one option-position -F none"',
        "shared assertions",
    )
    install_guard("check() {", "shared")
else:
    raise SystemExit(f"unknown instrumentation kind: {kind}")

Path(dst).write_text(text)
PY
}

mkdir -p "$T/bin" "$T/home" "$T/tmp"
cases=(
  "direct|tests/mac/mac_direct_transport_hostkey_selftest.sh|ZB_DIRECT_HOSTKEY_SELFTEST_INNER"
  "direct|tests/mac/ms5_gate_hostkey_selftest.sh|ZB_MS5HOSTKEY_SELFTEST_INNER"
  "direct|tests/mac/ms5_setup_hostkey_selftest.sh|ZB_MS5SETUPHOSTKEY_SELFTEST_INNER"
  "shared|tests/mac/mac_transport_selftest.sh|ZB_TRANSPORT_SELFTEST_INNER"
)

for row in "${cases[@]}"; do
  IFS='|' read -r kind rel inner_var <<<"$row"
  name=$(basename "$rel" .sh)
  out="$T/$name.out"
  copy="$T/$name.sh"
  if ! instrument "$kind" "$ROOT/$rel" "$copy" >"$T/instrument.out" 2>&1; then
    bad "$rel could not be instrumented: $(tr '\n' ' ' < "$T/instrument.out")"
    continue
  fi
  chmod +x "$copy"
  env -i PATH=/usr/bin:/bin HOME="$T/home" TMPDIR="$T/tmp" "$inner_var=1" \
    timeout -s TERM 600 bash "$copy" "$ROOT" >"$out" 2>&1 </dev/null
  rc=$?
  f3=$(grep -c '^ok   F3 ' "$out" 2>/dev/null || true)
  [ "$f3" -eq 1 ] || bad "$name: F3 parser controls did not run and pass exactly once (got $f3)"
  if [ "$rc" -eq 0 ] && grep -q '^PASS' "$out" && ! grep -q '^FAIL ' "$out"; then
    ok "$name: every driven argv has the exact host/key/config and retained protections; F3 controls pass"
  else
    n=$(grep -c '^FAIL ' "$out" 2>/dev/null || true)
    nf=$(grep -c '^FAIL F1:' "$out" 2>/dev/null || true)
    other=$((n - nf))
    bad "$name: exit $rc with $nf missing--F argv row(s), $other other failing row(s)"
    grep '^FAIL ' "$out" | sed -n '1,6{s/^/    /;p;}'
  fi
done

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-ssh-config-none-selftest\n'; exit 0; fi
printf 'FAIL\tmac-ssh-config-none-selftest\t%s failure(s)\n' "$fails"
exit 1
