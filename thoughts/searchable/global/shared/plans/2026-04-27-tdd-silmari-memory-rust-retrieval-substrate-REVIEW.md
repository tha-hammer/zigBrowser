---
date: 2026-04-27T16:30:00-04:00
reviewer: Claude (Opus 4.7)
plan_under_review: thoughts/searchable/shared/plans/2026-04-27-tdd-silmari-memory-rust-retrieval-substrate.md
plan_planner: Codex
plan_git_commit: 7a2ae74ce3d3cfde6b91be6c3518f5a021071087
review_type: pre_implementation_contract_review
related_beads_issues:
  - silmari-agent-memory-9f9
  - silmari-agent-memory-xom
  - silmari-agent-memory-rjn
  - silmari-agent-memory-p6i
  - silmari-agent-memory-adf
status: needs_major_revision
tags: [review, tdd, plan, rust, zettelkasten, retrieval, contracts]
---

# Plan Review Report: TDD silmari_memory_rust Retrieval Substrate

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | ⚠️ | 4 issues (1 critical) |
| Interfaces | ⚠️ | 3 issues (1 critical) |
| Promises | ⚠️ | 2 issues |
| Data Models | ❌ | 6 issues (3 critical) |
| APIs | ⚠️ | 2 issues |

**Approval Status:** ❌ **Needs Major Revision** — 5 critical issues must be resolved before implementation. The TDD scaffold is sound; the contract gaps are concentrated in (a) edge vocabulary, (b) keyword normalization, (c) line-of-thought output shape, and (d) Beads schema field handling.

---

## Critical Issues (Must Address Before Implementation)

### C-1. Keyword normalization is specified incorrectly — round-trip lookups will fail

**Location:** Behavior 4, Test Specification (lines 605–625), Red test (lines 632–639)

**Plan claim:** Looking up `" Design Systems "` should return the term `"design systems"` (single space between words):

```rust
let hit = silmari_memory_rust::keyword_index::lookup_keyword(harness.db(), "design systems")
    .unwrap()
    .unwrap();
assert_eq!(hit.term, "design systems");
```

**Reality:** `apps/silmari-mcp/src/lib/keyword-index.ts:128–145` normalizes to **underscore-separated** form:

```typescript
const collapsed = term.toLowerCase().trim().replace(/\s+/g, '_');
```

So `" Design Systems "` actually normalizes to `"design_systems"`, and the keyword-label constructor (`labels.ts:179` → `keyword:design_systems`) confirms underscore is the on-disk form. The plan's assertion would store one shape and look up another — every multi-word keyword would miss.

**Impact:** Behavior 4 cannot pass against any imported corpus; importer-produced keyword rows would be unrecallable.

**Recommendation:**
- Change the test fixture to assert `"design_systems"`.
- Add `normalize_term` Rust function spec to mirror the JS algorithm: lowercase → trim → `\s+` → `_` → reject control chars (TS rejects code <32 or 127).
- Add a parity test that round-trips `keyword:<normalized>` labels through the Rust normalizer to confirm exact agreement with `apps/silmari-mcp/src/lib/labels.ts:179` (`keywordLabel`).

---

### C-2. Edge vocabulary in Behavior 2 is incomplete and ignores the AUTO/REVIEWED tier gate

**Location:** Behavior 2, Test Specification (lines 354–367), Red test (lines 374–397), Refactor goals (lines 446–451)

**Plan implies:** A small set of edge variants such as `EdgeType::Reinforces`, `Extends`, `Refines`, `Contradicts`, `Supports`, `Blocks` (the example surfaces only `Reinforces`).

**Reality (`apps/silmari-mcp/src/lib/labels.ts:79–97`):** there are **12 edge types in two named tiers**, and the tier distinction governs whether an agent may create the edge directly:

