---
date: 2026-04-27T12:49:48-04:00
planner: Codex
git_commit: 7a2ae74ce3d3cfde6b91be6c3518f5a021071087
branch: main
repository: silmari-agent-memory
topic: "TDD plan - silmari_memory_rust Zettelkasten-native retrieval substrate"
app_name: silmari_memory_rust
tags: [tdd, plan, rust, zettelkasten, retrieval, silmari, keyword-index, folgezettel, typed-edges]
related_research:
  - thoughts/searchable/shared/research/2026-04-27-zettelkasten-rust-retrieval-substrate.md
related_beads_issues:
  - silmari-agent-memory-9f9
  - silmari-agent-memory-xom
  - silmari-agent-memory-rjn
  - silmari-agent-memory-p6i
  - silmari-agent-memory-adf
status: implemented
last_updated: 2026-04-27
last_updated_by: Codex
type: tdd_plan
review_resolution:
  review_file: thoughts/searchable/shared/plans/2026-04-27-tdd-silmari-memory-rust-retrieval-substrate-REVIEW.md
  status: all_critical_and_warning_items_folded_into_plan
---

# silmari_memory_rust Retrieval Substrate - TDD Implementation Plan

## Overview

Create a new Rust app named `silmari_memory_rust` at `apps/silmari_memory_rust`.

The app is a Zettelkasten-native retrieval substrate, not a port of Beads issue search. The first implementation slice must prove the current Silmari semantics in Rust:

1. Exact keyword-register lookup is the entry point for idea recall.
2. Folgezettel addresses drive parent, sibling, child, and chain retrieval.
3. Typed `ref:<edge>:<target>` labels become first-class edges.
4. Line-of-thought retrieval is a bounded structural neighborhood.
5. Beads-shaped data can be imported for migration, but Beads `LIKE` search and issue-management relations do not define recall behavior.

This plan is behavior-first. Each behavior below starts with failing Rust tests, then the minimum implementation, then refactoring while preserving the tests.

## Review-Driven Revision Notes

This revision incorporates the contract review in `thoughts/searchable/shared/plans/2026-04-27-tdd-silmari-memory-rust-retrieval-substrate-REVIEW.md`.

The reviewed plan is implementation-ready only if the following constraints are treated as hard requirements, not optional polish:

- Keyword normalization must exactly mirror `apps/silmari-mcp/src/lib/keyword-index.ts::normalizeTerm`: lowercase, trim, collapse whitespace to underscores, and reject ASCII control characters.
- Edge types are the full 12-value Silmari vocabulary, split into AUTO and REVIEWED tiers, with explicit `requires_review` behavior.
- `LineOfThought` includes `trunk_seeds` and the address-based variant used before a seed card id exists.
- Native `cards.fz_address` and `cards.trunk` are derived schema-evolution columns populated from labels, not current TypeScript storage columns.
- The importer consumes raw `beads_rust` sqlite as the v1 canonical adapter, joins the normalized `labels` table, filters tombstones/templates/ephemeral rows explicitly, and rejects non-`blocks` Beads dependencies for native edge synthesis.
- The public Rust API exposes cache/context and option structs instead of relying on implicit TypeScript globals or unnamed builders.
- JSON emitted by the CLI uses camelCase to match existing TypeScript clients, while Rust structs keep snake_case internally.

## Current State Analysis

### Key Discoveries

- `vendor/beads_rust/src/cli/commands/search.rs:3` describes Beads search as classic bd-style `LIKE` over title, description, and id. This is explicitly not Zettelkasten recall.
- `vendor/beads_rust/src/storage/sqlite.rs:2205` and `vendor/beads_rust/src/storage/sqlite.rs:2226` implement `search_issues` as a `LIKE` scan against `issues`.
- `vendor/beads_rust/src/storage/schema.rs:121` stores Beads labels in `labels(issue_id, label)`, which makes exact Silmari labels usable as a migration input.
- `vendor/beads_rust/src/validation/mod.rs:542` confirms namespaced labels with colons are valid, enabling labels such as `fz:2_3a1` and `ref:reinforces:zk-123`.
- `apps/silmari-mcp/src/lib/labels.ts:79`, `apps/silmari-mcp/src/lib/labels.ts:89`, and `apps/silmari-mcp/src/lib/labels.ts:97` define the current Silmari edge vocabulary.
- `apps/silmari-mcp/src/lib/labels.ts:125`, `apps/silmari-mcp/src/lib/labels.ts:161`, `apps/silmari-mcp/src/lib/labels.ts:213`, and `apps/silmari-mcp/src/lib/labels.ts:277` define the label constructors and parsers the Rust app must preserve.
- `apps/silmari-mcp/src/lib/keyword-index.ts:1`, `apps/silmari-mcp/src/lib/keyword-index.ts:20`, and `apps/silmari-mcp/src/lib/keyword-index.ts:253` define the sqlite keyword index as exact normalized lookup, not full-text fallback.
- `apps/silmari-mcp/src/lib/navigate.ts:220`, `apps/silmari-mcp/src/lib/navigate.ts:294`, `apps/silmari-mcp/src/lib/navigate.ts:487`, and `apps/silmari-mcp/src/lib/navigate.ts:746` define the composed recall path: keyword hit, entry cards, folgezettel neighborhoods, and optional typed edge traversal.
- `apps/silmari-mcp/src/lib/line-of-thought.ts:187` defines line-of-thought retrieval around parent, siblings, children, hubs, trunk seeds, and a 150-card cap.
- `apps/silmari-memory-card-viewer/server.ts:96` and `apps/silmari-memory-card-viewer/server.ts:141` show a current edge-adaptation workaround: parse `ref:*` labels from exported issue rows into `card_edges`.
- `apps/silmari-mcp/tests/navigate.test.ts:27` through `apps/silmari-mcp/tests/navigate.test.ts:165` provide pure folgezettel behavior fixtures to port into Rust tests.
- `apps/silmari-mcp/tests/keyword-index-sqlite.test.ts:50` through `apps/silmari-mcp/tests/keyword-index-sqlite.test.ts:143` provide sqlite keyword-index schema and density invariants.
- `apps/silmari-mcp/tests/zk-recall-limit.test.ts:75` through `apps/silmari-mcp/tests/zk-recall-limit.test.ts:211` provide recall limit, truncation, sort, and miss-shape expectations.
- `apps/silmari-memory-card-viewer/tests/server.test.ts:126` through `apps/silmari-memory-card-viewer/tests/server.test.ts:417` provide ref-label parsing and edge-synthesis behavior fixtures.

### Registry And Schema Reality Check

- The requested workflow requires `specs/schemas/resource_registry.json`, but this repo does not contain that file.
- The repo also does not contain root-level `schema/`, `schemas/`, or `specs/schemas/` directories.
- `vendor/beads_rust/agent_baseline/schemas/` exists, but those files are vendor Beads baseline schemas, not this repo's canonical Silmari resource registry.
- Existing plans in this repo handle the same gap by using `[PROPOSED]` registry identities and `schema_contract_refs: N/A`. This plan follows that local precedent.
- Every planned Rust function still includes required documentation contract tags so future registry backfill has explicit anchors.

## Desired End State

`apps/silmari_memory_rust` is a Rust crate with a binary and library:

```text
apps/silmari_memory_rust/
  Cargo.toml
  src/
    lib.rs
    main.rs
    schema.rs
    model.rs
    labels.rs
    store.rs
    importer.rs
    keyword_index.rs
    folgezettel.rs
    edges.rs
    retrieval.rs
    cli.rs
  tests/
    schema_init.rs
    labels.rs
    import_beads.rs
    keyword_recall.rs
    neighborhood.rs
    edges.rs
    line_of_thought.rs
    cli_contract.rs
```

The native sqlite schema uses card language:

- `cards`
- `card_labels`
- `card_edges`
- `keyword_entries`
- `schema_versions`

No native table is named `issues`, `dependencies`, `issue_metrics`, or `triage_recommendations`. Those names may appear only in the migration adapter tests and importer implementation that reads Beads-shaped source data.

### Schema Evolution Contract

The native schema is a deliberate evolution from the current TypeScript storage shape:

- Current TypeScript stores folgezettel and trunk values as labels on Beads `issues` rows. There is no current `issues.fz_address` or `issues.trunk` column.
- Native Rust stores `cards.fz_address` and `cards.trunk` as derived columns for efficient retrieval. They are populated from `fz:<trunk>_<sequence>` and `trunk:<id>` labels at insert/import time.
- Until the importer is proven stable, all public store writes and importer transactions must validate that the derived columns match the label set. Because sqlite `CHECK` constraints cannot reference `card_labels`, this is an insert/read assertion in `store.rs`, backed by a parity test rather than a cross-table `CHECK`.
- The importer must keep the original labels in `card_labels` even when the same fact is materialized into a derived column. This preserves round-trip parity and allows future migration audits.

