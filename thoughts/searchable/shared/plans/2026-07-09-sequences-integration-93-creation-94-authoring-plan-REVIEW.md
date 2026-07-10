# Plan Review Report: Sequences Integration 9.3/9.4 — Creation + Step Authoring

**Plan reviewed:** `thoughts/searchable/shared/plans/2026-07-09-sequences-integration-93-creation-94-authoring-plan.md`
**Reviewed by:** SAI automated review (v2 — incorporates deep codebase research)
**Date:** 2026-07-09
**Research basis:** 5 parallel codebase analysis agents with verified line-number evidence across zigBrowser (`/home/maceo/ntm_Dev/zigBrowser`) and sequences (`/home/maceo/ntm_Dev/sequences`) repos

---

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | ❌ | 7 critical, 2 warnings |
| Interfaces | ⚠️ | 3 warnings |
| Promises | ⚠️ | 2 warnings |
| Data Models | ❌ | 3 critical, 1 warning |
| APIs | ❌ | 2 critical (endpoint mismatch + payload schema conflict) |
| Workflow Closure | ❌ | 2 critical, 2 warnings |

**Verdict: Needs Major Revision** — 14 critical issues must be resolved before implementation.

---

## Contract Review

### Well-Defined:
- ✅ `toCommandSequence(allocator, step, candidate) -> []AutomationCommand` — clear Zig contract for step→command conversion
- ✅ `buildAutomationPlan(steps, config) -> { version, automation_steps, approved_at }` — JS plan builder contract
- ✅ `validateStep(step, capabilities, {commands}) -> { valid, errors, warnings }` — validation contract with specific error codes
- ✅ `resolveTokens(text, candidate, {mode}) -> { text, unresolved }` — token resolution contract with preview/resolve modes
- ✅ `AutomationPlan.from_dict(data) -> AutomationPlan` — Python deserialization contract
- ✅ Error enumerations: `UnresolvedTokens`, `GroundingReviewRequired`, `empty_subject`, `empty_body`, `forbidden_verb`, `partial_grounding` — explicit codes
- ✅ Grounding-status gating matches PRD 9.4's `DRAFT_GROUNDING_VIOLATION`/review-queue semantics
- ✅ Token resolution preview vs approval-mode distinction matches PRD 9.4

### Missing or Unclear:

- ❌ **C-1: Fundamental execution model conflict between plan and Phase 0 (CRITICAL).** The plan assumes zigBrowser executes sequences by replaying low-level browser commands: `approved_plan.automation_steps[i].command_sequence` contains `{method: "page.navigate", params: {url: "..."}}`, `{method: "dom.fill", params: {selector: "#subject", value: "..."}}` etc. — raw JSON-RPC calls dispatched to `AutomationRouter.dispatch()`.

  Phase 0's actual `execution-plan` endpoint (Phase 0 plan lines 483-543) returns a **completely different** high-level contract:
  ```
  action: "send_email"
  renderedMessage: { subject, body, renderedHash }
  candidate/mailbox refs
  ```
  There is **no `command_sequence`/method-call array** in Phase 0's execution plan payload. Phase 0 treats the execution plan as "what to send" (high-level intent), not "how to drive the browser" (low-level commands).

  Furthermore, the **existing send pipeline** (`sequenceExecutionService.sendDueStep()` at `sequences/backend/services/sequences/sequenceExecutionService.js:175`) already sends emails via `MailboxGatewayV1.sendSequenceMessage()` — a direct API/SMTP gateway call, NOT browser automation. The plan proposes an entirely different execution model (browser automation) without addressing how it coexists with or replaces the existing gateway-based pipeline.

  **Impact:** The plan's core abstraction — that `approved_plan` contains browser-level command sequences — is incompatible with Phase 0's actual API contract AND the existing send pipeline. Nothing in Behaviors 1-6 can be implemented against the Phase 0 API as it actually exists.

  **Recommendation:** Resolve the fundamental question: Is zigBrowser automation a **replacement** for the gateway-based send pipeline, or a **supplement** for social/browser-only actions? Then either:
  1. Align the plan's `command_sequence` model with Phase 0's high-level `action` model, or
  2. Align Phase 0's API with the plan's low-level command model, or
  3. Define a two-tier model: gateway for email sends, browser automation for social/LinkedIn actions only

