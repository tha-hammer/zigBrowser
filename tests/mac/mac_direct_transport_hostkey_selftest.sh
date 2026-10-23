#!/usr/bin/env bash
# Hostless selftest: every Mac gate that builds its OWN ssh/scp command line (not through tests/mac/mac_gate_lib.sh)
# reaches the Macs only with pinned host keys and no askpass (bd zigBrowser-4pa.77, validation ms7-9 M4; bd
# zigBrowser-3ui.9 parts 2 and 3). ms6_gate.sh used StrictHostKeyChecking=no with UserKnownHostsFile=/dev/null, and
# the other direct-transport gates trusted whatever the operator's ~/.ssh/known_hosts holds, so a host answering on a
# Mac's address could receive the sources and hand back the results.
# Each script in DRIVEN runs for real (as a file, or from the commit's bytes the way its launcher requires) in a scratch
# git repo, against a stub ssh/scp first on PATH that records its argv and environment and succeeds. Scripts that
# fetch and verify the python.org pkg before any connection also get stub curl, uv, python3 and sha256sum (no
# download, no build; sha256sum answers the script's own pin), so the run reaches the same transport lines.
# tests/mac/ms6_5_reaper_gate.sh is NEVER run (session brief): its own SSH/SCP definition lines and its KNOWN_HOSTS
# line are evaluated in a function and called once per Mac against the same stubs.
# For EVERY recorded ssh/scp call ("-o Key=Value" and "-oKey=Value" both read; keys are case-insensitive):
#   H1 StrictHostKeyChecking is given and every value is "yes" (no "no", "accept-new" or "off");
#   H2 UserKnownHostsFile is given exactly once and is the repo's tests/mac/known_hosts (not /dev/null, not ~/.ssh);
#   H3 BatchMode=yes and IdentitiesOnly=yes are given;
#   H4 ssh/scp run without DISPLAY, WAYLAND_DISPLAY, XAUTHORITY or SSH_ASKPASS, although the script was launched with
#      all four (an inherited askpass can open a password window on the owner's desktop);
#   H5 the host is one of the two configured Macs (never a built-in default host);
#   H6 per script, at least one ssh call reaches each Mac, and one scp call too where the script copies files, so the
#      checks cannot pass vacuously;
#   H7 census: every tests/mac/*.sh and packaging/macos/*.sh (selftests aside) with its own ssh/scp command line is
#      in DRIVEN, EVALUATED or PINNED_ELSEWHERE (each of those has its own driven host-key selftest), so a new or
#      missed script fails here instead of slipping past.
# No Mac, no signal, no network: HOME/TMPDIR in this test's temp tree; the test re-runs itself in a private
# user+network namespace and runs each script under its own `unshare --user --map-current-user --net`.
# Run: bash tests/mac/mac_direct_transport_hostkey_selftest.sh [repo root]   (step: zig build test-mac-build-script)
set -uo pipefail
if [ "${ZB_DIRECT_HOSTKEY_SELFTEST_INNER:-}" != 1 ]; then
  ZB_DIRECT_HOSTKEY_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-direct-hostkey-selftest-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-direct-hostkey-selftest-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2