### Native Data Model Contract

- `cards.kind` is closed over `biblio`, `idea`, `hub`, `structure`, `register`, `fact`, `signal`, `learning`, `preference`, `decision`, and `stub`.
- `cards.box` is closed over `biblio` and `idea`.
- `cards.trunk` is nullable, and when present is closed over `1`, `2`, `3`, `4`, `5`, and `root`. Cross-trunk register label `0` is not a native card trunk.
- `cards.content_hash` is nullable, and when present must be exactly 8 lowercase hex characters, matching `apps/silmari-mcp/src/lib/labels.ts`.
- `cards.description` stores the exact Beads `description` field. `cards.body` stores a deterministic display/search payload formed from non-empty `description`, `design`, `acceptance_criteria`, and `notes` sections in that order. Native recall must not use `body` as a fallback search source in this tranche.
- `keyword_entries.entry_points` is sqlite JSON containing an ordered array of strings in the current TypeScript wire shape. Rust exposes these as `EntryPoint::Address(String)` for slash-form folgezettel addresses or `EntryPoint::CardId(String)` otherwise.

### Domain Error Contract

The crate exposes one domain error enum and module-specific typed variants:

```rust
#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("label parse error: {0}")]
    LabelParse(String),
    #[error("folgezettel address error: {0}")]
    FolgezettelAddress(String),
    #[error("keyword validation error: {0}")]
    KeywordValidation(String),
    #[error("edge traversal error: {0}")]
    EdgeTraversal(String),
    #[error("edge validation error: {0}")]
    EdgeValidation(String),
    #[error("import error: {0}")]
    Import(String),
    #[error("cli error: {0}")]
    Cli(String),
    #[error("schema compatibility error: found {found}, supported {supported}")]
    SchemaCompatibility { found: i64, supported: i64 },
}
```

Label parsing warnings are not fatal errors. `parse_labels` returns `ParsedLabels { warnings: Vec<LabelParseWarning>, ... }` and only returns `Err` for malformed labels that make derived columns impossible to trust, such as an invalid `fz:` encoding.

### Observable Behaviors

- Given an empty directory, when `silmari_memory_rust init --db <path>` runs, then a native sqlite DB is created with card tables and schema version metadata.
- Given Silmari labels from existing Beads rows, when labels are parsed, then folgezettel addresses round-trip, card metadata is extracted, valid typed refs are preserved, and malformed refs are reported as nonfatal warnings.
- Given a Beads-shaped sqlite fixture, when the importer runs, then cards, labels, keyword entries, and typed edges are loaded into native tables without depending on Beads `LIKE` search semantics.
- Given a normalized keyword term, when recall runs, then exact `keyword_entries` hits drive retrieval and misses return the same null/empty shape as current `zk_recall`.
- Given a folgezettel address, when the Rust neighborhood builder runs, then it returns the addressed card, proper parents, same-depth siblings, and direct children while excluding register/index cards.
- Given typed edges and traversal options, when edge traversal runs, then it performs bounded breadth-first traversal with direction, edge-type filtering, and de-duplication.
- Given a seed card, when line-of-thought runs, then it returns parent, siblings, children, hubs, trunk seeds, a capped union, and `total_scope`.
- Given CLI commands, when they run, then they emit stable JSON for future MCP/viewer integration and typed nonzero errors for invalid inputs.

## What We're NOT Doing

| Out of scope | Reason |
|---|---|
| Replacing `apps/silmari-mcp` in this tranche | The first Rust slice proves the retrieval substrate and CLI/library contract. MCP integration can wrap it after parity is proven. |
| Rewriting the viewer UI | Viewer work is tracked separately by `silmari-agent-memory-xom`; this app supplies native graph/retrieval data. |
| Porting Beads issue tracker behavior | Beads remains a migration input. Native recall is keyword, folgezettel, and typed edge driven. |
| Adding LLM semantic proposal logic | The current target is deterministic retrieval substrate behavior. Semantic proposal can use this substrate later. |
| Inventing a canonical resource registry file | The repo lacks the registry. This plan records proposed aliases and contract anchors without fabricating source-of-truth files. |

## Testing Strategy

- **Framework**: Rust `cargo test`
- **Primary command**: `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml`
- **Focused commands**:
  - `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml schema_init`
  - `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml labels`
  - `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml import_beads`
  - `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml keyword_recall`
  - `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml neighborhood`
  - `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml edges`
  - `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml line_of_thought`
  - `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml cli_contract`
- **Recommended dev dependencies**: `tempfile`, `assert_cmd`, `predicates`
- **Recommended runtime dependencies**: `rusqlite` with bundled sqlite, `serde`, `serde_json`, `thiserror`, `clap`, `chrono`, `uuid`
- **Test types**:
  - Pure unit tests for label and folgezettel math
  - Store integration tests against temp sqlite files
  - Importer integration tests against Beads-shaped temp sqlite fixtures
  - CLI contract tests with `assert_cmd`
  - Parity fixture tests derived from existing Bun tests

## Behavior 1: Native Schema Initialization

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `rust.schema_init`
- `predicate_refs`: empty sqlite path, supported schema version, card-native table vocabulary
- `codepath_ref`: `apps/silmari_memory_rust/src/schema.rs::init_schema`
- `schema_contract_refs`: `N/A`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] rust.schema_init`

### Test Specification

**Given**: a path to a non-existent sqlite database  
**When**: `init_schema` runs  
**Then**: native card tables and `schema_versions` exist, issue-tracker tables do not exist, and running init again is idempotent

**Edge Cases**:

- parent directory exists but DB file does not
- DB already exists with schema version 1
- DB has a future schema version and init returns a typed compatibility error
- invalid `cards.kind`, `cards.box`, `cards.trunk`, `cards.content_hash`, and `card_edges.edge_type` values fail at the schema/store boundary
- `keyword_entries.entry_points` rejects invalid JSON

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/schema_init.rs`

```rust
use rusqlite::Connection;
use tempfile::tempdir;

#[test]
fn init_creates_card_native_schema_and_versions() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("silmari.db");

    silmari_memory_rust::schema::init_schema(&db_path).unwrap();

    let conn = Connection::open(&db_path).unwrap();
    let tables: Vec<String> = conn
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();

    assert!(tables.contains(&"cards".to_string()));
    assert!(tables.contains(&"card_labels".to_string()));
    assert!(tables.contains(&"card_edges".to_string()));
    assert!(tables.contains(&"keyword_entries".to_string()));
    assert!(tables.contains(&"schema_versions".to_string()));
    assert!(!tables.contains(&"issues".to_string()));
    assert!(!tables.contains(&"dependencies".to_string()));
}

#[test]
fn init_is_idempotent() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("silmari.db");

    silmari_memory_rust::schema::init_schema(&db_path).unwrap();
    silmari_memory_rust::schema::init_schema(&db_path).unwrap();

    let conn = Connection::open(&db_path).unwrap();
    let version: i64 = conn
        .query_row(
            "SELECT version FROM schema_versions WHERE table_name = 'cards'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(version, 1);
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/Cargo.toml`
- `apps/silmari_memory_rust/src/lib.rs`
- `apps/silmari_memory_rust/src/schema.rs`

```rust
use std::path::Path;

use rusqlite::Connection;

pub const SUPPORTED_SCHEMA_VERSION: i64 = 1;

/// Initialize the native Silmari memory sqlite schema.
///
/// @rr.id [PROPOSED]
/// @rr.alias rust.schema_init
/// @path.id init-native-schema
/// @gwt.given a writable sqlite path and no native Silmari schema
/// @gwt.when schema initialization runs
/// @gwt.then card-native tables and schema version rows exist idempotently
/// @reads [PROPOSED]
/// @writes [PROPOSED]
/// @raises [PROPOSED]:SchemaCompatibilityError
/// @schema.contract N/A
pub fn init_schema(path: &Path) -> Result<(), crate::Error> {
    let conn = Connection::open(path)?;
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS cards (
          id TEXT PRIMARY KEY NOT NULL,
          box TEXT NOT NULL CHECK(box IN ('biblio','idea')),
          kind TEXT NOT NULL CHECK(kind IN (
            'biblio','idea','hub','structure','register','fact',
            'signal','learning','preference','decision','stub'
          )),
          title TEXT NOT NULL,
          description TEXT NOT NULL DEFAULT '',
          body TEXT NOT NULL,
          fz_address TEXT,
          trunk TEXT CHECK(trunk IS NULL OR trunk IN ('1','2','3','4','5','root')),
          source TEXT,
          content_hash TEXT CHECK(
            content_hash IS NULL OR
            (length(content_hash) = 8 AND content_hash GLOB '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]')
          ),
          created_at TEXT,
          updated_at TEXT
        );
        CREATE TABLE IF NOT EXISTS card_labels (
          card_id TEXT NOT NULL,
          label TEXT NOT NULL,
          PRIMARY KEY(card_id, label),
          FOREIGN KEY(card_id) REFERENCES cards(id)
        );
        CREATE TABLE IF NOT EXISTS card_edges (
          source_id TEXT NOT NULL,
          target_id TEXT NOT NULL,
          edge_type TEXT NOT NULL CHECK(edge_type IN (
            'follows','continues','branches','derives-from','blocks','refers-to','annotates',
            'supports','contradicts','extends','reinforces','refines'
          )),
          PRIMARY KEY(source_id, target_id, edge_type)
        );
        CREATE TABLE IF NOT EXISTS keyword_entries (
          term TEXT PRIMARY KEY NOT NULL,
          entry_points TEXT NOT NULL CHECK(json_valid(entry_points)),
          curator TEXT NOT NULL CHECK(curator IN ('human','agent')),
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS schema_versions (
          table_name TEXT PRIMARY KEY NOT NULL,
          version INTEGER NOT NULL,
          applied_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_card_labels_label_card ON card_labels(label, card_id);
        CREATE INDEX IF NOT EXISTS idx_cards_fz_address ON cards(fz_address);
        CREATE INDEX IF NOT EXISTS idx_cards_trunk ON cards(trunk);
        CREATE INDEX IF NOT EXISTS idx_card_edges_target_type ON card_edges(target_id, edge_type);
        INSERT OR IGNORE INTO schema_versions(table_name, version, applied_at)
          VALUES
            ('cards', 1, datetime('now')),
            ('card_labels', 1, datetime('now')),
            ('card_edges', 1, datetime('now')),
            ('keyword_entries', 1, datetime('now'));
        ",
    )?;
    Ok(())
}
```

