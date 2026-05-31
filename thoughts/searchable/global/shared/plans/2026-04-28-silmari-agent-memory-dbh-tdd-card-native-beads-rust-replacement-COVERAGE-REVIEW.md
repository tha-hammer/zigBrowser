---
date: 2026-04-28T17:24:36-04:00
reviewer: Codex
topic: "Card-Native beads_rust Replacement TDD Implementation Plan - Coverage Review"
tags: [review, cw9, coverage, external]
status: complete
reviewed_plan: thoughts/searchable/shared/plans/2026-04-28-silmari-agent-memory-dbh-tdd-card-native-beads-rust-replacement.md
review_type: coverage
---

# Coverage Review: Card-Native beads_rust Replacement TDD Implementation Plan

## Summary

| Check | Status | Gaps |
|-------|--------|------|
| Formal proof source consistency | fail | Bridge-only verifiers are not classified; `gwt-0004` model/test artifacts use stale error-code/envelope contracts versus the plan |
| Bridge verifier coverage | fail | Model-checked verifier gaps in `gwt-0001`, `gwt-0004`, and `gwt-0006`; bridge-only `ValidErrorCodes` is unclassified |
| Bridge operation coverage | fail | `gwt-0001`, `gwt-0004`, and `gwt-0006` generated tests do not replay the model operation traces |
| Simulation trace coverage | fail | No generated trace replay coverage for `gwt-0001`, `gwt-0004`, or `gwt-0006` |
| TLA+ invariant coverage | fail | Multiple standalone `.cfg` invariants lack direct generated assertions |
| Artifact count consistency | fail | Artifact files exist, but `gwt-0004` and `gwt-0006` generated tests do not match the actual proof surface; `gwt-0004` is stale against the plan |

## Proof Surface Classification

The `.cfg` files are the source of truth for TLC-checked proof targets. Bridge artifacts add generated verifier metadata, but several bridge verifiers are helper/composite entries and are not TLC-checked.

### gwt-0001: schema_v2_migration_gate

| Verifier / Property | Source | Model-Checked? | Plan Labels Correctly? |
|---------------------|--------|----------------|------------------------|
| FutureVersionNeverMutated | `.cfg` invariant | YES | YES |
| NoPartialMigration | `.cfg` invariant | YES | YES |
| V1FullyUpgraded | `.cfg` invariant | YES | YES |
| SecondOpenIdempotent | `.cfg` invariant | YES | YES |
| FutureVersionRejectedCorrectly | `.cfg` invariant | YES | YES |
| V2OpenRemainsStable | `.cfg` invariant | YES | YES |
| AllInvariants | `.cfg` invariant, composite | YES | YES |

### gwt-0002: edge_authority_gate

| Verifier / Property | Source | Model-Checked? | Plan Labels Correctly? |
|---------------------|--------|----------------|------------------------|
| AutoEdgeBecomesLive | `.cfg` invariant | YES | YES |
| ReviewedAgentEdgeQueued | `.cfg` invariant | YES | YES |
| ImportedReviewedEdgePending | `.cfg` invariant | YES | YES |
| CompatFacadeIsolated | `.cfg` invariant | YES | YES |
| ReviewedLiveRequiresAuthority | `.cfg` invariant | YES | YES |
| AllInvariants | bridge artifact only, composite helper | NO | WARNING: not classified |

### gwt-0003: native_create_postsave_gate

| Verifier / Property | Source | Model-Checked? | Plan Labels Correctly? |
|---------------------|--------|----------------|------------------------|
| ValidPhase, NoPartialCommit, FromAddressValidationPrecedesDedupe, NoPostSaveWithoutCreate, PostSaveRunsAfterCreate, NoPostSaveOnCreateFailure, AtomicEventedDurableOnSuccess, BrCompatIdOrNull, BrCompatMatchesCreate, TypedErrorMapsToNullResult, SaveCardShapeStable, SaveCardFieldTypes, RecurrenceStillCreatesDurableCard, GivenWhenThenGuarantees | `.cfg` invariants | YES | YES |

### gwt-0004: cli_envelope_open_policy_gate

