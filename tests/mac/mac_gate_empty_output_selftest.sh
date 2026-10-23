#!/usr/bin/env bash
# UNREGISTERED RED for bd zigBrowser-3ui.14.
#
# Each listed two-host gate is run for real against executing ssh/scp stubs that consume all stdin, emit no bytes,
# and exit 0. A gate passes this oracle only if both configured fake hosts were reached, the gate exits nonzero, and
# it prints no top-level PASS ... both-arches line. This proves an empty successful transport cannot stand in for
# the remote test's own success evidence.
#
# Scope is the issue's 20 affected gates. tests/mac/ms_runtime_rows_gate.sh is owned elsewhere and excluded.
# tests/mac/ms6_5_reaper_gate.sh is destructive, is not in the issue list, and is never run here.
# This test stays unregistered until its GREEN is approved.
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

calls_of() { cat "$1/n" 2>/dev/null || echo 0; }
call_host() { # call_host <control dir> <index>
  local -a a pos=()
  local j skip=
  mapfile -d '' a < "$1/call.$2"
  for ((j = 1; j < ${#a[@]}; j++)); do
    if [ -n "$skip" ]; then skip=; continue; fi
    case "${a[j]}" in
      -i|-o|-F|-p|-P|-l|-c|-J) skip=1 ;;
      -*) ;;
      *) pos+=("${a[j]}") ;;
    esac
  done
  if [ "${a[0]}" = ssh ]; then printf '%s\n' "${pos[0]:-}"
  else
    for j in "${pos[@]}"; do case "$j" in *:*) printf '%s\n' "${j%%:*}"; return ;; esac; done
  fi
}

run_gate() { # run_gate <script> <provenance mode>; sets C and RC
  local script=$1 prov=$2 name pb pin=
  name=$(basename "$script" .sh)
  C="$T/case.$name"
  mkdir -p "$C/home" "$C/tmp"
  pb="$T/bin"
  if [ "$prov" = pin ]; then
    pb="$T/prov:$T/bin"
    pin=$(sed -n 's/^PIN=\([0-9a-f]\{64\}\)$/\1/p' "$R/$script" | head -n 1)
  fi
  (cd "$R" && env -i PATH="$pb:/usr/bin:/bin" HOME="$C/home" TMPDIR="$C/tmp" GIT_CONFIG_NOSYSTEM=1 \
     ZB_EMPTY_OUTPUT_CTL="$C" ZB_STUB_SHA256="$pin" ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" \
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

accepted=0
for row in "${GATES[@]}"; do
  IFS='|' read -r script prov <<<"$row"
  name=$(basename "$script" .sh)
  run_gate "$script" "$prov"
  n=$(calls_of "$C")
  intel_seen=0
  arm_seen=0
  for ((i = 0; i < n; i++)); do
    host=$(call_host "$C" "$i")
    [ "$host" = "$INTEL" ] && intel_seen=1
    [ "$host" = "$ARM" ] && arm_seen=1
  done
  top_pass=0
  grep -q $'^PASS\t.*\tboth-arches' "$C/out" && top_pass=1
  if [ "$intel_seen" -ne 1 ] || [ "$arm_seen" -ne 1 ]; then
    bad "$name: vacuous ($n calls; intel=$intel_seen arm=$arm_seen)"
  elif [ "$RC" -ne 0 ] && [ "$top_pass" -eq 0 ]; then
    ok "$name: empty successful transports are refused (exit $RC, $n calls)"
  else
    accepted=$((accepted + 1))
    bad "$name: accepted empty successful transports (exit $RC, top-level PASS=$top_pass, $n calls)"
  fi
done

if [ "$fails" -eq 0 ]; then
  printf 'PASS\tmac-gate-empty-output-selftest\t20/20 gates refused empty transport output\n'
  exit 0
fi
printf 'FAIL\tmac-gate-empty-output-selftest\t%s/20 gates accepted empty transport output; %s total failure(s)\n' \
  "$accepted" "$fails"
exit 1
