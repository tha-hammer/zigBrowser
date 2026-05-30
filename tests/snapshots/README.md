# Snapshot Re-Approval Flow

This directory owns the Track-C snapshot baseline and tolerance workflow.

## One-step regenerate + approve (real pipeline)

When `Page.navigate`-based rendering is available and writes candidate PNGs to
`.zig-cache/snapshot_actual/<page-id>.png`, run:

```bash
python3 tests/snapshots/reapprove_snapshots.py \
  --render-cmd 'zig test src/paint/snapshot_gate.zig --test-filter "corpus render gate reaches 90% threshold"' \
  --allow-render-fail \
  --tune-thresholds --apply-thresholds \
  --approve
```

Notes:
- `--allow-render-fail` is intentional: regen commands may fail while old baselines are still in place.
- `--approve` replaces `tests/snapshots/approved/*.png` from candidate PNGs.
- `--tune-thresholds --apply-thresholds` updates per-page tolerances in `manifest.json` from observed diff ratios.

## Tune only a small sample first

```bash
python3 tests/snapshots/reapprove_snapshots.py \
  --ids page01,page02 \
  --tune-thresholds
```

## Approve only a subset

```bash
python3 tests/snapshots/reapprove_snapshots.py \
  --ids page01,page02,page03 \
  --approve
```