| Verifier / Property | Source | Model-Checked? | Plan Labels Correctly? |
|---------------------|--------|----------------|------------------------|
| SuccessEnvelopeHasResult | `.cfg` invariant | YES | YES |
| ErrorEnvelopeHasCode | `.cfg` invariant | YES | YES |
| ReadMissingDBNoCreate | `.cfg` invariant | YES | YES |
| WriteRequiresWritePolicy | `.cfg` invariant | YES | YES |
| ErrorCodesAreStable | `.cfg` invariant | YES | NO: model uses stale code set |
| FacadeCanClassify | `.cfg` invariant | YES | NO: generated test does not assert plan code set |
| EmptyResultDistinguishable | `.cfg` invariant | YES | YES |
| ValidErrorCodes | bridge artifact helper | NO | WARNING: not classified; also stale against plan |
| AllInvariants | bridge artifact only, composite helper | NO | WARNING: not classified |

`gwt-0004.tla` defines `ValidErrorCodes` as `DB_MISSING`, `DB_MALFORMED`, `DB_LOCKED`, `PARSE_ERROR`, `POLICY_VIOLATION`, `INPUT_ERROR`, `TIMEOUT`, and `NONE`. The plan now requires `CARD_NOT_FOUND`, `QUERY_TIMEOUT`, `VALIDATION_ERROR`, `SCHEMA_INCOMPATIBLE`, `DB_NOT_FOUND`, and `CLI_PARSE`. The generated test file uses still another set (`sqlite`, `unknown_edge_type`, `cli_parse`). This is a stale artifact mismatch, not just a coverage omission.

### gwt-0005: migration_snapshot_staging_gate

| Verifier / Property | Source | Model-Checked? | Plan Labels Correctly? |
|---------------------|--------|----------------|------------------------|
| SourceReadonlyAfterSnapshot, NoTargetMutationBeforePromote, FailedValidationNoPromote, NoReplaceModePreventsPromote, DryRunModePreventsPromote, ReportExistsAtTerminal, MalformedKeywordsReported, BlocksDirectionPreserved, StagingBeforePromote, SnapshotBeforeStaging, SnapshotBeforeValidation | `.cfg` invariants | YES | YES |
| AllInvariants | bridge artifact only, composite helper | NO | WARNING: not classified |

### gwt-0006: ts_facade_observability_gate

| Verifier / Property | Source | Model-Checked? | Plan Labels Correctly? |
|---------------------|--------|----------------|------------------------|
| BrCreateReturnsStringOrNull | `.cfg` invariant | YES | YES |
| BrListTimeoutDistinct | `.cfg` invariant | YES | YES |
| BrListNonTimeoutReturnsRows | `.cfg` invariant | YES | YES |
| BrShowNoFuzzyMatch | `.cfg` invariant | YES | YES |
| BrShowExactOrNull | `.cfg` invariant | YES | YES |
| BrSearchBiblioOriented | `.cfg` invariant | YES | YES |
| BrSearchNotIdeaRecall | `.cfg` invariant | YES | YES |
| LabelLookupNativeNoLegacyDb | `.cfg` invariant | YES | YES |
| NoNativeInternalImport | `.cfg` invariant | YES | YES |
| NoBrSqliteDirectImport | `.cfg` invariant | YES | YES |
| ModePreservesSignature | `.cfg` invariant | YES | YES |
| AllInvariants | bridge artifact only, composite helper | NO | WARNING: not classified |

### gwt-0007: viewer_export_contract_gate

| Verifier / Property | Source | Model-Checked? | Plan Labels Correctly? |
|---------------------|--------|----------------|------------------------|
| AllRequiredTablesPresent, SemanticEdgesInCardEdgesOnly, BlocksEdgesInDependencies, BlocksDirectionPreserved, CardEdgesColumnsCorrect, LabelSynthesisIdempotentFallback, BuildLinksDirectionConsistent, IssueOverviewMvPresent, ExportMetaPresent, BoundedExecution | `.cfg` invariants | YES | YES |
| AllInvariants | bridge artifact only, composite helper | NO | WARNING: not classified |

### gwt-0008: sai_recall_shim_gate

| Verifier / Property | Source | Model-Checked? | Plan Labels Correctly? |
|---------------------|--------|----------------|------------------------|
| ShimOutputNoEntryCards, ShimOutputNoLifecycleFields, KeywordEntriesKeyStable, FolgezettelNeighborsKeyStable, CrossRefsKeyStable, SaiReceivesNormalizedShape, EmptyDataDegradesPredictably, NativeRustDoesNotLeakStorageFields, BothSourcesConvergeOnRecallSummaryShape, BoundedExecution | `.cfg` invariants | YES | YES |
| AllInvariants | bridge artifact only, composite helper | NO | WARNING: not classified |

