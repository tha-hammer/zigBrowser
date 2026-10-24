#!/usr/bin/env bash
# UNREGISTERED RED ORACLE (zigBrowser-4pa.73; SilverRidge f69c8dad): HOME evidence uses one canonical reversible
# ASCII encoding for every filesystem path and symlink target. The recorder must preserve arbitrary filename bytes,
# including CR, LF, tab, U+0002 and non-UTF-8, without record splitting or collisions; such names are audited and are
# never protected-path skips. The differ must decode the evidence before applying path semantics, accept identical
# snapshots as CLEAN, and emit complete encoded HOME-DELTA rows for a rename between otherwise valid snapshots.
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

/usr/bin/python3 -I -B -X utf8 - "$ROOT/tests/mac/ms1c_app_gate.sh" "$ROOT/tests/mac/ms1c_home_protected_paths.txt" "$BASE" <<'PY'
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
)
links: dict[bytes, bytes] = {}
for index, target in enumerate(link_targets):
    name = f"link-{index}".encode("ascii")
    os.symlink(target, os.path.join(root_b, name))
    links[name] = target

protected_rel = b"Library/Preferences/com.apple.morphology.internal.plist"
protected_path = os.path.join(root_b, protected_rel)
os.makedirs(os.path.dirname(protected_path), exist_ok=True)
fd = os.open(protected_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
os.write(fd, b"protected\n")
os.close(fd)


def snapshot(side: str, label: str) -> tuple[int, Path]:
    output = work / label
    old_argv, real_open = sys.argv, os.open

    def permission(path, flags, *args, **kwargs):
        if os.path.abspath(os.fsencode(path)) == os.path.abspath(protected_path) \
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
    markers: list[list[str]] = []
    for line in lines[1:-1]:
        if line.startswith("SKIPPED-PROTECTED\t"):
            markers.append(line.split("\t"))
            continue
        fields = line.split("\t", 1)
        if len(fields) != 2:
            bad(row, f"split ordinary record {line!r}")
            continue
        try:
            rel = decode(fields[0])
        except ValueError as error:
            bad(row, f"ordinary path is not canonical: {error}")
            continue
        ordinary.setdefault(rel, []).append(fields[1])

    wanted_paths = {b".", protected_rel, *names, *links}
    if set(ordinary) != wanted_paths or any(len(rows) != 1 for rows in ordinary.values()):
        bad(row, f"decoded paths differ: missing={wanted_paths - set(ordinary)!r}, extra={set(ordinary) - wanted_paths!r}")
    for name, target in links.items():
        meta = ordinary.get(name, [""])[0].split(" ", 10)
        try:
            got_target = decode(meta[10]) if len(meta) == 11 else None
        except ValueError as error:
            bad(row, f"symlink {name!r} target is not canonical: {error}")
            continue
        if not meta or meta[0] != "l" or got_target != target:
            bad(row, f"symlink {name!r} target {got_target!r}, wanted {target!r}")

    if len(markers) != 1:
        bad(row, f"wanted one exact protected marker, got {markers!r}")
    else:
        marker = markers[0]
        try:
            marker_path = decode(marker[3]) if len(marker) == 5 else None
        except ValueError as error:
            bad(row, f"marker path is not canonical: {error}")
            marker_path = None
        if marker[:3] != ["SKIPPED-PROTECTED", side, "HOME"] \
                or marker_path != protected_rel or marker[4:] != ["EACCES"]:
            bad(row, f"wrong protected marker {marker!r}")
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
                    "/control/zigBrowser"]
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


wanted_before = {b".", protected_rel, *names, *links}
before_rc, before = snapshot("BEFORE", "home.before")
after_same_rc, after_same = snapshot("AFTER", "home.after.same")
if before_rc != 0 or after_same_rc != 0:
    bad("round trip", f"snapshot rc before={before_rc}, after={after_same_rc}")
inspect_snapshot("BEFORE round trip", before, "BEFORE", wanted_before)
inspect_snapshot("AFTER round trip", after_same, "AFTER", wanted_before)
clean_rc, clean_out = differ("identical", before, after_same)
if clean_rc != 0 or clean_out != ["HOMEAUDIT\tCLEAN\t0"]:
    bad("identical", f"wanted exact CLEAN/0, got rc={clean_rc} {clean_out!r}")

old_name = b"tab\tname"
new_name = b"renamed\r\n\t\x02-\xff"
os.rename(os.path.join(root_b, old_name), os.path.join(root_b, new_name))
wanted_after = (wanted_before - {old_name}) | {new_name}
after_rc, after = snapshot("AFTER", "home.after.rename")
if after_rc != 0:
    bad("rename", f"after snapshot rc={after_rc}")
inspect_snapshot("AFTER rename", after, "AFTER", wanted_after)
rename_rc, rename_out = differ("rename", before, after)
old_full = encode(os.path.join(root_b, old_name))
new_full = encode(os.path.join(root_b, new_name))
delta_prefixes = {
    f"HOME-DELTA\tDELETED\t{old_full}\t",
    f"HOME-DELTA\tADDED\t{new_full}\t",
}
got_deltas = [line for line in rename_out if line.startswith("HOME-DELTA\t")]
if rename_rc != 2 or rename_out[-1:] != ["HOMEAUDIT\tCHANGED\t2"] or len(got_deltas) != 2 \
        or {next((prefix for prefix in delta_prefixes if line.startswith(prefix)), "") for line in got_deltas} != delta_prefixes:
    bad("rename", f"wanted two complete encoded deltas/2, got rc={rename_rc} {rename_out!r}")
try:
    for line in got_deltas:
        decode(line.split("\t", 3)[2])
except (IndexError, ValueError) as error:
    bad("rename", f"delta path is not canonical: {error}")

for problem in problems:
    print("FAIL " + problem)
if problems:
    print(f"FAIL\tms1c-home-codec-red\t{len(problems)} problem(s)")
    raise SystemExit(1)
print("PASS\tms1c-home-codec-red\tarbitrary-path-and-link-bytes")
PY
