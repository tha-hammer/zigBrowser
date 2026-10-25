#!/usr/bin/env bash
# REGISTERED GREEN ORACLE (zigBrowser-4pa.73; owner decision 2026-10-24): the MS1c HOME snapshots may skip only the exact
# paths in tests/mac/ms1c_home_protected_paths.txt, and only for EACCES/EPERM. Every accepted observation records
# SKIPPED-PROTECTED<TAB><BEFORE|AFTER><TAB>HOME<TAB><canonical-path><TAB><EACCES|EPERM> plus its available lstat
# identity. Every other path or errno remains incomplete, while arbitrary filename bytes remain ordinary audited
# entries rather than permission skips.
#
# The data file is the byte-sorted set of all 98 Permission-denied/Operation-not-permitted HOME ERROR paths in the
# released b0409175 arm64 evidence. Its one filename-format ERROR is intentionally excluded: it was not an unreadable
# protected path. The Intel HOME snapshot did not run because the separate /var/folders audit refused first.
#
# This reuses the registered MS1c executing fake-Mac fixture only through its setup boundary, commits the reviewed
# data file into that fixture's clean source tree, drives the real gate, and directly drives its embedded snapshot/
# diff programs for side, errno, exhaustive exact-match, readable-path, metadata and transition boundaries. The
# direct driver also exposes six field-isolated broad-match mutants so the intended green must reject prefix, family
# and glob matching independently at both the early FileProvider entry and a CoreSpotlight entry.
set -uo pipefail

ROOT=$(realpath "${1:-.}")
SOURCE="$ROOT/tests/mac/ms1c_app_gate_selftest.sh"
LIST="$ROOT/tests/mac/ms1c_home_protected_paths.txt"
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-ms1c-home-protected-red-XXXXXX") || exit 1
case "$BASE" in "${TMPDIR:-/tmp}"/zb-ms1c-home-protected-red-??????) ;; *) echo "FAIL: unsafe temp path: $BASE" >&2; exit 1 ;; esac
cleanup() { rm -rf -- "${BASE:?}"; }
trap cleanup EXIT

marker=$(grep -nFx '# ── Base run ──' "$SOURCE" | cut -d: -f1)
[ -n "$marker" ] && [ "$(grep -cFx '# ── Base run ──' "$SOURCE")" -eq 1 ] || {
  echo "FAIL: could not find the unique MS1c fixture boundary" >&2; exit 1;
}
DRIVER="$BASE/driver.sh"
head -n "$marker" "$SOURCE" > "$DRIVER" || exit 1
cat >> "$DRIVER" <<'DRIVER'

LIST="$ROOT/tests/mac/ms1c_home_protected_paths.txt"
LIST_SHA=34c7f1a9a3b647486bcceaba19c53b10247eb5fd93edfff456c3bec81da210a9

# Bind the reviewed data artifact itself: 98 exact, relative, byte-sorted paths and no comments, globs or broad
# ancestor entries. The digest is over the paths extracted from the released arm64 home.before ERROR lines.
list_shape=ok
[ -f "$LIST" ] || list_shape=missing
[ "$(wc -l < "$LIST" 2>/dev/null)" -eq 98 ] 2>/dev/null || list_shape="$list_shape count"
[ "$(sha256sum "$LIST" 2>/dev/null | awk '{ print $1 }')" = "$LIST_SHA" ] || list_shape="$list_shape digest"
[ "$(LC_ALL=C sort -u "$LIST" 2>/dev/null | wc -l)" -eq 98 ] 2>/dev/null || list_shape="$list_shape order-or-duplicate"
cmp -s "$LIST" <(LC_ALL=C sort -u "$LIST") || list_shape="$list_shape unsorted"
if grep -Eq '(^/|^$|(^|/)\.\.(/|$)|[?*\[])' "$LIST" 2>/dev/null; then list_shape="$list_shape non-exact"; fi
if [ "$list_shape" = ok ]; then
  ok "H1: reviewed data is the exact 98-path protected set from released HOME errors ($LIST_SHA)"
else
  bad "H1: protected-path data is not the reviewed set: $list_shape"
fi

# The production gate receives the data through the same clean committed tree that build-on-mac stages.
cp -f -- "$LIST" "$R/tests/mac/ms1c_home_protected_paths.txt" || exit 1
"${GIT[@]}" add -- tests/mac/ms1c_home_protected_paths.txt \
  && "${GIT[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m protected-data \
  || { bad "could not add protected-path data to the scratch repo"; exit 1; }