## Verifier Coverage

### gwt-0001: schema_v2_migration_gate

| Verifier | Test Assertion | Covered? |
|----------|---------------|----------|
| FutureVersionNeverMutated | `test_future_schema_version_is_rejected_without_mutation` snapshots before/after future-version rejection | YES |
| NoPartialMigration | No generated test seeds partial migration or failed transactional migration state | NO |
| V1FullyUpgraded | Plan red test mentions real v1 migration, but `tests/generated/test_gwt_0001.py` only initializes a new DB and checks supported version | NO |
| SecondOpenIdempotent | `test_open_or_migrate_is_idempotent` compares schema identity after repeated opens | YES |
| FutureVersionRejectedCorrectly | `test_future_schema_version_is_rejected_without_mutation` expects schema incompatibility | YES |
| V2OpenRemainsStable | `test_open_or_migrate_is_idempotent` plus status-column check cover stable v2 reopen | PARTIAL |
| AllInvariants | Composite depends on uncovered `NoPartialMigration` and `V1FullyUpgraded` | NO |

### gwt-0002: edge_authority_gate

| Verifier | Test Assertion | Covered? |
|----------|---------------|----------|
| AutoEdgeBecomesLive | `test_auto_edge_becomes_live_invariant` and trace replay assert live edge counts | YES |
| ReviewedAgentEdgeQueued | `test_reviewed_agent_edge_queued_invariant` asserts proposals and no live edge | YES |
| ImportedReviewedEdgePending | `test_imported_reviewed_edge_pending_invariant` asserts imported reviewed proposals | YES |
| CompatFacadeIsolated | `test_compat_facade_isolated_invariant` asserts facade writes stay isolated | YES |
| ReviewedLiveRequiresAuthority | `test_reviewed_live_requires_authority_invariant` asserts live edges require auto or human authority | YES |
| AllInvariants | Bridge-only composite helper | SKIP |

### gwt-0003: native_create_postsave_gate

All 14 `.cfg` invariants have generated direct tests named after the invariant and a trace-derived final-state test. Covered.

### gwt-0004: cli_envelope_open_policy_gate

| Verifier | Test Assertion | Covered? |
|----------|---------------|----------|
| SuccessEnvelopeHasResult | `test_init_creates_parent_directories_and_returns_ok_true` asserts `ok`, but not `result`; `test_recall_success_emits_stable_json_shape` asserts raw recall JSON instead of `NativeEnvelope` | NO |
| ErrorEnvelopeHasCode | `_assert_json_error` asserts an `error.code`, but does not assert `ok:false` and uses stale code names | PARTIAL |
| ReadMissingDBNoCreate | `test_read_missing_db_returns_error_without_creating_file` asserts no DB file creation | YES, but stale code expectation |
| WriteRequiresWritePolicy | No generated write or migration policy assertion | NO |
| ErrorCodesAreStable | Generated tests expect `sqlite`, `unknown_edge_type`, and `cli_parse`, while plan requires uppercase stable codes and TLA uses another stale set | NO |
| FacadeCanClassify | No generated test proves facade classification without string matching raw stderr | NO |
| EmptyResultDistinguishable | No generated success-empty result envelope test | NO |
| ValidErrorCodes | Bridge-only helper; stale code set versus plan | WARNING |
| AllInvariants | Bridge-only composite helper | SKIP |

### gwt-0005: migration_snapshot_staging_gate

All 11 `.cfg` invariants have generated trace-derived invariant tests and edge-case tests. Covered.

### gwt-0006: ts_facade_observability_gate

