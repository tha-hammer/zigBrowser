#!/usr/bin/env python3
"""GREEN, REGISTERED (red 0d028aab; SilverRidge cfccc8e7 item B).

Every path-bearing /var/folders evidence field uses canonical padded URL-safe
Base64 of its ``os.fsencode`` bytes, prefixed ``b64:``.  The real embedded
snapshotter/differ and public begin/end output are driven with CR, LF, tab,
U+0002, non-UTF-8, escape-looking and collision-prone names, plus symlink
targets containing slashes and control bytes.  Ordering and literal protected
matching use decoded raw bytes.  Malformed evidence produces one bounded
INCONCLUSIVE record, no traceback and no partial delta.

This side-effecting oracle is a direct dependency of test-mac-varfolders-audit and the aggregate test.
Run: python3 -X dev tests/e2e/mac_varfolders_path_codec_test.py [helper]
"""
from __future__ import annotations

import ast
import base64
import binascii
import contextlib
import errno
import io
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mac_varfolders_audit_test as base  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "tests" / "mac" / "mac_varfolders_audit.sh"
PROTECTED = ("C", b"com.apple.WebKit.GPU.Sandbox")
NAMES = (
    b"Icon\r",
    b"line\nbreak",
    b"tab\tname",
    "clock-\u0002-name".encode("utf-8"),
    b"non-utf8-\xff",
    "non-utf8-\ufffd".encode("utf-8"),
    b"b64:SWNvbg0=",
    b"backslash-\\x0d-%0D",
    b"ordinary",
    b"left/same",
    b"right/same",
)
LINK_TARGETS = (
    b"target\r",
    b"target\nline",
    b"target\tfield",
    b"target-\x02-\xff",
    b"b64:dGFyZ2V0",
    b"target-\\x0a-%0A",
    b"directory/target-\x02-\xff",
)
KIND = ((stat.S_ISREG, "f"), (stat.S_ISDIR, "d"), (stat.S_ISLNK, "l"), (stat.S_ISFIFO, "p"),
        (stat.S_ISSOCK, "s"), (stat.S_ISCHR, "c"), (stat.S_ISBLK, "b"))
failures: list[str] = []


def bad(row: str, why: str) -> None:
    failures.append(f"{row}: {why}")


def encode(value: bytes | str) -> str:
    return "b64:" + base64.urlsafe_b64encode(os.fsencode(value)).decode("ascii")


