#!/usr/bin/env bash
# UNREGISTERED RED for bd zigBrowser-3ui.14.
#
# Each listed two-host gate is run for real against executing ssh/scp stubs. The stubs classify the intended remote
# test call (the one whose command ends in /bin/bash -s), record its host, consume all stdin, and can deliver the
# gate's exact remote-owned success records only at that boundary. Empty, wrong-call, wrong-marker and one-arch
# modes are accepted only when the gate returns ordinary status 1 with its exact gate-owned host/arch refusal rows;
# a timeout, signal, preflight/unrelated failure, unconditional overall=1 or a PASS from the wrong call cannot pass.
# Exact-positive mode must reach one intended leg per host and produce exactly one gate-level both-arches PASS.
#
# Scope is the issue's 20 affected gates. tests/mac/ms_runtime_rows_gate.sh is owned elsewhere and excluded.
# tests/mac/ms6_5_reaper_gate.sh is destructive, is not in the issue list, and is never run here.
# This test stays unregistered until its GREEN is approved. ZB_EMPTY_OUTPUT_SELFTEST_ONLY selects one gate by
# basename for isolated mutants; omitting it preserves the fixed twenty-gate census.
set -uo pipefail

: "${HOME:?run with a private HOME}"
: "${TMPDIR:?run with a private TMPDIR}"
ROOT=$(realpath "${1:-.}")
tmp_root=$(realpath "$TMPDIR")
BASE=$(mktemp -d "$tmp_root/zb-mac-empty-output-XXXXXX") || exit 1
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$tmp_root"/zb-mac-empty-output-??????) rm -rf -- "${T:?}" ;; esac
}
trap cleanup EXIT

fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1
ARM=arm@10.0.0.2

# script | local provenance stubs (pin for the two python.org package gates)
GATES=(
  "tests/mac/ms2a_gate.sh|-"
  "tests/mac/ms2b_gate.sh|-"
  "tests/mac/ms2c_gate.sh|-"
  "tests/mac/ms3_gate.sh|-"
  "tests/mac/ms4_gate.sh|-"
  "tests/mac/ms5_gate.sh|-"
  "tests/mac/ms5_deps_gate.sh|pin"
  "tests/mac/ms5_kill_group_gate.sh|-"
  "tests/mac/ms5_r1_env_gate.sh|-"
  "tests/mac/ms5_relocate_gate.sh|pin"
  "tests/mac/ms5_setup_e2e.sh|-"
  "tests/mac/ms5_setup_refusal_gate.sh|-"
  "tests/mac/ms5_spawn_gate.sh|-"
  "tests/mac/ms5_spawn_io_gate.sh|-"
  "tests/mac/ms5_token_fd_gate.sh|-"
  "tests/mac/ms6_5_reaper_census_gate.sh|-"
  "tests/mac/ms6_gate.sh|-"
  "tests/mac/ms6_harness_mac_gate.sh|-"
  "tests/mac/ms6_netd_darwin_gate.sh|-"
  "tests/mac/ms6_r1_kernel_gate.sh|-"
)
[ "${#GATES[@]}" -eq 20 ] || { echo "selftest error: gate census is ${#GATES[@]}, want 20" >&2; exit 2; }