```typescript
// Lines 79–87: AUTO_EDGE_TYPES (7 types — agents may create directly)
['follows', 'continues', 'branches', 'derives-from', 'blocks', 'refers-to', 'annotates']

// Lines 89–95: REVIEWED_EDGE_TYPES (5 types — require human review gate)
['supports', 'contradicts', 'extends', 'reinforces', 'refines']

// Line 97
export const VALID_EDGE_TYPES = [...AUTO_EDGE_TYPES, ...REVIEWED_EDGE_TYPES] as const;
```

`labels.ts:108` (`edgeRequiresReview()`) implements the gate, and the `link-proposals.jsonl` workflow depends on it. The plan's port omits both the tier names and the review-gate predicate.

**Impact:**
- Importer cannot tell which edges should land in `card_edges` directly vs. queue into a review path.
- Future MCP integration would create REVIEWED edges (e.g., `reinforces`, `supports`) without the human-approval ceremony, violating the `MEMORY.md` rule "reinforces/supports/contradicts/extends/refines 503; use relates-to."

**Recommendation:**
- Reify the closed enum with **12 variants** in the Rust `model.rs` and split into `AutoEdgeType` and `ReviewedEdgeType` (or annotate variants with a `tier()` method).
- Add a B2 test fixture that covers all 12 edge types, modeled on `apps/silmari-memory-card-viewer/tests/server.test.ts:131–140` ("parses all 12 Silmari edge types").
- Add a contract: `EdgeType::requires_review(&self) -> bool` and a typed error `EdgeType::AttemptedReviewedAutoCreate`.
- Update Acceptance Criteria to assert "12 edge variants present, AUTO/REVIEWED tier preserved."

---

### C-3. `LineOfThought` Rust struct is missing `trunk_seeds` (specified in tests, dropped from interface)

**Location:** Behavior 8, Resource Registry Binding (line 1064), Test Specification (lines 1073–1077), Red test (lines 1093–1112)

**Plan inconsistency:** The behavior description, registry `predicate_refs` ("trunk seed cards"), and refactor goals all reference trunk seeds. The Red test only asserts `parent`, `siblings`, `children`, `hubs`, and `all`. The implied output struct is `{queried, parent, siblings, children, hubs, all, total_scope}` — **no `trunk_seeds` field**.

**Reality (`apps/silmari-mcp/src/lib/line-of-thought.ts:66–83`):**

```typescript
interface LineOfThought {
  queried: BeadRow | null;
  parent: BeadRow | null;
  siblings: BeadRow[];
  children: BeadRow[];
  hubs: BeadRow[];
  trunkSeeds: BeadRow[];   // ← present in TS, missing from Rust plan
  all: BeadRow[];
  totalScope: number;
}
```

`findTrunkSeeds()` (line-of-thought.ts:128–134) is explicitly specified: scan the trunk, filter sequences matching `^\d+$` (root-level entries), exclude register `'0'`, return the live BeadRow set. The current MCP tool (`apps/silmari-mcp/src/index.ts:692–696`) returns the field directly; clients in production may already depend on it.

**Impact:** Phase 2 L4 anchor checks (referenced in `line-of-thought.ts:242`) and the viewer's group rendering both consume `trunkSeeds`. Omitting the field breaks the published contract.

**Recommendation:**
- Add `trunk_seeds: Vec<Card>` to the `LineOfThought` Rust struct.
- Add a Red test `line_of_thought_returns_trunk_seeds_for_root_filtered_sequences` mirroring `findTrunkSeeds`.
- Document the union as parent ∪ siblings ∪ children ∪ hubs ∪ trunk_seeds (matching TS line-of-thought.ts:1–13).

---

### C-4. Plan misrepresents current TS storage shape — folgezettel/trunk live in labels, not columns

**Location:** Behavior 1 schema (lines 263–278), Behavior 5 ("native cards with `fz_address` values", line 781)

**Plan claim:** `cards` table has dedicated columns `fz_address TEXT` and `trunk TEXT`. The plan reads as if it were "preserving" the existing column layout.