#### Refactor: Improve Code

**Files**:

- `apps/silmari_memory_rust/src/schema.rs`
- `apps/silmari_memory_rust/src/store.rs`
- `apps/silmari_memory_rust/src/error.rs`

Refactor goals:

- move table names into constants used by tests and implementation
- add future-version detection before applying migrations
- add indexes for `card_labels(label, card_id)`, `cards(fz_address)`, `cards(trunk)`, and `card_edges(target_id, edge_type)`
- add store-level validation that `cards.fz_address` and `cards.trunk` match the `fz:*` and `trunk:*` labels persisted for the card
- wrap sqlite errors in a domain `Error` enum

### Success Criteria

**Automated:**

- [x] Red: `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml schema_init`
- [x] Green: the same command passes
- [x] Refactor: `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml`

**Manual:**

- [x] Inspect `.schema` output and confirm native table vocabulary
- [x] Inspect `.schema` output and confirm enum/check constraints and retrieval indexes are present
- [x] Confirm no issue-tracker table names appear outside importer tests

---

## Behavior 2: Silmari Label Parsing Preserves Existing Semantics

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `rust.label_parser`
- `predicate_refs`: Silmari label namespace, edge vocabulary, folgezettel slash/underscore encoding
- `codepath_ref`: `apps/silmari_memory_rust/src/labels.rs::parse_labels`
- `schema_contract_refs`: `N/A`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] rust.label_parser`

### Edge Vocabulary Contract

Rust must preserve the exact current Silmari wire strings:

```rust
pub enum EdgeType {
    Follows,
    Continues,
    Branches,
    DerivesFrom,
    Blocks,
    RefersTo,
    Annotates,
    Supports,
    Contradicts,
    Extends,
    Reinforces,
    Refines,
}

pub enum EdgeTier {
    Auto,
    Reviewed,
}

pub enum EdgeValidationError {
    UnknownEdgeType(String),
    AttemptedReviewedAutoCreate { edge_type: EdgeType },
}
```

`Display` and `FromStr` round-trip to kebab-case wire strings: `DerivesFrom` <-> `derives-from`, `RefersTo` <-> `refers-to`, and so on. `EdgeType::tier()` returns `Auto` for `follows`, `continues`, `branches`, `derives-from`, `blocks`, `refers-to`, and `annotates`; it returns `Reviewed` for `supports`, `contradicts`, `extends`, `reinforces`, and `refines`. `EdgeType::requires_review()` is true only for reviewed edges. Store APIs that create edges directly must reject reviewed edges with `EdgeValidationError::AttemptedReviewedAutoCreate` before the CLI maps it to `Error::EdgeValidation`.

### Test Specification

**Given**: Beads/Silmari labels such as `fz:2_3a1`, `kind:idea`, `trunk:2`, and `ref:reinforces:zk-a`  
**When**: the Rust parser reads those labels  
**Then**: it returns a slash-form folgezettel address, typed card metadata, valid refs, and nonfatal warnings for malformed or unknown refs

**Edge Cases**:

- no `fz:` label
- deeply nested folgezettel sequence
- unknown edge type produces `LabelParseWarning::UnknownEdgeType`
- empty ref target
- non-ref namespaced labels
- duplicate labels
- all 12 valid edge types parse and serialize back to the same kebab-case string
- reviewed edge types preserve the human-review gate

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/labels.rs`

```rust
use silmari_memory_rust::labels::{parse_labels, EdgeType};

#[test]
fn parses_fz_label_round_trip() {
    let parsed = parse_labels(&["fz:2_3a1p".into(), "kind:idea".into()]).unwrap();
    assert_eq!(parsed.fz_address.as_deref(), Some("2/3a1p"));
    assert_eq!(parsed.kind.as_deref(), Some("idea"));
}

#[test]
fn parses_valid_refs_and_skips_unknown_edges() {
    let parsed = parse_labels(&[
        "ref:reinforces:zk-a".into(),
        "ref:notatype:zk-b".into(),
        "ref:extends:".into(),
    ])
    .unwrap();

    assert_eq!(parsed.refs.len(), 1);
    assert_eq!(parsed.refs[0].edge_type, EdgeType::Reinforces);
    assert_eq!(parsed.refs[0].target_id, "zk-a");
    assert_eq!(parsed.warnings.len(), 2);
}

#[test]
fn parses_all_twelve_edge_types_and_preserves_review_gate() {
    let cases = [
        ("follows", EdgeType::Follows, false),
        ("continues", EdgeType::Continues, false),
        ("branches", EdgeType::Branches, false),
        ("derives-from", EdgeType::DerivesFrom, false),
        ("blocks", EdgeType::Blocks, false),
        ("refers-to", EdgeType::RefersTo, false),
        ("annotates", EdgeType::Annotates, false),
        ("supports", EdgeType::Supports, true),
        ("contradicts", EdgeType::Contradicts, true),
        ("extends", EdgeType::Extends, true),
        ("reinforces", EdgeType::Reinforces, true),
        ("refines", EdgeType::Refines, true),
    ];

    for (wire, expected, requires_review) in cases {
        let parsed: EdgeType = wire.parse().unwrap();
        assert_eq!(parsed, expected);
        assert_eq!(parsed.to_string(), wire);
        assert_eq!(parsed.requires_review(), requires_review);
    }
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/labels.rs`
- `apps/silmari_memory_rust/src/model.rs`

```rust
/// Parse Silmari label metadata and typed refs.
///
/// @rr.id [PROPOSED]
/// @rr.alias rust.label_parser
/// @path.id parse-silmari-labels
/// @gwt.given labels encoded with fz, kind, box, trunk, source, content_hash, and ref prefixes
/// @gwt.when labels are parsed into native Rust structs
/// @gwt.then card metadata and valid typed refs are returned while malformed refs are reported as warnings
/// @reads [PROPOSED]
/// @writes [PROPOSED]
/// @raises [PROPOSED]:LabelParseError
/// @schema.contract N/A
pub fn parse_labels(labels: &[String]) -> Result<ParsedLabels, crate::Error> {
    let mut parsed = ParsedLabels::default();
    for label in labels {
        if let Some(rest) = label.strip_prefix("fz:") {
            let (trunk, sequence) = rest
                .split_once('_')
                .ok_or_else(|| crate::Error::invalid_label(label))?;
            parsed.fz_address = Some(format!("{trunk}/{sequence}"));
        }
        if let Some(rest) = label.strip_prefix("ref:") {
            match parse_ref(rest) {
                Ok(parsed_ref) => parsed.refs.push(parsed_ref),
                Err(warning) => parsed.warnings.push(warning),
            }
        }
    }
    Ok(parsed)
}
```

#### Refactor: Improve Code

**Files**:

- `apps/silmari_memory_rust/src/labels.rs`
- `apps/silmari_memory_rust/src/model.rs`

Refactor goals:

- represent edge types with the closed 12-variant enum matching `VALID_EDGE_TYPES`
- split edge tier behavior into `EdgeType::tier()` and `EdgeType::requires_review()`
- add `Display`/`FromStr` round-trip tests for all kebab-case wire values
- keep conversion helpers symmetrical: `fz_label_from_address` and `parse_fz_label`
- add deterministic ordering for returned refs
- add table-driven parity tests from `apps/silmari-memory-card-viewer/tests/server.test.ts`
- return `ParsedLabels.warnings` for unknown refs and empty targets instead of silently dropping parse problems