- ❌ **C-2: Plan scope mismatch with PRD titles (CRITICAL).** The plan is titled "PRD 9.3 (New Sequence Creation) + PRD 9.4 (Sequence Step Authoring)" but its "What We're NOT Doing" section (plan line 118) explicitly excludes ALL UI work that the PRDs define:
  - "The sequences dashboard UI or wizard shell implementation"
  - "The UI components (React) for step authoring"

  PRD 9.3 defines 6 surfaces (S1-S6): dashboard entry, wizard shell, mailbox settings pane, template chooser, AI-config pane, generation orchestration. PRD 9.4 defines 3 surfaces: step list/editor, generate-step-with-AI modal, preview/personalization panel. **None of these are built by this plan.**

  The plan actually implements a downstream **automation execution bridge** — step→command-verb mapping, automation plan construction, token resolution, Python SDK plan reader — that assumes the wizard and authoring UI already exist and have produced valid steps.

  **Impact:** The plan title implies PRD 9.3/9.4 implementation, but a reader expecting wizard/authoring work will find none. Downstream planning that depends on "9.3/9.4 are done" will be wrong.

  **Recommendation:** Rename the plan to accurately reflect its scope: "Sequences Automation Execution Bridge — Step→Command Mapping and Plan Construction" (or similar). Add an explicit "Prerequisites" section listing the actual 9.3/9.4 UI implementation as a dependency.

- ❌ **C-3: Token resolution architecture conflict (CRITICAL).** The plan has token resolution in two languages with no clear ownership boundary:
  - Behavior 1 (Zig `toCommandSequence`): takes `CandidateContext`, resolves tokens at execution time per-candidate
  - Behavior 5 (JS `resolveTokens`): resolves tokens at authoring preview and approval time
  - Behavior 2 (JS `buildAutomationPlan`): produces `command_sequence` entries — but are these templates or resolved values?

  The `approved_plan` is written once at approval and is per-sequence, not per-enrollment. Each enrollment has a different candidate, so the approved plan CANNOT contain resolved parameter values (e.g., `"Hello Alice"`) — it must contain templates (e.g., `"Hello {{First Name}}"`) with token placeholders.

  The JS plan builder test (plan line 384) checks command count and method names but is ambiguous on whether params contain templates or resolved values. The Zig test (plan line 217) passes a `CandidateContext` and expects resolved commands. If Zig does execution-time resolution, the `command_sequence.params` in the approved plan must contain templates, not final values — but this is never stated.

  **Impact:** Without this contract clarified, implementers will make incompatible assumptions.

  **Recommendation:** Add explicit contract: "approved_plan contains TEMPLATE commands. JS `resolveTokens` is for authoring preview ONLY. Zig `toCommandSequence` does execution-time resolution per enrollment."

- ❌ **C-4: linkedin_action step type contract violation vs PRD 9.4 (CRITICAL).** PRD 9.4 defines `linkedin_action` as a first-class `SequenceAuthoringStep.type` value with sub-fields `linkedinAction: 'view_profile' | 'connect' | 'message'` and `linkedinMessage`. The plan (Behavior 2, line 464) treats LinkedIn only as a boolean config toggle (`includeLinkedInStep`) appended at plan-build time.

  This means LinkedIn steps can't be authored inline between email steps, can't be positioned at arbitrary points, and have no candidate context.

  **Impact:** Recruiters author LinkedIn steps per the PRD; the plan builder ignores their position and configuration.

  **Recommendation:** Add `linkedin_action` to step type handling. Remove `includeLinkedInStep` boolean in favor of inline step handling.

- ❌ **C-5: HTML body vs dom.fill plaintext mismatch (CRITICAL).** PRD 9.4 specifies email body is HTML (rich text editor). The plan uses `dom.fill` (Behavior 1, plan line 224-225) to set the body field. `dom.fill` sets `.value` on `<input>`/`<textarea>` — it doesn't work with `contenteditable` divs (what every real email compose UI uses). The plan also explicitly blocks `page.evaluate` as a security constraint (Behavior 3, plan lines 568-578), so there's no alternative path.

  **Impact:** Email body composition will fail at runtime on every real email platform.

  **Recommendation:** Add a `dom.setContent` verb for contenteditable elements, or use platform-specific compound commands that encapsulate the interaction.