# script | launch (file, commit, compile) | provenance stubs (-, pin = the script's PIN, empty) | scp (scp or -)
DRIVEN=(
  "tests/mac/ms6_gate.sh|file|-|scp"
  "tests/mac/ms5_deps_gate.sh|file|pin|scp"
  "tests/mac/ms5_kill_group_gate.sh|file|-|-"
  "tests/mac/ms5_r1_env_gate.sh|file|-|scp"
  "tests/mac/ms5_relocate_gate.sh|file|pin|scp"
  "tests/mac/ms5_spawn_gate.sh|file|-|scp"
  "tests/mac/ms5_spawn_io_gate.sh|file|-|scp"
  "tests/mac/ms5_stage_gate.sh|file|pin|scp"
  "tests/mac/ms5_token_fd_gate.sh|file|-|scp"
  "tests/mac/ms6_5_reaper_census_gate.sh|file|-|-"
  "tests/mac/ms6_hard_gate.sh|commit|empty|scp"
  "tests/mac/ms6_harness_mac_gate.sh|file|-|-"
  "tests/mac/ms6_netd_darwin_gate.sh|file|-|scp"
  "tests/mac/ms6_r1_kernel_gate.sh|file|-|scp"
  "tests/mac/ms7_appkit_gate.sh|commit|-|scp"
  "tests/mac/mac_compile_only.sh|compile|-|-"
)
EVALUATED=(tests/mac/ms6_5_reaper_gate.sh)
# Pinned through their own driven selftests: build_on_mac_selftest.sh, mac_gate_callers_selftest.sh (C7),
# ms5_gate_hostkey_selftest.sh, ms5_setup_hostkey_selftest.sh.
PINNED_ELSEWHERE=(tests/mac/build-on-mac.sh tests/mac/mac_gate_lib.sh tests/mac/ms5_gate.sh tests/mac/ms5_setup_e2e.sh
                  tests/mac/ms5_setup_refusal_gate.sh)

mkdir -p "$T/bin" "$T/prov" "$T/home" "$T/tmp"
for tool in ssh scp; do
  cat > "$T/bin/$tool" <<EOF
#!/bin/bash
c=\${ZB_SELFTEST_CTL:?}
i=\$(cat "\$c/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "\$c/n"
printf '%s\0' $tool "\$@" > "\$c/call.\$i"
printf 'DISPLAY=%s WAYLAND_DISPLAY=%s XAUTHORITY=%s SSH_ASKPASS=%s\n' "\${DISPLAY-<unset>}" "\${WAYLAND_DISPLAY-<unset>}" \\
  "\${XAUTHORITY-<unset>}" "\${SSH_ASKPASS-<unset>}" > "\$c/env.\$i"
cat > /dev/null
exit 0
EOF
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "${ZB_SELFTEST_CTL:?}/zig"\nexit 0\n' > "$T/bin/zig"
cat > "$T/prov/curl" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do [ "$1" = -o ] && { echo stub > "$2"; shift; }; shift; done
exit 0
EOF
cat > "$T/prov/uv" <<'EOF'
#!/bin/bash
prev=
for a in "$@"; do case "$prev" in --target) mkdir -p "$a" ;; -o) : > "$a" ;; esac; prev=$a; done
exit 0
EOF
cat > "$T/prov/python3" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -m ] && [ "${2:-}" = venv ]; then
  mkdir -p "$3/bin" && for t in pip python; do printf '#!/bin/sh\nexit 0\n' > "$3/bin/$t"; chmod +x "$3/bin/$t"; done