TREE=$("${GIT[@]}" rev-parse 'HEAD^{tree}')
COMMITSHA=$("${GIT[@]}" rev-parse HEAD)

protected_files() { # protected_files <mode>: create every reviewed path unreadable, or restore it readable
  local mode=$1 rel p
  while IFS= read -r rel; do
    p="$X/hosts/intel/$rel"
    mkdir -p -- "${p%/*}" || return 1
    if [ "$mode" = lock ]; then printf 'protected\n' > "$p" || return 1; chmod 000 "$p" || return 1
    else chmod 600 "$p" || return 1
    fi
  done < "$LIST"
}
snapshot_has_all_skips() { # snapshot_has_all_skips <file>
  local snap=$1 side=$2
  [ -f "$snap" ] || return 1
  /usr/bin/python3 -I -B -X utf8 - "$snap" "$LIST" "$side" <<'PY'
import base64, binascii, os, sys
snapshot, reviewed, side = sys.argv[1:4]
def field(value):
    return "b64:" + base64.urlsafe_b64encode(os.fsencode(value)).decode("ascii")
def decode(value):
    if not value.startswith("b64:") or not value.isascii():
        raise ValueError
    raw = base64.b64decode(value[4:].encode("ascii"), altchars=b"-_", validate=True)
    if field(raw) != value:
        raise ValueError
    return raw
try:
    lines = open(snapshot, encoding="ascii").read().splitlines()
    wanted = open(reviewed, "rb").read().splitlines()
    rows, markers = {}, []
    for line in lines[1:-1]:
        if line.startswith("ERROR\t"):
            raise ValueError
        if line.startswith("SKIPPED-PROTECTED\t"):
            parts = line.split("\t")
            if len(parts) != 5 or parts[:3] != ["SKIPPED-PROTECTED", side, "HOME"] or parts[4] != "EACCES":
                raise ValueError
            markers.append(decode(parts[3]))
        else:
            path, meta = line.split("\t", 1)
            rows.setdefault(decode(path), []).append(meta)
    if markers != wanted or lines[-1:] != [f"END\t{len(rows)}"]:
        raise ValueError
    for path in wanted:
        meta = rows.get(path, [])
        parts = meta[0].split(" ") if len(meta) == 1 else []
        if len(parts) != 11 or parts[0] != "f" or parts[1] != "0" or parts[9:] != ["-", "-"]:
            raise ValueError
except (OSError, UnicodeError, ValueError, binascii.Error):
    raise SystemExit(1)
PY
}
home_field() {
  /usr/bin/python3 -I -B -c 'import base64,os,sys; print("b64:" + base64.urlsafe_b64encode(os.fsencode(sys.argv[1])).decode("ascii"))' "$1"
}

# Every reviewed path is exercised, not merely sampled. A complete before and after snapshot must each report all
# 98 skips, and the leg log must retain both sets as evidence while the ordinary workload completes.
protected_files lock || { bad "H2: could not create the protected-path fixture"; exit 1; }
run_gate protected-list
HL="$EV/x86_64/evidence/leg.log"
if [ "$rc" -eq 0 ] && leg_is x86_64 PASS && leg_is arm64 PASS && ! no_pass \
   && snapshot_has_all_skips "$EV/x86_64/evidence/home.before" BEFORE \
   && snapshot_has_all_skips "$EV/x86_64/evidence/home.after" AFTER \
   && [ "$(grep -c "^SKIPPED-PROTECTED${TB}" "$HL" 2>/dev/null)" -eq 196 ]; then
  ok "H2: all 98 listed unreadable paths are SKIPPED-PROTECTED in both snapshots and the workload passes"
else
  bad "H2: listed paths were not exact reported skips; exit $rc, skips=$(grep -c "^SKIPPED-PROTECTED${TB}" "$HL" 2>/dev/null || true), errors=$(grep -c "^ERROR${TB}" "$HL" 2>/dev/null || true): $(tailout)"
fi