- ❌ **C-6: Existing send pipeline conflict (CRITICAL).** The existing execution path `sendDueStep()` (`sequences/backend/services/sequences/sequenceExecutionService.js:175`) sends emails via `MailboxGatewayV1.sendSequenceMessage({provider, accessToken, from, to, subject, renderedBody, threadId, ...})` — a direct API/SMTP call. It uses `claimForSend()` (row-level `FOR UPDATE` locking), `evaluateSendability()` (preflight checks), `buildSentMessage()` (canonical sent-row builder), and `persistSentMessage()` (DB write + enrollment advancement).

  The plan proposes browser automation as the execution model — navigate to compose UI, fill fields, click send. But:
  - The plan says (line 118) "NOT modifying the existing send-pipeline execution"
  - If browser automation is a separate path, how does it coordinate with the existing gateway path?
  - Who picks which path runs for which step?
  - Do both paths write to `sequence_messages` and `sequence_events` the same way?
  - Does the existing `claimForSend`/`persistSentMessage` flow apply to browser-automated sends?

  **Impact:** Two incompatible send paths with no routing logic between them. Risk of double-sends or orphaned state.

  **Recommendation:** Explicitly define the relationship: "Browser automation replaces gateway for [X scenarios]" or "Browser automation is for social/LinkedIn only; email continues through gateway." Add routing logic to the plan.

- ❌ **C-7: Missing error contract for execution-time failures (CRITICAL).** The plan defines step execution failure (Behavior 6, plan lines 876-881) with `element_not_found` as an example. But the error contract between zigBrowser and the sequences backend is incomplete. The existing error codes (`-32001 ELEMENT_NOT_FOUND`, `-32002 TIMEOUT`, `-32003 NAVIGATION_FAILED` from `sdk/python/src/zigbrowser/errors.py`) need to map to enrollment state transitions (`pause`, `retry`, `skip`), but that mapping is unstated.

  Also: the actual `AutomationError` dataclass the plan proposes for `types.py` conflicts with reality — `types.py` is EMPTY (0 lines). Error types live in `errors.py` (`AutomationError`, `ProtocolError`, `ZigBrowserError`).

  **Recommendation:** Define error classification table. Put new dataclasses in the correct file (`errors.py` or `sequences.py`, not `types.py`).

- ⚠️ **C-8: Social verbs exist in Python SDK but not in Zig router.** The Python SDK (`client.py`) already has `linkedin`/`instagram`/`social`/`cookies` namespaces that call methods like `"linkedin.connect"`, `"social.rate_status"`. But `router.zig:6-20` has only 13 `dom.*`/`page.*` verbs — NO social verb entries. These Python namespaces are speculative/unbacked. The plan's tests (Behavior 2, plan line 403-407) assume social verbs work end-to-end, which they don't.

  **Recommendation:** Document Phase 5 social verbs as a blocking dependency. Mark LinkedIn tests as pending until Phase 5 lands.

- ⚠️ **C-9: Two incompatible wire protocols.** Python SDK (`client.py`) uses 4-byte big-endian length-prefixed framing over UDS. Zig RPC layer (`automation_rpc.zig`) uses line-based JSON-RPC 2.0 framing (newline-delimited). These are different wire protocols that cannot interoperate directly. The plan doesn't acknowledge this difference.

  **Recommendation:** Clarify which framing protocol the Python SDK's `StepExecutor` uses to communicate with zigBrowser. The existing client already handles this correctly, but the plan should reference the existing framing rather than assuming JSON-RPC line-based.

---

## Interface Review

### Well-Defined:
- ✅ `AutomationCommand { method: []const u8, params_json: []const u8 }` — matches existing `router.zig` dispatch signature (`dispatch(self, method: []const u8, params_json: ?[]const u8) ![]const u8`)
- ✅ `validateStep` / `validateStepsForApproval` — clear two-tier validation (single step vs approval gate)
- ✅ `resolveTokens` with mode parameter — clean interface for preview vs resolve
- ✅ Token map design — centralized `TOKEN_MAP` as single source of truth

### Missing or Unclear:

- ⚠️ **I-1: `StepExecutor` interface incomplete.** Behavior 6 shows `StepExecutor(mock_zigbrowser)` and `executor.execute_step(step)` but doesn't define return type, API client for result reporting, per-enrollment candidate context handling, or scheduling directive behavior.

  **Recommendation:** Define a `StepExecutionResult` dataclass and specify StepExecutor's full constructor signature.

- ⚠️ **I-2: `build.zig` changes needed but unspecified.** The new `step_mapping.zig` needs to be registered in `build.zig` for the test import to work.

  **Recommendation:** Add a "Build System Changes" section.

