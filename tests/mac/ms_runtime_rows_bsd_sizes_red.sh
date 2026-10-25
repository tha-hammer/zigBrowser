#!/usr/bin/env bash
# RED, UNREGISTERED: exercise the real two-host fake transport with BSD-style
# padded `wc -c` output. The producer must serialize canonical decimal sizes;
# the strict consumer continues to reject padding, wrong digests and sizes.
set -uo pipefail

ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-runtime-bsd-size-red-XXXXXX") || exit 1
cleanup() {
  case "$BASE" in "${TMPDIR:-/tmp}"/zb-runtime-bsd-size-red-??????)
    chmod -R u+rwx "${BASE:?}" 2>/dev/null
    rm -rf -- "${BASE:?}"
  esac
}
trap cleanup EXIT

# The consumer stays strict. These field-isolated controls must remain red.
python3 - "$ROOT" "$BASE" <<'PY'
import importlib.util
from pathlib import Path
import sys

root, base = map(Path, sys.argv[1:])
path = root / "tests/e2e/mac_signal_runtime_test.py"
sys.path.insert(0, str(path.parent))
spec = importlib.util.spec_from_file_location("signal_runtime_row", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)

def fixture(name: str, variant: str = "good"):
    run = base / name / ("zb-gate-" + "1" * 40 + "-deadbeef")
    return module.write_package_fixture(run, variant)

def mutate_field(evidence: Path, tag: str, index: int, value: str) -> None:
    rows = [line.split("\t") for line in evidence.read_text(encoding="utf-8").splitlines()]
    row = next(row for row in rows if row[0] == tag)
    row[index] = value
    evidence.write_text("".join("\t".join(row) + "\n" for row in rows), encoding="utf-8")

browser, evidence, commit = fixture("canonical")
problems, package_line = module.package_problems(browser, evidence, commit)
if problems or package_line is None:
    raise SystemExit(f"canonical package control failed: {problems!r} {package_line!r}")
print("ASSERT\tms-runtime-rows-bsd-sizes\tconsumer-canonical-green")

reason = "PK20 DMG digest/size does not match package evidence"
for name, variant, value in (
    ("wrong-digest", "wrong-dmg-digest", None),
    ("wrong-size", "good", "999999"),
    ("padded-size", "good", "  47"),
):
    browser, evidence, commit = fixture(name, variant)
    if value is not None:
        mutate_field(evidence, "PACKAGE_DMG", 2, value)
    problems, package_line = module.package_problems(browser, evidence, commit)
    if problems != [reason] or package_line is not None:
        raise SystemExit(f"strict consumer accepted {name}: {problems!r}")
    print(f"ASSERT\tms-runtime-rows-bsd-sizes\tconsumer-{name}-red")
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

SOURCE="$ROOT/tests/mac/ms_signal_runtime_gate_red.sh"
DRIVER="$BASE/ms_signal_runtime_gate_bsd_wc.sh"
python3 - "$SOURCE" "$DRIVER" <<'PY'
from pathlib import Path
import sys

source, target = map(Path, sys.argv[1:])
text = source.read_text(encoding="utf-8")
copy_row = '''cp -f "$ROOT/tests/e2e/mac_signal_runtime_test.py" "$R/tests/e2e/"
'''
copy_closure = '''for f in mac_signal_runtime_test.py automation_core_test.py automation_fixture_server.py slice2_common.py; do
  cp -f "$ROOT/tests/e2e/$f" "$R/tests/e2e/"
done
'''
if text.count(copy_row) != 1:
    raise SystemExit("BSD-size red: consumer import-closure seam changed")
text = text.replace(copy_row, copy_closure)

needle = '''cat > "$T/macbin/find" <<'EOF'
#!/bin/bash
exec /usr/bin/find "$@"
EOF
'''
replacement = needle + '''
cat > "$T/macbin/wc" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -c ] && [ "$#" -eq 1 ]; then
  n=$(/usr/bin/wc -c)
  printf '%8d\n' "$n"
else
  exec /usr/bin/wc "$@"
fi
EOF
'''
if text.count(needle) != 1:
    raise SystemExit("BSD-size red: wc insertion seam changed")