# Exact-match control: a nearby unreadable file absent from the reviewed data must remain an ERROR. The before audit
# must stop this Mac before any workload or control is launched.
protected_files unlock || { bad "H3: could not restore the protected-path fixture"; exit 1; }
UNLISTED='Library/Preferences/com.apple.morphology.not-reviewed.plist'
UNLISTED_FIELD=$(home_field "$UNLISTED") || exit 1
printf 'unlisted\n' > "$X/hosts/intel/$UNLISTED" && chmod 000 "$X/hosts/intel/$UNLISTED" || exit 1
run_gate unlisted-protected
HL="$EV/x86_64/evidence/leg.log"
if [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && leg_is arm64 PASS && no_pass \
   && [ -z "$(pyrows intel)" ] \
   && grep -qxF "ERROR${TB}$UNLISTED_FIELD${TB}Permission denied" "$EV/x86_64/evidence/home.before" 2>/dev/null \
   && ! grep -qF "SKIPPED-PROTECTED${TB}BEFORE${TB}HOME${TB}$UNLISTED_FIELD${TB}" "$HL" 2>/dev/null; then
  ok "H3: an unlisted unreadable sibling stays ERROR and INCONCLUSIVE before workload"
else
  bad "H3: unlisted unreadable path did not fail closed; exit $rc, intel rows '$(pyrows intel)': $(tailout)"
fi

# Directly exercise the embedded recorder and differ. This binds the future production interface used by take():
#   HOME_SNAP_PY <home> <excluded-run-root> <reviewed-list> <BEFORE|AFTER> <output>
# and preserves HOME_DIFF_PY's existing inputs plus the reviewed protected list. The subprocess stays inside this selftest's private namespaces.
DIRECT="$T/home-direct.py"
cat > "$DIRECT" <<'PY'
from __future__ import annotations

import base64
import binascii
import errno
import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

gate, reviewed, scratch = map(Path, sys.argv[1:4])
text = gate.read_text()
paths = reviewed.read_text().splitlines()
problems: list[str] = []


def bad(row: str, why: str) -> None:
    problems.append(f"{row}: {why}")


def field(value) -> str:
    return "b64:" + base64.urlsafe_b64encode(os.fsencode(value)).decode("ascii")


def decode(value: str) -> bytes:
    if not value.startswith("b64:") or not value.isascii():
        raise ValueError("not a canonical evidence field")
    raw = base64.b64decode(value[4:].encode("ascii"), altchars=b"-_", validate=True)
    if field(raw) != value:
        raise ValueError("not a canonical evidence field")
    return raw


def extract(name: str) -> str:
    mark = name + "='\n"
    start = text.index(mark) + len(mark)
    end = text.index("\n'\n", start)
    return text[start:end]


snap_source = extract("HOME_SNAP_PY")
diff_source = extract("HOME_DIFF_PY")

# These are causal controls for the literal-membership oracle. Each changes only the intended green predicate and is
# run by the outer driver after the candidate passes. The two sites are deliberately far apart in the reviewed set:
# its first FileProvider entry and its first CoreSpotlight entry.
mutant = os.environ.get("ZB_MS1C_HOME_MATCH_MUTANT", "")
mutant_predicates = {
    "prefix-fileprovider": 'rel_raw.startswith(b"Library/Application Support/FileProvider/6C899D1B-D76E-47F6-840A-186D246B9E1E/wharf/tombstone/")',
    "family-fileprovider": 'rel_raw.startswith(b"Library/Application Support/FileProvider/")',
    "glob-fileprovider": '__import__("fnmatch").fnmatchcase(os.fsdecode(rel_raw), "Library/Application Support/FileProvider/*/wharf/tombstone/*")',
    "prefix-corespotlight": 'rel_raw.startswith(b"Library/Metadata/CoreSpotlight/NSFileProtectionComplete/index.spotlightV3/")',
    "family-corespotlight": 'rel_raw.startswith(b"Library/Metadata/CoreSpotlight/")',
    "glob-corespotlight": '__import__("fnmatch").fnmatchcase(os.fsdecode(rel_raw), "Library/Metadata/CoreSpotlight/*/index.spotlightV3/*")',
}
if mutant:
    predicate = mutant_predicates.get(mutant)
    anchor = "if rel_raw in protected and reason:"
    if predicate is None or snap_source.count(anchor) != 1:
        print(f"FAIL mutant setup: mode={mutant!r}, anchor-count={snap_source.count(anchor)}")
        raise SystemExit(2)
    snap_source = snap_source.replace(anchor, f"if (rel_raw in protected or ({predicate})) and reason:")


def meta(path: Path, digest: str) -> str:
    st = path.lstat()
    kind = "f" if stat.S_ISREG(st.st_mode) else "d" if stat.S_ISDIR(st.st_mode) else "o"
    return "%s %o %d %d %d %d %d %d %d %s -" % (
        kind, stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid, st.st_nlink, st.st_size, st.st_mtime_ns,
        st.st_ctime_ns, st.st_ino, digest,
    )


class Fixture:
    def __init__(self) -> None:
        self.work = Path(tempfile.mkdtemp(prefix="home-protected-", dir=scratch))
        self.root = self.work / "home"
        self.root.mkdir()
        self.exclude = self.root / ("zb-gate-" + "0" * 40 + "-a")
        self.exclude.mkdir()
        self.list = self.work / "reviewed.txt"
        shutil.copyfile(reviewed, self.list)
        self.locked_dirs: list[Path] = []

    def path(self, rel: str) -> Path:
        return self.root / rel

    def file(self, rel: str, mode: int = 0o600) -> Path:
        path = self.path(rel)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"protected\n")
        path.chmod(mode)
        return path

    def directory(self, rel: str, mode: int = 0o700) -> Path:
        path = self.path(rel)
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(mode)
        if mode == 0:
            self.locked_dirs.append(path)
        return path

    def snapshot(
        self,
        side: str,
        forced: tuple[Path, int] | None = None,
        name: str | None = None,
        forced_many: dict[Path, int] | None = None,
    ) -> tuple[int, Path]:
        output = self.work / (name or ("home." + side.lower()))
        list_copy = self.work / ("list-" + output.name)
        shutil.copyfile(reviewed, list_copy)
        real_open = os.open
        forced_errors = {}
        if forced is not None:
            target, number = forced
            forced_errors[os.path.abspath(target)] = number
        if forced_many is not None:
            forced_errors.update((os.path.abspath(target), number) for target, number in forced_many.items())
        if forced_errors:
            def replacement(path, flags, *args, **kwargs):
                absolute = os.path.abspath(os.fspath(path))
                if absolute in forced_errors:
                    number = forced_errors[absolute]
                    raise OSError(number, os.strerror(number), os.fspath(path))
                return real_open(path, flags, *args, **kwargs)
            os.open = replacement
        old_argv = sys.argv
        rc = 0
        try:
            sys.argv = ["home-snapshot", str(self.root), str(self.exclude), str(list_copy), side, str(output)]
            try:
                exec(compile(snap_source, "HOME_SNAP_PY", "exec"), {"__name__": "__main__"})
            except SystemExit as stopped:
                rc = int(stopped.code or 0)
        except Exception as error:
            bad("direct snapshot", f"uncaught {type(error).__name__}: {error}")
            rc = 99
        finally:
            sys.argv = old_argv
            os.open = real_open
        return rc, output

    def close(self) -> None:
        for path in sorted(self.locked_dirs, key=lambda item: len(item.parts), reverse=True):
            if path.exists():
                path.chmod(0o700)
        shutil.rmtree(self.work)