- ⚠️ **I-3: SequenceAuthoringStep type omits PRD fields.** The plan's Zig/JS step structures omit `senderMailboxId`, `signatureId`, and `status` from the PRD 9.4 `SequenceAuthoringStep` type (PRD lines 143-167). They also flatten `waitBefore` (a field ON email steps in the PRD) into a separate `wait` step type.

  **Recommendation:** Document which PRD fields are intentionally omitted and why. If `senderMailboxId` is needed for command construction (to determine which mailbox compose UI to navigate to), its omission may be blocking.

---

## Promise Review

### Well-Defined:
- ✅ Idempotency: approval is a one-shot DB write, no async edges. The existing `appendSequenceEvent` uses `dedup_key` with `UNIQUE(org_id, dedup_key) WHERE dedup_key IS NOT NULL` for idempotency.
- ✅ Grounding review gate: steps with `grounding_status: 'review'` block plan construction
- ✅ Validation-before-execution: `validateStepsForApproval` runs before `buildAutomationPlan`
- ✅ Wait steps as scheduling directives: explicitly stated as "not automation commands"

### Missing or Unclear:

- ⚠️ **P-1: Execution ordering guarantee unstated.** The plan says commands dispatch "in order" but doesn't specify serial vs parallel execution, timeout behavior, or partial completion semantics. The test (plan line 929) checks `call_count == 4` but doesn't assert ordering.

  **Recommendation:** Add serial execution guarantee with fail-fast behavior.

- ⚠️ **P-2: Concurrent enrollment execution not addressed.** The existing scheduler (`sequenceScheduler.js` exports `runSequenceTick`/`startSequenceScheduler`/`stopSequenceScheduler`) and `sendStore.listDueEnrollments()` handle multi-enrollment scheduling for the gateway path. If browser automation is a separate path, it needs its own scheduling or integration with the existing scheduler. Neither is specified.

  **Recommendation:** State explicitly whether enrollment scheduling is in or out of scope.

---

## Data Model Review

### Well-Defined:
- ✅ `SequenceStep` Zig struct — typed fields, enums for step_type/reply_mode/grounding_status
- ✅ `AutomationCommand` Zig struct — method + params_json
- ✅ TOKEN_MAP dictionary — explicit token name → candidate field mapping
- ✅ `SchedulingDirective` Python dataclass — `wait_before: Optional[dict]`

### Missing or Unclear:

- ❌ **D-1: `approved_plan` JSONB schema ambiguity (CRITICAL).** Current `approved_plan` (from `sequenceExecutionService.js:82`) is:
  ```json
  { "steps": [{ "index": 0 }], "approved_at": "...", "version": 1 }
  ```
  This is a **hardcoded single-step placeholder** — NOT a multi-step plan. The migration 100 comment describes it as a "Frozen plan snapshot (steps + resolved window/cap/sender, captured at approval so later template edits never change what an approved enrollment sends)" but the code doesn't match the comment.

  The plan proposes extending this with `automation_steps` containing full command sequences. But:
  1. Nothing else in the 37-file services directory reads or writes `approved_plan` (verified by codebase search)
  2. The plan says "NOT modifying the existing send-pipeline execution" (line 118) but extending `approved_plan` IS modifying the send pipeline's data contract
  3. No v1→v2 migration or backward compatibility strategy

  **Impact:** Existing approved sequences have v1 shape. New sequences get v2 shape. Any code reading `approved_plan` must handle both.

  **Recommendation:** Define exact v2 schema. State additive vs breaking. Add version discriminator.

- ❌ **D-2: CandidateContext struct fields don't match candidate data model (CRITICAL).** Candidate data comes from `sequence_enrollments` which has only references (`candidate_source`, `candidate_id`, `workspace_candidate_id`) — not inline fields. Actual candidate details (first_name, company, etc.) are resolved through the contact subsystem (`contact/contactReadinessResolver.js`, `contact/persistContactPointsFromEnrichment.js`) and stored in `contact_status` JSONB on the enrollment row.

  The plan references `GET /api/v1/automation/enrollments/:id/context` for candidate data, but this endpoint doesn't exist in Phase 0. The candidate field set is not enumerated — what fields does `contact_status` JSONB guarantee?

  **Recommendation:** Define `CandidateContext` schema with required vs optional fields. Align with actual `contact_status` JSONB shape from the contact subsystem.

