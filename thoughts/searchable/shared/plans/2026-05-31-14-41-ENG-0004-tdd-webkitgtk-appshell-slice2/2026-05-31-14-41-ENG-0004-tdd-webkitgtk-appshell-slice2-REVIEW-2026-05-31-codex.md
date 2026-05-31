# Plan Review Report: WebKitGTK App Shell — Slice 2 TDD Implementation Plan (2026-05-31 Codex Re-Review)

Plan: `thoughts/searchable/shared/plans/2026-05-31-14-41-ENG-0004-tdd-webkitgtk-appshell-slice2.md`

## Review Summary

| Category | Status | Issues Found |
|---|---|---|
| Contracts | ❌ | 1 critical |
| Interfaces | ⚠️ | 2 warnings |
| Promises | ❌ | 1 critical, 1 warning |
| Data Models | ⚠️ | 1 warning |
| APIs | ❌ | 1 critical |

## Findings (ordered by severity)

### 1) ❌ Critical — Main-frame detection contract is incorrect and undermines nav policy guarantees
- Evidence in plan:
  - `webkit_navigation_action_get_frame_name` is treated as `NULL ⇒ main frame` in multiple places: lines 111, 176, 415-419, 530-531.
- Evidence in local WebKit docs:
  - GIR docs state `get_frame_name` returns the target frame name (e.g. `_blank`) and **returns NULL in all other cases**, not specifically “main frame”.
  - `/usr/share/gir-1.0/WebKit2-4.1.gir:13345-13347`
- Impact:
  - C10/C14.9 “main-frame-only enforcement” is not actually enforceable with the oracle currently specified.
  - B2/B3 behavior can diverge under subframe/unnamed-frame navigations, weakening the plan’s allow/block guarantees.
- Required amendment:
  - Remove the `NULL ⇒ main frame` claim from C10/C14.9.
  - Either:
    - define Slice 2 policy as applying to **all** `NAVIGATION_ACTION` decisions, or
    - provide a verified main-frame discriminator that is actually available for this decision type.

### 2) ❌ Critical — `open_in_subwindow` mapping is underspecified at the `decide-policy` seam
- Evidence in plan:
  - C14.3 maps `Decision.open_in_subwindow` to value `2` and says the callback “switches 0/1/2 to the matching WebKit action” (lines 322, 326-327).
- Evidence in local headers/docs:
  - WebKit policy actions are `use`, `ignore`, `download` only.
  - `/usr/include/webkitgtk-4.1/webkit/WebKitPolicyDecision.h:53-63`
  - For `NEW_WINDOW_ACTION`, acceptable policy decisions are `use` or `ignore`.
  - `/usr/share/gir-1.0/WebKit2-4.1.gir:16008-16010`
- Impact:
  - Implementation can diverge at the core control boundary (whether new windows open at all, and via which path).
  - B4 is not deterministic from spec text alone.
- Required amendment:
  - Pin explicit mapping rule: `open_in_subwindow` for `NEW_WINDOW_ACTION` must call `webkit_policy_decision_use(decision)`, then rely on `create` callback wiring (C14.10) to supply the app-owned child view.
  - State that `open_in_subwindow` is invalid for non-`NEW_WINDOW_ACTION` and must assert/log+ignore.

### 3) ⚠️ Warning — Host reload trigger is named but not concretely specified for E2E driving
- Evidence in plan:
  - Behavior 1 requires “host triggers `webkit_web_view_reload`” and E2E “calls reload” (lines 480, 497-499), with only “host trigger seam” in `src/app.zig` (line 493).
- Impact:
  - Reload behavior can’t be exercised reproducibly from black-box E2E without an explicit trigger contract.
- Recommendation:
  - Add one concrete trigger contract for tests (for example a dedicated CLI/debug command, signal hook, or explicit in-app host control path guarded for test mode).

### 4) ⚠️ Warning — `add` command return encoding is inconsistent in the plan text
- Evidence in plan:
  - C14.8 says `add` returns JSON number text `5` (line 404).
  - Behavior 5 red test expects `"5"` (line 632).
- Impact:
  - Unit/E2E assertions can drift between string and numeric semantics.
- Recommendation:
  - Normalize to bare JSON number text `5` everywhere and adjust sample assertions accordingly.

### 5) ⚠️ Warning — Current-state prerequisite text is stale vs repository reality
- Evidence in plan:
  - Plan frontmatter/current-state still says Slice 1 currently has “0 source files” (lines 11, 69).
- Impact:
  - This can cause wrong gating assumptions and mislead implementation sequencing.
- Recommendation:
  - Refresh Current State Analysis to reflect the now-present Slice 1 code and tests.

## Suggested Plan Amendments

```diff
# In §C10 / §C14.9
- main-frame detect via get_frame_name (NULL ⇒ main frame)
+ get_frame_name is treated as target-name metadata only (not a main-frame oracle)
+ Slice-2 nav policy enforcement scope is explicitly [all NAVIGATION_ACTION | verified-main-frame-only via <verified API>]

# In §C14.3
- switch 0/1/2 to matching WebKit action
+ for NEW_WINDOW_ACTION + Decision.open_in_subwindow: call webkit_policy_decision_use(decision)
+ then route through create callback (C14.10) to construct app-owned child window
+ Decision.open_in_subwindow for other decision types is invalid (assert/log + ignore)

# In Behavior 1
+ define exact host reload trigger used by E2E harness

# In §C14.8 / Behavior 5
- dispatch(add) example/test mix of 5 and "5"
+ dispatch(add) returns JSON number text 5 (unquoted) consistently

# In frontmatter/current-state section
- currently 0 source files
+ updated to current repository state
```

## Approval Status

- [ ] Ready for Implementation
- [ ] Needs Minor Revision
- [x] Needs Major Revision

Reason: two unresolved criticals remain at the navigation/policy boundary and must be fixed before implementation starts.