### Success Criteria

**Automated:**

- [x] Red: `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml labels`
- [x] Green: the same command passes
- [x] Refactor: all label parity fixtures pass

**Manual:**

- [x] Compare edge enum values against `apps/silmari-mcp/src/lib/labels.ts`
- [x] Confirm the AUTO/REVIEWED edge tier is preserved and reviewed edges cannot be auto-created by store APIs
- [x] Confirm no Beads dependency type enum is reused for Silmari semantic edges

---

## Behavior 3: Beads-Shaped Import Loads Native Cards And Edges

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `rust.beads_import`
- `predicate_refs`: Beads `issues`, `labels`, and `dependencies` source tables; Silmari label namespace
- `codepath_ref`: `apps/silmari_memory_rust/src/importer.rs::import_beads_box`
- `schema_contract_refs`: `N/A`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] rust.beads_import`

### Importer Source Contract

The v1 canonical importer source is raw `vendor/beads_rust` sqlite:

- Read `issues` rows directly from the Beads sqlite database.
- Read labels through `labels(issue_id, label)`, not through a denormalized `issues.labels` column.
- Read dependencies through `dependencies(issue_id, depends_on_id, type)`, but materialize only `type = 'blocks'` into native `card_edges`.
- Treat the viewer's denormalized `bv --export-pages` shape as a future adapter, not the v1 source of truth.
- Wrap one `import_beads_box` call in a single sqlite transaction against the target DB. A mid-import failure leaves the target DB unchanged.

### Beads Field Disposition

| Beads `issues` column | Disposition | Native handling |
|---|---|---|
| `id` | KEEP-AS-IS | `cards.id` |
| `content_hash` | TRANSFORM | `cards.content_hash` only if 8 lowercase hex chars; otherwise warning + null |
| `title` | KEEP-AS-IS | `cards.title` |
| `description` | KEEP-AS-IS | `cards.description` and first section of `cards.body` |
| `design` | TRANSFORM | Append non-empty value to `cards.body` under `Design` |
| `acceptance_criteria` | TRANSFORM | Append non-empty value to `cards.body` under `Acceptance Criteria` |
| `notes` | TRANSFORM | Append non-empty value to `cards.body` under `Notes` |
| `status` | TOMBSTONE-FILTER | Skip row when `status = 'tombstone'`; otherwise do not copy lifecycle state |
| `priority` | DROP | Must not influence native recall order |
| `issue_type` | DROP | Native kind comes from `kind:*` labels |
| `assignee` | DROP | Issue-management metadata |
| `owner` | DROP | Issue-management metadata |
| `estimated_minutes` | DROP | Issue-management metadata |
| `created_at` | KEEP-AS-IS | `cards.created_at` |
| `created_by` | DROP | Issue-management metadata |
| `updated_at` | KEEP-AS-IS | `cards.updated_at` |
| `closed_at` | DROP | Issue lifecycle metadata |
| `close_reason` | DROP | Issue lifecycle metadata |
| `closed_by_session` | DROP | Issue lifecycle metadata |
| `due_at` | DROP | Issue-management metadata |
| `defer_until` | DROP | Issue-management metadata |
| `external_ref` | DROP | Avoid importing Beads unique external refs into native memory identity |
| `source_system` | TRANSFORM | `cards.source` only when no `source:*` label exists |
| `source_repo` | DROP | Beads repo metadata |
| `deleted_at` | TOMBSTONE-FILTER | Skip row when non-null |
| `deleted_by` | DROP | Tombstone metadata |
| `delete_reason` | DROP | Tombstone metadata |
| `original_type` | DROP | Compaction/source metadata |
| `compaction_level` | DROP | Compaction metadata |
| `compacted_at` | DROP | Compaction metadata |
| `compacted_at_commit` | DROP | Compaction metadata |
| `original_size` | DROP | Compaction metadata |
| `sender` | DROP | Messaging metadata |
| `ephemeral` | TOMBSTONE-FILTER | Skip row when `1` |
| `pinned` | DROP | UI/task-list metadata |
| `is_template` | TOMBSTONE-FILTER | Skip row when `1` |

### Test Specification

**Given**: a Beads-shaped sqlite source DB with issue rows and Silmari labels  
**When**: `import_beads_box` imports it into the native DB  
**Then**: native `cards`, `card_labels`, and `card_edges` are populated, `ref:*` labels become typed edges, and issue-management fields do not leak into retrieval tables

**Edge Cases**:

- missing labels row
- malformed `ref:*` label
- `blocks` appears as both `ref:blocks:<target>` and Beads dependency
- Beads dependency has `type = 'parent-child'`, `conditional-blocks`, or `waits-for` and is not converted into a native edge
- `status = 'tombstone'`, `deleted_at IS NOT NULL`, `ephemeral = 1`, or `is_template = 1` row is skipped
- register cards are imported but marked as `kind = register`
- duplicate import is idempotent
- imported `fz_address` and `trunk` derived columns match `parse_labels(labels)`
- invalid source row midway through import rolls back the whole target transaction

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/import_beads.rs`

```rust
use rusqlite::Connection;
use tempfile::tempdir;

#[test]
fn imports_beads_rows_into_card_native_tables() {
    let dir = tempdir().unwrap();
    let source = dir.path().join("beads.db");
    let target = dir.path().join("silmari.db");
    create_beads_fixture(&source);

    silmari_memory_rust::schema::init_schema(&target).unwrap();
    silmari_memory_rust::importer::import_beads_box(&source, &target, "idea").unwrap();

    let conn = Connection::open(&target).unwrap();
    let card_count: i64 = conn.query_row("SELECT COUNT(*) FROM cards", [], |r| r.get(0)).unwrap();
    let edge_count: i64 = conn.query_row("SELECT COUNT(*) FROM card_edges", [], |r| r.get(0)).unwrap();
    assert_eq!(card_count, 2);
    assert_eq!(edge_count, 1);

    let fz: String = conn
        .query_row("SELECT fz_address FROM cards WHERE id = 'zk-a'", [], |r| r.get(0))
        .unwrap();
    assert_eq!(fz, "2/3a1");
}

#[test]
fn skips_tombstones_templates_ephemeral_and_non_blocks_dependencies() {
    let dir = tempdir().unwrap();
    let source = dir.path().join("beads.db");
    let target = dir.path().join("silmari.db");
    create_beads_fixture_with_filtered_rows_and_dependency_types(&source);

    silmari_memory_rust::schema::init_schema(&target).unwrap();
    let summary = silmari_memory_rust::importer::import_beads_box(&source, &target, "idea").unwrap();

    assert_eq!(summary.skipped_tombstones, 1);
    assert_eq!(summary.skipped_ephemeral, 1);
    assert_eq!(summary.skipped_templates, 1);

    let conn = Connection::open(&target).unwrap();
    let parent_child_edges: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM card_edges WHERE edge_type = 'parent-child'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(parent_child_edges, 0);
}

#[test]
fn import_rolls_back_target_transaction_on_mid_import_failure() {
    let dir = tempdir().unwrap();
    let source = dir.path().join("beads.db");
    let target = dir.path().join("silmari.db");
    create_beads_fixture_with_invalid_second_row(&source);

    silmari_memory_rust::schema::init_schema(&target).unwrap();
    let err = silmari_memory_rust::importer::import_beads_box(&source, &target, "idea").unwrap_err();
    assert!(err.to_string().contains("import"));

    let conn = Connection::open(&target).unwrap();
    let card_count: i64 = conn.query_row("SELECT COUNT(*) FROM cards", [], |r| r.get(0)).unwrap();
    assert_eq!(card_count, 0);
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/importer.rs`
- `apps/silmari_memory_rust/src/store.rs`

```rust
use std::path::Path;

/// Import one Beads box into native Silmari card tables.
///
/// @rr.id [PROPOSED]
/// @rr.alias rust.beads_import
/// @path.id import-beads-box
/// @gwt.given a Beads sqlite database containing issue rows and Silmari labels
/// @gwt.when the importer loads rows into the native Rust store
/// @gwt.then cards, labels, and typed edges are materialized without issue-search semantics
/// @reads [PROPOSED]
/// @writes [PROPOSED]
/// @raises [PROPOSED]:ImportError
/// @schema.contract N/A
pub fn import_beads_box(source_db: &Path, target_db: &Path, box_name: &str) -> Result<ImportSummary, crate::Error> {
    let _source = rusqlite::Connection::open(source_db)?;
    let mut target = rusqlite::Connection::open(target_db)?;
    let tx = target.transaction()?;
    let _ = box_name;
    // Minimal import: read issues, join labels by issue_id, parse labels, validate derived columns,
    // upsert cards, labels, keyword entries, and allowed typed edges. Commit only after all rows pass.
    tx.commit()?;
    Ok(ImportSummary::default())
}
```