- ❌ **D-3: File paths reference wrong repository (CRITICAL).** The plan specifies:
  - `sequences/backend/services/sequences/automationPlanBuilder.js`
  - `sequences/backend/services/sequences/stepValidator.js`
  - `sequences/backend/services/sequences/tokenResolver.js`
  - `sequences/backend/services/sequences/__tests__/*.test.js`

  These paths are relative to zigBrowser. But the sequences backend lives in a **separate repository** at `/home/maceo/ntm_Dev/sequences`. There is no `sequences/` directory inside zigBrowser. The plan's JS behaviors (2-5) must be implemented in the sequences repo, not zigBrowser.

  **Impact:** An implementer following the plan's file paths will create files in the wrong repository.

  **Recommendation:** Clarify all file paths with explicit repo prefixes. The Zig files (Behavior 1) are in zigBrowser; the JS files (Behaviors 2-5) are in the sequences repo; the Python files (Behavior 6) are in zigBrowser.

- ⚠️ **D-4: Step reordering impact on automation_steps.** PRD 9.4 supports drag-and-drop step reordering. When steps are reordered, wait-step folding (`scheduling.wait_before` on the next email step) must be recomputed. The plan doesn't address this but it may be implicitly handled if `buildAutomationPlan` runs at approval time (after all reordering is final).

  **Recommendation:** State explicitly that plan construction happens after all editing is complete.

---

## API Review

### Well-Defined:
- ✅ Phase 0 defines 14 endpoints under `/api/v1/automation` with HMAC-SHA256 auth
- ✅ Error envelope: `{error: {code, message, retryable, requestId, traceId, commandId, details}}`
- ✅ Idempotency via `Idempotency-Key` header + per-endpoint dedup keys
- ✅ New migration `13X_sequence_automation_integration.sql` adds execution tracking tables

### Missing or Unclear:

- ❌ **A-1: Extensive endpoint mismatch between plan and Phase 0 (CRITICAL).** The 9.3/9.4 plan invented its own endpoint names that diverge from Phase 0's actual contract:

  | 9.3/9.4 plan expects | Phase 0 actually defines | Status |
  |---|---|---|
  | `GET /sequences/:id/plan` | `GET /sequences/:sequenceId/execution-plan` | **Wrong path** — different name, likely same intent |
  | `GET /sequences/:id/steps` | `GET /sequences/:sequenceId/steps` (via `sequences.saveSteps` PUT + `sequences.previewStep` POST) | **Partial match** — read exists but shape may differ |
  | `POST /sequences/:id/steps/:stepIndex/result` | `POST /executions/:executionId/steps/:stepExecutionId/result` | **Wrong shape** — Phase 0 keys by execution ID, not sequence+stepIndex |
  | `POST /sequences/:id/events` | `POST /events` (not scoped under sequence) | **Wrong shape** — Phase 0 events aren't sequence-scoped |
  | `PATCH /enrollments/:id` | **Not defined** | **Gap** |
  | `GET /enrollments/:id/context` | **Not defined** | **Gap** |
  | `GET /capabilities` | **Not defined** | **Gap** |
  | `GET /health` | **Not defined** | **Gap** |

  **Impact:** 4 endpoints don't exist. 4 endpoints have wrong paths or shapes. The plan cannot be implemented against Phase 0's actual API.

  **Recommendation:** Reconcile all endpoint references with Phase 0's actual contract. For missing endpoints (`/enrollments/:id/context`, `PATCH /enrollments/:id`, `/capabilities`, `/health`), either add them to Phase 0 or remove them from 9.3/9.4's requirements with an alternative data flow.

- ❌ **A-2: Auth model mismatch (CRITICAL).** The plan states auth is "API key in `X-Automation-Key` header" (plan line 220). Phase 0 actually uses HMAC-SHA256 request signing with `X-ZB-Client-Id`, `X-ZB-Timestamp`, `X-ZB-Nonce`, `X-ZB-Signature` headers. These are completely different auth models. The plan's Python SDK `StepExecutor` would need to implement HMAC signing, not simple API key passthrough.

  **Recommendation:** Align auth model with Phase 0's HMAC-SHA256 spec. Update Behavior 6's Python SDK to use the correct signing headers.

---

## Workflow Closure Review

### Well-Defined:
- ✅ Closure Test 1 (approval writes plan): Well-structured with SOURCE, TRIGGER, OBSERVE, FORBIDDEN SPAN, RED-AT-SEAM proof, DRIVABILITY, EXECUTION sections. Correctly classified as BLOCKING.
- ✅ Production operation chain clearly mapped: wizard → POST → messages → approval → plan → read → dispatch → result → advance → events
- ✅ Closure Test 1 trigger at `approveSequence()` is the correct production entrypoint for plan construction
- ✅ Closure test framework EXISTS at `~/.claude/commands/references/closure-test-framework.md` and the plan's closure test structure follows the §6 spec template