**Reality:** TS code stores fz/trunk **as labels** on `issues` rows; there is no `fz_address` column. `parseFzFromLabels()` (`labels.ts:213–220`) extracts the slash-form address from `fz:<trunk>_<sequence>` at every read.

**Impact:** This is a **schema evolution**, not a port. That's a defensible design choice for the Rust substrate — but mislabeling it as parity hides:
- A migration step (the importer must compute `fz_address` and `trunk` from labels).
- A double-source-of-truth risk (label vs. column drift).
- A new invariant the codebase must enforce: column matches the `fz:` label exactly.

**Recommendation:**
- Add an explicit "Schema Evolution" subsection under "Desired End State" stating that `fz_address` and `trunk` are derived columns, populated from labels at insert time, and validated against labels on every read until the importer stabilizes.
- Add a CHECK constraint or insert-time assertion: `cards.fz_address IS NULL OR EXISTS (SELECT 1 FROM card_labels WHERE card_id = cards.id AND label = 'fz:' || REPLACE(cards.fz_address, '/', '_'))`.
- Add a parity test: imported card's `fz_address` column matches `parseFzFromLabels(labels)`.

---

### C-5. Importer (Behavior 3) does not enumerate the 35+ Beads issue fields it must filter

**Location:** Behavior 3 (lines 467–588)

**Plan claim:** "Issue-management fields do not leak into retrieval tables." The Red test asserts only that `cards`/`card_edges` rows exist with correct counts.

**Reality:** `vendor/beads_rust/src/storage/sqlite.rs:2222–2228` shows the live `issues` SELECT exposes 35+ fields including: `status`, `priority`, `assignee`, `owner`, `sender`, `ephemeral`, `pinned`, `is_template`, `due_at`, `defer_until`, `external_ref` (UNIQUE), `closed_by_session`, `compaction_level`, `original_size`, `deleted_at`, `delete_reason`, etc. The plan's `cards` table has 11 columns — **what happens to the other 24+?**

Additionally:
- The current viewer at `apps/silmari-memory-card-viewer/server.ts:149` runs `SELECT id, labels FROM issues` — but the Beads schema (`schema.rs:121–129`) puts labels in a **separate** `labels(issue_id, label)` table. There is no `issues.labels` column. The viewer relies on a denormalized export shape from `bv --export-pages`. Plan must declare which adapter it consumes and whether it joins or denormalizes.
- `dependencies(issue_id, depends_on_id, type)` allows types beyond `'blocks'` (`'parent-child'`, `'conditional-blocks'`, `'waits-for'`). The plan refactor goal mentions blocks dedup; it doesn't mention rejecting non-blocks dependency rows.

**Impact:**
- Silent field drop is fine for retrieval, but `external_ref` UNIQUE collisions, `deleted_at` tombstones, and `ephemeral`/`is_template` flags will produce incorrect cards if not explicitly filtered.
- Without an enumeration, the importer's behavior is undefined — that's a contract gap.

**Recommendation:**
- Add a "Beads Field Disposition" subsection to Behavior 3 listing every Beads `issues` column with one of: KEEP-AS-IS / TRANSFORM / DROP / TOMBSTONE-FILTER.
- Specify which adapter the importer uses: (a) raw `vendor/beads_rust` sqlite (with normalized labels JOIN), (b) `bv --export-pages` denormalized export. The plan's tests imply (a); the viewer's existing path implies (b). Pick one as the canonical source for v1, document the other as future work.
- Add a Red test that imports a fixture with `deleted_at IS NOT NULL` and asserts the row is skipped.
- Add a Red test that imports a `dependencies` row with `type = 'parent-child'` and asserts no `card_edges` row is produced.

---

## Contract Review

### Well-Defined