def lines(path: Path) -> list[str]:
    return path.read_text(encoding="ascii").splitlines() if path.is_file() else []


def marker(side: str, rel: str, reason: str) -> str:
    return f"SKIPPED-PROTECTED\t{side}\tHOME\t{field(rel)}\t{reason}"


def row_for(body: list[str], rel: str) -> list[str]:
    found = []
    for line in body:
        if line.startswith(("ROOT\t", "ERROR\t", "END\t", "SKIPPED-PROTECTED\t")):
            continue
        try:
            path, meta = line.split("\t", 1)
            if decode(path) == os.fsencode(rel):
                found.append(meta)
        except (ValueError, binascii.Error):
            pass
    return found


def expect_skip(row: str, fixture: Fixture, side: str, rel: str, reason: str, forced: int | None = None) -> Path:
    target = fixture.path(rel)
    rc, output = fixture.snapshot(side, (target, forced) if forced is not None else None, row.replace(" ", "-"))
    body = lines(output)
    want_meta = meta(target, "-")
    if rc != 0:
        bad(row, f"wanted complete snapshot, got rc={rc}")
    if body.count(marker(side, rel, reason)) != 1:
        bad(row, f"wanted one exact marker, got {[line for line in body if line.startswith('SKIPPED-PROTECTED')]!r}")
    if row_for(body, rel) != [want_meta]:
        bad(row, f"wanted retained lstat row {want_meta!r}, got {row_for(body, rel)!r}")
    if any(line.startswith("ERROR\t") for line in body):
        bad(row, f"accepted permission error left ERROR rows {body[-5:]!r}")
    return output