### Missing or Unclear:

- ❌ **W-1: Test infrastructure exists but plan misreferences it (CRITICAL).** The plan says "Requires PostgreSQL test instance (existing test infra)" — this infra DOES exist but in the **sequences repo** (`/home/maceo/ntm_Dev/sequences`), not in zigBrowser:
  - Test runner: Vitest (not Jest), configured at `sequences/vitest.config.js`
  - DB setup: `tests/integration/global-setup.js` provisions test DB, runs migrations, seeds org, creates RLS-honest app role
  - Cleanup: `truncateAll()` helper with children-first FK ordering
  - Integration pattern: real `pg.Pool` against `DATABASE_URL_TEST`, per-run tag-based isolation

  However, the **sequences repo uses `describe.skipIf(!databaseUrl)` in integration tests** — this is exactly the anti-pattern the closure-test-framework §4 rule 6 flags as UNVERIFIED. A skipped BLOCKING closure test is equivalent to a missing one.

  The plan's lifecycle test (Behavior 4) calls `createDraftSequence()` and `createDraftWithSteps()` helper functions that don't exist — they need to be written as test fixtures.

  **Impact:** Tests can potentially run using the sequences repo's existing Vitest + PostgreSQL infra, but:
  1. File paths in the plan point to zigBrowser, not the sequences repo
  2. Test helpers need to be written
  3. The `describe.skipIf` pattern must NOT be used for closure tests (must fail-closed per §4 rule 6)

  **Recommendation:** Fix file paths. Write test helpers. For closure tests: use `describe` (not `describe.skipIf`) and let the test fail when the DB is absent, per the framework's fail-closed requirement.

- ❌ **W-2: Execution trigger chain has no closure test (CRITICAL).** The plan has a closure test for "approval writes plan" but NOT for the full execution chain:
  ```
  [zigBrowser reads plan via API] → [resolves tokens per candidate] → [dispatches commands]
      → [POST step result] → [enrollment advances] → [event written]
  ```
  Closure Test 2 (plan line 1027-1036) tests `StepExecutor.execute_step()` with a mock UDS server. This is a unit test of command dispatch, NOT a closure test — the TRIGGER (`StepExecutor.execute_step()`) is below the production trigger (the scheduler that initiates execution), violating the no-shortcut rule. It doesn't test API reads, token resolution with real candidates, result reporting, enrollment advancement, or event recording.

  **Impact:** The most critical workflow (execute a step against a real candidate) has no source-to-sink proof.

  **Recommendation:** Add a Closure Test 3:
  ```
  SOURCE: sequences table (approved, with plan), sequence_enrollments (active, with candidate)
  TRIGGER: execution scheduler tick or API call initiating execution
  OBSERVE: sequence_events has StepCompleted; enrollment.current_step_index advanced
  ```
  Requires Phase 0 API reconciliation (A-1) first.

- ⚠️ **W-3: No production caller for Zig `toCommandSequence`.** The function is never called by production code. The Python `StepExecutor` dispatches pre-built commands from the plan — it doesn't call back into Zig for token resolution. If `toCommandSequence` is for execution-time resolution (per C-3), it needs a production caller.

  **Recommendation:** Clarify production caller or remove from plan if unused.

- ⚠️ **W-4: Behavior classifications incomplete.** The plan has 2 closure tests (both labeled BLOCKING) but 6 behaviors. Behaviors 1, 3, 4, 5 are unclassified. Per the closure-test-framework, unclassified defaults to BLOCKING, which means 4 behaviors lack their required closure tests.

  **Recommendation:** Classify each behavior as BLOCKING or LEAF with rationale:
  - Behavior 1 (Zig step mapping): LEAF — same module, no async edge, unit test suffices
  - Behavior 3 (Step validation): LEAF — pure function, unit test suffices
  - Behavior 4 (Lifecycle): BLOCKING — crosses DB boundary
  - Behavior 5 (Token resolution): LEAF — pure function, unit test suffices

---

## Critical Issues (Must Address Before Implementation)

