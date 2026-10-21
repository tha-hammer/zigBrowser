#!/bin/sh
# tests/mac/spawn_group_io_test.c's failure paths never signal a child that is not ours to signal (RoseCat 7250 #1).
# Built on Linux against a MUTANT src/agent_spawn_posix.c without POSIX_SPAWN_SETPGROUP, so no spawned child leads
# its own group, with ZB_SPAWN_IO_CHILD_HANG=1, so each child outlives its deadline and the test's cleanup path really
# runs, and with tests/kill_group/log_only_fake.c wrapping kill/killpg, so nothing reaches the kernel either way.
# Required: the test finishes within 120 s, and the fake logged NO signal at all (a non-leader must be refused by
# zb_agent_kill_group before any call, then only reaped with a time bound).
# Run only inside a private user+PID namespace:
#   unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid tests/kill_group/spawn_io_no_stray_signal.sh'
# usage: tests/kill_group/spawn_io_no_stray_signal.sh [repo root]
set -eu
root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
out=$(mktemp -d "${TMPDIR:-/tmp}/zb-spawnio-sig-XXXXXX")
trap 'case "$out" in "${TMPDIR:-/tmp}"/zb-spawnio-sig-??????) find "${out:?}" -delete;; esac' EXIT
sed 's/short flags = POSIX_SPAWN_SETPGROUP;/short flags = 0;  \/* MUTANT: no own process group *\//' \
  "$root/src/agent_spawn_posix.c" > "$out/agent_spawn_posix_mutant.c"
grep -q 'MUTANT: no own process group' "$out/agent_spawn_posix_mutant.c" \
  || { echo "FAIL: mutant not applied" >&2; exit 1; }
cc -std=gnu11 -Wall -Wextra -Werror -Dweak_import=weak -I "$root/src" -Wl,--wrap=kill -Wl,--wrap=killpg \
  "$root/tests/mac/spawn_group_io_test.c" "$root/tests/kill_group/log_only_fake.c" "$out/agent_spawn_posix_mutant.c" \
  -o "$out/spawn_io_test"
set +e
ZB_SPAWN_IO_CHILD_HANG=1 timeout 120 "$out/spawn_io_test" </dev/null >"$out/out.log" 2>"$out/err.log"
rc=$?
set -e
signals=$(grep -c '^FAKE-SIGNAL' "$out/err.log" || true)
grep '^FAKE-SIGNAL' "$out/err.log" | head -5 | sed 's/^/  /'
if [ "$rc" -eq 124 ]; then echo "FAIL	spawn-io-no-stray-signal	the test hung past 120 s"; exit 1; fi
if [ "$signals" -ne 0 ]; then
  echo "FAIL	spawn-io-no-stray-signal	$signals signal(s) aimed at children that do not lead their own group"
  exit 1
fi
echo "PASS	spawn-io-no-stray-signal	no signal reached a non-leader child (test exit $rc, as expected for the mutant)"
