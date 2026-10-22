#!/usr/bin/env bash
# Hostless selftest of tests/mac/build-on-mac.sh, the build step every Mac gate shares (plan R30-MS1,
# bd zigBrowser-4pa.59 + zigBrowser-4pa.77; owner decision R30.3 #2). The script must:
#   (1) send `git archive <sha>` (committed bytes only: no untracked file, no dirty working copy);
#   (2) extract into a fresh per-run remote directory zb-gate-<sha>-<nonce>, from a fresh local tar (never the old
#       fixed /tmp/zb_worktree_mac.tar), both different on every run;
#   (3) print a PASS line holding the 40-hex sha;
#   (4) exit non-zero when `git archive` fails (errors are no longer hidden);
#   (5) give every ssh/scp StrictHostKeyChecking=yes, BatchMode=yes, IdentitiesOnly=yes and
#       UserKnownHostsFile=<the pinned tests/mac/known_hosts>, which holds both Macs' host keys;
#   (6) never pass StrictHostKeyChecking=no/accept-new or UserKnownHostsFile=/dev/null;
#   (7) leave no local tar behind; (8) run alone, remove its remote directory at the end.
# No Mac, no network, no signal: the REAL script runs in a scratch git repo, with a stub `ssh` and `scp` first on PATH
# that record their argv, stdin and the local files they are handed, and succeed. The whole test runs in a private
# user+mount namespace whose /tmp is this test's own temporary tree, so nothing (not even the old fixed tar path)
# touches the host's /tmp.
# Run: bash tests/mac/build_on_mac_selftest.sh [script path]   (step: zig build test-mac-build-script)
set -uo pipefail

if [ "${1:-}" != --inner ]; then
  SCRIPT=$(realpath "${1:-tests/mac/build-on-mac.sh}")
  SELF=$(realpath "$0")
  BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-bom-selftest-XXXXXX")
  T=$(realpath "$BASE")
  trap 'case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-bom-selftest-??????) rm -rf "${T:?}" ;; esac' EXIT
  cp "$SELF" "$T/self.sh" && cp "$SCRIPT" "$T/build-on-mac.sh" || exit 1
  [ -f "$(dirname "$SCRIPT")/known_hosts" ] && cp "$(dirname "$SCRIPT")/known_hosts" "$T/known_hosts"
  unshare --user --map-root-user --mount bash -c 'mount --bind "$1" /tmp && exec bash /tmp/self.sh --inner' _ "$T"
  exit $?
fi

# ---- inside the namespace: /tmp is this test's private tree ----------------------------------------------------
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
mkdir -p /tmp/bin /tmp/ctl /tmp/home /tmp/tmp /tmp/repo/src /tmp/repo/tests/mac /tmp/repo/packaging/macos

for tool in ssh scp; do
  cat > "/tmp/bin/$tool" <<EOF
