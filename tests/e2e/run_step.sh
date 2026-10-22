#!/bin/sh
# run_step.sh <label> [--summary <ERE>] -- <command> [args...]
#
# Runs one gate step's command and says what it printed and why it ended (test_run_step.py). zig build hands a
# system command its own stdout/stderr, so under -j a step's lines interleave with every other step's, unlabelled,
# and a failure says only "process exited with error code 1" (agent-netd-spawn-e2e, whose test died in Xlib's
# exit(1) with no summary line). Here every line the command printed, stdout and stderr in order, comes after it
# ends as one block, each prefixed "[<label>] ". Then, unless it exited 0 with its summary:
#   <label>: no summary line (the process ended mid-run); last line: <it>   (with --summary, when the last line
#                                                                            does not match the ERE)
#   <label>: exit <n>  or, above 128,  <label>: status <n> (signal-style: 128+<s>)   (a status other than 0)
# A shell sees only the status: an explicit "exit 143" and a SIGTERM both read 143, so a status above 128 is called
# signal-style, never proof of a signal (RoseCat 7573).
# The exit status is the command's own, or 1 for a clean exit without its summary line.
set -u
label=${1:?usage: run_step.sh <label> [--summary <ERE>] -- <command> [args...]}
shift
summary=
if [ "${1:-}" = "--summary" ]; then
    summary=${2:?--summary needs an ERE}
    shift 2
fi
[ "${1:-}" = "--" ] || { echo "run_step.sh: expected -- before the command" >&2; exit 2; }
shift
[ "$#" -gt 0 ] || { echo "run_step.sh: no command" >&2; exit 2; }

out=$(mktemp "${TMPDIR:-/tmp}/zb-run-step.XXXXXX") || exit 2
trap 'rm -f -- "${out:?}"' EXIT
"$@" > "$out" 2>&1
rc=$?
awk -v p="[$label] " '{ print p $0 }' "$out"

status=$rc
if [ -n "$summary" ]; then
    last=$(tail -n 1 "$out")
    if ! printf '%s\n' "$last" | grep -Eq -- "$summary"; then
        echo "$label: no summary line (the process ended mid-run); last line: $last"
        [ "$status" -eq 0 ] && status=1
    fi
fi
if [ "$rc" -gt 128 ]; then
    echo "$label: status $rc (signal-style: 128+$((rc - 128)))"
elif [ "$rc" -ne 0 ]; then
    echo "$label: exit $rc"
fi
exit "$status"