#### Refactor: Improve Code

**Files**:

- `apps/silmari_memory_rust/src/importer.rs`
- `apps/silmari_memory_rust/src/store.rs`
- `apps/silmari_memory_rust/tests/fixtures.rs`

Refactor goals:

- isolate Beads source row structs from native card structs
- define an adapter trait boundary, but keep raw Beads sqlite relation-table labels as the only v1 implementation; viewer-export JSON label arrays remain documented future work
- report skipped malformed labels without failing the whole import
- dedupe `blocks` when both `ref:blocks:<target>` labels and Beads `dependencies.type = 'blocks'` rows exist
- reject non-`blocks` Beads dependency rows for native edge synthesis and count them in `ImportSummary.skipped_dependencies`
- validate derived `fz_address`/`trunk` columns against imported labels before committing
- add a fixture asserting `cards.body` is the deterministic concatenation of `description`, `design`, `acceptance_criteria`, and `notes`

### Success Criteria

**Automated:**

- [x] Red: `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml import_beads`
- [x] Green: import test passes with a temp sqlite fixture
- [x] Refactor: duplicate import keeps row counts stable

**Manual:**

- [x] Confirm importer is the only module that queries `issues` or `dependencies`
- [x] Confirm native retrieval never calls Beads `search_issues`
- [x] Confirm no issue-management fields in the disposition table are copied into native retrieval order, filters, or edge logic

---

## Behavior 4: Exact Keyword Register Lookup Drives Recall Entry Points

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `rust.keyword_register`
- `predicate_refs`: normalized keyword term, `keyword_entries.entry_points`, curator
- `codepath_ref`: `apps/silmari_memory_rust/src/keyword_index.rs::lookup_keyword`
- `schema_contract_refs`: `N/A`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] rust.keyword_register`

### Test Specification

**Given**: a native keyword index row created from ` Design Systems `
**When**: lookup runs for ` Design Systems `
**Then**: the normalized exact term `design_systems` matches and returns all entry points in stored order

**Given**: body text contains the query but no keyword row exists  
**When**: recall runs  
**Then**: it returns a keyword miss shape and does not fall back to full-text or Beads `LIKE` behavior

**Edge Cases**:

- duplicate entry point for a term
- term with punctuation and repeated whitespace
- many entry points are retained without FIFO cap
- empty or whitespace-only term returns typed validation error
- ASCII control characters (`< 32` or `127`) return typed validation errors
- `keyword:<normalized>` label constructor/parsing parity matches TypeScript `keywordLabel`
- entry points resolve as slash-form addresses or card ids through the typed `EntryPoint` enum

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/keyword_recall.rs`

```rust
use tempfile::tempdir;

#[test]
fn exact_normalized_keyword_lookup_returns_all_entry_points() {
    let harness = test_store();
    harness.add_keyword(" Design Systems ", vec!["2/1", "2/1a", "2/1b"]);

    let hit = silmari_memory_rust::keyword_index::lookup_keyword(harness.db(), " Design Systems ")
        .unwrap()
        .unwrap();

    assert_eq!(hit.term, "design_systems");
    assert_eq!(hit.entry_points, vec!["2/1", "2/1a", "2/1b"]);
}

#[test]
fn keyword_label_round_trips_through_typescript_normalization_shape() {
    let normalized = silmari_memory_rust::keyword_index::normalize_term(" Design   Systems ").unwrap();
    assert_eq!(normalized, "design_systems");
    assert_eq!(silmari_memory_rust::labels::keyword_label(&normalized), "keyword:design_systems");
}

#[test]
fn recall_does_not_fallback_to_body_text_search_on_keyword_miss() {
    let harness = test_store();
    harness.add_card("zk-a", "2/1", "This body mentions design systems");

    let session = silmari_memory_rust::retrieval::recall(harness.db(), "design systems", Default::default()).unwrap();

    assert!(session.entry_points.is_none());
    assert!(session.entry_cards.is_empty());
    assert!(session.neighborhoods.is_empty());
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/keyword_index.rs`
- `apps/silmari_memory_rust/src/retrieval.rs`

```rust
/// Look up an exact normalized keyword register entry.
///
/// @rr.id [PROPOSED]
/// @rr.alias rust.keyword_register
/// @path.id lookup-keyword-register
/// @gwt.given a user query and native keyword_entries rows
/// @gwt.when the query is normalized and looked up by exact term
/// @gwt.then matching entry points are returned or None is returned without text-search fallback
/// @reads [PROPOSED]
/// @writes [PROPOSED]
/// @raises [PROPOSED]:KeywordValidationError
/// @schema.contract N/A
pub fn lookup_keyword(conn: &rusqlite::Connection, term: &str) -> Result<Option<KeywordEntry>, crate::Error> {
    let normalized = normalize_term(term)?;
    // SELECT term, entry_points, curator, updated_at FROM keyword_entries WHERE term = ?
    Ok(None)
}
```

#### Refactor: Improve Code

**Files**:

- `apps/silmari_memory_rust/src/keyword_index.rs`
- `apps/silmari_memory_rust/tests/keyword_recall.rs`

Refactor goals:

- add one normalization implementation shared by `add_keyword_entry`, `lookup_keyword`, and `keyword_label`; it must lowercase, trim, replace one or more whitespace codepoints with `_`, reject empty output, and reject ASCII control chars (`< 32` or `127`)
- store `entry_points` as JSON for parity with current sqlite index and decode through `EntryPoint::{Address, CardId}`
- expose a typed `KeywordMiss` shape consumed by `retrieval::recall`
- port density invariant from `apps/silmari-mcp/tests/keyword-index-sqlite.test.ts`

### Success Criteria

**Automated:**

- [x] Red: `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml keyword_recall`
- [x] Green: exact lookup and miss-shape tests pass
- [x] Refactor: 10+ entry-point density test passes

**Manual:**

- [x] Confirm no `LIKE` query appears in `keyword_index.rs` or `retrieval.rs`
- [x] Confirm `design systems`, ` Design Systems `, and `Design   Systems` all round-trip to the same `design_systems` row
- [x] Confirm the only text-search behavior is explicitly out of the idea recall hot path

---

## Behavior 5: Folgezettel Neighborhood Retrieval Matches Current Semantics

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `rust.folgezettel_neighborhood`
- `predicate_refs`: slash-form folgezettel address, trunk scan, card kind filtering
- `codepath_ref`: `apps/silmari_memory_rust/src/folgezettel.rs::neighborhood`
- `schema_contract_refs`: `N/A`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] rust.folgezettel_neighborhood`

### Test Specification

**Given**: cards at `2/1`, `2/1a`, `2/1b`, `2/1a1`, and `2/1a2`  
**When**: neighborhood runs for `2/1a`  
**Then**: it returns `2/1` as parent, `2/1b` as sibling, and `2/1a1`, `2/1a2` as direct children

**Edge Cases**:

- root card has no parent
- register cards are excluded from sibling and child sets
- malformed addresses return typed validation errors
- multi-digit segments and width-expanded letter segments match existing tests
- missing queried address returns empty groups rather than panicking

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/neighborhood.rs`

```rust
#[test]
fn neighborhood_returns_parent_siblings_and_direct_children() {
    let harness = test_store();
    harness.add_card("zk-parent", "2/1", "parent");
    harness.add_card("zk-seed", "2/1a", "seed");
    harness.add_card("zk-sibling", "2/1b", "sibling");
    harness.add_card("zk-child-a", "2/1a1", "child a");
    harness.add_card("zk-child-b", "2/1a2", "child b");

    let result = silmari_memory_rust::folgezettel::neighborhood(harness.db(), "2/1a").unwrap();

    assert_eq!(ids(&result.parents), vec!["zk-parent"]);
    assert_eq!(ids(&result.siblings), vec!["zk-sibling"]);
    assert_eq!(ids(&result.children), vec!["zk-child-a", "zk-child-b"]);
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/folgezettel.rs`
- `apps/silmari_memory_rust/src/store.rs`

```rust
/// Build the structural neighborhood for a folgezettel address.
///
/// @rr.id [PROPOSED]
/// @rr.alias rust.folgezettel_neighborhood
/// @path.id build-folgezettel-neighborhood
/// @gwt.given a slash-form address and native cards with derived fz_address values validated against labels
/// @gwt.when the neighborhood builder scans the address trunk
/// @gwt.then it returns proper parents, same-depth siblings, and direct children
/// @reads [PROPOSED]
/// @writes [PROPOSED]
/// @raises [PROPOSED]:FolgezettelAddressError
/// @schema.contract N/A
pub fn neighborhood(conn: &rusqlite::Connection, address: &str) -> Result<Neighborhood, crate::Error> {
    // Parse trunk and sequence, load trunk cards, classify by segment math.
    Ok(Neighborhood::default())
}
```

#### Refactor: Improve Code