def expect_error(row: str, setup, expected_rel: str, forced: int | None = None) -> None:
    fixture = Fixture()
    try:
        target = setup(fixture)
        output_name = row.replace(" ", "-").replace("/", "-")
        rc, output = fixture.snapshot("BEFORE", (target, forced) if forced is not None else None, output_name)
        body = lines(output)
        if rc != 3 or any(line.startswith("SKIPPED-PROTECTED\t") for line in body):
            bad(row, f"wanted incomplete non-skip, got rc={rc} tail={body[-5:]!r}")
        expected = f"ERROR\t{field(expected_rel)}\t{os.strerror(forced)}" if forced is not None else None
        if expected is not None and body.count(expected) != 1:
            bad(row, f"wanted one exact {expected!r}, got {[line for line in body if line.startswith('ERROR')]!r}")
        elif expected is None and not any(line.startswith("ERROR\t" + field(expected_rel) + "\t") for line in body):
            bad(row, f"missing exact ERROR path for {expected_rel!r}: {body[-5:]!r}")
    finally:
        fixture.close()


def expect_error_batch(row: str, rels: list[str]) -> None:
    fixture = Fixture()
    try:
        targets = {fixture.file(rel): errno.EACCES for rel in rels}
        rc, output = fixture.snapshot("BEFORE", name=row.replace(" ", "-"), forced_many=targets)
        body = lines(output)
        actual = sorted(line for line in body if line.startswith("ERROR\t"))
        wanted = sorted(f"ERROR\t{field(rel)}\t{os.strerror(errno.EACCES)}" for rel in rels)
        skips = [line for line in body if line.startswith("SKIPPED-PROTECTED\t")]
        if rc != 3 or skips or actual != wanted:
            missing = sorted(set(wanted) - set(actual))[:5]
            extra = sorted(set(actual) - set(wanted))[:5]
            bad(row, f"wanted incomplete exact errors={len(wanted)}, got rc={rc} errors={len(actual)} "
                     f"skips={len(skips)} missing={missing!r} extra={extra!r}")
    finally:
        fixture.close()


# D1: EPERM is accepted and normalized symmetrically on both sides, once, with lstat identity retained.
for side in ("BEFORE", "AFTER"):
    fixture = Fixture()
    try:
        rel = paths[-1]
        fixture.file(rel)
        expect_skip(f"D1 EPERM {side}", fixture, side, rel, "EPERM", errno.EPERM)
    finally:
        fixture.close()

# D2: a listed readable file is never blind-excluded and retains its content digest.
fixture = Fixture()
try:
    rel = paths[-1]
    target = fixture.file(rel)
    rc, output = fixture.snapshot("BEFORE", name="D2-readable")
    body = lines(output)
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    if rc != 0 or any(line.startswith("SKIPPED-PROTECTED\t") for line in body) or row_for(body, rel) != [meta(target, digest)]:
        bad("D2 readable listed", f"rc={rc} row={row_for(body, rel)!r} markers={[x for x in body if x.startswith('SKIPPED')]!r}")
finally:
    fixture.close()

# D3: EIO is non-exempt on both sides even for an exact reviewed path.
for side in ("BEFORE", "AFTER"):
    fixture = Fixture()
    try:
        rel = paths[-1]
        target = fixture.file(rel)
        rc, output = fixture.snapshot(side, (target, errno.EIO), "D3-EIO-" + side)
        body = lines(output)
        if rc != 3 or any(line.startswith("SKIPPED-PROTECTED\t") for line in body) \
                or not any(line.startswith(f"ERROR\t{field(rel)}\t") for line in body):
            bad(f"D3 EIO {side}", f"rc={rc} tail={body[-5:]!r}")
    finally:
        fixture.close()

# D4: literal paths only. For every reviewed entry, batch four flat variants (suffix, a one-character substitution,
# same basename elsewhere and a sibling) and a child. Drive each immediate parent in its own fixture because many
# reviewed leaves share or nest parent directories. Every one of these paths is checked against the reviewed set
# before execution, then must produce its one exact ERROR, no protected marker and an incomplete snapshot.
reviewed_set = set(paths)
flat_variants: list[str] = []
child_variants: list[str] = []
parent_variants: list[str] = []
for index, rel in enumerate(paths):
    item = Path(rel)
    replacement = "x" if rel[-1] != "x" else "y"
    flat_variants.extend((
        rel + ".unlisted-suffix",
        rel[:-1] + replacement,
        f".ms1c-unlisted/same-basename/{index:03d}/{item.name}",
        str(item.parent / f"{item.name}.unlisted-sibling-{index:03d}"),
    ))
    child_variants.append(rel + "/unlisted-child")
    if str(item.parent) not in ("", "."):
        parent_variants.append(str(item.parent))