text = text.replace(needle, replacement)

chmod = 'chmod +x "$T/bin/ssh" "$T/bin/scp" "$T/macbin/getconf" "$T/macbin/find" "$T/macbin/python3"'
if text.count(chmod) != 1:
    raise SystemExit("BSD-size red: chmod seam changed")
text = text.replace(chmod, chmod + ' "$T/macbin/wc"')

consumer_seam = '''[ "${5:-}" = --package-commit ] && commit=${6:-} \\
  || { printf 'FAIL\\tmac-signal-runtime\\tmissing-package-commit\\n'; exit 1; }
'''
real_consumer = consumer_seam + '''if ! /usr/bin/python3 - "$row" "$browser" "$manifest" "$commit" <<'PYREAL'
import importlib.util
from pathlib import Path
import sys

row = Path(sys.argv[1]).resolve()
browser = Path(sys.argv[2])
evidence = Path(sys.argv[3])
commit = sys.argv[4]
sys.path.insert(0, str(row.parent))
spec = importlib.util.spec_from_file_location("signal_runtime_real_consumer", row)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
problems, package_line = module.package_problems(browser, evidence, commit)
if problems or package_line is None:
    for problem in problems:
        print(f"FAIL {problem}")
    raise SystemExit(1)
PYREAL
then
  exit 1
fi
'''
if text.count(consumer_seam) != 1:
    raise SystemExit("BSD-size red: real-consumer seam changed")
text = text.replace(consumer_seam, real_consumer)

for name in ("dmg", "browser", "build", "shim"):
    raw = '$(wc -c < "$' + name + '")'
    canonical = '$(wc -c < "$' + name + '" | tr -d \'[:space:]\')'
    if text.count(raw) != 1:
        raise SystemExit(f"BSD-size red: strict-consumer {name} seam changed")
    text = text.replace(raw, canonical)

run_seam = '''fresh_macs
run_gate
if [ "$RC" -ne 0 ]; then
'''
failure_judge = '''bsd_pk20_failure_exact() {
  local a row reason name
  for a in x86_64 arm64; do
    row=$(member "$a" "evidence/rows/$ID.out") || return 1
    [ "$(grep -c '^FAIL PK20 ' <<<"$row")" -eq 4 ] || return 1
    for name in DMG executable 'build executable' shim; do
      reason="FAIL PK20 $name digest/size does not match package evidence"
      [ "$(grep -cxF "$reason" <<<"$row")" -eq 1 ] || return 1
    done
    ! grep -qE 'ModuleNotFoundError|ImportError|Traceback' <<<"$row" || return 1
    ! grep -q '^SIGNAL_' <<<"$row" || return 1
  done
}

fresh_macs
run_gate
if [ "$RC" -ne 0 ]; then
  if bsd_pk20_failure_exact; then
    ok "bsd-padded-four-pk20-per-leg"
  else
    bad "G1 BSD-padded run did not reach exactly four PK20 records per leg"
  fi
'''
if text.count(run_seam) != 1:
    raise SystemExit("BSD-size red: integrated failure-judge seam changed")
text = text.replace(run_seam, failure_judge)

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
  if ! grep -qx $'ASSERT\tmac-signal-runtime\tbsd-padded-four-pk20-per-leg\tpass' "$out"; then
    printf 'FIXTURE_ERROR\tms-runtime-rows-bsd-sizes-red\tmissing exact per-leg PK20 proof\n'
    exit 2
  fi
  printf 'FAIL\tms-runtime-rows-bsd-sizes-red\treal manifest producer emitted padded sizes\n'
  exit 1
fi
printf 'PASS\tms-runtime-rows-bsd-sizes-red\n'