**Files**:

- `apps/silmari_memory_rust/src/folgezettel.rs`
- `apps/silmari_memory_rust/src/retrieval.rs`

Refactor goals:

- accept an optional `RecallContext`/`TrunkScanCache` so repeated neighborhood calls in one recall scan each trunk once
- port pure `parentSequences`, `siblingSequences`, and `isChildSequence` parity cases from `apps/silmari-mcp/tests/navigate.test.ts`
- keep register-card exclusion explicit and tested
- make ordering deterministic by folgezettel sequence

### Success Criteria

**Automated:**

- [x] Red: `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml neighborhood`
- [x] Green: core neighborhood test passes
- [x] Refactor: all pure folgezettel parity tests pass

**Manual:**

- [x] Compare address classification with current TypeScript fixtures
- [x] Confirm the implementation does not rely on Beads label prefix scans

---

## Behavior 6: Composed Recall Applies Limit, Sort, Truncation, And Neighborhoods

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `rust.recall_session`
- `predicate_refs`: keyword hit, entry points, sort mode, per-term limit, trunk neighborhood cache
- `codepath_ref`: `apps/silmari_memory_rust/src/retrieval.rs::recall`
- `schema_contract_refs`: `N/A`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] rust.recall_session`

### Recall API Contract

```rust
pub struct RecallContext {
    pub trunk_scan_cache: TrunkScanCache,
}

pub struct TrunkScanCache {
    // Keyed by trunk id (`1`..`5`, `root`) and reused across all entry points in one recall.
}

pub enum EntryPoint {
    Address(String),
    CardId(String),
}

pub struct RecallOptions {
    pub limit_per_term: usize,          // default 20
    pub sort_by: RecallSort,            // default reinforces_density
    pub edge_types: Option<Vec<EdgeType>>,
}
```

`recall` owns a fresh `RecallContext` by default and delegates to `recall_with_context` for tests and future MCP reuse. This preserves the TypeScript `TrunkScanCache` optimization from `navigate.ts` and avoids re-scanning a trunk for each entry point.

### Test Specification

**Given**: a keyword with more than 20 entry points  
**When**: recall runs with default options  
**Then**: it returns 20 surviving entry points, reports `total_matching`, marks `truncated = true`, and computes neighborhoods only for surviving entries

**Given**: inbound `reinforces` edges differ by entry card  
**When**: recall runs with default sorting  
**Then**: entry points are ordered by reinforces-density before neighborhoods are composed

**Edge Cases**:

- explicit `limit_per_term = 0`
- explicit `sort_by = recency`
- keyword miss preserves `entry_points = null`
- duplicate entry points collapse deterministically
- mixed keyword entry points containing card ids and slash-form addresses resolve through the same typed resolver
- one recall with many entry points in the same trunk scans that trunk once through `RecallContext`

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/keyword_recall.rs`

```rust
#[test]
fn recall_defaults_to_twenty_entries_and_reports_truncation() {
    let harness = test_store();
    for i in 1..=25 {
        let address = format!("2/{i}");
        harness.add_card(&format!("zk-{i}"), &address, "entry");
        harness.append_keyword("retrieval", &address);
    }

    let session = silmari_memory_rust::retrieval::recall(harness.db(), "retrieval", Default::default()).unwrap();

    let entry_points = session.entry_points.unwrap();
    assert_eq!(entry_points.addresses.len(), 20);
    assert_eq!(entry_points.total_matching, 25);
    assert!(entry_points.truncated);
    assert_eq!(session.neighborhoods.len(), 20);
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/retrieval.rs`
- `apps/silmari_memory_rust/src/keyword_index.rs`
- `apps/silmari_memory_rust/src/folgezettel.rs`

```rust
/// Compose a keyword-driven Zettelkasten recall session.
///
/// @rr.id [PROPOSED]
/// @rr.alias rust.recall_session
/// @path.id compose-recall-session
/// @gwt.given a normalized keyword, recall options, and native card/index rows
/// @gwt.when recall resolves entry points, applies limit/sort, and builds neighborhoods
/// @gwt.then the result preserves Silmari zk_recall shape including miss and truncation semantics
/// @reads [PROPOSED]
/// @writes [PROPOSED]
/// @raises [PROPOSED]:RecallError
/// @schema.contract N/A
pub fn recall(conn: &rusqlite::Connection, query: &str, opts: RecallOptions) -> Result<RecallSession, crate::Error> {
    let mut ctx = RecallContext::default();
    recall_with_context(conn, query, opts, &mut ctx)
}

pub fn recall_with_context(
    conn: &rusqlite::Connection,
    query: &str,
    opts: RecallOptions,
    ctx: &mut RecallContext,
) -> Result<RecallSession, crate::Error> {
    let hit = match crate::keyword_index::lookup_keyword(conn, query)? {
        Some(hit) => hit,
        None => return Ok(RecallSession::miss(query)),
    };
    // Resolve EntryPoint::Address or EntryPoint::CardId, apply sort, limit, truncation,
    // then build neighborhoods through ctx.trunk_scan_cache.
    Ok(RecallSession::from_hit(query, hit))
}
```

#### Refactor: Improve Code

**Files**:

- `apps/silmari_memory_rust/src/retrieval.rs`
- `apps/silmari_memory_rust/src/edges.rs`
- `apps/silmari_memory_rust/tests/keyword_recall.rs`

Refactor goals:

- share an in-memory trunk scan cache for all entry points in one call through `RecallContext`
- compute reinforces-density with a single grouped SQL query
- keep JSON serialization shape stable via snapshot-style tests
- port miss, truncation, limit zero, and recency fixtures from `zk-recall-limit.test.ts`
- add a test fixture with 20 entry points across 1-2 trunks proving each trunk is scanned once

### Success Criteria

**Automated:**

- [x] Red: `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml keyword_recall`
- [x] Green: default limit and miss-shape tests pass
- [x] Refactor: recency and reinforces-density tests pass

**Manual:**

- [x] Compare Rust JSON output to current `zk_recall` examples
- [x] Confirm no full-text fallback appears in the recall code path

---

## Behavior 7: Typed Edge Traversal Is Native And Bounded

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `rust.edge_traversal`
- `predicate_refs`: `card_edges`, valid edge vocabulary, direction, max depth
- `codepath_ref`: `apps/silmari_memory_rust/src/edges.rs::follow_edges`
- `schema_contract_refs`: `N/A`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] rust.edge_traversal`

### Edge Traversal Options Contract

```rust
pub enum Direction {
    Outbound,
    Inbound,
    Both,
}

pub struct EdgeTraversalOptions {
    pub direction: Direction,              // default Outbound
    pub edge_types: Option<Vec<EdgeType>>, // default None = all edge types
    pub max_depth: u32,                    // default 1; 0 returns seed-only context
    pub max_visited: u32,                  // default 10_000
}

pub enum EdgeTraversalError {
    VisitedSetExhausted { max_visited: u32 },
    InvalidDepth,
}
```

Traversal is breadth-first. It maintains a visited set keyed by card id, never revisits a card, and returns `VisitedSetExhausted` before unbounded memory growth.

### Test Specification

**Given**: cards connected by `ref:reinforces`, `ref:extends`, and `ref:blocks` edges  
**When**: edge traversal runs from a seed with `direction = outbound`, `edge_types = [reinforces]`, and `max_depth = 2`  
**Then**: only reachable `reinforces` targets within depth are returned once

**Edge Cases**:

- inbound traversal
- bidirectional traversal
- cycle does not loop forever
- max depth zero returns only root context
- unknown edge type is rejected by CLI/parser before traversal
- visited set exhaustion returns a typed error instead of continuing unbounded

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/edges.rs`

```rust
#[test]
fn follows_outbound_edges_with_type_filter_and_depth_limit() {
    let harness = test_store();
    harness.add_card("zk-a", "2/1", "a");
    harness.add_card("zk-b", "2/1a", "b");
    harness.add_card("zk-c", "2/1a1", "c");
    harness.add_card("zk-d", "2/1b", "d");
    harness.add_edge("zk-a", "zk-b", "reinforces");
    harness.add_edge("zk-b", "zk-c", "reinforces");
    harness.add_edge("zk-a", "zk-d", "extends");

    let result = silmari_memory_rust::edges::follow_edges(
        harness.db(),
        "zk-a",
        EdgeTraversalOptions {
            direction: Direction::Outbound,
            edge_types: Some(vec![EdgeType::Reinforces]),
            max_depth: 2,
            max_visited: 10_000,
        },
    )
    .unwrap();

    assert_eq!(ids(&result.cards), vec!["zk-b", "zk-c"]);
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/edges.rs`
- `apps/silmari_memory_rust/src/model.rs`

