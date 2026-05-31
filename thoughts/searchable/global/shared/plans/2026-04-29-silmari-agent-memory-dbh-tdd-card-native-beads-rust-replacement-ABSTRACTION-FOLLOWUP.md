---
date: 2026-04-29T06:14:12-04:00
reviewer: VioletBeacon
topic: "Card-native beads_rust replacement — targeted abstraction follow-up"
tags: [review, cw9, abstraction-gap, external, follow-up]
status: complete
reviewed_plan: thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement.md
review_type: abstraction_gap_followup
related_beads_issue: silmari-agent-memory-dbh.1.1
---

# Abstraction Follow-Up: gwt-0002 and gwt-0003 Context Remediation

## Summary

This targeted follow-up checks the remaining abstraction-context gaps tracked by
`silmari-agent-memory-dbh.1.1` after the plan incorporated the 2026-04-28 abstraction review.

| GWT | Abstraction boundaries checked | Documented | Undocumented gaps |
| --- | ---: | ---: | ---: |
| `gwt-0002` | 2 | 2 | 0 |
| `gwt-0003` | 2 | 2 | 0 |

Total decisions checked: 4  
Documented in context/plan: 4  
Undocumented gaps: 0  
Escalations to boundary-contract review: 0

## Decision Checklist

### gwt-0002: edge_authority_gate

#### DC-1: How does import distinguish accepted reviewed refs from pending proposals?
- **Spec says**: imported reviewed refs are not silently live reviewed edges.
- **Implementation must decide**: what concrete evidence allows promotion during import.
- **Correct choice**: import may promote reviewed refs only when a validated
  `AcceptedReviewManifest` is present and bound to the verified snapshot hash.
- **Documented in context**: `.cw9/context/gwt-0002.md` now includes the manifest JSON schema,
  validation rules, accepted/pending/refused report counts, and the rule that missing manifest
  means pending `edge_proposals`.

#### DC-2: Which write authority commits accepted reviewed import edges?
- **Spec says**: reviewed live edges require explicit authority.
- **Implementation must decide**: whether import can call `insert_edge` directly.
- **Correct choice**: accepted reviewed import edges must pass through
  `EdgeWriteAuthority::AcceptedProposal`; direct `insert_edge` is not allowed for this path.
- **Documented in context**: `.cw9/context/gwt-0002.md` explicitly names
  `EdgeWriteAuthority::AcceptedProposal` and repeats the anti-pattern.

### gwt-0003: native_create_postsave_gate

#### DC-3: Who owns durable post-save effects in native mode?
- **Spec says**: successful native create is atomic and evented, but the old context text still
  mentioned `runPostSaveSteps()`.
- **Implementation must decide**: whether TypeScript or Rust owns keyword labels, recurrence,
  generated labels, events, and accepted explicit edges.
- **Correct choice**: Rust `create_card` is the single durable native-mode post-save owner.
- **Documented in context**: `.cw9/context/gwt-0003.md` now names Rust `create_card` and lists the
  durable effects it owns.

#### DC-4: What may TypeScript do after native create?
- **Spec says**: compatibility callers keep existing result shapes.
- **Implementation must decide**: whether TypeScript can still run legacy Beads post-save helpers.
- **Correct choice**: TypeScript validates caller input, invokes native create, maps the native
  result to `SaveCardResult`, and runs only shadow/parity reporting when configured. Legacy
  `runPostSaveSteps()`, `emitReinforcesToPrior()`, Beads flush/rebuild, and direct
  `findBeadsByLabel()` paths are limited to the legacy branch.
- **Documented in context**: `.cw9/context/gwt-0003.md` now includes a native post-save ownership
  section and anti-patterns forbidding duplicate Rust/TypeScript durable effects.

## Verdict

- [x] All targeted abstraction gaps documented.
- [x] `cw9 test /home/maceo/Dev/silmari-agent-memory` still passes after the context changes.
- [x] `git diff --check` reports no whitespace errors for the edited context files.

Proceed to the remaining coverage/boundary work once `gwt-0006` is complete.