#!/bin/bash
i=\$(cat /tmp/ctl/n 2>/dev/null || echo 0); echo \$((i + 1)) > /tmp/ctl/n
printf '%s\0' $tool "\$@" > /tmp/ctl/call.\$i
src=\$(readlink /proc/self/fd/0)
case "\$src" in /*) [ -f "\$src" ] && printf '%s\n' "\$src" >> /tmp/ctl/local.\$i ;; esac   # a file fed on stdin
cat > /tmp/ctl/stdin.\$i
if [ $tool = scp ]; then
  skip=
  for a in "\$@"; do
    if [ -n "\$skip" ]; then skip=; continue; fi
    case "\$a" in -i|-o|-F|-P|-l|-c|-J) skip=1; continue ;; -*|*:*) continue ;; esac
    [ -f "\$a" ] && { printf '%s\n' "\$a" >> /tmp/ctl/local.\$i; cp "\$a" "/tmp/ctl/file.\$i.\$(basename "\$a")"; }
  done
fi
exit 0
EOF
  chmod +x "/tmp/bin/$tool"
done

# The scratch repo: the real script, the pinned host keys if the script ships them, and the paths it sends.
cp /tmp/build-on-mac.sh /tmp/repo/tests/mac/build-on-mac.sh
[ -f /tmp/known_hosts ] && cp /tmp/known_hosts /tmp/repo/tests/mac/known_hosts
echo 'committed a' > /tmp/repo/src/a.zig
echo 'build' > /tmp/repo/build.zig
echo 'zon' > /tmp/repo/build.zig.zon
echo '{}' > /tmp/repo/zigbrowser.json
echo 'plist' > /tmp/repo/packaging/macos/Info.plist
G=(env -i PATH=/usr/bin:/bin HOME=/tmp/home GIT_CONFIG_NOSYSTEM=1 git -C /tmp/repo)
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }
SHA=$("${G[@]}" rev-parse HEAD)
echo 'DIRTY a' > /tmp/repo/src/a.zig            # tracked and modified: must never be sent
echo 'untracked' > /tmp/repo/src/untracked.zig  # untracked: must never be sent

run() { # run <label>: runs the real script; sets rc, out, ncalls
  rm -f /tmp/ctl/*
  out=$(cd /tmp/repo && env -i PATH=/tmp/bin:/usr/bin:/bin HOME=/tmp/home TMPDIR=/tmp/tmp \
          ZB_MAC_HOST=intel@stub.invalid ZB_MAC_KEY=/tmp/home/no_such_key \
          timeout 60 bash tests/mac/build-on-mac.sh 2>&1 </dev/null)
  rc=$?
  ncalls=$(cat /tmp/ctl/n 2>/dev/null || echo 0)
  printf -- '--- %s: rc=%s calls=%s\n%s\n' "$1" "$rc" "$ncalls" "$out" | sed 's/^/     /'
}
argv() { tr '\0' ' ' < "/tmp/ctl/call.$1"; }   # one call's argv, space-joined
remote_dirs() { # every zb-gate-<sha>-<nonce> named in any recorded argv, one per line
  local i
  for ((i = 0; i < ncalls; i++)); do argv "$i"; echo; done | grep -oE 'zb-gate-[0-9a-f]{40}-[0-9a-f]+' | sort -u
}

# ---- run 1 -------------------------------------------------------------------------------------------------------
run "run 1"
if [ "$rc" -eq 0 ]; then ok "run 1: exit 0"; else bad "run 1: exit $rc, want 0"; fi

# (1) the tar handed over holds committed bytes only
tars=()
for f in /tmp/ctl/file.* /tmp/ctl/stdin.*; do
  [ -s "$f" ] && tar -tf "$f" >/dev/null 2>&1 && tars+=("$f")
done
if [ "${#tars[@]}" -eq 1 ]; then
  ok "(1) one tar was handed over"
  list=$(tar -tf "${tars[0]}")
  if grep -qE '(^|/)src/untracked\.zig$' <<<"$list"; then bad "(1) the tar holds the untracked file"
  else ok "(1) no untracked file in the tar"; fi
  member=$(grep -E '(^|/)src/a\.zig$' <<<"$list" | head -1)
  sent=$(tar -xOf "${tars[0]}" "$member" 2>/dev/null)
  if [ "$sent" = 'committed a' ]; then ok "(1) the dirty file was sent as its committed blob"
  else bad "(1) src/a.zig was sent as \"$sent\", want its committed blob"; fi
else
  bad "(1) ${#tars[@]} tars were handed over, want exactly 1"
fi

# (2) a fresh per-run remote dir for this sha, and a fresh local tar
dirs1=$(remote_dirs)
if [ "$(grep -c . <<<"$dirs1")" -eq 1 ]; then ok "(2) one remote run dir: $dirs1"
else bad "(2) remote run dirs named: \"$(tr '\n' ' ' <<<"$dirs1")\", want exactly one zb-gate-<sha>-<nonce>"; fi
case "$dirs1" in "zb-gate-$SHA-"*) ok "(2) the run dir names the staged sha" ;;
  *) bad "(2) the run dir does not name the staged sha $SHA" ;; esac
local1=$(cat /tmp/ctl/local.* 2>/dev/null)
if grep -qx /tmp/zb_worktree_mac.tar <<<"$local1"; then bad "(2) the local tar is the fixed /tmp/zb_worktree_mac.tar"
else ok "(2) the local tar is not the fixed path"; fi

# (3) the PASS line names the sha
if grep -E '^PASS' <<<"$out" | grep -qw "$SHA"; then ok "(3) the PASS line holds the sha"
else bad "(3) no PASS line holding $SHA"; fi

# (5) and (6): every ssh/scp argv pins host keys
for ((i = 0; i < ncalls; i++)); do
  a=$(argv "$i")
  for want in StrictHostKeyChecking=yes BatchMode=yes IdentitiesOnly=yes; do
    case "$a" in *"$want"*) ;; *) bad "(5) call $i lacks $want: $a" ;; esac
  done
  khf=$(grep -oE 'UserKnownHostsFile=[^ ]+' <<<"$a" | head -1)
  khf=${khf#UserKnownHostsFile=}
  case "$khf" in */tests/mac/known_hosts) [ -s "$khf" ] || bad "(5) call $i: pinned file $khf is missing" ;;
    *) bad "(5) call $i: UserKnownHostsFile is \"$khf\", want the pinned tests/mac/known_hosts" ;; esac
  case "$a" in *StrictHostKeyChecking=no*|*StrictHostKeyChecking=accept-new*|*UserKnownHostsFile=/dev/null*)
    bad "(6) call $i turns host-key checking off: $a" ;; esac