```rust
/// Traverse native typed card edges with direction, type, and depth bounds.
///
/// @rr.id [PROPOSED]
/// @rr.alias rust.edge_traversal
/// @path.id follow-typed-card-edges
/// @gwt.given a seed card, card_edges rows, traversal direction, edge filters, and max depth
/// @gwt.when bounded traversal runs
/// @gwt.then reachable cards are returned once with edge metadata and no dependency-table semantics
/// @reads [PROPOSED]
/// @writes [PROPOSED]
/// @raises [PROPOSED]:EdgeTraversalError
/// @schema.contract N/A
pub fn follow_edges(conn: &rusqlite::Connection, seed_id: &str, opts: EdgeTraversalOptions) -> Result<EdgeTraversal, crate::Error> {
    // Breadth-first traversal with visited set and SQL lookups by source or target.
    Ok(EdgeTraversal::default())
}
```

#### Refactor: Improve Code

**Files**:

- `apps/silmari_memory_rust/src/edges.rs`
- `apps/silmari_memory_rust/src/retrieval.rs`

Refactor goals:

- support outbound, inbound, and both directions through one query builder
- return edge path metadata for future viewer use
- add grouped inbound count helper for recall reinforces-density
- port valid/invalid edge-type fixtures from `server.test.ts`
- add a low `max_visited` cycle fixture that asserts `VisitedSetExhausted`

### Success Criteria

**Automated:**

- [x] Red: `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml edges`
- [x] Green: outbound depth and type filter test passes
- [x] Refactor: inbound, both-direction, and cycle tests pass

**Manual:**

- [x] Confirm `blocks` is just another Silmari edge in native `card_edges`
- [x] Confirm reviewed semantic edges still require the review gate for creation, even though traversal can read them
- [x] Confirm Beads dependency rows are not needed after import

---

## Behavior 8: Line Of Thought Composes A Bounded Structural Scope

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `rust.line_of_thought`
- `predicate_refs`: seed card, folgezettel neighborhood, hub cards, trunk seed cards, 150-card cap
- `codepath_ref`: `apps/silmari_memory_rust/src/retrieval.rs::line_of_thought`
- `schema_contract_refs`: `N/A`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] rust.line_of_thought`

### Line-Of-Thought API Contract

```rust
pub struct LineOfThought {
    pub queried: Option<Card>,
    pub parent: Option<Card>,
    pub siblings: Vec<Card>,
    pub children: Vec<Card>,
    pub hubs: Vec<Card>,
    pub trunk_seeds: Vec<Card>,
    pub all: Vec<Card>,
    pub total_scope: usize,
}

pub fn line_of_thought(conn: &rusqlite::Connection, seed_card_id: &str) -> Result<LineOfThought, crate::Error>;
pub fn line_of_thought_at_address(conn: &rusqlite::Connection, address: &str) -> Result<LineOfThought, crate::Error>;
```

`line_of_thought_at_address` mirrors the current TypeScript save-time path where an address exists before a seed card id is stable. The flat `all` union is deduped from `queried`, `parent`, `siblings`, `children`, `hubs`, and `trunk_seeds`, then capped at 150. When scope exceeds 150, truncation follows current TypeScript behavior: sort candidates by `created_at` newest-first, then tie-break by id for deterministic output.

### Test Specification

**Given**: a seed idea card with a parent, siblings, children, hub cards, and trunk roots
**When**: line-of-thought runs for the seed card id or folgezettel address
**Then**: it returns named groups including `trunk_seeds` plus a de-duplicated `all` union capped at 150 cards and a `total_scope`

**Edge Cases**:

- seed card id not found
- seed card lacks folgezettel address
- more than 150 cards in scope
- hubs overlap with siblings or children
- trunk seed already appears as parent
- root-level trunk seed scan includes numeric root sequences, excludes register `0`, and excludes deleted/filter-only rows
- address-only lookup returns the same groups as card-id lookup when the card exists

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/line_of_thought.rs`

```rust
#[test]
fn line_of_thought_returns_named_groups_and_capped_union() {
    let harness = test_store();
    harness.add_card("zk-parent", "2/1", "parent");
    harness.add_card("zk-seed", "2/1a", "seed");
    harness.add_card("zk-sibling", "2/1b", "sibling");
    harness.add_card("zk-child", "2/1a1", "child");
    harness.add_hub("zk-hub", "2/0a", "hub");
    harness.add_card("zk-trunk-seed", "2/2", "trunk seed");

    let lot = silmari_memory_rust::retrieval::line_of_thought(harness.db(), "zk-seed").unwrap();

    assert_eq!(lot.queried.as_ref().unwrap().id, "zk-seed");
    assert_eq!(lot.parent.as_ref().unwrap().id, "zk-parent");
    assert_eq!(ids(&lot.siblings), vec!["zk-sibling"]);
    assert_eq!(ids(&lot.children), vec!["zk-child"]);
    assert_eq!(ids(&lot.hubs), vec!["zk-hub"]);
    assert_eq!(ids(&lot.trunk_seeds), vec!["zk-parent", "zk-trunk-seed"]);
    assert!(lot.all.len() <= 150);
    assert_eq!(lot.total_scope, lot.all.len());
}

#[test]
fn line_of_thought_at_address_matches_card_id_variant_and_truncates_by_recency() {
    let harness = test_store_with_151_scope_cards();

    let by_id = silmari_memory_rust::retrieval::line_of_thought(harness.db(), "zk-seed").unwrap();
    let by_address = silmari_memory_rust::retrieval::line_of_thought_at_address(harness.db(), "2/1a").unwrap();

    assert_eq!(ids(&by_address.all), ids(&by_id.all));
    assert_eq!(by_id.all.len(), 150);
    assert!(is_newest_first_then_id(&by_id.all));
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/retrieval.rs`
- `apps/silmari_memory_rust/src/folgezettel.rs`
- `apps/silmari_memory_rust/src/store.rs`

```rust
/// Compose a bounded line-of-thought scope around a seed card.
///
/// @rr.id [PROPOSED]
/// @rr.alias rust.line_of_thought
/// @path.id compose-line-of-thought
/// @gwt.given a seed card id and native card graph state
/// @gwt.when line-of-thought retrieval gathers structural neighbors, hubs, and trunk seeds
/// @gwt.then named groups and a de-duplicated capped union are returned
/// @reads [PROPOSED]
/// @writes [PROPOSED]
/// @raises [PROPOSED]:LineOfThoughtError
/// @schema.contract N/A
pub fn line_of_thought(conn: &rusqlite::Connection, seed_card_id: &str) -> Result<LineOfThought, crate::Error> {
    // Resolve seed, derive neighborhood, query hubs and trunk seeds, de-dupe all, cap at 150.
    Ok(LineOfThought::default())
}

pub fn line_of_thought_at_address(conn: &rusqlite::Connection, address: &str) -> Result<LineOfThought, crate::Error> {
    // Resolve address directly, then compose the same groups and truncation as the card-id variant.
    Ok(LineOfThought::default())
}
```

#### Refactor: Improve Code

**Files**:

- `apps/silmari_memory_rust/src/retrieval.rs`
- `apps/silmari_memory_rust/src/store.rs`

Refactor goals:

- share neighborhood cache with composed recall
- make hub selection explicit through `kind = hub`
- sort named groups by folgezettel address for readability, but sort truncation candidates by `created_at` newest-first plus id tie-break to match TypeScript
- add cap tests with 151+ cards and explicit recency tie-break assertions
- add `find_trunk_seeds` parity tests: numeric root-level sequences only, register `0` excluded, live cards only

### Success Criteria

**Automated:**

- [x] Red: `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml line_of_thought`
- [x] Green: named-group test passes
- [x] Refactor: cap, overlap, missing seed, and missing fz tests pass

**Manual:**

- [x] Compare group names with current `zk_line_of_thought` result shape
- [x] Confirm JSON includes `trunkSeeds` and `totalScope` for TypeScript client compatibility
- [x] Confirm the 150-card cap is visible in serialized output

---

## Behavior 9: CLI Emits Stable JSON Contracts

### Resource Registry Binding

- `resource_id`: `[PROPOSED]`
- `address_alias`: `rust.cli_contract`
- `predicate_refs`: initialized native DB, command args, JSON output contract
- `codepath_ref`: `apps/silmari_memory_rust/src/cli.rs::run`
- `schema_contract_refs`: `N/A`

### Schema Interface Mapping

- `loop_mode`: `summary`
- `mapped_contracts`: `N/A`
- `registry_updates`: `[PROPOSED] rust.cli_contract`

### JSON Output Schema

Rust structs use snake_case internally. All CLI JSON uses `#[serde(rename_all = "camelCase")]` so existing TypeScript MCP/viewer clients see the current camelCase shape.

Successful commands emit the command payload directly:

```json
{
  "query": "retrieval",
  "entryPoints": {
    "term": "retrieval",
    "addresses": ["2/1"],
    "totalMatching": 1,
    "truncated": false
  },
  "entryCards": [],
  "neighborhoods": [],
  "crossRefs": []
}
```