- ✅ **Behavior 1**: `init_schema(&Path) -> Result<(), Error>` is idempotent and version-tracked. Schema-versions table provides forward-compat hooks.
- ✅ **Behavior 6**: `recall(conn, query, opts) -> Result<RecallSession, Error>` cleanly defines miss shape (`RecallSession::miss(query)`) vs. hit composition.
- ✅ **Behavior 9**: CLI exit-code contract — typed nonzero on parse error, JSON envelope with `--json`, stdout/stderr separation.
- ✅ **Out-of-scope table** (lines 121–127) is explicit and well-justified — particularly the "no LLM semantic proposal" boundary.

### Missing or Unclear

- ⚠️ **Behavior 2**: `parse_labels` returns `Result<ParsedLabels, Error>` but the documented behavior is "skip malformed refs." If the function never errors, `Result` is dead weight — clarify whether unknown edge type produces an error, a warning, or silent skip. TS code at `labels.ts:288` writes to stderr; the Rust contract should mirror this with a typed `LabelParseWarning` collected in `ParsedLabels`.
- ⚠️ **Behavior 3**: `import_beads_box(source, target, box_name) -> Result<ImportSummary, Error>` doesn't specify whether mid-import failure rolls back. Sqlite transaction boundary is implicit. Specify: "wrapped in a single sqlite transaction; partial failure leaves target unchanged."
- ⚠️ **Behavior 7**: `follow_edges` opts use a builder pattern (`Default::default().outbound().only(["reinforces"]).max_depth(2)`) — this builder is not defined anywhere in the plan. Spell out the `EdgeTraversalOptions` struct fields, defaults, and validation (e.g., `max_depth = 0` means seed-only).
- ⚠️ **Acceptance Criteria** says "no native dependency on Beads issue-search sorting or priority fields." Add a CI grep gate: `! rg --files-with-matches '\bsearch_issues\b|priority' apps/silmari_memory_rust/src` or equivalent.

### Recommendations

- Document an explicit `Error` enum (the plan refactor mentions "domain Error enum" without defining variants). Suggested variants from the codepath: `Sqlite(rusqlite::Error)`, `LabelParse(String)`, `FolgezettelAddress(String)`, `KeywordValidation(String)`, `EdgeTraversal(String)`, `Import(String)`, `Cli(String)`, `SchemaCompatibility{found: i64, supported: i64}`.

---

## Interface Review

### Well-Defined

- ✅ Module split (`schema`, `model`, `labels`, `store`, `importer`, `keyword_index`, `folgezettel`, `edges`, `retrieval`, `cli`) cleanly separates concerns. `importer` is the only module that touches `issues`/`dependencies` table names — good single-source-of-truth for Beads coupling.
- ✅ `parse_labels` API surface matches the TS shape: returns a struct with `fz_address`, `kind`, `box`, `trunk`, `source`, `content_hash`, `refs`. Symmetric encode/decode is called out in refactor goals.

### Missing or Unclear

- ⚠️ **TrunkScanCache absent from public API** — TS `navigate.ts:784` threads a `TrunkScanCache` map through `recall()` and `neighborhood()` so multi-entry recall scans each trunk exactly once. Plan's `recall(conn, query, opts)` signature has nowhere to plumb this cache. With 20 entry points across 1–2 trunks, this is a 10–20× perf regression vs. TS. Add a `RecallContext` struct or per-call cache that's reused inside `recall`.
- ⚠️ **`lineOfThoughtAtAddress` variant missing** — TS exports both `lineOfThought(seedCardId)` and `lineOfThoughtAtAddress(address)`; the latter is used at save-time when the seed has no card id yet (line-of-thought.ts:242). Plan exposes only the card-id form.
- ❌ **`EdgeType` enum naming** — refactor goal says "closed enum matching `VALID_EDGE_TYPES`." The TS source uses kebab-case strings (`derives-from`, `refers-to`). The Rust enum naming convention should be `DerivesFrom`, `RefersTo`, with explicit `Display`/`FromStr` round-trip tests against the kebab-case wire form. The plan does not specify this round-trip — call it out.