done
[ "$ncalls" -gt 0 ] && [ "$fails" -eq 0 ] && ok "(5)(6) all $ncalls ssh/scp calls pin host keys"
if [ -f /tmp/repo/tests/mac/known_hosts ]; then
  for h in 100.92.212.47 100.119.156.28; do
    if grep -qE "^([^ ]*,)?\[?$h\]?(:[0-9]+)?(,[^ ]*)? ssh-" /tmp/repo/tests/mac/known_hosts; then ok "(5) the pinned file holds $h"
    else bad "(5) the pinned file holds no key for $h"; fi
  done
else
  bad "(5) the script ships no pinned tests/mac/known_hosts"
fi

# (7) no local tar left behind
left=$(find /tmp/tmp -mindepth 1 2>/dev/null; ls -d /tmp/zb_worktree_mac.tar 2>/dev/null)   # nothing at all
if [ -z "$left" ]; then ok "(7) no local tar left behind"; else bad "(7) left behind: $left"; fi

# (8) run alone, the script removes its remote run dir at the end
if [ -n "$dirs1" ] && [ "$ncalls" -gt 0 ]; then
  last=$(argv $((ncalls - 1)))
  case "$last" in *"$dirs1"*-delete*|*"rm -rf"*"$dirs1"*) ok "(8) the last call removes $dirs1" ;;
    *) bad "(8) the last call does not remove the run dir: $last" ;; esac
else
  bad "(8) no run dir to remove"
fi

# ---- run 2: everything per-run must differ -----------------------------------------------------------------------
run "run 2"
dirs2=$(remote_dirs)
if [ -n "$dirs1" ] && [ -n "$dirs2" ] && [ "$dirs1" != "$dirs2" ]; then ok "(2) run 2 used another run dir"
else bad "(2) run 2 run dir \"$dirs2\" is not a fresh one (run 1: \"$dirs1\")"; fi
local2=$(cat /tmp/ctl/local.* 2>/dev/null)
if [ -z "$local1" ] || [ -z "$local2" ]; then bad "(2) no local tar file was seen (run 1: \"$local1\", run 2: \"$local2\")"
elif [ "$local1" = "$local2" ]; then bad "(2) both runs used the same local tar $local1"
else ok "(2) the local tar differs between runs"; fi

# ---- (4) a failing git archive fails the script ------------------------------------------------------------------
blob=$("${G[@]}" rev-parse HEAD:zigbrowser.json)
rm -f "/tmp/repo/.git/objects/${blob:0:2}/${blob:2}"
run "(4) a committed blob is unreadable"
if [ "$rc" -ne 0 ]; then ok "(4) exit $rc when git archive fails"; else bad "(4) exit 0 although git archive fails"; fi

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-build-script-selftest\n'; exit 0; fi
printf 'FAIL\tmac-build-script-selftest\t%s failure(s)\n' "$fails"
exit 1