| Verifier | Test Assertion | Covered? |
|----------|---------------|----------|
| BrCreateReturnsStringOrNull | No generated `brCreate` assertion | NO |
| BrListTimeoutDistinct | `test_native_mode_preserves_brlist_timeout_distinction` asserts `BrListTimeoutError` | YES |
| BrListNonTimeoutReturnsRows | No generated non-timeout rows/empty-rows assertion | NO |
| BrShowNoFuzzyMatch | `test_native_mode_brshow_rejects_ambiguous_prefixes` asserts prefix returns null | YES |
| BrShowExactOrNull | No generated exact-row or not-found branch assertion | NO |
| BrSearchBiblioOriented | No generated `brSearch` assertion | NO |
| BrSearchNotIdeaRecall | No generated proof that `brSearch` does not become idea recall | NO |
| LabelLookupNativeNoLegacyDb | `test_native_mode_label_lookup_compat_without_legacy_db` calls `brList` with a label, but does not call/seed `findCardsByLabelCompat` against a missing legacy DB | PARTIAL |
| NoNativeInternalImport | No generated source scan for direct native internal imports | NO |
| NoBrSqliteDirectImport | Generated test scans only `br-adapter.ts`; plan requires production imports outside the legacy adapter to be blocked, including `card-ops.ts` | PARTIAL |
| ModePreservesSignature | No generated signature or multi-mode routing assertion | NO |
| AllInvariants | Bridge-only composite helper | SKIP |

### gwt-0007: viewer_export_contract_gate

All 10 `.cfg` invariants have generated trace-derived invariant tests and edge-case tests. Covered.

### gwt-0008: sai_recall_shim_gate

The generated test does not create one test per invariant, but `test_trace_derived_sai_recall_shim_case` decodes trace states and `_assert_all_invariants` asserts every `.cfg` invariant over the trace-derived runtime result. Covered.

## Operation Coverage

| GWT | Bridge operations | Covered? | Notes |
|-----|-------------------|----------|-------|
| `gwt-0001` | 11 operations: `FirstOpen`, `CheckVersion`, `AfterVersionCheck`, `StartMigration`, `ApplyV2DDL`, `CommitMigration`, `MaybeRetry`, `SecondOpenCheck`, `SecondOpenCurrent`, `SetTerminated`, `Terminate` | NO | Generated tests do not load traces or assert operation sequence |
| `gwt-0002` | 3 operations | YES | Trace replay validates `Init`, `Classify`, `Route`, `Finish` shape |
| `gwt-0003` | 13 operations | YES | Trace-derived test asserts full expected program-counter sequence |
| `gwt-0004` | 7 operations | NO | Generated tests are hand-written CLI probes and do not replay `SelectPolicy`, `CheckInput`, `OpenDatabase`, `CheckWritePolicy`, `CheckTimeout`, `ExecuteCommand`, `Terminate` |
| `gwt-0005` | 13 operations | YES | Trace-derived tests exercise the model sequence and operation outcomes |
| `gwt-0006` | 14 operations | NO | Generated tests execute four adapter probes and do not replay `Dispatch`, compute branches, or label legacy/native transitions |
| `gwt-0007` | 12 operations | YES | Trace replay covers export, routing, synthesis, viewer read, and link build |
| `gwt-0008` | 7 operations | YES | Trace replay covers receive, normalize, strip, hydrate, build, terminate |

## Trace Coverage

| GWT | Trace Pattern | Category | Test? | Notes |
|---|---|---|---|---|
| `gwt-0001` | Native v1 upgrade to v2; existing v2 reopen; future version rejection | happy/error/idempotence | PARTIAL | Generated tests cover future rejection and repeated open, but do not load the 160 trace artifacts or seed a real v1 migration path |
| `gwt-0002` | Auto edge, reviewed agent edge, imported reviewed edge, compatibility facade edge, empty/single/diamond cases | happy/error/edge | YES | Trace corpus count and representative traces are tested |
| `gwt-0003` | Valid create, invalid fromAddress, recurrence, post-save, native/compat modes | happy/error/edge | YES | Trace stream and final-state obligations are tested |
| `gwt-0004` | Init/read/write/migration classes; missing/existing/malformed/locked DBs; timeout; empty results; invalid input | happy/error/edge | NO | Generated tests cover a few CLI probes but do not draw values from the 160 traces |
| `gwt-0005` | Snapshot, validation, dry-run/no-replace/refused promote, reports, malformed keywords, blocks direction | happy/error/edge | YES | Trace replay and edge-case tests present |
| `gwt-0006` | Legacy/shadow/native-primary; `brCreate`, `brList`, `brShow`, `brSearch`, label lookup; timeout/malformed/missing/not found/success | happy/error/edge | NO | Generated tests cover only timeout, prefix show, weak label list, and one source scan |
| `gwt-0007` | Export with/without typed edges and blocks, synthesis fallback, empty/single/diamond graph | happy/edge | YES | First ten trace-derived cases plus edge cases are tested |
| `gwt-0008` | Legacy/native recall payloads, lifecycle stripping, entryCards normalization, empty/missing/diamond cases | happy/edge | YES | Trace-derived shim cases and edge cases are tested |