mkdir -p "$T/bin" "$T/prov" "$T/home" "$T/keys"
cat > "$T/bin/transport" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
tool=${0##*/}
c=${ZB_EMPTY_OUTPUT_CTL:?}
i=$(cat "$c/n" 2>/dev/null || echo 0)
echo $((i + 1)) > "$c/n"
printf '%s\0' "$tool" "$@" > "$c/call.$i"
if [ "$tool" = ssh ]; then
  cat > "$c/stdin.$i"
  joined=" $* "
  kind=other
  case "$joined" in *' /bin/bash -s '*) kind=leg ;; esac
  printf '%s\n' "$kind" > "$c/kind.$i"
  host=
  for arg in "$@"; do
    [ "$arg" = "${ZB_INTEL_HOST:-}" ] && host=$arg
    [ "$arg" = "${ZB_ARM_HOST:-}" ] && host=$arg
  done
  printf '%s\n' "$host" > "$c/host.$i"
  emit_success() {
    local arch=x86_64
    [ "$host" = "${ZB_ARM_HOST:-}" ] && arch=arm64
    case "${ZB_GATE_NAME:?}" in
      ms2a_gate) printf '%s\n' \
        $'PASS\tms2a-routed-commands' $'PASS\tms2a-private-world' $'PASS\tms2a-abi-census' \
        $'PASS\tms2a-late-completion' $'PASS\tms2a-string-ownership' $'PASS\tms2a-str-accounting' \
        $'PASS\tms2a-hang-guard' $'PASS\tms2a.2-nav-failure' $'PASS\tms2a-dispatch-race' \
        $'PASS\tms2a-immediate-quit' $'PASS\tms2a-teardown-reap' $'PASS\tms2a-refused-start' \
        $'PASS\tms2a-user-nav-failure' $'PASS\tms2a-hook-inert' $'PASS\tms2a-stale-callback' \
        $'PASS\tms2a-stale-failure' ;;
      ms2b_gate) printf '%s\n' \
        $'PASS\tms2b-key-table-parity\t(31 names)' $'PASS\tms2b.1a-native-click' \
        $'PASS\tms2b.1b-key-text' $'PASS\tms2b-key-coverage' $'PASS\tms2b-ack-error' \
        $'PASS\tms2b-doc-changed' $'PASS\tms2b-text-doc-changed-selftest' \
        $'PASS\tms2b-text-doc-changed' $'PASS\tms2b-partial-type' $'PASS\tms2b-pair-race' \
        $'PASS\tms2b-ack-hang' $'PASS\tms2b-dialogs' $'PASS\tms2b-eval-dialog' ;;
      ms2c_gate) printf '%s\n' \
        $'PASS\tms2c-list-windows' $'PASS\tms2c-stable-ids' $'PASS\tms2c-window-fifo' \
        $'PASS\tms2c-popup-chain' $'PASS\tms2c-loading' $'PASS\tms2c-process-group' \
        $'PASS\tms2c-oob-during-stuck' $'PASS\tms2c-snapshot-oob' $'PASS\tms2c-dialog-snapshot' \
        $'PASS\tms2c-script-close' $'PASS\tms2c-health' $'PASS\tms2c-close-window' \
        $'PASS\tms2c-crash' $'PASS\tms2c-crash-controls' $'PASS\tms2c-recover' \
        $'PASS\tms2c-recover-dialog' $'PASS\tms2c-recover-stale-health' ;;
      ms3_gate) printf '%s\n' $'PASS\tms3-cookie' $'PASS\tms3-config-flags' \
        $'PASS\tms3-profile-persist' $'PASS\tms3-profile-cwd-isolation' ;;
      ms4_gate) printf '%s\n' $'PASS\tms4-load-serial' $'PASS\tms4.4-login-gate' ;;
      ms5_gate) printf '%s\n' $'PASS\tms5-keychain-seam' $'PASS\tms5-keychain-zigport' ;;
      ms5_deps_gate) printf 'PASS\tms5-deps\t%s\n' "$arch" ;;
      ms5_kill_group_gate) printf 'PASS\tkill-group\t8 cases\n' ;;
      ms5_r1_env_gate) printf 'PASS\tms5-r1-env\t5 cases\n' ;;
      ms5_relocate_gate) printf 'PASS\tms5-relocate\t%s\n' "$arch" ;;
      ms5_setup_e2e) printf 'PASS\tms5-setup-e2e\t%s\n' "$arch" ;;
      ms5_setup_refusal_gate) printf 'PASS\tms5-setup-refusal\t%s\n' "$arch" ;;
      ms5_spawn_gate) printf 'PASS\tms5-spawn-group\t2 cases\n' ;;
      ms5_spawn_io_gate) printf 'PASS\tms5-spawn-io\t4 cases\n' ;;
      ms5_token_fd_gate) printf 'PASS\tms5-token-fd\t5 cases\n' ;;
      ms6_5_reaper_census_gate) printf 'PASS ms6-5-reaper-census 18 checks\n' ;;
      ms6_gate) printf '%s\n' $'PASS\tms6-containment' $'PASS\tms6.1-token-isolation' \
        $'PASS\tms6-generated-profiles' \
        $'PASS\tms6-3-fd3-reopen-PROBE (partial; MS6.3 real-CLI hard gate pending the MS5-gated harness)' \
        $'PASS\tms6-4-egress' ;;
      ms6_harness_mac_gate) printf 'PASS\tms6-harness-mac\t%s\t19 tests, none skipped, 0 ResourceWarning\n' "$arch" ;;
      ms6_netd_darwin_gate) printf 'PASS\tms6-netd-darwin\t7 cases\n' ;;
      ms6_r1_kernel_gate) printf 'PASS\tms6-r1-kernel\tkernel properties\n' ;;
      *) exit 92 ;;
    esac
  }
  emit=none
  mode=${ZB_GATE_OUTPUT_MODE:-empty}
  [ "${ZB_EMPTY_OUTPUT_TRANSPORT_FAULT:-}" = timeout ] && [ "$mode" = empty ] && mode=timeout
  case "$mode" in
    empty) ;;
    exact) [ "$kind" = leg ] && { emit=exact; emit_success; } ;;
    one_arch) [ "$kind" = leg ] && [ "$host" = "${ZB_INTEL_HOST:-}" ] && { emit=exact; emit_success; } ;;
    wrong_call) [ "$kind" = other ] && [ -n "$host" ] && { emit=wrong-call; emit_success; } ;;
    wrong_marker) [ "$kind" = leg ] && { emit=wrong-marker; printf 'PASS\twrong-remote-test\t%s\t%s\n' "${ZB_GATE_NAME:?}" "$host"; } ;;
    timeout) if [ "$kind" = leg ]; then printf 'timeout\n' > "$c/emit.$i"; exit 124; fi ;;
    *) exit 91 ;;
  esac
  printf '%s\n' "$emit" > "$c/emit.$i"
