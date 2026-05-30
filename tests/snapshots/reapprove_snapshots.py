#!/usr/bin/env python3
"""Snapshot re-approval and tolerance tuning flow for Track-C corpus gates.

Typical real-render flow:

  python3 tests/snapshots/reapprove_snapshots.py \
    --render-cmd 'zig build test' \
    --allow-render-fail \
    --tune-thresholds --apply-thresholds \
    --approve
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        default="tests/snapshots/manifest.json",
        help="Snapshot manifest JSON path",
    )
    parser.add_argument(
        "--actual-dir",
        default=".zig-cache/snapshot_actual",
        help="Directory containing candidate PNGs named <page-id>.png",
    )
    parser.add_argument(
        "--ids",
        default="",
        help="Optional comma-separated subset of page ids (e.g. page01,page02)",
    )
    parser.add_argument(
        "--render-cmd",
        default="",
        help="Optional shell command that regenerates candidate PNGs before diff/approve",
    )
    parser.add_argument(
        "--allow-render-fail",
        action="store_true",
        help="Continue if render command exits non-zero (useful when regen command runs assertion tests)",
    )
    parser.add_argument(
        "--approve",
        action="store_true",
        help="Copy candidate PNGs into approved snapshot paths",
    )
    parser.add_argument(
        "--tune-thresholds",
        action="store_true",
        help="Compute threshold suggestions from observed diffs",
    )
    parser.add_argument(
        "--apply-thresholds",
        action="store_true",
        help="Write tuned thresholds back to manifest",
    )
    parser.add_argument(
        "--tune-margin",
        type=float,
        default=0.004,
        help="Safety margin added on top of observed diff ratio when tuning thresholds",
    )
    parser.add_argument(
        "--min-threshold",
        type=float,
        default=0.02,
        help="Lower bound for tuned thresholds",
    )
    parser.add_argument(
        "--max-threshold",
        type=float,
        default=0.20,
        help="Upper bound for tuned thresholds",
    )
    return parser.parse_args()


def load_manifest(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("manifest root must be an object")
    pages = data.get("pages")
    if not isinstance(pages, list):
        raise ValueError("manifest must contain pages[]")
    return data


def parse_ids(ids_csv: str) -> set[str]:
    ids = {part.strip() for part in ids_csv.split(",") if part.strip()}
    return ids


def run_render_cmd(cmd: str, allow_fail: bool) -> None:
    print(f"[reapprove] running render command: {cmd}")
    proc = subprocess.run(cmd, shell=True, text=True)
    if proc.returncode != 0 and not allow_fail:
        raise RuntimeError(f"render command failed with exit {proc.returncode}")
    if proc.returncode != 0:
        print(
            f"[reapprove] render command exited {proc.returncode}; continuing because --allow-render-fail is set"
        )


def diff_ratio(actual_png: Path, approved_png: Path) -> float:
    proc = subprocess.run(
        ["python3", "tests/snapshots/pillow_tools.py", "diff", str(actual_png), str(approved_png)],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.strip()
        raise RuntimeError(f"diff failed for {actual_png} vs {approved_png}: {stderr}")
    return float(proc.stdout.strip())


def round_threshold(value: float) -> float:
    return round(value, 6)


def main() -> int:
    args = parse_args()
    manifest_path = Path(args.manifest)
    actual_dir = Path(args.actual_dir)

    data = load_manifest(manifest_path)
    pages: list[dict[str, Any]] = data["pages"]

    selected_ids = parse_ids(args.ids)
    if selected_ids:
        pages = [page for page in pages if str(page.get("id", "")) in selected_ids]
        if not pages:
            print("[reapprove] no pages matched --ids", file=sys.stderr)
            return 2

    if args.render_cmd:
        run_render_cmd(args.render_cmd, args.allow_render_fail)

    total = len(pages)
    missing = 0
    compared = 0
    within = 0
    approved = 0

    tuned = 0
    changed_thresholds = 0

    print(f"[reapprove] manifest: {manifest_path}")
    print(f"[reapprove] evaluating {total} page(s) using actual-dir={actual_dir}")

    for page in pages:
        page_id = str(page.get("id", ""))
        approved_png = Path(str(page.get("snapshot_png", "")))
        threshold = float(page.get("threshold", 0.0))
        candidate_png = actual_dir / f"{page_id}.png"

        if not candidate_png.exists():
            missing += 1
            print(f"MISSING  {page_id:>7} candidate={candidate_png}")
            continue
        if not approved_png.exists():
            missing += 1
            print(f"MISSING  {page_id:>7} approved={approved_png}")
            continue

        ratio = diff_ratio(candidate_png, approved_png)
        compared += 1
        ok = ratio <= threshold
        if ok:
            within += 1

        print(
            f"DIFF     {page_id:>7} ratio={ratio:.6f} threshold={threshold:.6f} {'OK' if ok else 'FAIL'}"
        )

        if args.tune_thresholds:
            tuned += 1
            tuned_threshold = max(args.min_threshold, ratio + args.tune_margin)
            tuned_threshold = min(tuned_threshold, args.max_threshold)
            tuned_threshold = round_threshold(tuned_threshold)
            if tuned_threshold != threshold:
                changed_thresholds += 1
                print(
                    f"TUNE     {page_id:>7} {threshold:.6f} -> {tuned_threshold:.6f}"
                )
                if args.apply_thresholds:
                    page["threshold"] = tuned_threshold

        if args.approve:
            approved_png.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(candidate_png, approved_png)
            approved += 1
            print(f"APPROVED {page_id:>7} {candidate_png} -> {approved_png}")

    if args.apply_thresholds and args.tune_thresholds:
        manifest_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        print(f"[reapprove] wrote updated thresholds to {manifest_path}")

    print("[reapprove] summary:")
    print(f"  compared: {compared}/{total}")
    print(f"  within-threshold: {within}/{compared}")
    print(f"  missing-candidates-or-approved: {missing}")
    print(f"  tuned-pages: {tuned}")
    print(f"  changed-thresholds: {changed_thresholds}")
    print(f"  approved-pages: {approved}")

    if missing > 0:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
