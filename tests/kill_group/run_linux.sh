#!/bin/sh
# zb_agent_kill_group's ownership guard on Linux (tests/kill_group/kill_group_test.c; RoseCat 7172, 7182). Every
# killpg/kill of the code under test is routed by -Wl,--wrap to tests/kill_group/kill_group_fake.c, which forwards
# only a SIGKILL to the one child leader the test allowlisted. It still runs only inside a private user+PID namespace:
#   unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid tests/kill_group/run_linux.sh'
# usage: tests/kill_group/run_linux.sh [repo root]   (default: this script's repo)
set -eu
root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
out=$(mktemp -d "${TMPDIR:-/tmp}/zb-killgroup-XXXXXX")
trap 'case "$out" in */zb-killgroup-*) rm -rf -- "${out:?}";; esac' EXIT
cc -std=gnu11 -Wall -Wextra -Werror -I "$root/src" -Wl,--wrap=killpg -Wl,--wrap=kill \
  "$root/tests/kill_group/kill_group_test.c" "$root/tests/kill_group/kill_group_fake.c" "$root/src/agent_spawn_posix.c" \
  -o "$out/kill_group_test"
"$out/kill_group_test" </dev/null