Errors emitted with `--json` use a stable envelope on stdout, with diagnostics on stderr only when they are not part of the machine-readable payload:

```json
{
  "error": {
    "code": "unknown_edge_type",
    "message": "unknown edge type: relates-to",
    "details": {
      "value": "relates-to"
    }
  }
}
```

Recommended error codes are `schema_compatibility`, `label_parse`, `folgezettel_address`, `keyword_validation`, `edge_validation`, `edge_traversal`, `import`, `cli_parse`, and `sqlite`.

### Test Specification

**Given**: a native DB path and a recall query  
**When**: `silmari_memory_rust recall --db <path> --query retrieval --json` runs  
**Then**: stdout is valid JSON with `query`, `entryPoints`, `entryCards`, `neighborhoods`, and `crossRefs` keys

**Given**: invalid args or an unknown edge type  
**When**: CLI parsing runs  
**Then**: the process exits nonzero and emits a typed error object when `--json` is present

**Edge Cases**:

- `init --db` creates parent directories
- `import-beads --source --db --box idea` reports counts
- `neighborhood --address` validates slash-form addresses
- `line-of-thought --card-id` handles missing cards as typed error

### TDD Cycle

#### Red: Write Failing Test

**File**: `apps/silmari_memory_rust/tests/cli_contract.rs`

```rust
use assert_cmd::Command;
use predicates::prelude::*;
use tempfile::tempdir;

#[test]
fn recall_command_emits_stable_json_shape() {
    let dir = tempdir().unwrap();
    let db = seed_recall_fixture(dir.path());

    Command::cargo_bin("silmari_memory_rust")
        .unwrap()
        .args(["recall", "--db", db.to_str().unwrap(), "--query", "retrieval", "--json"])
        .assert()
        .success()
        .stdout(predicate::str::contains("\"query\""))
        .stdout(predicate::str::contains("\"entryPoints\""))
        .stdout(predicate::str::contains("\"neighborhoods\""));
}

#[test]
fn json_errors_use_stable_error_envelope() {
    Command::cargo_bin("silmari_memory_rust")
        .unwrap()
        .args(["edges", "--db", "/tmp/missing.db", "--seed", "zk-a", "--type", "relates-to", "--json"])
        .assert()
        .failure()
        .stdout(predicate::str::contains("\"error\""))
        .stdout(predicate::str::contains("\"code\""))
        .stdout(predicate::str::contains("\"unknown_edge_type\""));
}
```

#### Green: Minimal Implementation

**Files**:

- `apps/silmari_memory_rust/src/main.rs`
- `apps/silmari_memory_rust/src/cli.rs`

```rust
/// Run the silmari_memory_rust CLI command surface.
///
/// @rr.id [PROPOSED]
/// @rr.alias rust.cli_contract
/// @path.id run-rust-memory-cli
/// @gwt.given command line arguments and a native Silmari memory database
/// @gwt.when a user invokes init, import-beads, recall, neighborhood, edges, or line-of-thought
/// @gwt.then stable JSON success or typed JSON errors are emitted for downstream clients
/// @reads [PROPOSED]
/// @writes [PROPOSED]
/// @raises [PROPOSED]:CliError
/// @schema.contract N/A
pub fn run(args: impl IntoIterator<Item = String>) -> Result<i32, crate::Error> {
    // Parse clap args and call library functions.
    Ok(0)
}
```

#### Refactor: Improve Code

**Files**:

- `apps/silmari_memory_rust/src/cli.rs`
- `apps/silmari_memory_rust/tests/cli_contract.rs`

Refactor goals:

- centralize JSON serialization for success and error envelopes
- apply `#[serde(rename_all = "camelCase")]` to public JSON DTOs
- add `--format json` alias if future shell UX wants more formats
- keep stdout pure JSON and diagnostics on stderr
- add command-specific snapshot fixtures once output shapes settle
- add a recall snapshot fixture that matches the TypeScript `zk_recall` casing contract

### Success Criteria

**Automated:**

- [x] Red: `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml cli_contract`
- [x] Green: `init` and `recall` CLI tests pass
- [x] Refactor: all CLI subcommand contract tests pass

**Manual:**

- [x] Run `apps/silmari_memory_rust/target/debug/silmari_memory_rust --help`
- [x] Run a seeded `recall --json` and inspect output for MCP/viewer readiness
- [x] Confirm invalid CLI input with `--json` emits `{ "error": { "code", "message", "details" } }`

---

## Integration And Parity Testing

### Rust-Only Integration

- Create a temp native DB.
- Initialize schema.
- Insert cards, labels, edges, and keywords through public Rust APIs.
- Assert recall, neighborhood, edge traversal, and line-of-thought agree on the same data.

Command:

```bash
cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml integration_retrieval
```

### Migration Parity

- Create a temp Beads-shaped sqlite DB using fixture helpers.
- Import it into native DB.
- Assert native retrieval returns the same semantic groups expected from current TypeScript tests.

Command:

```bash
cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml import_beads
```

### Existing TypeScript Guardrails

The Rust app does not replace TypeScript tests in this phase, but these tests remain the behavior source for parity:

```bash
cd apps/silmari-mcp && bun test tests/navigate.test.ts
cd apps/silmari-mcp && bun test tests/keyword-index-sqlite.test.ts
cd apps/silmari-mcp && bun test tests/zk-recall-limit.test.ts
cd apps/silmari-memory-card-viewer && bun test tests/server.test.ts
```

## Proposed Implementation Order

1. `schema_init`: create the crate and native DB schema.
2. `labels`: port label namespace and edge vocabulary.
3. `import_beads`: make existing data loadable into native tables.
4. `keyword_recall`: implement exact keyword lookup and miss shape.
5. `neighborhood`: implement folgezettel math and structural neighborhood.
6. `recall_session`: compose keyword, sort, limit, truncation, and neighborhoods.
7. `edge_traversal`: add bounded typed-edge traversal.
8. `line_of_thought`: compose bounded structural scope.
9. `cli_contract`: expose stable JSON commands.

This order keeps the first tests small and prevents the CLI from being designed before the storage and retrieval behavior is proven.

## Acceptance Criteria

**Automated Verification:**

- [x] `cargo test --manifest-path apps/silmari_memory_rust/Cargo.toml` passes.
- [x] `cargo fmt --manifest-path apps/silmari_memory_rust/Cargo.toml -- --check` passes.
- [x] `cargo clippy --manifest-path apps/silmari_memory_rust/Cargo.toml --all-targets -- -D warnings` passes.
- [x] `! rg --files-with-matches '\bsearch_issues\b|\bpriority\b' apps/silmari_memory_rust/src --glob '!importer.rs'` passes. `importer.rs` may mention `priority` only to read and drop it per the field disposition table.
- [x] `cd apps/silmari-mcp && bun test tests/navigate.test.ts tests/keyword-index-sqlite.test.ts tests/zk-recall-limit.test.ts` still passes.
- [x] `cd apps/silmari-memory-card-viewer && bun test tests/server.test.ts` still passes.

**Manual Verification:**

- [x] A small Beads-shaped fixture imports into a native card schema.
- [x] `silmari_memory_rust recall --json` produces a keyword-driven session without body-text fallback.
- [x] `silmari_memory_rust line-of-thought --json` returns named groups, `trunkSeeds`, and cap metadata.
- [x] Native DB inspection shows card-native table names and typed `card_edges`.
- [x] Native `EdgeType` exposes all 12 Silmari edge variants, preserves AUTO/REVIEWED tier behavior, and round-trips kebab-case wire strings.
- [x] There is no native dependency on Beads issue-search sorting or priority fields.
- [x] `cards.fz_address` and `cards.trunk` are verified as derived values from preserved labels during import/write paths.

## References

- Research: `thoughts/searchable/shared/research/2026-04-27-zettelkasten-rust-retrieval-substrate.md`
- Beads search path: `vendor/beads_rust/src/cli/commands/search.rs`
- Beads sqlite storage: `vendor/beads_rust/src/storage/sqlite.rs`
- Beads schema: `vendor/beads_rust/src/storage/schema.rs`
- Current label namespace: `apps/silmari-mcp/src/lib/labels.ts`
- Current keyword index: `apps/silmari-mcp/src/lib/keyword-index.ts`
- Current navigation and recall: `apps/silmari-mcp/src/lib/navigate.ts`
- Current line of thought: `apps/silmari-mcp/src/lib/line-of-thought.ts`
- Viewer edge synthesis: `apps/silmari-memory-card-viewer/server.ts`
- Folgezettel tests: `apps/silmari-mcp/tests/navigate.test.ts`
- Keyword sqlite tests: `apps/silmari-mcp/tests/keyword-index-sqlite.test.ts`
- Recall limit tests: `apps/silmari-mcp/tests/zk-recall-limit.test.ts`
- Viewer edge tests: `apps/silmari-memory-card-viewer/tests/server.test.ts`
