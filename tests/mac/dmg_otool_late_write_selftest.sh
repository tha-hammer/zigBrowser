#!/usr/bin/env bash
# The dmg script's otool check must not depend on how otool's output is timed (bd zigBrowser-4pa.73; SilverRidge
# push-safety audit 2e8e0190). Under set -euo pipefail, `otool -L ... | grep -qF ...` lets grep exit at the first match
# and close the pipe; an otool that writes another line after that dies of SIGPIPE, the pipeline fails, and a valid
# package aborts with "does not load". This runs tests/mac/dmg_script_selftest.sh (its D1-D6, ad hoc and release) with
# ZB_DMG_SELFTEST_OTOOL_LATE=1: its fake otool writes the matching shim line, pauses, then writes its later dependency
# line. Every row must still pass, deterministically.
# Run: bash tests/mac/dmg_otool_late_write_selftest.sh [repo root]
set -uo pipefail
ROOT=$(realpath "${1:-.}")
out=$(ZB_DMG_SELFTEST_OTOOL_LATE=1 bash "$ROOT/tests/mac/dmg_script_selftest.sh" "$ROOT" 2>&1)
rc=$?
printf '%s\n' "$out" | sed 's/^/  /'
if [ "$rc" -eq 0 ] && grep -qx $'PASS\tmac-dmg-script-selftest' <<<"$out"; then
  printf 'PASS\tmac-dmg-otool-late-write-selftest\n'; exit 0
fi
printf 'FAIL\tmac-dmg-otool-late-write-selftest\tthe dmg script fails when otool writes after its shim line (exit %s)\n' "$rc"
exit 1
