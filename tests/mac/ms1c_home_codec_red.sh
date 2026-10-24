#!/usr/bin/env bash
# REGISTERED GREEN ORACLE (zigBrowser-4pa.73; SilverRidge 54dd191b): HOME evidence uses one canonical reversible
# ASCII encoding for every filesystem path and symlink target. The recorder must preserve arbitrary filename bytes,
# including CR, LF, tab, U+0002 and non-UTF-8, without record splitting or collisions; such names are audited and are
# never protected-path skips. The differ must decode the evidence before applying path semantics, accept identical
# snapshots as CLEAN, and emit complete encoded HOME-DELTA rows for a rename between otherwise valid snapshots. All
# three path-bearing streams stay in original-byte order, and the differ rejects every noncanonical evidence field.
set -uo pipefail

ROOT=$(realpath "${1:-.}") || exit 1
if [ "${ZB_MS1C_HOME_CODEC_INNER:-}" != 1 ]; then
  outer_net=$(readlink /proc/self/ns/net) || exit 1
  exec env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS \
    ZB_MS1C_HOME_CODEC_INNER=1 ZB_MS1C_HOME_CODEC_OUTER_NET="$outer_net" \
    unshare --user --map-current-user --net bash "$(realpath "$0")" "$ROOT"
fi
if [ -z "${ZB_MS1C_HOME_CODEC_OUTER_NET:-}" ] \
   || [ "$(readlink /proc/self/ns/net)" = "$ZB_MS1C_HOME_CODEC_OUTER_NET" ]; then
  printf 'FAIL\tms1c-home-codec-red\tnot in a private network namespace\n'
  exit 1
fi

BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-ms1c-home-codec-red-XXXXXX") || exit 1
case "$BASE" in
  "${TMPDIR:-/tmp}"/zb-ms1c-home-codec-red-??????) ;;
  *) printf 'FAIL\tms1c-home-codec-red\tunsafe temp path %s\n' "$BASE"; exit 1 ;;
esac
cleanup() { rm -rf -- "${BASE:?}"; }
trap cleanup EXIT

HARNESS="$BASE/home-codec.py"
cat > "$HARNESS" <<'PY'
from __future__ import annotations

import base64
import contextlib
import errno
import io
import os
import sys
from pathlib import Path

gate, reviewed, work = map(Path, sys.argv[1:4])
problems: list[str] = []


def bad(row: str, why: str) -> None:
    problems.append(f"{row}: {why}")


def extract(name: str) -> str:
    text = gate.read_text()
    mark = name + "='\n"
    try:
        start = text.index(mark) + len(mark)
        end = text.index("\n'\n", start)
    except ValueError as error:
        raise RuntimeError(f"cannot extract {name}") from error
    return text[start:end]


def encode(raw: bytes) -> str:
    return "b64:" + base64.urlsafe_b64encode(raw).decode("ascii")


def decode(field: str) -> bytes:
    if not field.startswith("b64:") or not field.isascii():
        raise ValueError(f"not a prefixed ASCII field: {field!r}")
    try:
        raw = base64.b64decode(field[4:].encode("ascii"), altchars=b"-_", validate=True)
    except (ValueError, base64.binascii.Error) as error:
        raise ValueError(f"invalid Base64 field: {field!r}") from error
    if encode(raw) != field:
        raise ValueError(f"non-canonical Base64 field: {field!r}")
    return raw


snap_source = extract("HOME_SNAP_PY")
diff_source = extract("HOME_DIFF_PY")
mutant = os.environ.get("ZB_MS1C_HOME_CODEC_MUTANT", "")
if mutant:
    if mutant != "encoded-text-sort":
        print(f"FAIL mutant setup: unknown mutant {mutant!r}")
        raise SystemExit(2)
    snap_anchors = {
        "for _k, line in sorted(rows):":
            "for _k, line in sorted(rows, key=lambda item: item[1]):",
        "for _k, line in sorted(set(skipped)):":
            "for _k, line in sorted(set(skipped), key=lambda item: item[1]):",
    }
    diff_anchors = {
        "for rel in sorted(set(a) | set(b)):":
            "for rel in sorted(set(a) | set(b), key=lambda value: evidence_field(os.fsencode(value))):",
    }
    for anchor, replacement in snap_anchors.items():
        if snap_source.count(anchor) != 1:
            print(f"FAIL mutant setup: snapshot anchor count {snap_source.count(anchor)} for {anchor!r}")
            raise SystemExit(2)
        snap_source = snap_source.replace(anchor, replacement)
    for anchor, replacement in diff_anchors.items():
        if diff_source.count(anchor) != 1:
            print(f"FAIL mutant setup: differ anchor count {diff_source.count(anchor)} for {anchor!r}")
            raise SystemExit(2)
        diff_source = diff_source.replace(anchor, replacement)