| # | Category | Issue | Impact |
|---|----------|-------|--------|
| 1 | Contract | **Execution model conflict** — plan assumes low-level command sequences; Phase 0 returns high-level actions; existing pipeline uses email gateway, not browser automation | Core abstraction is incompatible with both Phase 0 API and existing send pipeline |
| 2 | Contract | **Plan scope mismatch** — titled "PRD 9.3 + 9.4" but implements none of the wizard/authoring UI these PRDs define | Misleading title; downstream planning will assume 9.3/9.4 is done |
| 3 | Contract | **Token resolution architecture conflict** — Zig and JS both resolve tokens, no ownership boundary | Incompatible implementations per-enrollment |
| 4 | Contract | **linkedin_action step type missing** — PRD defines it as first-class; plan uses boolean toggle | Authored LinkedIn steps won't map to commands correctly |
| 5 | Contract | **HTML body vs dom.fill** — email body is HTML, dom.fill only works with input/textarea | Every email platform interaction fails at runtime |
| 6 | Contract | **Send pipeline conflict** — existing gateway path vs proposed browser automation path, no routing | Risk of double-sends or orphaned state |
| 7 | Contract | **Execution error contract missing** — no error→enrollment-action mapping; types.py is empty | zigBrowser can't communicate failures meaningfully |
| 8 | Data Model | **approved_plan schema ambiguity** — current is hardcoded single-step placeholder; no v1→v2 strategy | Backward compatibility break |
| 9 | Data Model | **CandidateContext undefined** — candidate data comes from contact subsystem via JSONB, not inline fields | Token resolution fails at execution time |
| 10 | Data Model | **File paths reference wrong repository** — JS files target zigBrowser but sequences backend is separate repo | Implementer creates files in wrong repo |
| 11 | API | **8 endpoint mismatches** — 4 missing, 4 wrong path/shape vs Phase 0 actual contract | Plan cannot be implemented against Phase 0's API |
| 12 | API | **Auth model mismatch** — plan says API key; Phase 0 uses HMAC-SHA256 signing | Auth implementation will be wrong |
| 13 | Closure | **Test infra misreferenced** — exists in sequences repo, not zigBrowser; describe.skipIf anti-pattern | Tests can't run as written; closure tests may skip to false green |
| 14 | Closure | **Execution chain has no closure test** — only command dispatch tested, not the full scheduler→API→dispatch→result chain | Most critical workflow unproven |

## Suggested Plan Amendments

```diff
# FOUNDATIONAL: Resolve execution model before anything else

+ Add: Section 0 — "Execution Model Decision"
+   Option A: Browser automation REPLACES gateway for all sends → modify sendDueStep
+   Option B: Browser automation for social/LinkedIn ONLY, gateway stays for email
+   Option C: Browser automation as fallback when gateway is unavailable
+   Must pick one before proceeding

+ Add: Reconciliation with Phase 0 API contract
+   - Align all endpoint paths with Phase 0's actual names
+   - Resolve high-level vs low-level execution plan payload
+   - Adopt Phase 0's HMAC-SHA256 auth model
+   - File missing endpoints as Phase 0 scope additions or remove from requirements

~ Modify: Plan title → "Sequences Automation Execution Bridge" (not "PRD 9.3 + 9.4")
+ Add: Prerequisites section listing actual 9.3/9.4 UI implementation as dependency

# In Behavior 1: Step Mapping

+ Add: Explicit token resolution ownership contract
+ Add: linkedin_action step type handling
+ Add: JSON deserialization contract (camelCase → snake_case)
+ Add: build.zig module registration
~ Modify: dom.fill for body → dom.setContent or compound command

# In Behavior 2: Plan Construction

- Remove: includeLinkedInStep boolean toggle
+ Add: Inline linkedin_action step handling
+ Add: Test asserting params contain template placeholders
+ Add: approved_plan v1→v2 schema + migration strategy
+ Add: Relationship to existing sendDueStep gateway path

# In Behaviors 2-5: Fix repository paths

~ Modify: All JS file paths from zigBrowser-relative to sequences-repo-relative
~ Modify: Test runner from Jest to Vitest (matching sequences repo)
+ Add: Test helper implementations (createDraftSequence, createDraftWithSteps)

# In Behavior 6: Python SDK

+ Add: StepExecutionResult dataclass (in errors.py or sequences.py, NOT types.py)
+ Add: HMAC-SHA256 auth signing for Phase 0 API calls
+ Add: Error classification table
+ Add: Source-to-sink closure test for execution chain

# In Workflow Closure

+ Add: Behavior classifications (BLOCKING/LEAF with rationale)
+ Add: Closure Test 3 — execution chain source-to-sink
~ Modify: Closure tests must NOT use describe.skipIf (fail-closed per §4 rule 6)
```

