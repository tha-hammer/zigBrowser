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

def fixture(name: str):
    run = base / name / ("zb-gate-" + "1" * 40 + "-deadbeef")
    return module.write_package_fixture(run, "good")

def mutate_field(evidence: Path, tag: str, index: int, value: str) -> None:
    rows = [line.split("\t") for line in evidence.read_text(encoding="utf-8").splitlines()]
    row = next(row for row in rows if row[0] == tag)
    row[index] = value
    evidence.write_text("".join("\t".join(row) + "\n" for row in rows), encoding="utf-8")

for name, index, value in (
    ("wrong-digest", 1, "0" * 64),
    ("wrong-size", 2, "999999"),
    ("padded-size", 2, "  47"),
):
    browser, evidence, commit = fixture(name)
    mutate_field(evidence, "PACKAGE_DMG", index, value)
    problems, package_line = module.package_problems(browser, evidence, commit)
    has_expected_reason = bool(problems) if name == "wrong-digest" else any(
        problem.startswith("PK20 ") for problem in problems
    )
    if not has_expected_reason or package_line is not None:
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
  printf 'FAIL\tms-runtime-rows-bsd-sizes-red\treal manifest producer emitted padded sizes\n'
  exit 1
fi
printf 'PASS\tms-runtime-rows-bsd-sizes-red\n'
