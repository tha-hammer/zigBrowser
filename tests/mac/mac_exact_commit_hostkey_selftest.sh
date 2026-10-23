#!/usr/bin/env bash
# Hostless selftest: the three exact-commit launchers take the Macs' pinned host keys from the commit they run, never
# from the mutable working tree (bd zigBrowser-4pa.77 / 3ui.9; SilverRidge 7f58dd72). mac_compile_only.sh
# (ZB_COMPILE_HARNESS_SHA256 + bash -c "$(git show ...)"), ms6_hard_gate.sh and ms7_appkit_gate.sh (bash -c "$(git
# show ...)") vouch for their own bytes and export the commit, so a trust root read from the outer checkout would let
# a dirty tests/mac/known_hosts change the accepted host key while the approved launcher and commit stay the same.
# The real launchers run from the commit's bytes in a scratch git repo whose outer tests/mac/known_hosts is changed
# AFTER the commit, in each of these outer states:
#   dirty     the file's content is replaced by a different, attacker-style host line (uncommitted);
#   replaced  the file is replaced by a symlink to /dev/null (uncommitted).
# A stub ssh/scp first on PATH records each call's argv and, at the moment of the call, the SHA-256 of the file its
# UserKnownHostsFile names. For EVERY recorded call:
#   K1 UserKnownHostsFile is given exactly once;
#   K2 its path is inside the launcher's own run tree (this test's TMPDIR), never the outer checkout's file;
#   K3 the bytes it named at call time are exactly `git show SHA:tests/mac/known_hosts` (SHA-256 equal);
#   K4 per launcher and outer state, at least one ssh call reached each Mac, so K1-K3 cannot pass vacuously.
# No Mac, no signal, no network: HOME/TMPDIR in this test's temp tree; the test re-runs itself in a private
# user+network namespace and runs each launcher under its own `unshare --user --map-current-user --net`.
# Run: bash tests/mac/mac_exact_commit_hostkey_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_EXACT_HOSTKEY_SELFTEST_INNER:-}" != 1 ]; then
  ZB_EXACT_HOSTKEY_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-exact-hostkey-selftest-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-exact-hostkey-selftest-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2

# script | launch (commit: bash -c "$(git show)"; compile: plus ZB_COMPILE_HARNESS_SHA256) | provenance stubs
LAUNCHERS=(
  "tests/mac/mac_compile_only.sh|compile|-"
  "tests/mac/ms6_hard_gate.sh|commit|empty"
  "tests/mac/ms7_appkit_gate.sh|commit|-"
)

mkdir -p "$T/bin" "$T/prov" "$T/home"
for tool in ssh scp; do
  cat > "$T/bin/$tool" <<EOF
#!/bin/bash
c=\${ZB_SELFTEST_CTL:?}
i=\$(cat "\$c/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "\$c/n"
printf '%s\0' $tool "\$@" > "\$c/call.\$i"
khf= prev=
for a in "\$@"; do
  if [ "\$prev" = -o ]; then case "\${a,,}" in userknownhostsfile=*) khf=\${a#*=} ;; esac; fi
  case "\${a,,}" in -ouserknownhostsfile=*) khf=\${a#*=} ;; esac
  prev=\$a
done
if [ -n "\$khf" ] && [ -r "\$khf" ]; then /usr/bin/sha256sum < "\$khf" | cut -c1-64 > "\$c/khsha.\$i"; else echo unreadable > "\$c/khsha.\$i"; fi
cat > /dev/null
exit 0
EOF
done
printf '#!/bin/bash\nexit 0\n' > "$T/bin/zig"
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

# The scratch repo: the real launchers and everything they export, committed; then the outer file is changed.
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
SHA=$("${G[@]}" rev-parse HEAD)
WANT=$("${G[@]}" show "$SHA:tests/mac/known_hosts" | /usr/bin/sha256sum | cut -c1-64)
OUTER="$R/tests/mac/known_hosts"

for state in dirty replaced; do
  rm -f -- "$OUTER"
  case "$state" in
    dirty) printf '10.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAttackerSuppliedKeyAttackerSuppliedKey00\n' > "$OUTER" ;;
    replaced) ln -s /dev/null "$OUTER" ;;
  esac
  [ -n "$("${G[@]}" status --porcelain -- tests/mac/known_hosts)" ] || { bad "$state: the outer known_hosts is not changed"; continue; }
  for row in "${LAUNCHERS[@]}"; do
    IFS='|' read -r s launch prov <<<"$row"
    name="$(basename "$s" .sh) [$state]" c="$T/ctl.$(basename "$s" .sh).$state" run="$T/run.$(basename "$s" .sh).$state"
    mkdir -p "$c" "$run/tmp"
    env_extra=(ZB_SELFTEST_CTL="$c")
    path_bin="$T/bin"
    [ "$prov" = empty ] && { path_bin="$T/prov:$T/bin"; env_extra+=(ZB_STUB_SHA256=); }
    launcher=$("${G[@]}" show "$SHA:$s")
    [ "$launch" = compile ] && env_extra+=(ZB_COMPILE_HARNESS_SHA256="$(printf '%s\n' "$launcher" | /usr/bin/sha256sum | cut -c1-64)")
    (cd "$R" && env -i PATH="$path_bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$run/tmp" ZB_MAC_HOST="$INTEL" \
       ZB_MAC_ARM_HOST="$ARM" ZB_MAC_KEY="$T/home/no_such_key" "${env_extra[@]}" \
       unshare --user --map-current-user --net timeout -s TERM 120 bash -c "$launcher" "$(basename "$s" .sh)" "$SHA" \
       >"$c/out" 2>&1 </dev/null)
    before=$fails
    declare -A seen=()
    n=$(cat "$c/n" 2>/dev/null || echo 0)
    for ((i = 0; i < n; i++)); do
      mapfile -d '' a < "$c/call.$i"
      tool=${a[0]} host= skip= khf=() pos=()
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
        [ "${key,,}" = userknownhostsfile ] && khf+=("$val")
      done
      if [ "$tool" = ssh ]; then host=${pos[0]:-}
      else for p in "${pos[@]}"; do case "$p" in *:*) host=${p%%:*} ;; esac; done; fi
      seen[$tool:$host]=1
      where="$name call $i ($tool $host)"
      [ "${#khf[@]}" -eq 1 ] || { bad "K1: $where UserKnownHostsFile is '${khf[*]}', want exactly one"; continue; }
      case "$(realpath -m "${khf[0]}")" in
        "$run/tmp"/*) ;;
        *) bad "K2: $where UserKnownHostsFile ${khf[0]} is not inside the launcher's run tree (the outer checkout is $OUTER)" ;;
      esac
      got=$(cat "$c/khsha.$i")
      [ "$got" = "$WANT" ] || bad "K3: $where the known_hosts it named hashed $got at call time, want the commit's blob $WANT"
    done
    for host in "$INTEL" "$ARM"; do
      [ -n "${seen[ssh:$host]:-}" ] || bad "K4: $name: no ssh call reached $host (the checks would be vacuous)"
    done
    unset seen
    if [ "$fails" -eq "$before" ]; then ok "$name: all $n calls use the commit's known_hosts from its own export"
    else tail -n 2 "$c/out" | sed "s|^|    $name: |"; fi
  done
done

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-exact-commit-hostkey-selftest\n'; exit 0; fi
printf 'FAIL\tmac-exact-commit-hostkey-selftest\t%s failure(s)\n' "$fails"
exit 1