def decode(field: str) -> bytes:
    if not field.startswith("b64:") or not field.isascii():
        raise ValueError(f"not prefixed ASCII: {field!r}")
    try:
        raw = base64.b64decode(field[4:].encode("ascii"), altchars=b"-_", validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError(f"invalid Base64: {field!r}") from error
    if encode(raw) != field:
        raise ValueError(f"noncanonical Base64: {field!r}")
    return raw


def extract(row: str, helper: Path, variable: str) -> str | None:
    result = subprocess.run(
        ["bash", "-c", f'. "$1"; printf "%s" "${{{variable}}}"', "_", str(helper)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    if result.returncode != 0 or not result.stdout:
        bad(row, f"cannot extract {variable}: rc={result.returncode} {result.stderr!r}")
        return None
    return result.stdout.decode("utf-8")


class Fixture:
    def __init__(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="zb-vf-codec-"))
        tmp_b = os.fsencode(self.tmp)
        self.P = os.path.join(tmp_b, b"parent-\r-\xff")
        self.T = os.path.join(self.P, b"T-\n-\x02")
        self.C = os.path.join(self.P, b"C-\t-b64:Qw==")
        for directory in (self.T, self.C):
            os.makedirs(directory)
        for index, rel in enumerate(NAMES):
            path = os.path.join(self.C, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(f"payload-{index}\n".encode("ascii"))
        self.links: dict[bytes, bytes] = {}
        for index, target in enumerate(LINK_TARGETS):
            rel = f"link-{index}".encode("ascii")
            os.symlink(target, os.path.join(self.T, rel))
            self.links[rel] = target
        self.protected = os.path.join(self.C, PROTECTED[1])
        os.makedirs(self.protected)
        self.unlisted = os.path.join(self.C, b"com.apple.WebKit.GPU.Sandbox.unreviewed")
        os.makedirs(self.unlisted)
        self.roots = self.tmp / "roots.tsv"
        self.roots.write_text(
            f"T\t{encode(self.T)}\nC\t{encode(self.C)}\nP\t{encode(self.P)}\n", encoding="ascii",
        )

    def close(self) -> None:
        shutil.rmtree(self.tmp)


def independent_record(path: bytes) -> str:
    st = os.lstat(path)
    kind = next((name for test, name in KIND if test(st.st_mode)), "o")
    if kind == "f":
        import hashlib
        with open(path, "rb") as stream:
            sha = hashlib.sha256(stream.read()).hexdigest()
    else:
        sha = "-"
    link = encode(os.readlink(path)) if kind == "l" else "-"
    return (f"{kind} {stat.S_IMODE(st.st_mode):o} {st.st_uid} {st.st_gid} {st.st_nlink} {st.st_size} "
            f"{st.st_mtime_ns} {st.st_ctime_ns} {st.st_ino} {sha} {link}")


def census(fixture: Fixture) -> dict[tuple[str, bytes], str]:
    rows: dict[tuple[str, bytes], str] = {}
    skip = {os.path.basename(fixture.T), os.path.basename(fixture.C)}
    for token, root in (("T", fixture.T), ("C", fixture.C), ("P", fixture.P)):
        rows[(token, b".")] = independent_record(root)
        for dirpath, dirs, names in os.walk(root, topdown=True, followlinks=False):
            if token == "P" and dirpath == fixture.P:
                dirs[:] = [name for name in dirs if name not in skip]
                names = [name for name in names if name not in skip]
            for name in dirs + names:
                path = os.path.join(dirpath, name)
                rows[(token, os.path.relpath(path, root))] = independent_record(path)
    return rows


def run_snapshot(
    row: str,
    source: str,
    fixture: Fixture,
    output: Path,
    side: str,
    denied: bytes | None,
    error_number: int = errno.EACCES,
    roots_file: Path | None = None,
) -> int:
    old_argv, real_scandir = sys.argv, os.scandir
    stdout, stderr = io.StringIO(), io.StringIO()

    def scandir(path):
        if denied is not None and os.path.normpath(os.fsencode(path)) == os.path.normpath(denied):
            raise OSError(error_number, os.strerror(error_number), os.fsdecode(path))
        return real_scandir(path)

    rc = 0
    try:
        os.scandir = scandir
        sys.argv = ["snapshot", str(roots_file or fixture.roots), str(output), side]
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                exec(compile(source, "__VF_SNAPSHOT_PY", "exec"), {"__name__": "__main__"})
            except SystemExit as stopped:
                rc = int(stopped.code or 0)
    except Exception as error:
        bad(row, f"uncaught {type(error).__name__}: {error}")
        rc = 99
    finally:
        os.scandir, sys.argv = real_scandir, old_argv
    if stdout.getvalue() or stderr.getvalue():
        bad(row, f"snapshotter must be silent, got stdout={stdout.getvalue()!r} stderr={stderr.getvalue()!r}")
    return rc


def parse_snapshot(
    row: str,
    path: Path,
    fixture: Fixture,
    side: str,
    want: dict[tuple[str, bytes], str],
) -> None:
    try:
        raw = path.read_bytes()
        text = raw.decode("ascii")
    except (OSError, UnicodeDecodeError) as error:
        bad(row, f"snapshot is not canonical ASCII: {error}")
        return
    lines = text.splitlines()
    if not lines or len([line for line in lines if line.startswith("END\t")]) != 1:
        bad(row, f"snapshot has no single END: {lines[-4:]!r}")
        return
    roots, body = [], []
    for line in lines[:-1]:
        if line.startswith("ROOT\t"):
            fields = line.split("\t")
            try:
                decoded = decode(fields[2]) if len(fields) == 5 else None
            except ValueError as error:
                bad(row, f"ROOT path is not canonical: {error}")
                decoded = None
            roots.append((fields[1] if len(fields) > 1 else "", decoded))
        else:
            body.append(line)
    wanted_roots = [("T", fixture.T), ("C", fixture.C), ("P", fixture.P)]
    if roots != wanted_roots:
        bad(row, f"decoded ROOT paths differ: got {roots!r}, want {wanted_roots!r}")

    ordinary: dict[tuple[str, bytes], list[str]] = {}
    order: list[tuple[str, bytes]] = []
    markers: list[list[str]] = []
    marker_phase = False
    for line in body:
        if line.startswith("ERROR\t"):
            bad(row, f"valid arbitrary bytes became an ERROR: {line!r}")
            continue
        if line.startswith("SKIPPED-PROTECTED\t"):
            marker_phase = True
            markers.append(line.split("\t"))
            continue
        if marker_phase:
            bad(row, f"ordinary row appears after marker: {line!r}")
        fields = line.split("\t", 2)
        try:
            rel = decode(fields[1]) if len(fields) == 3 else b""
        except ValueError as error:
            bad(row, f"ordinary path is not canonical: {error}")
            continue
        key = (fields[0], rel)
        order.append(key)
        ordinary.setdefault(key, []).append(fields[2])
    if set(ordinary) != set(want) or any(len(values) != 1 for values in ordinary.values()):
        bad(row, f"ordinary path set differs: missing={set(want) - set(ordinary)!r}, "
            f"extra={set(ordinary) - set(want)!r}")
    for key, expected in want.items():
        if ordinary.get(key) != [expected]:
            bad(row, f"metadata mismatch for {key!r}: {ordinary.get(key)!r} != {[expected]!r}")
    if order != sorted(order, key=lambda item: (item[0], item[1])):
        bad(row, f"ordinary rows are not in decoded raw-byte order: {order!r}")
    if len(markers) != 1:
        bad(row, f"wanted one exact protected marker, got {markers!r}")
    else:
        fields = markers[0]
        try:
            marker_path = decode(fields[3]) if len(fields) == 5 else None
        except ValueError as error:
            bad(row, f"marker path is not canonical: {error}")
            marker_path = None
        if fields[:3] != ["SKIPPED-PROTECTED", side, PROTECTED[0]] \
                or marker_path != PROTECTED[1] or fields[4:] != ["EACCES"]:
            bad(row, f"wrong protected marker {fields!r}")
    for rel, target in fixture.links.items():
        meta = ordinary.get(("T", rel), [""])[0].split(" ", 10)
        try:
            got_target = decode(meta[10]) if len(meta) == 11 else None
        except ValueError as error:
            bad(row, f"symlink target {rel!r} is not canonical: {error}")
            got_target = None
        if not meta or meta[0] != "l" or got_target != target:
            bad(row, f"symlink target {rel!r} decoded to {got_target!r}, want {target!r}")
    want_end = f"END\t{len(ordinary) + len(markers)}"
    if lines[-1:] != [want_end]:
        bad(row, f"END count mismatch: got {lines[-1:]!r}, want {[want_end]!r}")


def run_diff(row: str, source: str, before: Path, after: Path) -> tuple[int, list[str]]:
    old_argv = sys.argv
    stdout, stderr = io.StringIO(), io.StringIO()
    rc = 0
    try:
        sys.argv = ["diff", str(before), str(after)]
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                exec(compile(source, "__VF_DIFF_PY", "exec"), {"__name__": "__main__"})
            except SystemExit as stopped:
                rc = int(stopped.code or 0)
    except Exception as error:
        bad(row, f"uncaught {type(error).__name__}: {error}")
        rc = 99
    finally:
        sys.argv = old_argv
    if stderr.getvalue():
        bad(row, f"differ wrote stderr/traceback: {stderr.getvalue()!r}")
    return rc, stdout.getvalue().splitlines()


def public_cycle(helper: Path) -> None:
    base.failures, base.hits = [], []
    box = base.Box(helper)
    try:
        rc, out = box.call("varfolders_begin")
        if rc != 0 or out:
            bad("B1 public roots", f"begin must be silent and complete, got rc={rc} {out!r}")
            return
        rc, out = box.call("varfolders_end")
        want_head = [
            f"VARFOLDERS_ROOTS\tT\t{encode(box.T)}\tC\t{encode(box.C)}",
            f"VARFOLDERS_PARENT\t{encode(box.user)}",
        ]
        if rc != 0 or out != want_head + ["VARFOLDERS\tCOMPLETE\t0"]:
            bad("B1 public roots", f"want canonical root/parent fields and COMPLETE 0, got rc={rc} {out!r}")
    finally:
        box.close()
    if base.hits:
        bad("B1 public roots", f"helper changed audited roots: {base.hits[:4]!r}")


def isolate_directory_metadata(before: Path, after: Path, output: Path) -> None:
    before_lines = before.read_text(encoding="ascii").splitlines()
    after_lines = after.read_text(encoding="ascii").splitlines()
    before_dirs: dict[tuple[str, bytes], str] = {}
    for line in before_lines:
        fields = line.split("\t", 2)
        if len(fields) == 3 and fields[0] in ("T", "C", "P") and fields[2].startswith("d "):
            before_dirs[(fields[0], decode(fields[1]))] = line
    for index, line in enumerate(after_lines):
        fields = line.split("\t", 2)
        if len(fields) == 3 and fields[0] in ("T", "C", "P") and fields[2].startswith("d "):
            key = (fields[0], decode(fields[1]))
            if key in before_dirs:
                after_lines[index] = before_dirs[key]
    output.write_text("\n".join(after_lines) + "\n", encoding="ascii")


def corrupt_snapshot(source: Path, output: Path, kind: str) -> None:
    lines = source.read_text(encoding="ascii").splitlines()
    if kind == "root-unprefixed":
        fields = lines[0].split("\t")
        fields[2] = fields[2][4:]
        lines[0] = "\t".join(fields)
    elif kind == "ordinary-invalid":
        index = next(i for i, line in enumerate(lines) if line.startswith("C\t"))
        fields = lines[index].split("\t", 2)
        fields[1] = "b64:%%%="
        lines[index] = "\t".join(fields)
    elif kind == "marker-raw":
        index = next(i for i, line in enumerate(lines) if line.startswith("SKIPPED-PROTECTED\t"))
        fields = lines[index].split("\t")
        fields[3] = os.fsdecode(PROTECTED[1])
        lines[index] = "\t".join(fields)
    elif kind == "link-noncanonical":
        index = next(i for i, line in enumerate(lines) if line.startswith(f"T\t{encode(b'link-3')}\t"))
        fields = lines[index].split("\t", 2)
        meta = fields[2].split(" ", 10)
        if "_" not in meta[10]:
            raise AssertionError(meta[10])
        meta[10] = meta[10].replace("_", "/")
        fields[2] = " ".join(meta)
        lines[index] = "\t".join(fields)
    elif kind == "ordinary-unpadded":
        index = next(i for i, line in enumerate(lines) if line.startswith(f"C\t{encode(b'ordinary')}\t"))
        fields = lines[index].split("\t", 2)
        fields[1] = fields[1].rstrip("=")
        lines[index] = "\t".join(fields)
    else:
        raise AssertionError(kind)
    output.write_text("\n".join(lines) + "\n", encoding="ascii")


def run_rows(helper: Path) -> list[str]:
    global failures
    failures = []
    if not helper.is_file():
        return [f"the helper {helper} does not exist"]
    snap_source = extract("B0", helper, "__VF_SNAPSHOT_PY")
    diff_source = extract("B0", helper, "__VF_DIFF_PY")
    if snap_source is None or diff_source is None:
        return list(failures)
    for name, source in (("snapshotter", snap_source), ("differ", diff_source)):
        try:
            ast.parse(source, filename=name, mode="exec", feature_version=(3, 9))
        except SyntaxError as error:
            bad("B0 Python 3.9", f"embedded {name} is not Python 3.9 syntax: {error}")

    public_cycle(helper)
    fixture = Fixture()
    try:
        if len(NAMES) != len(set(NAMES)) or len({encode(name) for name in NAMES}) != len(NAMES):
            bad("setup", "raw or encoded names collide")
        raw_pair = [b"line\nbreak", b"ordinary-renamed\r\t\x02-\xff"]
        if sorted(raw_pair) == sorted(raw_pair, key=encode):
            bad("setup", "delta names do not invert raw-byte and encoded-text ordering")

        # The snapshotter has its own decoder. A decoder-equivalent roots field with a wrong prefix must fail closed
        # before it accepts any root, ordinary row, protected marker or partial evidence.
        bad_roots = fixture.tmp / "roots-wrong-prefix.tsv"
        bad_root_lines = fixture.roots.read_text(encoding="ascii").splitlines()
        root_fields = bad_root_lines[0].split("\t")
        if len(root_fields) != 2 or not root_fields[1].startswith("b64:"):
            bad("B7 snapshot roots", f"fixture has no canonical first root: {bad_root_lines[:1]!r}")
        else:
            root_fields[1] = "bad:" + root_fields[1][4:]
            bad_root_lines[0] = "\t".join(root_fields)
            bad_roots.write_text("\n".join(bad_root_lines) + "\n", encoding="ascii")
            refused = fixture.tmp / "wrong-prefix-refused.tsv"
            refused_rc = run_snapshot(
                "B7 snapshot roots", snap_source, fixture, refused, "BEFORE", fixture.protected,
                roots_file=bad_roots,
            )
            refused_lines = refused.read_text(encoding="ascii").splitlines() if refused.is_file() else []
            want_refused = [
                f"ERROR\tP\t{encode(b'.')}\tmalformed roots evidence",
                "END\t0",
            ]
            if refused_rc != 3 or refused_lines != want_refused \
                    or sum(len(line) + 1 for line in refused_lines) > 500:
                bad("B7 snapshot roots", "wrong-prefix roots field must produce one bounded refusal and END 0, "
                    f"with no accepted evidence; got rc={refused_rc} {refused_lines!r}")

        before, same = fixture.tmp / "before.tsv", fixture.tmp / "same.tsv"
        before_rc = run_snapshot("B2 BEFORE", snap_source, fixture, before, "BEFORE", fixture.protected)
        same_rc = run_snapshot("B2 AFTER", snap_source, fixture, same, "AFTER", fixture.protected)
        expected = census(fixture)
        if before_rc != 0 or same_rc != 0:
            bad("B2 round trip", f"snapshots must be complete, got before={before_rc} after={same_rc}")
        parse_snapshot("B2 BEFORE", before, fixture, "BEFORE", expected)
        parse_snapshot("B2 AFTER", same, fixture, "AFTER", expected)
        stable_rc, stable_out = run_diff("B3 stable", diff_source, before, same)
        want_stable = [
            f"SKIPPED-PROTECTED\tBEFORE\tC\t{encode(PROTECTED[1])}\tEACCES",
            f"SKIPPED-PROTECTED\tAFTER\tC\t{encode(PROTECTED[1])}\tEACCES",
            "VARFOLDERS\tCOMPLETE\t0",
        ]
        if stable_rc != 0 or stable_out != want_stable:
            bad("B3 stable", f"want exact accepted round trip {want_stable!r}, got rc={stable_rc} {stable_out!r}")

        # Decoded exact policy matching: a suffix-broadened directory stays an ordinary incomplete error.
        unlisted = fixture.tmp / "unlisted.tsv"
        unlisted_rc = run_snapshot("B4 literal policy", snap_source, fixture, unlisted, "BEFORE", fixture.unlisted)
        unlisted_lines = unlisted.read_text(encoding="ascii").splitlines() if unlisted.is_file() else []
        unlisted_errors = [line for line in unlisted_lines if line.startswith("ERROR\t")]
        if unlisted_rc != 3 or any(line.startswith("SKIPPED-PROTECTED\t") for line in unlisted_lines) \
                or len(unlisted_errors) != 1:
            bad("B4 literal policy", f"unlisted decoded path must be incomplete, got rc={unlisted_rc} "
                f"{unlisted_lines[-4:]!r}")
        elif decode(unlisted_errors[0].split("\t")[2]) != os.path.relpath(fixture.unlisted, fixture.C):
            bad("B4 literal policy", f"ERROR path does not round trip: {unlisted_errors!r}")

        # Rename two arbitrary-byte leaves. Directory metadata is held fixed so the differ has exactly two leaf deltas.
        old_name = b"line\nbreak"
        new_name = b"ordinary-renamed\r\t\x02-\xff"
        os.rename(os.path.join(fixture.C, old_name), os.path.join(fixture.C, new_name))
        after = fixture.tmp / "after.tsv"
        after_rc = run_snapshot("B5 AFTER rename", snap_source, fixture, after, "AFTER", fixture.protected)
        expected_after = census(fixture)
        if after_rc != 0:
            bad("B5 rename", f"after snapshot must be complete, got rc={after_rc}")
        parse_snapshot("B5 AFTER rename", after, fixture, "AFTER", expected_after)
        isolated = fixture.tmp / "after-isolated.tsv"
        try:
            isolate_directory_metadata(before, after, isolated)
        except (OSError, UnicodeError, ValueError) as error:
            bad("B5 rename", f"cannot isolate directory metadata: {error}")
            isolated = after
        rename_rc, rename_out = run_diff("B5 rename", diff_source, before, isolated)
        deltas = [line for line in rename_out if line.startswith("VARFOLDERS-DELTA\t")]
        decoded_deltas: list[tuple[str, bytes]] = []
        for line in deltas:
            fields = line.split("\t")
            try:
                rel = decode(fields[3]) if len(fields) == 6 else b""
            except ValueError as error:
                bad("B5 rename", f"delta path is not canonical: {error}")
                continue
            decoded_deltas.append((fields[1], rel))
        want_deltas = [("removed", old_name), ("added", new_name)]
        if rename_rc != 0 or rename_out[-1:] != ["VARFOLDERS\tCOMPLETE\t2"] \
                or decoded_deltas != want_deltas:
            bad("B5 rename", f"want two complete raw-byte-ordered deltas {want_deltas!r}, "
                f"got rc={rename_rc} {rename_out!r}")

        # Each path-bearing evidence class rejects malformed/noncanonical input with one bounded verdict and no delta.
        for kind in ("root-unprefixed", "ordinary-invalid", "marker-raw", "link-noncanonical", "ordinary-unpadded"):
            corrupt = fixture.tmp / f"corrupt-{kind}.tsv"
            try:
                corrupt_snapshot(same, corrupt, kind)
            except (OSError, UnicodeError, ValueError, AssertionError, StopIteration) as error:
                bad(f"B6 {kind}", f"fixture construction failed: {error}")
                continue
            malformed_rc, malformed_out = run_diff(f"B6 {kind}", diff_source, before, corrupt)
            fields = malformed_out[0].split("\t") if len(malformed_out) == 1 else []
            if malformed_rc != 2 or len(fields) != 3 or fields[:2] != ["VARFOLDERS", "INCONCLUSIVE"] \
                    or not fields[2] or len(malformed_out[0]) > 500 \
                    or any(line.startswith("VARFOLDERS-DELTA\t") for line in malformed_out):
                bad(f"B6 {kind}", f"want one bounded INCONCLUSIVE and no partial delta, "
                    f"got rc={malformed_rc} {malformed_out!r}")
    finally:
        fixture.close()
    return list(failures)


def main(argv: list[str]) -> int:
    helper = Path(argv[1]) if len(argv) > 1 else HELPER
    problems = run_rows(helper)
    for problem in problems:
        print("FAIL " + problem)
    if problems:
        print(f"FAIL\tmac-varfolders-path-codec\t{len(problems)} problem(s)")
        return 1
    print("PASS\tmac-varfolders-path-codec\tB1-B7")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
