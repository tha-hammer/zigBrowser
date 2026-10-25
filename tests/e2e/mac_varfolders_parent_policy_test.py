#!/usr/bin/env python3
"""RED, UNREGISTERED: owner /var/folders policy (SilverRidge 56f84347, 22fa1dd5).

Every complete delta inside the identity-bound physical per-user parent is
evidence-only: P itself, 0/, X/, arbitrary siblings, T and C are all reported
exactly once in decoded-byte order and end in COMPLETE with the exact total.
Changes in another per-user directory, bucket, or the /var/folders parent are
outside that boundary and are not part of this user's census.  Incomplete or
malformed evidence remains fail closed; the registered legacy suites retain
those safety checks.

This file must remain absent from build.zig until the reviewed production green.
Direct: python3 -X dev -W error tests/e2e/mac_varfolders_parent_policy_test.py [helper]
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mac_varfolders_audit_test as base  # noqa: E402
import mac_varfolders_census_test as census  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "tests" / "mac" / "mac_varfolders_audit.sh"
failures: list[str] = []


def bad(row: str, why: str) -> None:
    failures.append(f"{row}: {why}")


def exact_complete(row: str, box: base.Box, change, named: list[tuple[str, str, str]]) -> None:
    state: dict[str, dict] = {}

    def between(current: base.Box) -> None:
        state["before"] = base.observe(current)
        change(current)
        state["after"] = base.observe(current)

    rc, out = box.cycle(between)
    deltas = base.want_deltas(state["before"], state["after"])
    identities = [base.delta_identity(delta) for delta in deltas]
    if identities != named:
        bad(row, f"fixture wants exact ordered identities {named!r}, got {identities!r}")
        return
    decoded_order = [(delta[2], base.decode_field(delta[3])) for delta in deltas]
    if decoded_order != sorted(decoded_order):
        bad(row, f"deltas are not in decoded token/path byte order: {decoded_order!r}")
    want = census.head(box) + ["\t".join(delta) for delta in deltas] \
        + [f"VARFOLDERS\tCOMPLETE\t{len(deltas)}"]
    if rc != 0 or out != want:
        bad(row, f"record-all/fail-none wants rc=0 and exact output {want!r}, got rc={rc} {out!r}")


def pc3_change(box: base.Box) -> None:
    (box.user / "0" / "new.db").write_text("n\n")
    (box.user / "X" / "x.bin").write_text("x2\n")
    (box.user / "Z").mkdir()
    (box.user / "Z" / "z").write_text("z\n")
    box.user.chmod(0o750)
    (box.T / "t.txt").write_text("t\n")


def p_only_change(box: base.Box) -> None:
    (box.user / "0" / "zz.db").unlink()
    (box.user / "X" / "x.bin").write_text("x2\n")
    (box.user / "Q").mkdir()
    (box.user / "Q" / "q.bin").write_text("q\n")
    box.user.chmod(0o750)


def mixed_change(box: base.Box) -> None:
    (box.C / "c-new").write_text("c\n")
    (box.user / "0" / "p-new").write_text("p\n")
    (box.user / "Y").mkdir()
    (box.user / "Y" / "y-new").write_text("y\n")
    (box.T / "t-new").write_text("t\n")


def run_rows(helper: Path) -> list[str]:
    global failures
    failures = []
    base.failures, base.hits = [], []
    if not helper.is_file():
        return [f"the helper {helper} does not exist"]
    if not sys.platform.startswith("linux"):
        return ["the no-write boundary needs the Linux hostless gate"]

    box = census.census_box(helper)
    try:
        exact_complete(
            "P1 corrected PC3 mixed parent/T",
            box,
            pc3_change,
            [
                ("changed", "P", "."),
                ("changed", "P", "0"),
                ("added", "P", "0/new.db"),
                ("changed", "P", "X/x.bin"),
                ("added", "P", "Z"),
                ("added", "P", "Z/z"),
                ("changed", "T", "."),
                ("added", "T", "t.txt"),
            ],
        )
    finally:
        box.close()

    box = census.census_box(helper)
    try:
        exact_complete(
            "P2 P-only add/change/remove/self",
            box,
            p_only_change,
            [
                ("changed", "P", "."),
                ("changed", "P", "0"),
                ("removed", "P", "0/zz.db"),
                ("added", "P", "Q"),
                ("added", "P", "Q/q.bin"),
                ("changed", "P", "X/x.bin"),
            ],
        )
    finally:
        box.close()

    box = census.census_box(helper)
    try:
        exact_complete(
            "P3 mixed P/T/C no double count",
            box,
            mixed_change,
            [
                ("changed", "C", "."),
                ("added", "C", "c-new"),
                ("changed", "P", "."),
                ("changed", "P", "0"),
                ("added", "P", "0/p-new"),
                ("added", "P", "Y"),
                ("added", "P", "Y/y-new"),
                ("changed", "T", "."),
                ("added", "T", "t-new"),
            ],
        )
    finally:
        box.close()

    box = census.census_box(helper)
    try:
        same_bucket = box.var / "folders" / "ab" / "other-user"
        other_bucket = box.var / "folders" / "zz" / "other-user"
        folders_parent = box.var / "folders" / "not-a-user-root"
        for directory in (same_bucket, other_bucket, folders_parent):
            directory.mkdir(parents=True)
            (directory / "outside.db").write_text("v1\n")

        def outside_only(_box: base.Box) -> None:
            for directory in (same_bucket, other_bucket, folders_parent):
                (directory / "outside.db").write_text("v2\n")

        exact_complete("P4 exact per-user boundary", box, outside_only, [])
    finally:
        box.close()

    if base.hits:
        bad("P5 no-write", f"helper changed the fake /var/folders tree: {base.hits[:8]!r}")
    return list(failures) + [failure for failure in base.failures if failure.startswith("V2 ")]


def main(argv: list[str]) -> int:
    helper = Path(argv[1]) if len(argv) > 1 else HELPER
    problems = run_rows(helper)
    for problem in problems:
        print("FAIL " + problem)
    if problems:
        print(f"FAIL\tmac-varfolders-parent-policy\t{len(problems)} problem(s)")
        return 1
    print("PASS\tmac-varfolders-parent-policy\tP1-P5")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
