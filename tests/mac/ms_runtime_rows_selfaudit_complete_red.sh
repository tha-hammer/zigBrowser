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
      printf 'recorded owner-policy delta\n' > "$ZB_FAKE_MAC/vf/0/T/recorded-delta"
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

needle = '  text=$(cat "$of")\n'
extra = '''  text=$(cat "$of")
  [ "$(grep -cx $'SELFAUDIT\\tinner-varfolders\\tVARFOLDERS\\tCOMPLETE\\t1' <<<"$text")" -eq 1 ] || return 1
  [ "$(grep -c $'^SELFAUDIT\\tinner-varfolders\\tVARFOLDERS-DELTA\\t' <<<"$text")" -eq 1 ] || return 1
  [ "$(grep -cx $'SELFAUDIT\\touter-end\\tVARFOLDERS\\tCOMPLETE\\t1' <<<"$text")" -eq 1 ] || return 1
  [ "$(grep -c $'^SELFAUDIT\\touter-end\\tVARFOLDERS-DELTA\\t' <<<"$text")" -eq 1 ] || return 1
'''
if text.count(needle) != 1:
    raise SystemExit("self-audit red: success judge seam changed")
text = text.replace(needle, extra)
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
