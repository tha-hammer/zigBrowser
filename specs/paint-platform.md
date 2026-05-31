# Paint/Platform Spec (Obsolete in WebKitGTK Slice 1)

Status: obsolete for active runtime as of 2026-05-31 pivot.

Reason:
- Custom display-list/raster/text/SDL paint stack is no longer the active product direction.
- Slice 1 now uses WebKitGTK rendering, with E2E observation via title protocol and PNG snapshot checks.

Active runtime validation path:
- `tests/e2e/webkitgtk_slice1_e2e.py`
- `tests/snapshots/pillow_tools.py nonuniform`

References:
- Active plan: `thoughts/searchable/shared/plans/2026-05-31-12-48-ENG-0003-tdd-webkitgtk-browser-slice1.md`
- Historical implementation snapshot: git tag `archive/custom-engine-pre-webkit`