all_variants = flat_variants + child_variants + parent_variants
if len(flat_variants) != 4 * len(paths) or len(child_variants) != len(paths) \
        or len(parent_variants) != len(paths):
    bad("D4 exhaustive setup", "not every reviewed entry produced all six required variant classes")
if any(rel in reviewed_set for rel in all_variants):
    bad("D4 exhaustive setup", "a generated negative is itself present in the reviewed set")
if len(flat_variants) != len(set(flat_variants)) or len(child_variants) != len(set(child_variants)):
    bad("D4 exhaustive setup", "generated flat or child negatives are not unique")
if any(right.startswith(left + "/") for left in paths for right in paths if left != right):
    bad("D4 exhaustive setup", "reviewed entries unexpectedly nest, so child batching is ambiguous")

expect_error_batch("D4 exhaustive flat variants", flat_variants)
expect_error_batch("D4 exhaustive child variants", child_variants)
for index, parent in enumerate(parent_variants):
    expect_error(
        f"D4 exhaustive parent {index + 1}/{len(parent_variants)}",
        lambda fixture, parent=parent: fixture.file(parent),
        parent,
        errno.EACCES,
    )

deep = "Library/Metadata/CoreSpotlight/NSFileProtectionComplete/index.spotlightV3/store.db"

# D5: an arbitrary-byte descendant beneath a readable listed path is an ordinary audited entry, never a permission
# exception. This preserves the old filename boundary under the lossless evidence codec.
def arbitrary_name(fixture: Fixture) -> tuple[Path, bytes]:
    base = fixture.directory(deep)
    raw = os.fsencode(base) + b"/bad\n\t\x02-\xff-name"
    fd = os.open(raw, os.O_CREAT | os.O_WRONLY, 0o600)
    os.close(fd)
    return Path(os.fsdecode(raw)), os.path.relpath(raw, os.fsencode(fixture.root))


fixture = Fixture()
try:
    target, rel_raw = arbitrary_name(fixture)
    rc, output = fixture.snapshot("BEFORE", name="D5-arbitrary-name")
    body = lines(output)
    got = row_for(body, os.fsdecode(rel_raw))
    if rc != 0 or len(got) != 1 or any(line.startswith(("ERROR\t", "SKIPPED-PROTECTED\t")) for line in body):
        bad("D5 arbitrary name", f"wanted one ordinary row and complete snapshot, got rc={rc} row={got!r} tail={body[-5:]!r}")
finally:
    fixture.close()