work.mkdir()
root = work / "home"
exclude = root / ("zb-gate-" + "0" * 40 + "-codec")
root.mkdir()
exclude.mkdir()

# Each byte string is a single filename (never a slash). The escape-looking forms prove that the encoding namespace
# does not collide with literal user names which resemble either this codec or common ad-hoc escape schemes.
names = (
    b"Icon\r",
    b"line\nbreak",
    b"tab\tname",
    "Ƭ".encode("utf-8") + b"\x02$\t::pinterest.heic",
    b"non-utf8-\xff",
    b"b64:SWNvbg0=",
    b"backslash-\\x0d-%0D",
    b"ordinary",
)
if len(names) != len(set(names)) or len({encode(name) for name in names}) != len(names):
    bad("setup", "raw or encoded filename collision")

root_b = os.fsencode(root)
for index, name in enumerate(names):
    fd = os.open(os.path.join(root_b, name), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(f"payload-{index}\n".encode("ascii"))

link_targets = (
    b"target\r",
    b"target\nline",
    b"target\tfield",
    b"target-\x02-\xff",
    b"b64:dGFyZ2V0",
    b"target-\\x0a-%0A",
    b"directory/target-\x02-\xff",
)
links: dict[bytes, bytes] = {}
for index, target in enumerate(link_targets):
    name = f"link-{index}".encode("ascii")
    os.symlink(target, os.path.join(root_b, name))
    links[name] = target

protected_rels = (
    b"Library/Biome/streams/restricted/Safari.PageLoad/local/795030430619125",
    b"Library/Biome/streams/restricted/Safari.PageLoad/local/tombstone/795296858958047",
    b"Library/Preferences/com.apple.morphology.internal.plist",
)
protected_paths: set[bytes] = set()
for protected_rel in protected_rels:
    protected_path = os.path.join(root_b, protected_rel)
    protected_paths.add(os.path.abspath(protected_path))
    os.makedirs(os.path.dirname(protected_path), exist_ok=True)
    fd = os.open(protected_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.write(fd, b"protected\n")
    os.close(fd)


def filesystem_census() -> set[bytes]:
    """Independent byte-path census of every entry the recorder must retain, excluding the run root by identity."""
    found = {b"."}
    for dirpath, dirs, filenames in os.walk(root_b, topdown=True, followlinks=False):
        if dirpath == root_b:
            dirs[:] = [name for name in dirs if os.path.join(root_b, name) != os.fsencode(exclude)]
        for name in dirs + filenames:
            found.add(os.path.relpath(os.path.join(dirpath, name), root_b))
    return found


def snapshot(side: str, label: str) -> tuple[int, Path]:
    output = work / label
    old_argv, real_open = sys.argv, os.open

    def permission(path, flags, *args, **kwargs):
        if os.path.abspath(os.fsencode(path)) in protected_paths \
                and flags & os.O_WRONLY == 0 and flags & os.O_RDWR == 0:
            raise OSError(errno.EACCES, os.strerror(errno.EACCES), os.fsdecode(path))
        return real_open(path, flags, *args, **kwargs)

    rc = 0
    try:
        os.open = permission
        sys.argv = ["home-snapshot", str(root), str(exclude), str(reviewed), side, str(output)]
        try:
            exec(compile(snap_source, "HOME_SNAP_PY", "exec"), {"__name__": "__main__"})
        except SystemExit as stopped:
            rc = int(stopped.code or 0)
    except Exception as error:
        bad(label, f"uncaught {type(error).__name__}: {error}")
        rc = 99
    finally:
        os.open = real_open
        sys.argv = old_argv
    return rc, output


def inspect_snapshot(row: str, path: Path, side: str, expected_names: set[bytes]) -> None:
    try:
        raw = path.read_bytes()
        raw.decode("ascii")
    except (OSError, UnicodeDecodeError) as error:
        bad(row, f"snapshot is not readable ASCII: {error}")
        return
    lines = raw.decode("ascii").splitlines()
    if any(line.startswith("ERROR\t") for line in lines):
        bad(row, f"arbitrary bytes became ERROR rows: {[line for line in lines if line.startswith('ERROR')]!r}")
    if len(lines) < 3 or not lines[0].startswith("ROOT\t") or not lines[-1].startswith("END\t"):
        bad(row, f"invalid envelope: {lines[:1]!r} ... {lines[-1:]!r}")
        return
    root_fields = lines[0].split("\t")
    try:
        got_roots = tuple(decode(field) for field in root_fields[1:])
    except ValueError as error:
        bad(row, f"ROOT path is not canonical: {error}")
        got_roots = ()
    wanted_roots = (os.fsencode(root), os.fsencode(exclude))
    if root_fields[:1] != ["ROOT"] or got_roots != wanted_roots:
        bad(row, f"ROOT fields {got_roots!r}, wanted {wanted_roots!r}")

    ordinary: dict[bytes, list[str]] = {}
    ordinary_order: list[bytes] = []
    markers: list[list[str]] = []
    marker_order: list[bytes] = []
    marker_phase = False
    for line in lines[1:-1]:
        if line.startswith("SKIPPED-PROTECTED\t"):
            marker_phase = True
            markers.append(line.split("\t"))
            continue
        if marker_phase:
            bad(row, f"ordinary record appears after protected markers: {line!r}")
        fields = line.split("\t", 1)
        if len(fields) != 2:
            bad(row, f"split ordinary record {line!r}")
            continue
        try:
            rel = decode(fields[0])
        except ValueError as error:
            bad(row, f"ordinary path is not canonical: {error}")
            continue
        ordinary_order.append(rel)
        ordinary.setdefault(rel, []).append(fields[1])

    wanted_paths = expected_names
    if set(ordinary) != wanted_paths or any(len(rows) != 1 for rows in ordinary.values()):
        bad(row, f"decoded paths differ: missing={wanted_paths - set(ordinary)!r}, extra={set(ordinary) - wanted_paths!r}")
    if ordinary_order != sorted(wanted_paths):
        bad(row, f"ordinary record order is not raw-byte order: {ordinary_order!r}")
    for name, target in links.items():
        meta = ordinary.get(name, [""])[0].split(" ", 10)
        try:
            got_target = decode(meta[10]) if len(meta) == 11 else None
        except ValueError as error:
            bad(row, f"symlink {name!r} target is not canonical: {error}")
            continue
        if not meta or meta[0] != "l" or got_target != target:
            bad(row, f"symlink {name!r} target {got_target!r}, wanted {target!r}")

    if len(markers) != len(protected_rels):
        bad(row, f"wanted {len(protected_rels)} exact protected markers, got {markers!r}")
    for marker in markers:
        try:
            marker_path = decode(marker[3]) if len(marker) == 5 else None
        except ValueError as error:
            bad(row, f"marker path is not canonical: {error}")
            marker_path = None
        if marker_path is not None:
            marker_order.append(marker_path)
        if marker[:3] != ["SKIPPED-PROTECTED", side, "HOME"] \
                or marker_path not in protected_rels or marker[4:] != ["EACCES"]:
            bad(row, f"wrong protected marker {marker!r}")
    if marker_order != sorted(protected_rels):
        bad(row, f"protected marker order is not raw-byte order: {marker_order!r}")
    weird = set(names) | set(links)
    for marker in markers:
        try:
            if len(marker) == 5 and decode(marker[3]) in weird:
                bad(row, f"arbitrary-byte path was incorrectly skipped: {marker!r}")
        except ValueError:
            pass
    if lines[-1:] != [f"END\t{len(ordinary)}"]:
        bad(row, f"END mismatch: {lines[-1:]!r}, rows={len(ordinary)}")
    if set(ordinary) != expected_names:
        bad(row, "snapshot path set does not match this phase")


def differ(row: str, before: Path, after: Path) -> tuple[int, list[str]]:
    old_argv = sys.argv
    output = io.StringIO()
    rc = 0
    try:
        sys.argv = ["home-diff", str(before), str(after), str(root), "Library/Logs/DiagnosticReports",
                    "/control/zigBrowser", str(reviewed)]
        with contextlib.redirect_stdout(output):
            try:
                exec(compile(diff_source, "HOME_DIFF_PY", "exec"), {"__name__": "__main__"})
            except SystemExit as stopped:
                rc = int(stopped.code or 0)
    except Exception as error:
        bad(row, f"uncaught {type(error).__name__}: {error}")
        rc = 99
    finally:
        sys.argv = old_argv
    return rc, output.getvalue().splitlines()


wanted_before = filesystem_census()
before_rc, before = snapshot("BEFORE", "home.before")
after_same_rc, after_same = snapshot("AFTER", "home.after.same")
if before_rc != 0 or after_same_rc != 0:
    bad("round trip", f"snapshot rc before={before_rc}, after={after_same_rc}")
inspect_snapshot("BEFORE round trip", before, "BEFORE", wanted_before)
inspect_snapshot("AFTER round trip", after_same, "AFTER", wanted_before)
clean_rc, clean_out = differ("identical", before, after_same)
if clean_rc != 0 or clean_out != ["HOMEAUDIT\tCLEAN\t0"]:
    bad("identical", f"wanted exact CLEAN/0, got rc={clean_rc} {clean_out!r}")

# The differ must reject corrupt evidence as evidence, not normalize it into some other filesystem path. Each pair
# is otherwise a complete one-row snapshot. The noncanonical spelling uses the standard Base64 slash in place of
# the canonical URL-safe underscore, so a permissive decoder would silently turn it into the same b"\xff" path.
strict_dir = work / "strict"
strict_dir.mkdir()
strict_meta = "f 600 1 1 1 0 0 0 1 " + "0" * 64 + " -"
strict_root = f"ROOT\t{encode(os.fsencode(root))}\t{encode(os.fsencode(exclude))}"
canonical_path = encode(b"\xff")


def strict_snapshot(path: Path, path_field: str) -> None:
    path.write_text(f"{strict_root}\n{path_field}\t{strict_meta}\nEND\t1\n", encoding="ascii")


for label, corrupt in (
    ("unprefixed", "not-prefixed"),
    ("invalid", "b64:%%%="),
    ("noncanonical", canonical_path.replace("_", "/")),
):
    strict_before = strict_dir / f"{label}.before"
    strict_after = strict_dir / f"{label}.after"
    strict_snapshot(strict_before, canonical_path)
    strict_snapshot(strict_after, corrupt)
    strict_rc, strict_out = differ("strict " + label, strict_before, strict_after)
    want = ["HOMEAUDIT\tINCONCLUSIVE\tthe after snapshot is incomplete"]
    if strict_rc != 3 or strict_out != want \
            or any(line.startswith("HOME-DELTA\t") or "\tCLEAN\t" in line for line in strict_out):
        bad("strict " + label, f"wanted exact bounded INCONCLUSIVE/3 and no delta/CLEAN, got rc={strict_rc} {strict_out!r}")

# The old/new names deliberately invert under encoded-text sorting: raw bytes put line before ordinary, while their
# Base64 payloads put ordinary before line. The emitted delta order therefore binds decoding followed by byte sort.
old_name = b"line\nbreak"
new_name = b"ordinary-renamed\r\t\x02-\xff"
os.rename(os.path.join(root_b, old_name), os.path.join(root_b, new_name))
wanted_after = (wanted_before - {old_name}) | {new_name}
after_rc, after = snapshot("AFTER", "home.after.rename")
if after_rc != 0:
    bad("rename", f"after snapshot rc={after_rc}")
inspect_snapshot("AFTER rename", after, "AFTER", wanted_after)


def isolate_rename(before_path: Path, after_path: Path) -> Path:
    """Keep the recorder-driven pair, but hold the home directory row fixed so only the renamed leaf is a delta."""
    try:
        before_lines = before_path.read_text(encoding="ascii").splitlines()
        after_lines = after_path.read_text(encoding="ascii").splitlines()
        prefix = encode(b".") + "\t"
        before_root = [line for line in before_lines if line.startswith(prefix)]
        positions = [index for index, line in enumerate(after_lines) if line.startswith(prefix)]
        if len(before_root) != 1 or len(positions) != 1:
            return after_path
        after_lines[positions[0]] = before_root[0]
        isolated = work / "home.after.rename.isolated"
        isolated.write_text("\n".join(after_lines) + "\n", encoding="ascii")
        return isolated
    except (OSError, UnicodeError):
        return after_path


rename_rc, rename_out = differ("rename", before, isolate_rename(before, after))
old_full = encode(os.path.join(root_b, old_name))
new_full = encode(os.path.join(root_b, new_name))
got_deltas = [line for line in rename_out if line.startswith("HOME-DELTA\t")]
decoded_deltas: list[tuple[str, bytes]] = []
for line in got_deltas:
    fields = line.split("\t")
    try:
        delta_path = decode(fields[2]) if len(fields) == 5 else None
    except ValueError as error:
        bad("rename", f"delta path is not canonical: {error}")
        delta_path = None
    if delta_path is not None:
        decoded_deltas.append((fields[1], delta_path))
expected_deltas = [
    ("DELETED", os.path.join(root_b, old_name)),
    ("ADDED", os.path.join(root_b, new_name)),
]
if rename_rc != 2 or rename_out[-1:] != ["HOMEAUDIT\tCHANGED\t2"] or len(got_deltas) != 2 \
        or decoded_deltas != expected_deltas \
        or not got_deltas[0].startswith(f"HOME-DELTA\tDELETED\t{old_full}\t") \
        or not got_deltas[1].startswith(f"HOME-DELTA\tADDED\t{new_full}\t"):
    bad("rename", f"wanted two complete encoded deltas/2, got rc={rename_rc} {rename_out!r}")
if [path for _kind, path in decoded_deltas] != sorted(path for _kind, path in decoded_deltas):
    bad("rename", f"HOME-DELTA order is not raw-byte order: {decoded_deltas!r}")

for problem in problems:
    print("FAIL " + problem)
if problems:
    print(f"FAIL\tms1c-home-codec-red\t{len(problems)} problem(s)")
    raise SystemExit(1)
print("PASS\tms1c-home-codec-red\tarbitrary-path-and-link-bytes")
PY

set +e
/usr/bin/python3 -I -B -X utf8 "$HARNESS" "$ROOT/tests/mac/ms1c_app_gate.sh" \
  "$ROOT/tests/mac/ms1c_home_protected_paths.txt" "$BASE/main"
main_rc=$?
set -e
if [ "$main_rc" -ne 0 ]; then
  exit "$main_rc"
fi

MUTANT_OUT="$BASE/encoded-text-sort.out"
set +e
ZB_MS1C_HOME_CODEC_MUTANT=encoded-text-sort \
  /usr/bin/python3 -I -B -X utf8 "$HARNESS" "$ROOT/tests/mac/ms1c_app_gate.sh" \
    "$ROOT/tests/mac/ms1c_home_protected_paths.txt" "$BASE/mutant" > "$MUTANT_OUT" 2>&1
mutant_rc=$?
set -e
if [ "$mutant_rc" -eq 0 ]; then
  printf 'FAIL\tms1c-home-codec-red\tencoded-text-sort mutant survived\n'
  exit 1
fi
if ! grep -Eq '^FAIL (BEFORE|AFTER) .*record order is not raw-byte order|^FAIL (BEFORE|AFTER) .*protected marker order is not raw-byte order|^FAIL rename: .*HOME-DELTA order is not raw-byte order' "$MUTANT_OUT"; then
  printf 'FAIL\tms1c-home-codec-red\tencoded-text-sort mutant failed for the wrong reason: %s\n' \
    "$(tail -n 3 "$MUTANT_OUT" | tr '\n' ' ')"
  exit 1
fi
printf 'PASS\tms1c-home-codec-mutant\tencoded-text-sort red\n'