## Review Checklist

### Contracts
- [ ] Component boundaries are clearly defined — ❌ execution model conflict (gateway vs browser automation)
- [ ] Input/output contracts are specified — ❌ token resolution ownership ambiguous
- [ ] Error contracts enumerate all failure modes — ❌ execution error→action mapping missing
- [x] Preconditions and postconditions are documented
- [ ] Invariants are identified — ❌ approved_plan schema invariant unspecified

### Interfaces
- [x] All public methods are defined with signatures
- [ ] Naming follows codebase conventions — ⚠️ types.py is empty; errors live in errors.py
- [x] Interface matches existing patterns
- [ ] Extension points are considered — ⚠️ step type extensibility unclear
- [x] Visibility modifiers are appropriate

### Promises
- [x] Behavioral guarantees are documented
- [ ] Async operations have timeout/cancellation handling — ⚠️ command execution ordering/timeout unstated
- [x] Resource cleanup is specified
- [x] Idempotency requirements are addressed (existing dedup_key mechanism)
- [ ] Ordering guarantees are documented where needed — ⚠️ serial command dispatch not guaranteed

### Data Models
- [ ] All fields have types — ❌ CandidateContext fields undefined
- [ ] Required vs optional is clear — ❌ candidate field optionality unstated
- [ ] Relationships are documented — ❌ approved_plan v1→v2 relationship unclear
- [ ] Migration strategy is defined — ❌ no v2 migration strategy
- [x] Serialization format is specified

### APIs
- [ ] All endpoints are defined — ❌ 8 endpoint mismatches with Phase 0
- [ ] Request/response formats are specified — ❌ payload schema conflict (commands vs actions)
- [x] Error responses are documented (Phase 0 error envelope)
- [ ] Authentication requirements are clear — ❌ wrong auth model
- [ ] Versioning strategy is defined — ⚠️ API versioning not specified

### Workflow Closure
- [ ] Each promised behavior is mapped from production trigger to user-visible result — ❌ execution chain unmapped
- [ ] Each workflow behavior is classified BLOCKING or LEAF — ❌ 4 of 6 behaviors unclassified
- [x] Closure-test anchors are derived (for Closure Test 1)
- [x] Red-at-seam is specified (for Closure Test 1)
- [ ] Target is drivable — ⚠️ test infra exists but in wrong repo; describe.skipIf anti-pattern
- [ ] Execution guarantee present — ⚠️ must use fail-closed, not describe.skipIf
- [ ] Every handler/projector/worker/listener has a production caller — ❌ Zig toCommandSequence has no production caller
- [x] Every route/scheduler/worker/listener registered where production runs it
- [x] No source-to-sink test directly seeds downstream read models
- [ ] Async/event workflows define persistence, consumer selection, retries — ⚠️ execution retry policy unstated
- [ ] Tenant/auth/RLS/transaction/request context is preserved — ⚠️ browser automation context unclear (existing pipeline uses `withTenantClient` + RLS)
- [ ] Silent/non-fatal errors and degraded responses are observable — ❌ error→enrollment action mapping missing

## Approval Status

- [ ] **Ready for Implementation** - No critical issues
- [ ] **Needs Minor Revision** - Address warnings before proceeding
- [x] **Needs Major Revision** - 14 critical issues must be resolved first

### Priority Order for Amendments

1. **Resolve execution model conflict** (C-1) — foundational; everything else depends on this decision
2. **Reconcile API endpoints with Phase 0** (A-1) — can't implement without matching endpoints
3. **Fix plan scope/title** (C-2) — prevents downstream planning confusion
4. **Resolve send pipeline coexistence** (C-6) — gateway vs browser automation routing
5. **Resolve token resolution architecture** (C-3) — affects every behavior
6. **Fix file paths to correct repository** (D-3) — blocks implementation literally
7. **Fix auth model** (A-2) — wrong auth prevents API communication
8. **Add linkedin_action step type** (C-4) — PRD contract violation
9. **Fix HTML body handling** (C-5) — execution will fail at runtime
10. **Define approved_plan v2 schema** (D-1) — backward compatibility
11. **Define CandidateContext schema** (D-2) — token resolution needs this
12. **Add execution error contract** (C-7) — error handling across boundary
13. **Fix test infrastructure references** (W-1) — tests can't run as written
14. **Add execution chain closure test** (W-2) — most critical workflow unproven