else
  dst="${@: -1}"
  src="${@: -2:1}"
  case "$dst" in
    *:*) ;;
    *) if [ -d "$dst" ]; then : > "$dst/$(basename "${src#*:}")"; else : > "$dst"; fi ;;
  esac
fi
exit 0
EOF
cp -f "$T/bin/transport" "$T/bin/ssh"
cp -f "$T/bin/transport" "$T/bin/scp"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/zig"

cat > "$T/prov/curl" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do [ "$1" = -o ] && { echo stub > "$2"; shift; }; shift; done
exit 0
EOF
cat > "$T/prov/uv" <<'EOF'
#!/usr/bin/env bash
prev=
for a in "$@"; do
  case "$prev" in --target) mkdir -p "$a" ;; -o) : > "$a" ;; esac
  prev=$a
done
exit 0
EOF
cat > "$T/prov/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -m ] && [ "${2:-}" = venv ]; then
  mkdir -p "$3/bin"
  for t in pip python; do printf '#!/usr/bin/env sh\nexit 0\n' > "$3/bin/$t"; chmod +x "$3/bin/$t"; done
fi
cat > /dev/null
exit 0
EOF
cat > "$T/prov/sha256sum" <<'EOF'
#!/usr/bin/env bash
[ -n "${ZB_STUB_SHA256:-}" ] && printf '%s  %s\n' "$ZB_STUB_SHA256" "${1:--}"
exit 0
EOF
chmod +x "$T"/bin/* "$T"/prov/*

KEYF="$T/keys/fake_mac_key"
printf 'not a real key\n' > "$KEYF"
chmod 600 "$KEYF"

# Several gates archive HEAD before invoking transport, so give every run an isolated committed copy.
R="$T/repo"
mkdir -p "$R"
for p in src tests packaging agent tools build.zig build.zig.zon zigbrowser.json; do
  [ -e "$ROOT/$p" ] && cp -Rf "$ROOT/$p" "$R/"
done
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { echo "selftest error: could not build the scratch repo" >&2; exit 2; }
REPO_SHA=$("${G[@]}" rev-parse HEAD) || exit 2

calls_of() { cat "$1/n" 2>/dev/null || echo 0; }
call_meta_count() { # <control dir> <host> <kind|*> <emit|*>
  local c=$1 want_host=$2 want_kind=$3 want_emit=$4 n i kind host emit count=0
  n=$(calls_of "$c")
  for ((i = 0; i < n; i++)); do
    [ -f "$c/kind.$i" ] || continue
    kind=$(cat "$c/kind.$i")
    host=$(cat "$c/host.$i")
    emit=$(cat "$c/emit.$i")
    [ "$host" = "$want_host" ] || continue
    [ "$want_kind" = '*' ] || [ "$kind" = "$want_kind" ] || continue
    [ "$want_emit" = '*' ] || [ "$emit" = "$want_emit" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

line_count() { # <file> <exact line>
  awk -v want="$2" '$0 == want { n++ } END { print n + 0 }' "$1"
}

both_arch_pass_count() {
  awk -F '\t' '$1 == "PASS" { for (i = 2; i <= NF; i++) if ($i == "both-arches") { n++; break } }
                  END { print n + 0 }' "$1"
}

leg_pass_count() {
  awk -F '\t' '$1 == "PASS" && $2 ~ /-leg$/ { n++ } END { print n + 0 }' "$1"
}

refusal_count() {
  awk -F '\t' '$1 == "FAIL" && $2 == "remote-success" { n++ } END { print n + 0 }' "$1"
}

refusal_line() { printf 'FAIL\tremote-success\t%s\t%s\t%s\tmissing' "$1" "$2" "$3"; }

top_line() { # <gate basename>
  case "$1" in
    ms2a_gate) printf 'PASS\tms2a-gate\tboth-arches' ;;
    ms2b_gate) printf 'PASS\tms2b-gate\tboth-arches' ;;
    ms2c_gate) printf 'PASS\tms2c-gate\tboth-arches' ;;
    ms3_gate) printf 'PASS\tms3-gate\tboth-arches' ;;
    ms4_gate) printf 'PASS\tms4-gate\tboth-arches' ;;
    ms5_gate) printf 'PASS\tms5-gate\tboth-arches' ;;
    ms5_deps_gate) printf 'PASS\tms5-deps-gate\tboth-arches' ;;
    ms5_kill_group_gate) printf 'PASS\tms5-kill-group-gate\tboth-arches' ;;
    ms5_r1_env_gate) printf 'PASS\tms5-r1-env-gate\tboth-arches' ;;
    ms5_relocate_gate) printf 'PASS\tms5-relocate-gate\tboth-arches' ;;
    ms5_setup_e2e) printf 'PASS\tms5-setup-e2e\tboth-arches\t%s' "$REPO_SHA" ;;
    ms5_setup_refusal_gate) printf 'PASS\tms5-setup-refusal-gate\tboth-arches\t%s' "$REPO_SHA" ;;
    ms5_spawn_gate) printf 'PASS\tms5-spawn-gate\tboth-arches' ;;
    ms5_spawn_io_gate) printf 'PASS\tms5-spawn-io-gate\tboth-arches' ;;
    ms5_token_fd_gate) printf 'PASS\tms5-token-fd-gate\tboth-arches' ;;
    ms6_5_reaper_census_gate) printf 'PASS\tms6-5-reaper-census-gate\tboth-arches' ;;
    ms6_gate) printf 'PASS\tms6-containment-probe-gate\tboth-arches\t(not the MS6 hard gates: MS6.3 and MS6.6(B) are NOT ARMED; seatbelt_ready needs the complete gate)' ;;
    ms6_harness_mac_gate) printf 'PASS\tms6-harness-mac-gate\tboth-arches' ;;
    ms6_netd_darwin_gate) printf 'PASS\tms6-netd-darwin-gate\tboth-arches' ;;
    ms6_r1_kernel_gate) printf 'PASS\tms6-r1-kernel-gate\tboth-arches' ;;
    *) return 2 ;;
  esac
}

run_gate() { # run_gate <script> <provenance mode> <transport mode>; sets C and RC
  local script=$1 prov=$2 mode=$3 name pb pin=
  name=$(basename "$script" .sh)
  C="$T/case.$name.$mode"
  mkdir -p "$C/home" "$C/tmp"
  pb="$T/bin"
  if [ "$prov" = pin ]; then
    pb="$T/prov:$T/bin"
    pin=$(sed -n 's/^PIN=\([0-9a-f]\{64\}\)$/\1/p' "$R/$script" | head -n 1)
  fi
  (cd "$R" && env -i PATH="$pb:/usr/bin:/bin" HOME="$C/home" TMPDIR="$C/tmp" GIT_CONFIG_NOSYSTEM=1 \
     ZB_EMPTY_OUTPUT_CTL="$C" ZB_STUB_SHA256="$pin" ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" \
     ZB_INTEL_HOST="$INTEL" ZB_ARM_HOST="$ARM" ZB_GATE_NAME="$name" ZB_GATE_OUTPUT_MODE="$mode" \
     ZB_EMPTY_OUTPUT_TRANSPORT_FAULT="${ZB_EMPTY_OUTPUT_TRANSPORT_FAULT:-}" \
     ZB_MAC_KEY="$KEYF" ZB_MAC_BUILD_TIMEOUT=10 ZB_MAC_LEG_TIMEOUT=10 \
     timeout -s TERM 120 bash "$script" > "$C/out" 2>&1 </dev/null)
  RC=$?
}

# Self-control: both transport fixtures succeed and emit exactly zero bytes.
for tool in ssh scp; do
  control="$T/control.$tool"
  mkdir -p "$control"
  if [ "$tool" = ssh ]; then
    stub_out=$(ZB_EMPTY_OUTPUT_CTL="$control" "$T/bin/ssh" "$INTEL" /bin/true </dev/null 2>&1)
  else
    stub_out=$(ZB_EMPTY_OUTPUT_CTL="$control" "$T/bin/scp" "$KEYF" "$INTEL:/tmp/empty-output" </dev/null 2>&1)
  fi
  stub_rc=$?
  if [ "$stub_rc" -eq 0 ] && [ -z "$stub_out" ]; then ok "control: $tool stub exits 0 with empty output"
  else bad "control: $tool stub rc=$stub_rc output='$stub_out'"; fi
done

violating=0
selected=0
only=${ZB_EMPTY_OUTPUT_SELFTEST_ONLY:-}
for row in "${GATES[@]}"; do
  IFS='|' read -r script prov <<<"$row"
  name=$(basename "$script" .sh)
  [ -z "$only" ] || [ "$name" = "$only" ] || continue
  selected=$((selected + 1))
  problems=()
  expected_top=$(top_line "$name") || { echo "selftest error: no top line for $name" >&2; exit 2; }

  for mode in empty wrong_call wrong_marker one_arch exact; do
    run_gate "$script" "$prov" "$mode"
    intel_legs=$(call_meta_count "$C" "$INTEL" leg '*')
    arm_legs=$(call_meta_count "$C" "$ARM" leg '*')
    top=$(line_count "$C/out" "$expected_top")
    all_top=$(both_arch_pass_count "$C/out")
    refs=$(refusal_count "$C/out")
    intel_ref=$(line_count "$C/out" "$(refusal_line "$name" "$INTEL" x86_64)")
    arm_ref=$(line_count "$C/out" "$(refusal_line "$name" "$ARM" arm64)")
    leg_passes=$(leg_pass_count "$C/out")

    [ "$intel_legs" -eq 1 ] && [ "$arm_legs" -eq 1 ] \
      || problems+=("$mode intended-legs=$intel_legs/$arm_legs")
    case "$mode" in
      exact)
        intel_emit=$(call_meta_count "$C" "$INTEL" leg exact)
        arm_emit=$(call_meta_count "$C" "$ARM" leg exact)
        intel_other=$(call_meta_count "$C" "$INTEL" other exact)
        arm_other=$(call_meta_count "$C" "$ARM" other exact)
        [ "$intel_emit" -eq 1 ] && [ "$arm_emit" -eq 1 ] && [ "$intel_other" -eq 0 ] && [ "$arm_other" -eq 0 ] \
          || problems+=("exact delivery=$intel_emit/$arm_emit wrong-call=$intel_other/$arm_other")
        [ "$RC" -eq 0 ] && [ "$top" -eq 1 ] && [ "$all_top" -eq 1 ] && [ "$refs" -eq 0 ] \
          || problems+=("exact rc=$RC expected-top=$top all-top=$all_top refusals=$refs")
        ;;
      empty|wrong_call|wrong_marker)
        [ "$RC" -eq 1 ] && [ "$top" -eq 0 ] && [ "$all_top" -eq 0 ] && [ "$leg_passes" -eq 0 ] \
          && [ "$refs" -eq 2 ] && [ "$intel_ref" -eq 1 ] && [ "$arm_ref" -eq 1 ] \
          || problems+=("$mode rc=$RC refusals=$refs($intel_ref/$arm_ref) leg-pass=$leg_passes top=$top/$all_top")
        if [ "$mode" = empty ]; then
          intel_emit=$(call_meta_count "$C" "$INTEL" leg none)
          arm_emit=$(call_meta_count "$C" "$ARM" leg none)
          [ "$intel_emit" -eq 1 ] && [ "$arm_emit" -eq 1 ] \
            || problems+=("empty delivery=$intel_emit/$arm_emit")
        elif [ "$mode" = wrong_call ]; then
          intel_emit=$(call_meta_count "$C" "$INTEL" other wrong-call)
          arm_emit=$(call_meta_count "$C" "$ARM" other wrong-call)
          intel_leg_emit=$(call_meta_count "$C" "$INTEL" leg wrong-call)
          arm_leg_emit=$(call_meta_count "$C" "$ARM" leg wrong-call)
          [ "$intel_emit" -ge 1 ] && [ "$arm_emit" -ge 1 ] && [ "$intel_leg_emit" -eq 0 ] && [ "$arm_leg_emit" -eq 0 ] \
            || problems+=("wrong-call delivery=$intel_emit/$arm_emit leg=$intel_leg_emit/$arm_leg_emit")
        else
          intel_emit=$(call_meta_count "$C" "$INTEL" leg wrong-marker)
          arm_emit=$(call_meta_count "$C" "$ARM" leg wrong-marker)
          [ "$intel_emit" -eq 1 ] && [ "$arm_emit" -eq 1 ] \
            || problems+=("wrong-marker delivery=$intel_emit/$arm_emit")
        fi
        ;;
      one_arch)
        intel_emit=$(call_meta_count "$C" "$INTEL" leg exact)
        arm_emit=$(call_meta_count "$C" "$ARM" leg none)
        [ "$intel_emit" -eq 1 ] && [ "$arm_emit" -eq 1 ] \
          || problems+=("one-arch delivery=$intel_emit/$arm_emit")
        [ "$RC" -eq 1 ] && [ "$top" -eq 0 ] && [ "$all_top" -eq 0 ] \
          && [ "$refs" -eq 1 ] && [ "$intel_ref" -eq 0 ] && [ "$arm_ref" -eq 1 ] \
          || problems+=("one-arch rc=$RC refusals=$refs($intel_ref/$arm_ref) top=$top/$all_top")
        ;;
    esac
  done

  if [ "${#problems[@]}" -eq 0 ]; then
    ok "$name: two causal refusals; exact two-leg positive; wrong-call/marker/one-arch refused"
  else
    violating=$((violating + 1))
    bad "$name: ${problems[*]}"
  fi
done

[ "$selected" -gt 0 ] || { echo "selftest error: selector '$only' matched no gate" >&2; exit 2; }

if [ "$fails" -eq 0 ]; then
  printf 'PASS\tmac-gate-empty-output-selftest\t%s/%s gates causally require exact remote success\n' "$selected" "$selected"
  exit 0
fi
printf 'FAIL\tmac-gate-empty-output-selftest\t%s/%s gates violate causal remote-success contract; %s total failure(s)\n' \
  "$violating" "$selected" "$fails"
exit 1