## Invariant Coverage

| GWT | Invariant | Type | Test Assertion | Covered? |
|-----|-----------|------|---------------|----------|
| `gwt-0001` | NoPartialMigration | standalone `.cfg` invariant | None for partial or failed migration atomicity | NO |
| `gwt-0001` | V1FullyUpgraded | standalone `.cfg` invariant | Plan red test exists, generated test missing real v1 seed/migration assertion | NO |
| `gwt-0001` | AllInvariants | composite `.cfg` invariant | Depends on uncovered invariants | NO |
| `gwt-0004` | SuccessEnvelopeHasResult | standalone `.cfg` invariant | No generated assertion for `{ok:true,result}` on success | NO |
| `gwt-0004` | WriteRequiresWritePolicy | standalone `.cfg` invariant | No generated write/migration open-policy assertion | NO |
| `gwt-0004` | ErrorCodesAreStable | standalone `.cfg` invariant | Generated test code uses stale/non-plan error codes | NO |
| `gwt-0004` | FacadeCanClassify | standalone `.cfg` invariant | No generated facade classification assertion | NO |
| `gwt-0004` | EmptyResultDistinguishable | standalone `.cfg` invariant | No generated empty success result assertion | NO |
| `gwt-0006` | BrCreateReturnsStringOrNull | standalone `.cfg` invariant | None | NO |
| `gwt-0006` | BrListNonTimeoutReturnsRows | standalone `.cfg` invariant | None | NO |
| `gwt-0006` | BrShowExactOrNull | standalone `.cfg` invariant | No exact row/not-found branch | NO |
| `gwt-0006` | BrSearchBiblioOriented | standalone `.cfg` invariant | None | NO |
| `gwt-0006` | BrSearchNotIdeaRecall | standalone `.cfg` invariant | None | NO |
| `gwt-0006` | NoNativeInternalImport | standalone `.cfg` invariant | None | NO |
| `gwt-0006` | ModePreservesSignature | standalone `.cfg` invariant | None | NO |

All other standalone `.cfg` invariants are covered directly or by trace-derived all-invariant assertions.

## Issues

### Critical

1. `gwt-0004` must be regenerated or amended before implementation. The plan's Behavior 11 requires uppercase adapter codes and `NativeEnvelope<T>` with `result`, but `.cw9/specs/gwt-0004.tla` uses `DB_MISSING`/`PARSE_ERROR` style codes and `tests/generated/test_gwt_0004.py` expects `sqlite`, `unknown_edge_type`, lowercase `cli_parse`, and raw recall JSON.
2. `gwt-0006` generated tests do not cover most model-checked facade invariants: `BrCreateReturnsStringOrNull`, `BrListNonTimeoutReturnsRows`, `BrShowExactOrNull`, `BrSearchBiblioOriented`, `BrSearchNotIdeaRecall`, `NoNativeInternalImport`, and `ModePreservesSignature`.
3. `gwt-0001` generated tests do not cover the model-checked v1 migration and no-partial-migration properties. The plan's red test includes a real v1 migration scenario, but the generated test file does not.

### Warnings

1. The plan reports artifact completion but does not classify bridge-only verifiers. Bridge-only helpers are `AllInvariants` for `gwt-0002`, `gwt-0004`, `gwt-0005`, `gwt-0006`, `gwt-0007`, `gwt-0008`, and `ValidErrorCodes` for `gwt-0004`.
2. `gwt-0001`, `gwt-0004`, and `gwt-0006` generated tests do not use their simulation trace files. That leaves operation sequencing and trace-category coverage implicit.
3. `gwt-0006` `NoBrSqliteDirectImport` coverage is too narrow: it scans only `br-adapter.ts`, while the plan requires a production import gate outside the legacy adapter implementation.

## Verdict

- [ ] Full coverage - proceed to `/cw9_review_abstraction_gap`
- [x] Gaps found - add missing test assertions before implementation
- [x] Formal proof mismatch - fix the plan/artifact language before continuing
- [x] Artifact mismatch - re-run bridge/gen-tests before continuing