### Recommendations

- Add a fully-spelled `EdgeType` enum body in Behavior 2 Refactor with all 12 variants and the kebab-case ↔ PascalCase mapping rule.
- Add `lineOfThoughtAtAddress` to Behavior 8 alongside `line_of_thought`.
- Add `RecallContext` (or named cache parameter) to Behavior 6 signature.

---

## Promise Review

### Well-Defined

- ✅ **150-card cap** (Behavior 8) — matches `LINE_OF_THOUGHT_MAX = 150` constant in TS, dedup-then-truncate ordering preserved.
- ✅ **Default 20-entry recall limit** (Behavior 6) — matches `DEFAULT_RECALL_LIMIT_PER_TERM = 20` (`navigate.ts:598`), and the truncation flag semantics (`truncated = kept.length < totalMatching`) are correctly described.
- ✅ **Idempotent init** (Behavior 1) — verified via schema-versions table reads on second invocation.
- ✅ **Idempotent import** (Behavior 3) — refactor goal calls out duplicate-import row stability.

### Missing or Unclear

- ⚠️ **Cycle promise** for edge traversal (Behavior 7) — Edge Cases mention "cycle does not loop forever" but no concrete bound on visited-set memory. With unbounded card counts, the promise needs a cap or a documented BFS visited-set sizing.
- ⚠️ **Truncation tie-break determinism** — Behavior 8 sorts truncation candidates by `created_at` (newest-first) per TS `line-of-thought.ts:160–171`. Plan's refactor mentions "sort groups by folgezettel address, then updated time, then id" — that's a different ordering than TS's recency-only truncation. Specify whether the Rust port matches TS exactly or intentionally diverges.

### Recommendations

- Add explicit visited-set bound (e.g., `max_visited = 10_000`) to `EdgeTraversalOptions` and a typed `EdgeTraversalError::VisitedSetExhausted`.
- Pin the truncation tie-break to TS behavior in Behavior 8 acceptance criteria.

---

## Data Model Review

### Well-Defined

- ✅ **`card_edges(source_id, target_id, edge_type)` composite PK** matches TS viewer's `card_edges` schema (server.test.ts:322).
- ✅ **`schema_versions(table_name, version, applied_at)`** is a clean version-tracking shape.

### Missing or Unclear

- ❌ **`cards.kind` column has no enum constraint** — TS supports a closed set: `biblio, idea, hub, structure, register, fact, signal, learning, preference, decision, stub` (extracted from `LABEL_PREFIX` analysis + downstream code). Plan declares `kind TEXT NOT NULL` with no CHECK constraint. Add `CHECK(kind IN (...))` or document the open-set decision.
- ❌ **`cards.box` column has no enum constraint** — TS supports `'biblio' | 'idea'` exactly. Add `CHECK(box IN ('biblio', 'idea'))`.
- ❌ **`cards.trunk` column has no enum constraint** — TS `TrunkId` is `1 | 2 | 3 | 4 | 5 | 'root'` (with `0` reserved for cross-trunk Register, `N/0` reserved per-trunk). Plan declares `trunk TEXT` open. Add `CHECK(trunk IN ('1','2','3','4','5','root'))` or document and justify the looser constraint.
- ❌ **`cards.content_hash` has no format constraint** — TS validates 8 hex chars with `/^[0-9a-f]{8}$/` (`labels.ts:173`). Add `CHECK(content_hash IS NULL OR length(content_hash) = 8)` and a regex assertion in the parser.
- ❌ **`cards.title` vs `cards.body` vs missing `description`** — TS `BeadRow` carries `title` and `description` (and Beads source has `description, design, acceptance_criteria, notes`). Plan has `title` + `body`. Specify the mapping: `body = description`? Or `body = description + design + notes`? This affects body-hash dedup and the `register-read` recipe.
- ⚠️ **`keyword_entries.entry_points TEXT`** — plan says "JSON array" in refactor goal but the column declaration doesn't say so. Add explicit `CHECK(json_valid(entry_points))` (sqlite 3.38+) or document the format invariant inline. Also document the dual-shape entry-point resolution from `keyword-index.ts:267–331` — entry points may be card IDs OR slash-form addresses (the Rust port must pick one).

