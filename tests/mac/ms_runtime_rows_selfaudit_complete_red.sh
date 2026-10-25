#!/usr/bin/env bash
# RED, UNREGISTERED: the real two-host fake transport must accept canonical
# nonzero COMPLETE counts from the helper self-audit without losing its delta
# evidence or stopping before package preparation and the selected row.
set -uo pipefail

ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-runtime-selfaudit-red-XXXXXX") || exit 1
cleanup() {
  case "$BASE" in "${TMPDIR:-/tmp}"/zb-runtime-selfaudit-red-??????)
    chmod -R u+rwx "${BASE:?}" 2>/dev/null
    rm -rf -- "${BASE:?}"
  esac
}
trap cleanup EXIT

SOURCE="$ROOT/tests/mac/ms_signal_runtime_gate_red.sh"
DRIVER="$BASE/ms_signal_runtime_gate_complete_count.sh"
python3 - "$SOURCE" "$DRIVER" <<'PY'
from pathlib import Path
import sys

source, target = map(Path, sys.argv[1:])
text = source.read_text(encoding="utf-8")
old = '''cat > "$T/macbin/getconf" <<'EOF'
#!/bin/bash
case "$1" in
  DARWIN_USER_TEMP_DIR) echo "$ZB_FAKE_MAC/vf/0/T/" ;;
  DARWIN_USER_CACHE_DIR) echo "$ZB_FAKE_MAC/vf/0/C/" ;;
  *) exit 1 ;;
esac
EOF
'''
new = '''cat > "$T/macbin/getconf" <<'EOF'
#!/bin/bash
case "$1" in
  DARWIN_USER_TEMP_DIR)
    state="$ZB_FAKE_MAC/getconf-temp-count"
    n=$(cat "$state" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" > "$state"
    if [ "$n" -eq 3 ]; then
      printf 'after--bytes\n' > "$ZB_FAKE_MAC/vf/0/T/recorded-delta"
    fi
    echo "$ZB_FAKE_MAC/vf/0/T/" ;;
  DARWIN_USER_CACHE_DIR) echo "$ZB_FAKE_MAC/vf/0/C/" ;;
  *) exit 1 ;;
esac
EOF
'''
if text.count(old) != 1:
    raise SystemExit("self-audit red: getconf seam changed")
text = text.replace(old, new)

baseline = '''    mkdir -p "$T/mac/$h/vf/0/T" "$T/mac/$h/vf/0/C" "$T/mac/$h/Library/Logs/DiagnosticReports"
'''
with_baseline = baseline + '''    printf 'before-bytes\\n' > "$T/mac/$h/vf/0/T/recorded-delta"
'''
if text.count(baseline) != 1:
    raise SystemExit("self-audit red: baseline seam changed")
text = text.replace(baseline, with_baseline)

