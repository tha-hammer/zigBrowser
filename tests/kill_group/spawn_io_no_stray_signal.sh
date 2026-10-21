#!/bin/sh
# tests/mac/spawn_group_io_test.c's failure paths never signal a child that is not ours to signal (RoseCat 7250 #1,
# 7258). Built on Linux against a MUTANT src/agent_spawn_posix.c with neither POSIX_SPAWN_SETPGROUP (no child leads
# its own group) nor the EINVAL guard (the four refusal cases then really spawn a child), with ZB_SPAWN_IO_CHILD_HANG=1
# (the echo children outlive their deadline), and with tests/kill_group/log_only_fake.c wrapping kill/killpg (nothing
# reaches the kernel either way). Required, every one (no arbitrary exit accepted):
#   - the source holds no raw kill(-child, ...) / killpg(-child, ...);
#   - the children really were non-leaders: the two "the child leads its own group" rows FAIL;
#   - every cleanup branch was reached and went through the guarded stop, refused as EPERM (1): exactly one
#     "STOP pipes child=<pid> kill_group=1", one "STOP same fd ...", and four "STOP refusal ..." rows;
#   - the run ends within 120 s with exit 1 and its exact summary line;
#   - the fake logged NO signal at all.
# Run only inside a private user+PID namespace:
#   unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid tests/kill_group/spawn_io_no_stray_signal.sh'
# usage: tests/kill_group/spawn_io_no_stray_signal.sh [repo root]
set -eu
root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
out=$(mktemp -d "${TMPDIR:-/tmp}/zb-spawnio-sig-XXXXXX")
trap 'case "$out" in "${TMPDIR:-/tmp}"/zb-spawnio-sig-??????) find "${out:?}" -delete;; esac' EXIT
fail() { echo "FAIL	spawn-io-no-stray-signal	$*"; exit 1; }
if grep -nE 'kill(pg)?\(-?child' "$root/tests/mac/spawn_group_io_test.c"; then
  fail "a raw signal call on a child remains"
fi
sed -e 's/short flags = POSIX_SPAWN_SETPGROUP;/short flags = 0;  \/* MUTANT: no own process group *\//' \
    -e 's/if ((stdin_fd != -1 \&\& stdin_fd <= 2) || (stdout_fd != -1 \&\& stdout_fd <= 2)) return EINVAL;/'\
'\/* MUTANT: no EINVAL guard *\//' \
  "$root/src/agent_spawn_posix.c" > "$out/agent_spawn_posix_mutant.c"
[ "$(grep -c 'MUTANT:' "$out/agent_spawn_posix_mutant.c")" = 2 ] || fail "the two mutations were not both applied"
cc -std=gnu11 -Wall -Wextra -Werror -Dweak_import=weak -I "$root/src" -Wl,--wrap=kill -Wl,--wrap=killpg \
  "$root/tests/mac/spawn_group_io_test.c" "$root/tests/kill_group/log_only_fake.c" "$out/agent_spawn_posix_mutant.c" \
  -o "$out/spawn_io_test"
set +e
ZB_SPAWN_IO_CHILD_HANG=1 timeout 120 "$out/spawn_io_test" </dev/null >"$out/out.log" 2>"$out/err.log"
rc=$?
set -e
signals=$(grep -c '^FAKE-SIGNAL' "$out/err.log" || true)
grep '^FAKE-SIGNAL' "$out/err.log" | head -5 | sed 's/^/  /'
[ "$rc" -ne 124 ] || fail "the test hung past 120 s"
[ "$signals" -eq 0 ] || fail "$signals signal(s) aimed at children that do not lead their own group"
count() { grep -cE "$1" "$out/out.log" || true; }
[ "$(count '^  FAIL pipes: the child leads its own group$')" = 1 ] \
  || fail "the pipes child was not shown to be a non-leader"
[ "$(count '^  FAIL inherit')" -ge 1 ] || fail "the inherit case did not run"
[ "$(count '^STOP pipes child=[0-9]+ kill_group=1$')" = 1 ] \
  || fail "the pipes cleanup was not reached through the guarded stop (EPERM)"
[ "$(count '^STOP same fd child=[0-9]+ kill_group=1$')" = 1 ] \
  || fail "the same-fd cleanup was not reached through the guarded stop (EPERM)"
[ "$(count '^STOP refusal child=[0-9]+ kill_group=1$')" = 4 ] \
  || fail "the four refusal cleanups were not reached through the guarded stop (EPERM)"
[ "$(count '^STOP ')" = 6 ] || fail "unexpected guarded stops: $(grep '^STOP ' "$out/out.log" | tr '\n' ';')"
[ "$rc" -eq 1 ] || fail "the mutant run must end with exit 1, got $rc"
tail -1 "$out/out.log" | grep -qE '^FAIL	ms5-spawn-io	[0-9]+ failure\(s\)$' || fail "no final summary line"
echo "PASS	spawn-io-no-stray-signal	6 cleanups reached, each refused by the guarded stop; no signal; exit 1 as pinned"