### Recommendations

- Add CHECK constraints for `kind`, `box`, `trunk`, `content_hash` lengths.
- Decide and document the `body` field: full Beads description-and-friends concat vs. description-only. Add a Red test that asserts the chosen mapping.
- Pick the `entry_points` shape (card ID vs. slash address) and add a typed `EntryPoint` Rust enum if both are supported, or document the single-shape decision.
- Add indexes called out in refactor goals (line 319) **before** Behavior 4 Red test runs at scale — the parity test for "10+ entry-point density" will be slow without `card_labels(label, card_id)`.

---

## API Review

### Well-Defined

- ✅ CLI subcommand surface (`init`, `import-beads`, `recall`, `neighborhood`, `edges`, `line-of-thought`) maps cleanly to behaviors.
- ✅ JSON output envelope is named (`--json` flag) and stable-shape promises are stated.

### Missing or Unclear

- ⚠️ **JSON error envelope is undefined** — Behavior 9 says "typed JSON errors are emitted for downstream clients" but no schema. Specify `{error: {code: string, message: string, details?: object}}`.
- ⚠️ **Field naming convention** — TS uses camelCase (`entryPoints`, `totalMatching`, `crossRefs`). Plan's tests use `snake_case` (`entry_points`, `total_matching`, `cross_refs`). MCP/viewer integration needs to know which is canonical. Pick one and add a serde rename if mixing. Recommendation: keep snake_case in Rust internals and `#[serde(rename_all = "camelCase")]` for JSON output to match existing TS clients.

### Recommendations

- Add a "JSON Output Schema" subsection to Behavior 9 with the exact envelope and an example for each subcommand.
- Pin the case convention with a serde rename rule and a Red test that snapshots a recall JSON output and compares against a TS-produced fixture.

---

## Suggested Plan Amendments

```diff
# In Behavior 1: Native Schema Initialization

+ Add CHECK constraints:
+   cards.kind IN ('biblio','idea','hub','structure','register','fact','signal','learning','preference','decision','stub')
+   cards.box IN ('biblio','idea')
+   cards.trunk IN ('1','2','3','4','5','root')
+   cards.content_hash IS NULL OR length(cards.content_hash) = 8
+ Add column: cards.description TEXT (or document body-vs-description mapping)
+ Add subsection "Schema Evolution Note": fz_address and trunk are derived columns, validated against labels.

# In Behavior 2: Label Parsing

~ Replace EdgeType example with all 12 variants split into AutoEdgeType + ReviewedEdgeType
+ Add fn EdgeType::requires_review(&self) -> bool
+ Add fn EdgeType::display_str(&self) -> &'static str (kebab-case)
+ Add fn EdgeType::from_str(s: &str) -> Result<Self, LabelParseError>
+ Add Red test: parses_all_twelve_edge_types_round_trip
+ Add Red test: edge_type_round_trip_kebab_pascal_kebab

# In Behavior 3: Beads Import

+ Add subsection "Beads Field Disposition" listing all 35+ issues columns with KEEP/TRANSFORM/DROP/TOMBSTONE-FILTER.
+ Pick adapter: raw beads_rust sqlite (with normalized labels JOIN) — document.
+ Add Red test: skips_rows_with_deleted_at_not_null
+ Add Red test: dependency_type_parent_child_does_not_become_card_edge
+ Promise: import is wrapped in a single sqlite transaction; partial failure rolls back.

# In Behavior 4: Keyword Recall

- assert_eq!(hit.term, "design systems");
+ assert_eq!(hit.term, "design_systems");
+ Specify normalize_term: lowercase → trim → \s+ → '_' → reject control chars (<32 || ==127).
+ Add Red test: parity_with_keywordLabel_typescript_round_trip

# In Behavior 6: Composed Recall

+ Add RecallContext (or per-call TrunkScanCache) to recall() signature for multi-entry-point trunk-scan reuse.
+ Pick entry_points shape (card id OR slash address) and document.

# In Behavior 7: Edge Traversal

+ Spell out EdgeTraversalOptions: { direction: Direction, edge_types: Option<Vec<EdgeType>>, max_depth: u32, max_visited: u32 }
+ Add typed error EdgeTraversalError::VisitedSetExhausted

# In Behavior 8: Line of Thought

+ Add field: trunk_seeds: Vec<Card> to LineOfThought struct
+ Add Red test: line_of_thought_returns_trunk_seeds_root_filtered
+ Add Red test: line_of_thought_truncates_by_recency_when_over_150
+ Add lineOfThoughtAtAddress(address) variant

# In Behavior 9: CLI

+ Add subsection "JSON Output Schema" with envelope, success, and error shapes.
+ Pin case convention: snake_case Rust + serde rename to camelCase JSON.
+ Add Red test: snapshot_recall_json_matches_typescript_fixture
```