fi
cat > /dev/null
exit 0
EOF
cat > "$T/prov/sha256sum" <<'EOF'
#!/bin/bash
[ -n "${ZB_STUB_SHA256:-}" ] && printf '%s  %s\n' "$ZB_STUB_SHA256" "${1:--}"
exit 0
EOF
chmod +x "$T"/bin/* "$T"/prov/*

# The scratch repo: the real scripts and everything they read, committed (several launch from the commit's bytes).
R="$T/repo"
mkdir -p "$R"
for p in src tests packaging agent tools build.zig build.zig.zon zigbrowser.json; do
  [ -e "$ROOT/$p" ] && cp -R "$ROOT/$p" "$R/"
done
find "${R:?}" -depth \( -name __pycache__ -o -name .zig-cache -o -name zig-out \) -exec rm -rf {} +
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }
PINNED=$(realpath "$R/tests/mac/known_hosts")
LAUNCH_ENV=(PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM"
            ZB_MAC_KEY="$T/home/no_such_key" DISPLAY=:99 WAYLAND_DISPLAY=wayland-selftest XAUTHORITY="$T/home/.Xauthority"
            SSH_ASKPASS="$T/bin/askpass-must-not-run")

check_calls() { # check_calls <name> <ctl dir> <scp|-> : H1-H6 over every recorded call
  local name=$1 c=$2 want_scp=$3 n i j tool host skip opt key val where p before=$fails
  local -a a strict khf batch ident pos
  declare -A seen=()
  n=$(cat "$c/n" 2>/dev/null || echo 0)
  for ((i = 0; i < n; i++)); do
    mapfile -d '' a < "$c/call.$i"
    tool=${a[0]} host= skip= strict=() khf=() batch=() ident=() pos=()
    for ((j = 1; j < ${#a[@]}; j++)); do
      if [ -n "$skip" ]; then skip=; continue; fi
      opt=
      case "${a[j]}" in
        -o) opt=${a[j+1]:-}; skip=1 ;;
        -o?*) opt=${a[j]#-o} ;;
        -i|-F|-p|-P|-l|-c|-J) skip=1; continue ;;
        -*) continue ;;
        *) pos+=("${a[j]}"); continue ;;
      esac
      key=${opt%%[= ]*} val=${opt#*[= ]}
      case "${key,,}" in
        stricthostkeychecking) strict+=("${val,,}") ;;
        userknownhostsfile) khf+=("$val") ;;
        batchmode) batch+=("${val,,}") ;;
        identitiesonly) ident+=("${val,,}") ;;
      esac
    done
    if [ "$tool" = ssh ]; then host=${pos[0]:-}
    else   # scp: the host of the remote operand (a copy to a Mac, or a fetch from one); a second remote host fails H5
      for p in "${pos[@]}"; do case "$p" in *:*) if [ -z "$host" ]; then host=${p%%:*}; elif [ "${p%%:*}" != "$host" ]; then host="mixed"; fi ;; esac; done
    fi
    where="$name call $i ($tool $host)"
    [ "$host" = "$INTEL" ] || [ "$host" = "$ARM" ] || bad "H5: $where goes to an unexpected host"
    seen[$tool:$host]=1
    if [ "${#strict[@]}" -ge 1 ] && [ -z "$(printf '%s\n' "${strict[@]}" | grep -vx yes)" ]; then :
    else bad "H1: $where StrictHostKeyChecking is '${strict[*]}', want yes"; fi
    if [ "${#khf[@]}" -eq 1 ] && [ "$(realpath -m "${khf[0]}")" = "$PINNED" ]; then :
    else bad "H2: $where UserKnownHostsFile is '${khf[*]}', want exactly the pinned tests/mac/known_hosts"; fi
    [ "${batch[*]}" = yes ] || bad "H3: $where BatchMode is '${batch[*]}', want yes"
    [ "${ident[*]}" = yes ] || bad "H3: $where IdentitiesOnly is '${ident[*]}', want yes"
    grep -qx 'DISPLAY=<unset> WAYLAND_DISPLAY=<unset> XAUTHORITY=<unset> SSH_ASKPASS=<unset>' "$c/env.$i" \
      || bad "H4: $where runs with a display or askpass: $(cat "$c/env.$i")"
  done
  for host in "$INTEL" "$ARM"; do
    [ -n "${seen[ssh:$host]:-}" ] || bad "H6: $name: no ssh call reached $host (the checks would be vacuous)"
    if [ "$want_scp" = scp ]; then
      [ -n "${seen[scp:$host]:-}" ] || bad "H6: $name: no scp call reached $host (its copy line went unchecked)"
    fi
  done
  [ "$fails" -eq "$before" ] && ok "$name: all $n ssh/scp calls pin tests/mac/known_hosts, BatchMode, no display/askpass"
}

for row in "${DRIVEN[@]}"; do
  IFS='|' read -r s launch prov want_scp <<<"$row"
  name=$(basename "$s" .sh) c="$T/ctl.$name" row_before=$fails
  mkdir -p "$c"
  [ -f "$R/$s" ] || { bad "$name: $s is missing"; continue; }
  env_extra=(ZB_SELFTEST_CTL="$c")
  case "$prov" in
    -) path_bin="$T/bin" ;;
    pin) path_bin="$T/prov:$T/bin"
         env_extra+=(ZB_STUB_SHA256="$(sed -n 's/^PIN=\([0-9a-f]\{64\}\)$/\1/p' "$R/$s" | head -n 1)") ;;
    empty) path_bin="$T/prov:$T/bin" env_extra+=(ZB_STUB_SHA256=) ;;
  esac
  case "$launch" in
    file) cmd=(bash "$s") ;;
    commit) cmd=(bash -c "$("${G[@]}" show "HEAD:$s")" "$name" HEAD) ;;
    compile) cmd=(bash -c "$("${G[@]}" show "HEAD:$s")" "$name" HEAD)
             env_extra+=(ZB_COMPILE_HARNESS_SHA256="$("${G[@]}" show "HEAD:$s" | /usr/bin/sha256sum | cut -c1-64)") ;;
  esac
  (cd "$R" && env -i "${LAUNCH_ENV[@]}" "${env_extra[@]}" PATH="$path_bin:/usr/bin:/bin" \
     unshare --user --map-current-user --net timeout -s TERM 120 "${cmd[@]}" >"$c/out" 2>&1 </dev/null)
  check_calls "$name" "$c" "$want_scp" || true
  [ "$fails" -eq "$row_before" ] || tail -n 3 "$c/out" | sed "s|^|    $name: |"
done

for s in "${EVALUATED[@]}"; do   # never run: its own definition lines, called once per Mac
  name=$(basename "$s" .sh) c="$T/ctl.$name"
  mkdir -p "$c"
  def=$(awk '/^[[:space:]]*(local[[:space:]]+)?(SSH|SCP)=\(/ { p = 1 } p { print } p && /\)[[:space:]]*$/ { p = 0 }' "$R/$s")
  kh=$(grep -E '^KNOWN_HOSTS=' "$R/$s" | head -n 1)
  [ -n "$def" ] || { bad "$name: no SSH=( definition found to evaluate"; continue; }
  want_scp=-; grep -qE '^[[:space:]]*(local[[:space:]]+)?SCP=\(' <<<"$def" && want_scp=scp
  (cd "$R" && env -i "${LAUNCH_ENV[@]}" ZB_SELFTEST_CTL="$c" ZB_DEF="$def" ZB_KH="$kh" \
     unshare --user --map-current-user --net timeout -s TERM 60 bash -c '
       leg() { local key=$2 KEY=$2; eval "$ZB_DEF"; "${SSH[@]}" "$1" true
               if [ -n "${SCP+x}" ]; then "${SCP[@]}" /dev/null "$1:x"; fi; }
       eval "$ZB_KH"; leg "$1" "$3"; leg "$2" "$3"' evaluated "$INTEL" "$ARM" "$T/home/no_such_key" \
     >"$c/out" 2>&1 </dev/null)
  check_calls "$name (evaluated, not run)" "$c" "$want_scp" || true
done

# H7: the census of scripts with their own ssh/scp command line.
known=" ${EVALUATED[*]} ${PINNED_ELSEWHERE[*]} "
for row in "${DRIVEN[@]}"; do known+=" ${row%%|*} "; done
while IFS= read -r f; do
  rel=${f#"$R"/}
  case "$rel" in *selftest*.sh) continue ;; esac
  grep -vE '^[[:space:]]*#' "$f" | grep -qE '(^|[[:space:](])(ssh|scp)[[:space:]]+-' || continue
  [[ "$known" == *" $rel "* ]] || bad "H7: $rel builds its own ssh/scp command line and no host-key selftest covers it"
done < <(find "$R/tests/mac" "$R/packaging/macos" -maxdepth 1 -name '*.sh' | LC_ALL=C sort)
[ "$fails" -eq 0 ] && ok "H7: every Mac script with its own ssh/scp line is covered"

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-direct-transport-hostkey-selftest\n'; exit 0; fi
printf 'FAIL\tmac-direct-transport-hostkey-selftest\t%s failure(s)\n' "$fails"
exit 1