judge_seam = '''judge_success() { # $1 output file, $2 x86 row file, $3 arm row file; current fake roots must be absent
'''
per_leg_judge = '''leg_complete_sequence() { # one architecture's copied leg.out
  local f=$1 inner_delta inner_complete inner_status crash_complete crash_status evidence_status
  local outer_delta outer_complete outer_status armed package row
  [ -f "$f" ] || return 1
  [ "$(grep -c $'^SELFAUDIT\\tinner-varfolders\\tVARFOLDERS-DELTA\\t' "$f")" -eq 1 ] || return 1
  [ "$(grep -c $'^SELFAUDIT\\tinner-varfolders\\tVARFOLDERS-DELTA\\tchanged\\tT\\t' "$f")" -eq 1 ] || return 1
  [ "$(grep -cx $'SELFAUDIT\\tinner-varfolders\\tVARFOLDERS\\tCOMPLETE\\t1' "$f")" -eq 1 ] || return 1
  [ "$(grep -cx $'SELFAUDIT_STATUS\\tinner-varfolders\\t0' "$f")" -eq 1 ] || return 1
  [ "$(grep -cx $'SELFAUDIT\\tinner-crashreports\\tCRASHREPORTS\\tCOMPLETE\\t0' "$f")" -eq 1 ] || return 1
  [ "$(grep -cx $'SELFAUDIT_STATUS\\tinner-crashreports\\t0' "$f")" -eq 1 ] || return 1
  [ "$(grep -cx $'SELFAUDIT_STATUS\\tinner-evidence\\t0' "$f")" -eq 1 ] || return 1
  [ "$(grep -c $'^SELFAUDIT\\touter-end\\tVARFOLDERS-DELTA\\t' "$f")" -eq 1 ] || return 1
  [ "$(grep -c $'^SELFAUDIT\\touter-end\\tVARFOLDERS-DELTA\\tchanged\\tT\\t' "$f")" -eq 1 ] || return 1
  [ "$(grep -cx $'SELFAUDIT\\touter-end\\tVARFOLDERS\\tCOMPLETE\\t1' "$f")" -eq 1 ] || return 1
  [ "$(grep -cx $'SELFAUDIT_STATUS\\touter-end\\t0' "$f")" -eq 1 ] || return 1
  [ "$(grep -cx 'EVIDENCE_ARMED' "$f")" -eq 1 ] || return 1
  [ "$(grep -c $'PACKAGE\\t' "$f")" -eq 1 ] || return 1
  [ "$(grep -cx $'ROW\\ttests/e2e/mac_signal_runtime_test.py\\tgreen\\trc=0\\tMATCH' "$f")" -eq 1 ] || return 1
  inner_delta=$(grep -n -m1 $'^SELFAUDIT\\tinner-varfolders\\tVARFOLDERS-DELTA\\t' "$f" | cut -d: -f1)
  inner_complete=$(grep -n -m1 $'^SELFAUDIT\\tinner-varfolders\\tVARFOLDERS\\tCOMPLETE\\t1$' "$f" | cut -d: -f1)
  inner_status=$(grep -n -m1 $'^SELFAUDIT_STATUS\\tinner-varfolders\\t0$' "$f" | cut -d: -f1)
  crash_complete=$(grep -n -m1 $'^SELFAUDIT\\tinner-crashreports\\tCRASHREPORTS\\tCOMPLETE\\t0$' "$f" | cut -d: -f1)
  crash_status=$(grep -n -m1 $'^SELFAUDIT_STATUS\\tinner-crashreports\\t0$' "$f" | cut -d: -f1)
  evidence_status=$(grep -n -m1 $'^SELFAUDIT_STATUS\\tinner-evidence\\t0$' "$f" | cut -d: -f1)
  outer_delta=$(grep -n -m1 $'^SELFAUDIT\\touter-end\\tVARFOLDERS-DELTA\\t' "$f" | cut -d: -f1)
  outer_complete=$(grep -n -m1 $'^SELFAUDIT\\touter-end\\tVARFOLDERS\\tCOMPLETE\\t1$' "$f" | cut -d: -f1)
  outer_status=$(grep -n -m1 $'^SELFAUDIT_STATUS\\touter-end\\t0$' "$f" | cut -d: -f1)
  armed=$(grep -n -m1 '^EVIDENCE_ARMED$' "$f" | cut -d: -f1)
  package=$(grep -n -m1 $'PACKAGE\\t' "$f" | cut -d: -f1)
  row=$(grep -n -m1 $'^ROW\\ttests/e2e/mac_signal_runtime_test.py\\tgreen\\trc=0\\tMATCH$' "$f" | cut -d: -f1)
  [ "$inner_delta" -lt "$inner_complete" ] && [ "$inner_complete" -lt "$inner_status" ] \
    && [ "$inner_status" -lt "$crash_complete" ] && [ "$crash_complete" -lt "$crash_status" ] \
    && [ "$crash_status" -lt "$evidence_status" ] && [ "$evidence_status" -lt "$outer_delta" ] \
    && [ "$outer_delta" -lt "$outer_complete" ] && [ "$outer_complete" -lt "$outer_status" ] \
    && [ "$outer_status" -lt "$armed" ] && [ "$armed" -lt "$package" ] && [ "$package" -lt "$row" ]
}

''' + judge_seam
if text.count(judge_seam) != 1:
    raise SystemExit("self-audit red: per-leg judge seam changed")
text = text.replace(judge_seam, per_leg_judge)

leg_loop = '''    h=${ha%|*}; a=${ha#*|}
'''
with_leg_check = leg_loop + '''    leg_complete_sequence "$EVD/$a/leg.out" || return 1
'''
if text.count(leg_loop) != 1:
    raise SystemExit("self-audit red: architecture loop seam changed")
text = text.replace(leg_loop, with_leg_check)
target.write_text(text, encoding="utf-8")
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
chmod 700 "$DRIVER"

out="$BASE/out"
bash "$DRIVER" "$ROOT" > "$out" 2>&1
rc=$?
cat "$out"
if [ "$rc" -ne 0 ]; then
  printf 'FAIL\tms-runtime-rows-selfaudit-complete-red\treal fake leg refused canonical COMPLETE 1\n'
  exit 1
fi
printf 'PASS\tms-runtime-rows-selfaudit-complete-red\n'