---

## Approval Status

- [ ] **Ready for Implementation** — No critical issues
- [ ] **Needs Minor Revision** — Address warnings before proceeding
- [x] **Needs Major Revision** — Critical issues must be resolved first

**Five critical issues** (C-1 through C-5) gate implementation. Of these, **C-1 (keyword normalization)** and **C-2 (12-edge vocabulary + AUTO/REVIEWED tier)** are the highest-leverage to fix first, because they cascade into Behaviors 3, 4, 6, and 7. **C-3 (`trunk_seeds` field)** is a single-field addition. **C-4 and C-5** are documentation gaps that turn into implementation footguns.

The TDD scaffold itself — Red/Green/Refactor per behavior, parity tests against existing TS fixtures, sqlite-backed integration — is well-structured. With the critical contract gaps resolved, the plan should be implementable in the proposed order without further structural changes.

---

## References

- Plan under review: `thoughts/searchable/shared/plans/2026-04-27-tdd-silmari-memory-rust-retrieval-substrate.md`
- TS label namespace: `apps/silmari-mcp/src/lib/labels.ts:28–301`
- TS keyword index: `apps/silmari-mcp/src/lib/keyword-index.ts:128–145, 155–162, 267–331, 417–427`
- TS recall composition: `apps/silmari-mcp/src/lib/navigate.ts:81–175, 220–250, 294–341, 487–574, 696–725, 746–806`
- TS line of thought: `apps/silmari-mcp/src/lib/line-of-thought.ts:57, 66–83, 108–134, 160–171, 188–195, 219, 242`
- TS folgezettel: `apps/silmari-mcp/src/lib/folgezettel.ts:69–185`
- Viewer edge synthesis: `apps/silmari-memory-card-viewer/server.ts:96–104, 141–174`
- Viewer schema mismatch (existing bug): `apps/silmari-memory-card-viewer/server.ts:149` queries `issues.labels` but Beads schema (`vendor/beads_rust/src/storage/schema.rs:18–129`) has labels in a separate table
- Beads search (out of scope): `vendor/beads_rust/src/cli/commands/search.rs:1–4`, `vendor/beads_rust/src/storage/sqlite.rs:2215–2242`
- Beads label validation: `vendor/beads_rust/src/validation/mod.rs:236–244, 542–544`
- Test fixtures: `apps/silmari-mcp/tests/navigate.test.ts:27–165`, `apps/silmari-mcp/tests/keyword-index-sqlite.test.ts:50–143`, `apps/silmari-mcp/tests/zk-recall-limit.test.ts:75–211`, `apps/silmari-memory-card-viewer/tests/server.test.ts:126–417`
