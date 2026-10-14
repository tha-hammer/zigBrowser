#!/usr/bin/env python3
"""Shared pieces for the Claude Agent drawer E2E tests.

`parse_row` checks every `DRAWER` row against the plan's D7b table
(thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md):
a row that does not match its kind's exact field shape raises `RowError`,
so a test can never pass on a malformed row. `<rect>` is `x,y,w,h` in root
coordinates."""

from __future__ import annotations

import re
from dataclasses import dataclass

RECT = r"-?\d+,-?\d+,\d+,\d+"
TEXT = r"[^\t]{0,4100}"  # 4 KiB cap plus the "…" marker
REASON = r"-|runtime-missing|sandbox|hook-isolation|config-changed|cli-changed|no-token|home-locked|exit-\d+|signal-\d+"

# kind -> one regex per field after <win> and <kind>.
DRAWER_KINDS: dict[str, list[str]] = {
    "icon": [RECT],
    "open": [RECT],
    "minus": [RECT],
    "anim": [r"\d+", RECT, RECT],
    "minimized": [RECT],
    "focus": [r"icon|input|send|stop|minus|list|approve|deny"],
    "scroll": [r"bottom|\d+(\.\d+)?"],
    "msg": [r"user|assistant|system|approval|error", TEXT],
    "delta": [r"[^\t]+", TEXT],
    "status": [r"stopped|starting|ready|busy|crashed|unavailable", REASON],
    "approval": [r"[^\t]+", r"[^\t]+", r"[^\t]+", r"[^\t]+", r"[0-9a-f]+"],
    "idles": [r"\d+"],
    "tree": [r"[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*"],
}


class RowError(AssertionError):
    pass


@dataclass(frozen=True)
class Row:
    win: int
    kind: str
    fields: tuple[str, ...]

    def rect(self, index: int = 0) -> tuple[int, int, int, int]:
        x, y, w, h = (int(v) for v in self.fields[index].split(","))
        return x, y, w, h


def parse_row(line: str) -> Row:
    """One `DRAWER\\t<win>\\t<kind>\\t...` stdout line -> Row, or RowError."""
    parts = line.split("\t")
    if len(parts) < 3 or parts[0] != "DRAWER":
        raise RowError(f"not a DRAWER row: {line!r}")
    if not re.fullmatch(r"[1-9]\d*", parts[1]):
        raise RowError(f"bad window id in {line!r}")
    kind = parts[2]
    shape = DRAWER_KINDS.get(kind)
    if shape is None:
        raise RowError(f"unknown DRAWER kind {kind!r} in {line!r}")
    fields = parts[3:]
    if len(fields) != len(shape) or not all(re.fullmatch(p, f) for p, f in zip(shape, fields)):
        raise RowError(f"DRAWER {kind} row does not match D7b: {line!r}")
    return Row(int(parts[1]), kind, tuple(fields))


def drawer_rows(lines: list[str]) -> list[Row]:
    """Every DRAWER row in `lines`, each validated (RowError on the first bad one)."""
    return [parse_row(line) for line in lines if line.startswith("DRAWER\t") or line == "DRAWER"]