def run_diff(row: str, fixture: Fixture, before: Path, after: Path) -> tuple[int, list[str]]:
    result = subprocess.run(
        [sys.executable, "-I", "-B", "-X", "utf8", "-c", diff_source, str(before), str(after),
         str(fixture.root), "Library/Logs/DiagnosticReports", "/control/zigBrowser", str(reviewed)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30,
    )
    if result.stderr:
        bad(row, f"differ wrote stderr {result.stderr!r}")
    return result.returncode, result.stdout.splitlines()


# D6: changing available metadata while still unreadable remains a HOME-DELTA; markers cannot hide it.
fixture = Fixture()
try:
    rel = paths[-1]
    target = fixture.file(rel, 0)
    before = expect_skip("D6 BEFORE", fixture, "BEFORE", rel, "EACCES")
    target.chmod(0o100)
    after = expect_skip("D6 AFTER", fixture, "AFTER", rel, "EACCES")
    rc, out = run_diff("D6 metadata", fixture, before, after)
    if rc != 0 or out[-1:] != ["HOMEAUDIT\tAMBIENT\t1"] \
            or not any(line.startswith(f"HOME-DELTA\tCHANGED\t{field(target)}\t") for line in out):
        bad("D6 metadata", f"wanted the exact CHANGED delta and AMBIENT/0, got rc={rc} {out!r}")
finally:
    fixture.close()

# D7: readable/unreadable transitions are never CLEAN in either direction.
for direction in ("unreadable-to-readable", "readable-to-unreadable"):
    fixture = Fixture()
    try:
        rel = paths[-1]
        target = fixture.file(rel, 0 if direction.startswith("unreadable") else 0o600)
        before = fixture.snapshot("BEFORE", name="D7-before-" + direction)[1]
        target.chmod(0o600 if direction.startswith("unreadable") else 0)
        after = fixture.snapshot("AFTER", name="D7-after-" + direction)[1]
        rc, out = run_diff("D7 " + direction, fixture, before, after)
        if rc == 0 or any(line == "HOMEAUDIT\tCLEAN\t0" for line in out):
            bad("D7 " + direction, f"transition was accepted: rc={rc} {out!r}")
    finally:
        fixture.close()

# Bind the skip-tuple comparison independently of ordinary metadata/content deltas. Each pair has the same ROOT,
# retained lstat row and END count; only the side-tagged protected marker's presence or reviewed reason changes.
def marker_only_snapshot(path: Path, fixture: Fixture, side: str, rel: str, reason: str | None) -> None:
    body = [
        f"ROOT\t{field(fixture.root)}\t{field(fixture.exclude)}",
        f"{field(rel)}\t{meta(fixture.path(rel), '-')}",
    ]
    if reason is not None:
        body.append(marker(side, rel, reason))
    body.append("END\t1")
    path.write_text("\n".join(body) + "\n", encoding="ascii")


for label, before_reason, after_reason in (
    ("presence", "EACCES", None),
    ("reason", "EACCES", "EPERM"),
):
    fixture = Fixture()
    try:
        rel = paths[-1]
        fixture.file(rel)
        before = fixture.work / f"D7-marker-only-{label}-before"
        after = fixture.work / f"D7-marker-only-{label}-after"
        marker_only_snapshot(before, fixture, "BEFORE", rel, before_reason)
        marker_only_snapshot(after, fixture, "AFTER", rel, after_reason)
        rc, out = run_diff("D7 marker-only " + label, fixture, before, after)
        want = ["HOMEAUDIT\tINCONCLUSIVE\tthe protected-path skip set changed"]
        if rc != 3 or out != want or any(line.startswith("HOME-DELTA\t") or "\tCLEAN\t" in line for line in out):
            bad("D7 marker-only " + label, f"wanted exact skip-set refusal/3 with no delta or CLEAN, got rc={rc} {out!r}")
    finally:
        fixture.close()

for problem in problems:
    print("FAIL " + problem)
if problems:
    print(f"FAIL\tms1c-home-protected-direct\t{len(problems)} problem(s)")
    raise SystemExit(1)
print("PASS\tms1c-home-protected-direct\tD1-D7")
PY

/usr/bin/python3 -I -B -X utf8 "$DIRECT" "$R/tests/mac/ms1c_app_gate.sh" "$LIST" "$T/tmp"
drc=$?
mutants_ok=1
if [ "$drc" -eq 0 ]; then
  for mutant in prefix-fileprovider family-fileprovider glob-fileprovider \
                 prefix-corespotlight family-corespotlight glob-corespotlight; do
    mout="$T/mutant.$mutant.out"
    if ZB_MS1C_HOME_MATCH_MUTANT="$mutant" \
       /usr/bin/python3 -I -B -X utf8 "$DIRECT" "$R/tests/mac/ms1c_app_gate.sh" "$LIST" "$T/tmp" > "$mout" 2>&1; then
      mutants_ok=0
      printf 'FAIL broad-match mutant survived: %s\n' "$mutant" >&2
    elif ! grep -q '^FAIL D4 exhaustive ' "$mout"; then
      mutants_ok=0
      printf 'FAIL broad-match mutant was not killed by exhaustive D4: %s: %s\n' \
        "$mutant" "$(tail -n 2 "$mout" | tr '\n' ' ')" >&2
    fi
  done
fi
if [ "$drc" -eq 0 ] && [ "$mutants_ok" -eq 1 ]; then
  ok "H4: direct HOME recorder/differ exhaustive literal path, side, errno, metadata and transition contract; six broad-match mutants red"
else
  bad "H4: direct HOME contract exited $drc, broad-match-mutants=$mutants_ok"
fi

if [ "$fails" -eq 0 ]; then
  printf 'PASS\tms1c-home-protected-red\t4/4\n'
  exit 0
fi
printf 'FAIL\tms1c-home-protected-red\t%s/4 failed\n' "$fails"
exit 1
DRIVER
chmod 700 "$DRIVER"

bash "$DRIVER" "$ROOT"
