# Sequences Integration TDD Plan — PRD 9.3 (New Sequence Creation) + PRD 9.4 (Sequence Step Authoring)

**Date:** 2026-07-09
**Scope:** zigBrowser ↔ sequences app tie-in for sequence creation and step authoring
**Coordination:** Agent pane 1 of 4; Phase 0 (API-DB layer) plan is the shared seam
**Primary inputs:**
- `sequences/thoughts/searchable/shared/prds/sequences/9.3-new-sequence-creation.md`
- `sequences/thoughts/searchable/shared/prds/sequences/9.4-sequence-step-authoring.md`
- zigBrowser automation engine: `src/automation/router.zig`, `src/automation_rpc.zig`, `sdk/python/`
- sequences DB: migrations `090`, `100`, `110`

## Overview

This plan defines how sequences created and authored in the sequences app become executable automation targets for zigBrowser, and how zigBrowser's automation commands map to sequence step authoring. It covers:

1. **Sequence-to-automation data model** — the schema that bridges a sequences-app "draft sequence with steps" to a zigBrowser-executable automation plan
2. **Step-to-command verb mapping** — how each `SequenceAuthoringStep` type maps to zigBrowser `dom.*`, `page.*`, and `social.*` command verbs
3. **Creation flow integration** — how `POST /api/v1/sequences` and AI generation connect to the automation engine
4. **Step validation against automation capabilities** — ensuring authored steps are executable before approval

## Current State Analysis

### zigBrowser Automation API (BUILT)

The automation engine exposes a JSON-RPC 2.0 API over AF_UNIX sockets with these command verbs:

| Verb | Params | Purpose |
|---|---|---|
| `dom.query` | `{selector, strict?, timeout_ms?}` | Find element |
| `dom.click` | `{selector, options?{force, trial, strict, timeout_ms}}` | Click element |
| `dom.fill` | `{selector, value, options?}` | Clear + fill input |
| `dom.type` | `{selector, text, delay_ms?, options?}` | Type character-by-character |
| `dom.getText` | `{selector, strict?}` | Extract text content |
| `dom.getAttribute` | `{selector, name, strict?}` | Read attribute |
| `dom.waitFor` | `{selector, state?, strict?, timeout_ms?}` | Wait for element state |
| `page.navigate` | `{url, timeout_ms?, waitUntil?}` | Navigate to URL |
| `page.reload` | `{timeout_ms?, waitUntil?}` | Reload page |
| `page.url` | `{}` | Get current URL |
| `page.title` | `{}` | Get page title |
| `page.evaluate` | `{expression}` | Run JS expression |
| `page.screenshot` | `{fullPage?}` | Capture screenshot |

**Source:** `src/automation/router.zig:6-20` (Verb enum), `src/automation/router.zig:164-178` (method→verb table)

Phase 5 adds social compound commands:
| Verb | Purpose |
|---|---|
| `social.login_check` | Verify platform login state |
| `social.rate_status` | Check daily action limits |
| `linkedin.connect` | Send connection request |
| `linkedin.message` | Send InMail/message |
| `linkedin.view_profile` | View a profile |
| `instagram.follow` | Follow account |

**Source:** `thoughts/searchable/shared/plans/2026-07-09-phase5-sdks-social-contracts-tdd-plan.md:27-31`

Python SDK public API: `ZigBrowser.dom.click()`, `.dom.fill()`, `.dom.type()`, `.page.navigate()`, etc.
**Source:** `sdk/python/src/zigbrowser/client.py:13-75`

### Sequences App DB (EXISTING)

**`sequences` table** (mig 090, extended by mig 100):
- `id`, `org_id`, `owner_user_id`, `name`, `status` (`draft|pending_approval|active|archived`)
- `job_id`, `workspace_search_id`
- `approved_at`, `approved_by`, `approved_plan` JSONB (mig 100)

**`sequence_enrollments`** (mig 090, extended by mig 100):
- `id`, `org_id`, `owner_user_id`, `sequence_id`
- `candidate_source`, `candidate_id`, `workspace_candidate_id`
- `status` (`draft|active|sent|paused|suppressed|bounced|stopped`), `current_step_index`, `next_send_at`, `stop_reason`

**`sequence_messages`** (mig 090, extended by mig 110):
- `id`, `org_id`, `owner_user_id`, `sequence_id`, `enrollment_id`
- `direction` (`outbound|inbound`), `subject`, `body`, `strategy`
- `grounding_status` (`grounded|partial|review`), `evidence_map` JSONB, `review_queue` JSONB
- `render_status` (`draft|failed`), `is_current`, `supersedes_id`
- Send columns: `sender_mailbox_connection_id`, `rendered_subject/body`, `sent_at`, `provider_message_id/thread_id`

**`sequence_events`** (mig 110):
- Canonical event types: `SequenceCreated`, `AudienceSelected`, `DraftGenerated`, `SequenceApproved`, `MessageSent`, etc.

**`approved_plan`** JSONB structure (from `sequenceExecutionService.js:82`):
```json
{ "steps": [{ "index": 0 }], "approved_at": "...", "version": 1 }
```

**Key gap:** There is NO `sequence_steps` table. Steps exist only as:
1. The `approved_plan` JSONB blob on the `sequences` table (frozen at approval)
2. Individual `sequence_messages` rows per enrollment (one message per enrollment per step)

The PRD 9.4 step model (`SequenceAuthoringStep`) is a UX-only contract today. Backend storage maps it to `approved_plan` + `sequence_messages`.

### What's Missing (This Plan's Scope)

1. No step schema that zigBrowser can consume for automation execution
2. No mapping from `SequenceAuthoringStep.type` to zigBrowser command verbs
3. No API endpoint for zigBrowser to read sequence steps for execution
4. No API endpoint for zigBrowser to push automation results (step completed, step failed)
5. No validation that authored steps are executable by the automation engine
6. No `automation_plan` schema that bridges the wizard's step model to the engine's command model

## Desired End State

After this plan is implemented:

1. A sequence created in the wizard (9.3) carries enough data for zigBrowser to execute it: sequence metadata, ordered steps with automation-verb mappings, target candidate context, and pacing/scheduling constraints.
2. Each authored step (9.4) maps deterministically to one or more zigBrowser command verb sequences, and the mapping is validated before approval.
3. The `approved_plan` JSONB is extended to include automation-executable step definitions alongside the existing approval snapshot.
4. zigBrowser can read execution plans through the Phase 0 API contract and report results back.

## What We're NOT Doing

- Phase 0 API layer internals (endpoints, auth, middleware) — we reference the seam
- PRD 9.1 (Sequence Tracking) or 9.2 (Analytics)
- The sequences dashboard UI or wizard shell implementation
- The UI components (React) for step authoring
- Modifying the existing send-pipeline execution (`sendStore.js`, `sequenceExecutionService.js`)
- Adding new DB tables — we extend existing schemas

## Phase 0 API Contract Dependencies

The Phase 0 API-DB layer plan (`2026-07-09-sequences-integration-api-db-layer-plan.md`) is being designed by a sibling agent. This plan consumes the following seam contract and specifies what 9.3/9.4 require from it:

### Required Reads (zigBrowser → sequences DB)

| Endpoint | Purpose | 9.3/9.4 Consumer |
|---|---|---|
| `GET /api/v1/automation/sequences/:id/plan` | Fetch the automation-executable plan for a sequence | zigBrowser execution engine, after approval |
| `GET /api/v1/automation/sequences/:id/steps` | Fetch ordered steps with command verb mappings | Step authoring preview, automation dry-run |
| `GET /api/v1/automation/enrollments/:id/context` | Fetch candidate context for token resolution | Step preview personalization, execution context |

### Required Writes (zigBrowser → sequences DB)

| Endpoint | Purpose | 9.3/9.4 Producer |
|---|---|---|
| `POST /api/v1/automation/sequences/:id/steps/:stepIndex/result` | Report step execution outcome | zigBrowser after executing a step |
| `POST /api/v1/automation/sequences/:id/events` | Emit automation execution events | zigBrowser telemetry bridge |
| `PATCH /api/v1/automation/enrollments/:id` | Advance enrollment state after step completion | zigBrowser post-step execution |

### Required Reads (sequences app → zigBrowser status)

| Endpoint | Purpose | 9.3/9.4 Consumer |
|---|---|---|
| `GET /api/v1/automation/capabilities` | Query available command verbs and platform support | Step authoring validation |
| `GET /api/v1/automation/health` | Check zigBrowser connectivity | Wizard shell status indicator |

## Testing Strategy

- **Unit tests (Zig):** Step-to-command mapping logic, automation plan validation, verb parameter construction
- **Unit tests (JS/Node):** Step schema validation, automation plan serialization, wizard-to-plan conversion
- **Integration tests (Python):** End-to-end flow from sequence creation through step authoring to automation plan readiness
- **Framework:** Zig `zig build test`, JS `npm test` (Jest/Vitest per sequences app), Python pytest per SDK patterns

---

## Behavior 1: Automation Step Schema — Mapping SequenceAuthoringStep to Command Verbs

### Test Specification

**Given:** A `SequenceAuthoringStep` of type `email` with subject, body, tokens, and `replyMode: 'new_thread'`
**When:** The step is converted to an automation execution plan
**Then:** It produces an ordered array of command verb calls:
1. `page.navigate` to the candidate's email compose URL (or platform messaging UI)
2. `dom.waitFor` the compose form
3. `dom.fill` the subject field with token-resolved subject
4. `dom.fill` (or `dom.type`) the body field with token-resolved body
5. `dom.click` the send button (only after approval, never during authoring)

**Given:** A `SequenceAuthoringStep` of type `email` with `replyMode: 'reply_in_same_thread'`
**When:** Converted to automation commands
**Then:** It produces commands that navigate to the existing thread and reply rather than composing new

**Given:** A `SequenceAuthoringStep` of type `wait` with `{ amount: 2, unit: 'business_days' }`
**When:** Converted to automation commands
**Then:** No automation commands are produced; the wait is a scheduling directive consumed by the execution scheduler, not the automation engine

**Given:** A step with `groundingStatus: 'review'` and non-empty `reviewQueue`
**When:** Converted to automation commands
**Then:** The step is flagged as NOT executable — automation plan marks it `blocked: 'grounding_review_required'` and no command sequence is generated until grounding is resolved

**Edge Cases:**
- Steps with unresolved `{{Token Name}}` tokens produce a validation error, not a command sequence
- Steps with empty subject or body produce a validation error
- Steps with `includeUnsubscribe: true` append an unsubscribe footer to the resolved body before command construction

### Files touched
- `src/automation/step_mapping.zig` (new: step-to-verb conversion logic)
- `sdk/python/src/zigbrowser/sequences.py` (new: Python-side step model + mapping)

### TDD Cycle

#### 🔴 Red: Write Failing Test
**File:** `tests/automation_step_mapping_test.zig`
```zig
const std = @import("std");
const testing = std.testing;
const step_mapping = @import("step_mapping");

test "email step produces navigate-wait-fill-fill command sequence" {
    const step = step_mapping.SequenceStep{
        .id = "step-1",
        .index = 0,
        .step_type = .email,
        .reply_mode = .new_thread,
        .subject = "Hello {{First Name}}",
        .body = "Your work at {{Current Company}} caught our eye",
        .tokens = &.{ "First Name", "Current Company" },
        .include_unsubscribe = true,
        .grounding_status = .grounded,
    };
    const candidate = step_mapping.CandidateContext{
        .first_name = "Alice",
        .current_company = "Acme",
        .email = "alice@example.com",
    };

    const commands = try step_mapping.toCommandSequence(testing.allocator, step, candidate);
    defer testing.allocator.free(commands);

    try testing.expectEqual(@as(usize, 4), commands.len);
    try testing.expectEqualStrings("page.navigate", commands[0].method);
    try testing.expectEqualStrings("dom.waitFor", commands[1].method);
    try testing.expectEqualStrings("dom.fill", commands[2].method); // subject
    try testing.expectEqualStrings("dom.fill", commands[3].method); // body
    // No dom.click for send — that's execution-only, not authoring
}

test "wait step produces zero automation commands" {
    const step = step_mapping.SequenceStep{
        .id = "step-2",
        .index = 1,
        .step_type = .wait,
        .wait_amount = 2,
        .wait_unit = .business_days,
    };

    const commands = try step_mapping.toCommandSequence(testing.allocator, step, .{});
    try testing.expectEqual(@as(usize, 0), commands.len);
}

test "unresolved tokens produce validation error" {
    const step = step_mapping.SequenceStep{
        .id = "step-3",
        .index = 0,
        .step_type = .email,
        .subject = "Hello {{Education}}",
        .body = "...",
        .tokens = &.{"Education"},
    };
    const candidate = step_mapping.CandidateContext{}; // no education field

    const result = step_mapping.toCommandSequence(testing.allocator, step, candidate);
    try testing.expectError(error.UnresolvedTokens, result);
}

test "review grounding status blocks command generation" {
    const step = step_mapping.SequenceStep{
        .id = "step-4",
        .index = 0,
        .step_type = .email,
        .grounding_status = .review,
        .review_queue = &.{.{ .reason = "ungrounded_claim" }},
    };

    const result = step_mapping.toCommandSequence(testing.allocator, step, .{});
    try testing.expectError(error.GroundingReviewRequired, result);
}
```

#### 🟢 Green: Minimal Implementation
**File:** `src/automation/step_mapping.zig`
```zig
pub const StepType = enum { email, wait };
pub const ReplyMode = enum { new_thread, reply_in_same_thread };
pub const WaitUnit = enum { minutes, hours, business_days, days };
pub const GroundingStatus = enum { grounded, partial, review };

pub const SequenceStep = struct {
    id: []const u8,
    index: u32,
    step_type: StepType,
    reply_mode: ReplyMode = .new_thread,
    subject: []const u8 = "",
    body: []const u8 = "",
    tokens: []const []const u8 = &.{},
    include_unsubscribe: bool = false,
    grounding_status: GroundingStatus = .grounded,
    review_queue: []const ReviewItem = &.{},
    wait_amount: u32 = 0,
    wait_unit: WaitUnit = .days,
};

pub const AutomationCommand = struct {
    method: []const u8,
    params_json: []const u8,
};

pub fn toCommandSequence(
    allocator: std.mem.Allocator,
    step: SequenceStep,
    candidate: CandidateContext,
) ![]AutomationCommand {
    if (step.step_type == .wait) return &.{};
    if (step.grounding_status == .review) return error.GroundingReviewRequired;
    // Resolve tokens, validate, build command list
    // ...
}
```

#### 🔵 Refactor: Improve Code
- [ ] No duplication: token resolution logic extracted into shared resolver
- [ ] Reveals intent: `toCommandSequence` reads as "convert step to commands"
- [ ] Complexity went down: flat switch on step_type
- [ ] No shallow wrappers: step_mapping does real work
- [ ] Fits existing patterns: follows `router.zig` Verb enum pattern

### Success Criteria
**Automated:**
- [ ] `zig build test --summary all` — step mapping tests pass
- [ ] Coverage of all step types (email new_thread, email reply, wait)
- [ ] Grounding review blocked
- [ ] Token resolution validated

**Manual:**
- [ ] Email step produces correct command sequence for a sample candidate

---

## Behavior 2: Automation Plan Construction — Sequence to Executable Plan

### Test Specification

**Given:** A draft sequence with 5 email steps and 4 wait steps (interleaved), mailbox settings, and AI-generated content
**When:** The sequence is approved via `sequenceExecutionService.approveSequence()`
**Then:** The `approved_plan` JSONB includes an `automation_steps` array where each email step has:
- `command_sequence`: ordered array of `{method, params}` ready for zigBrowser dispatch
- `token_bindings`: which candidate fields feed which tokens
- `grounding_metadata`: evidence_map and review status
- `scheduling`: wait-before timing derived from preceding wait steps

**Given:** The approved plan is read by zigBrowser through the Phase 0 API
**When:** zigBrowser parses the plan
**Then:** Each `command_sequence` entry maps directly to a valid `AutomationRouter.dispatch()` call via the JSON-RPC connection

**Edge Cases:**
- LinkedIn steps (`includeLinkedInStep: true` from 9.3 S5) map to `linkedin.view_profile` and `linkedin.connect` compound commands
- Plan construction validates all steps are executable before writing `approved_plan`
- Steps with `render_status: 'failed'` block plan construction

### Files touched
- `sequences/backend/services/sequences/automationPlanBuilder.js` (new)
- `sequences/backend/services/sequences/sequenceExecutionService.js` (extend `approveSequence`)

### TDD Cycle

#### 🔴 Red: Write Failing Test
**File:** `sequences/backend/services/sequences/__tests__/automationPlanBuilder.test.js`
```javascript
import { buildAutomationPlan } from '../automationPlanBuilder.js';

describe('Automation Plan Builder', () => {
  it('converts authored steps to automation-executable plan', () => {
    const steps = [
      { id: 'step-1', index: 0, type: 'email', replyMode: 'new_thread',
        subject: 'Hello {{First Name}}', body: 'Your work at {{Current Company}}...',
        tokens: ['First Name', 'Current Company'], includeUnsubscribe: true,
        groundingStatus: 'grounded', evidenceMap: [] },
      { id: 'step-2', index: 1, type: 'wait', wait: { amount: 2, unit: 'business_days' } },
      { id: 'step-3', index: 2, type: 'email', replyMode: 'reply_in_same_thread',
        subject: 'Re: Hello {{First Name}}', body: 'Just following up...',
        tokens: ['First Name'], includeUnsubscribe: true,
        groundingStatus: 'grounded', evidenceMap: [] },
    ];

    const plan = buildAutomationPlan(steps, {
      senderMailboxId: 'mbx-1',
      language: 'en',
      includeLinkedInStep: false,
    });

    expect(plan.version).toBe(1);
    expect(plan.automation_steps).toHaveLength(2); // only email steps
    expect(plan.automation_steps[0].command_sequence).toHaveLength(4);
    expect(plan.automation_steps[0].command_sequence[0].method).toBe('page.navigate');
    expect(plan.automation_steps[0].scheduling.wait_before).toBeNull();
    expect(plan.automation_steps[1].scheduling.wait_before).toEqual({
      amount: 2, unit: 'business_days',
    });
    expect(plan.automation_steps[1].command_sequence[0].method).toBe('page.navigate');
  });

  it('includes linkedin step when configured', () => {
    const steps = [
      { id: 'step-1', index: 0, type: 'email', replyMode: 'new_thread',
        subject: 'Hello', body: 'Message', tokens: [],
        includeUnsubscribe: true, groundingStatus: 'grounded' },
    ];

    const plan = buildAutomationPlan(steps, {
      senderMailboxId: 'mbx-1',
      language: 'en',
      includeLinkedInStep: true,
    });

    const linkedInStep = plan.automation_steps.find(
      s => s.command_sequence.some(c => c.method === 'linkedin.view_profile')
    );
    expect(linkedInStep).toBeDefined();
  });

  it('rejects plan with review-blocked steps', () => {
    const steps = [
      { id: 'step-1', index: 0, type: 'email', replyMode: 'new_thread',
        subject: 'Hello', body: 'Body', tokens: [],
        groundingStatus: 'review', reviewQueue: [{ reason: 'ungrounded_claim' }] },
    ];

    expect(() => buildAutomationPlan(steps, { senderMailboxId: 'mbx-1' }))
      .toThrow('grounding_review_required');
  });

  it('rejects plan with empty subject or body', () => {
    const steps = [
      { id: 'step-1', index: 0, type: 'email', replyMode: 'new_thread',
        subject: '', body: '', tokens: [], groundingStatus: 'grounded' },
    ];

    expect(() => buildAutomationPlan(steps, { senderMailboxId: 'mbx-1' }))
      .toThrow('invalid_step');
  });
});
```

#### 🟢 Green: Minimal Implementation
**File:** `sequences/backend/services/sequences/automationPlanBuilder.js`
```javascript
export function buildAutomationPlan(steps, config) {
  const automationSteps = [];
  let pendingWait = null;

  for (const step of steps) {
    if (step.type === 'wait') {
      pendingWait = step.wait;
      continue;
    }
    if (step.type === 'email') {
      validateEmailStep(step);
      automationSteps.push({
        step_id: step.id,
        step_index: step.index,
        command_sequence: buildEmailCommandSequence(step, config),
        token_bindings: step.tokens.map(t => ({ token: t, source: 'candidate' })),
        grounding_metadata: {
          status: step.groundingStatus,
          evidence_map: step.evidenceMap || [],
          review_queue: step.reviewQueue || [],
        },
        scheduling: { wait_before: pendingWait },
      });
      pendingWait = null;
    }
  }

  if (config.includeLinkedInStep) {
    automationSteps.push(buildLinkedInStep(config));
  }

  return { version: 1, automation_steps: automationSteps, approved_at: new Date().toISOString() };
}
```

#### 🔵 Refactor: Improve Code
- [ ] No duplication: `buildEmailCommandSequence` and `buildLinkedInStep` share navigation logic
- [ ] Reveals intent: function name is the contract
- [ ] Complexity went down: single pass through steps, accumulating wait directives
- [ ] No shallow wrappers: real construction logic
- [ ] Fits existing patterns: matches `sequenceExecutionService.js:82` approved_plan shape

### Success Criteria
**Automated:**
- [ ] `npm test -- automationPlanBuilder.test.js` — all cases pass
- [ ] Email steps produce valid command sequences
- [ ] Wait steps produce scheduling directives, not commands
- [ ] LinkedIn step included when configured
- [ ] Validation rejects review-blocked and empty steps

**Manual:**
- [ ] Generated plan JSON is parseable by zigBrowser Python SDK

---

## Behavior 3: Step Schema Validation Against Automation Capabilities

### Test Specification

**Given:** An authored step referencing `dom.click` with selector `#compose-send`
**When:** Step validation runs against the automation capability manifest
**Then:** The step is marked valid because `dom.click` is a known verb

**Given:** An authored step referencing a social command `linkedin.connect`
**When:** Step validation runs against the capability manifest
**Then:** The step is valid only if Phase 5 social commands are available (capability advertised)

**Given:** An authored step with `groundingStatus: 'partial'` and non-empty `reviewQueue`
**When:** Validation runs
**Then:** The step gets a warning (not a blocking error) — the recruiter can review but the step cannot be auto-executed

**Edge Cases:**
- Unknown command verbs fail validation
- Steps with tokens that reference non-existent candidate fields produce warnings at authoring time, errors at approval time
- `page.evaluate` with arbitrary JS is blocked at validation (security constraint)

### Files touched
- `sequences/backend/services/sequences/stepValidator.js` (new)

### TDD Cycle

#### 🔴 Red: Write Failing Test
**File:** `sequences/backend/services/sequences/__tests__/stepValidator.test.js`
```javascript
import { validateStep, validateStepsForApproval } from '../stepValidator.js';

describe('Step Validator', () => {
  const capabilities = {
    verbs: ['dom.query', 'dom.click', 'dom.fill', 'dom.type', 'dom.getText',
            'dom.getAttribute', 'dom.waitFor', 'page.navigate', 'page.reload',
            'page.url', 'page.title', 'page.screenshot'],
    social: ['linkedin.connect', 'linkedin.view_profile', 'linkedin.message'],
  };

  it('validates email step with known verbs', () => {
    const step = {
      id: 'step-1', index: 0, type: 'email', replyMode: 'new_thread',
      subject: 'Hello', body: 'Body', tokens: [],
      groundingStatus: 'grounded',
    };
    const result = validateStep(step, capabilities);
    expect(result.valid).toBe(true);
    expect(result.errors).toHaveLength(0);
  });

  it('warns on partial grounding', () => {
    const step = {
      id: 'step-2', index: 0, type: 'email', replyMode: 'new_thread',
      subject: 'Hello', body: 'Body', tokens: [],
      groundingStatus: 'partial',
      reviewQueue: [{ reason: 'claim_check' }],
    };
    const result = validateStep(step, capabilities);
    expect(result.valid).toBe(true); // not blocking
    expect(result.warnings).toContainEqual(
      expect.objectContaining({ code: 'partial_grounding' })
    );
  });

  it('blocks approval with empty subject', () => {
    const steps = [{
      id: 'step-3', index: 0, type: 'email', replyMode: 'new_thread',
      subject: '', body: 'Body', tokens: [], groundingStatus: 'grounded',
    }];
    const result = validateStepsForApproval(steps, capabilities);
    expect(result.valid).toBe(false);
    expect(result.errors[0].step_id).toBe('step-3');
    expect(result.errors[0].code).toBe('empty_subject');
  });

  it('blocks page.evaluate in automation plan', () => {
    const step = {
      id: 'step-4', index: 0, type: 'email', replyMode: 'new_thread',
      subject: 'Hello', body: 'Body with <script>eval</script>', tokens: [],
      groundingStatus: 'grounded',
    };
    // The plan builder should never produce page.evaluate from email steps
    const commands = [{ method: 'page.evaluate', params: { expression: 'alert(1)' } }];
    const result = validateStep(step, capabilities, { commands });
    expect(result.errors).toContainEqual(
      expect.objectContaining({ code: 'forbidden_verb' })
    );
  });
});
```

#### 🟢 Green: Minimal Implementation
**File:** `sequences/backend/services/sequences/stepValidator.js`
```javascript
const FORBIDDEN_VERBS = ['page.evaluate'];

export function validateStep(step, capabilities, { commands } = {}) {
  const errors = [];
  const warnings = [];

  if (step.type === 'email') {
    if (!step.subject?.trim()) errors.push({ step_id: step.id, code: 'empty_subject' });
    if (!step.body?.trim()) errors.push({ step_id: step.id, code: 'empty_body' });
    if (step.groundingStatus === 'review')
      errors.push({ step_id: step.id, code: 'grounding_review_required' });
    if (step.groundingStatus === 'partial')
      warnings.push({ step_id: step.id, code: 'partial_grounding' });
  }

  if (commands) {
    for (const cmd of commands) {
      if (FORBIDDEN_VERBS.includes(cmd.method))
        errors.push({ step_id: step.id, code: 'forbidden_verb', verb: cmd.method });
    }
  }

  return { valid: errors.length === 0, errors, warnings };
}

export function validateStepsForApproval(steps, capabilities) {
  const allErrors = [];
  for (const step of steps) {
    const { errors } = validateStep(step, capabilities);
    allErrors.push(...errors);
  }
  return { valid: allErrors.length === 0, errors: allErrors };
}
```

#### 🔵 Refactor: Improve Code
- [ ] No duplication: validation rules centralized
- [ ] Reveals intent: `validateStepsForApproval` is the approval gate
- [ ] Complexity went down: linear scan, no nested conditionals
- [ ] No shallow wrappers: real validation logic
- [ ] Fits existing patterns: mirrors grounding validation in `outreach_service.ground_draft`

### Success Criteria
**Automated:**
- [ ] `npm test -- stepValidator.test.js` — all cases pass
- [ ] Valid steps pass, invalid steps fail with specific codes
- [ ] Partial grounding warns, review grounding blocks
- [ ] Forbidden verbs detected

**Manual:**
- [ ] Validation errors surface in the wizard UI (cross-verify with Track 2)

---

## Behavior 4: Sequence Creation → Automation Plan Lifecycle

### Test Specification

**Given:** A recruiter creates a new sequence via the wizard (9.3 S4 "Start from scratch")
**When:** `POST /api/v1/sequences` creates a draft
**Then:** The draft sequence has `status: 'draft'`, no `approved_plan`, and a `SequenceCreated` event is written to `sequence_events`

**Given:** A recruiter generates a sequence with AI (9.3 S5→S6)
**When:** Generation completes with 5 email steps
**Then:** Each generated step is stored as a `sequence_message` row with `render_status: 'draft'`, `grounding_status` set by the LLM grounding service, and `evidence_map` populated. The sequence remains `status: 'draft'` — no auto-send.

**Given:** A sequence with fully-authored valid steps
**When:** The recruiter approves via the editor (Track 2 → shell Save)
**Then:** `approved_plan` is written with the automation plan (Behavior 2), `status` transitions to `active`, enrollments advance to `status: 'active'`, and a `SequenceApproved` event is written

**Given:** zigBrowser reads the approved plan for execution
**When:** It connects to the Phase 0 API and fetches the plan
**Then:** Each `automation_steps[i].command_sequence` contains valid JSON-RPC-ready `{method, params}` objects that `AutomationRouter.dispatch()` can execute

**Edge Cases:**
- Cloned sequences carry step content but NOT automation plans — a new plan must be built at approval
- Template-based sequences populate `sequence_messages` from template but require re-validation
- AI generation failure leaves partial steps; the sequence stays draft and the wizard shows error (9.3 S6 ERROR)
- Cancel during generation deletes the partial draft (or keeps it per OQ-4)

### Files touched
- `sequences/backend/services/sequences/sequenceExecutionService.js` (extend `approveSequence`)
- `sequences/backend/services/sequences/automationPlanBuilder.js` (from Behavior 2)

### TDD Cycle

#### 🔴 Red: Write Failing Test
**File:** `sequences/backend/services/sequences/__tests__/sequenceCreationLifecycle.test.js`
```javascript
import { approveSequence } from '../sequenceExecutionService.js';
import { buildAutomationPlan } from '../automationPlanBuilder.js';

describe('Sequence Creation → Automation Plan Lifecycle', () => {
  it('draft sequence has no approved_plan', async () => {
    const sequence = await createDraftSequence({
      name: 'Test Sequence', orgId: 'org-1', userId: 'user-1',
    });
    expect(sequence.status).toBe('draft');
    expect(sequence.approved_plan).toBeNull();
  });

  it('approval writes automation plan with command sequences', async () => {
    const sequence = await createDraftWithSteps([
      { type: 'email', subject: 'Hello', body: 'World', groundingStatus: 'grounded' },
      { type: 'wait', wait: { amount: 1, unit: 'days' } },
      { type: 'email', subject: 'Follow up', body: 'Checking in', groundingStatus: 'grounded' },
    ]);

    const result = await approveSequence(sequence.id, 'user-1');

    expect(result.status).toBe('active');
    expect(result.approved_plan).toBeDefined();
    expect(result.approved_plan.automation_steps).toHaveLength(2);
    expect(result.approved_plan.automation_steps[0].command_sequence[0].method)
      .toBe('page.navigate');
    expect(result.approved_plan.automation_steps[1].scheduling.wait_before)
      .toEqual({ amount: 1, unit: 'days' });
  });

  it('approval fails with invalid steps', async () => {
    const sequence = await createDraftWithSteps([
      { type: 'email', subject: '', body: '', groundingStatus: 'grounded' },
    ]);

    await expect(approveSequence(sequence.id, 'user-1'))
      .rejects.toThrow('invalid_step');
  });
});
```

#### 🟢 Green: Minimal Implementation
Extend `sequenceExecutionService.approveSequence()` to call `buildAutomationPlan()` and `validateStepsForApproval()` before writing `approved_plan`.

#### 🔵 Refactor: Improve Code
- [ ] No duplication: plan construction and validation in one approval path
- [ ] Reveals intent: approval gate is explicit
- [ ] Complexity went down: linear pipeline
- [ ] No shallow wrappers: integrates into existing approval flow
- [ ] Fits existing patterns: matches `sequenceExecutionService.js:82` approved_plan write

### Success Criteria
**Automated:**
- [ ] `npm test -- sequenceCreationLifecycle.test.js` — lifecycle tests pass
- [ ] Draft has no plan, approval writes plan, invalid steps block approval

**Manual:**
- [ ] Sequence created through wizard produces a valid automation plan on approval

---

## Behavior 5: Token Resolution and Candidate Context Binding

### Test Specification

**Given:** A step with subject `"Hello {{First Name}}, your work at {{Current Company}}"` and a candidate with `first_name: "Alice"`, `current_company: "Acme"`
**When:** Token resolution runs
**Then:** The resolved subject is `"Hello Alice, your work at Acme"`

**Given:** A step with `{{Education}}` token and a candidate missing education data
**When:** Token resolution runs in authoring preview mode
**Then:** The token is marked as unresolved: `"Hello {{Education:MISSING}}"` and a warning is surfaced

**Given:** A step with `{{Education}}` token at approval time
**When:** Token resolution runs in approval mode
**Then:** The step is blocked with error `'unresolved_token'` — cannot approve with missing mandatory personalization

**Edge Cases:**
- Nested tokens (`{{First Name}}{{Last Name}}`) resolve independently
- Empty string after resolution (candidate first_name is "") is treated as unresolved
- Token names are case-insensitive
- Unknown token names produce validation errors

**Property:** For all valid candidate contexts C and token strings T: `resolve(T, C)` produces a string with no `{{...}}` patterns remaining, OR produces exactly the set of `{{name:MISSING}}` markers for fields absent in C.

### Files touched
- `sequences/backend/services/sequences/tokenResolver.js` (new)

### TDD Cycle

#### 🔴 Red: Write Failing Test
**File:** `sequences/backend/services/sequences/__tests__/tokenResolver.test.js`
```javascript
import { resolveTokens, validateTokens } from '../tokenResolver.js';

describe('Token Resolution', () => {
  const candidate = {
    first_name: 'Alice',
    current_company: 'Acme',
    job_title: 'Engineer',
  };

  it('resolves all known tokens', () => {
    const result = resolveTokens('Hello {{First Name}} at {{Current Company}}', candidate);
    expect(result.text).toBe('Hello Alice at Acme');
    expect(result.unresolved).toHaveLength(0);
  });

  it('marks missing tokens in preview mode', () => {
    const result = resolveTokens('Hello {{Education}}', candidate, { mode: 'preview' });
    expect(result.text).toBe('Hello {{Education:MISSING}}');
    expect(result.unresolved).toEqual(['Education']);
  });

  it('blocks unresolved tokens in approval mode', () => {
    const result = validateTokens(['{{Education}}'], candidate);
    expect(result.valid).toBe(false);
    expect(result.errors[0].code).toBe('unresolved_token');
    expect(result.errors[0].token).toBe('Education');
  });

  it('is case-insensitive', () => {
    const result = resolveTokens('{{first name}}', candidate);
    expect(result.text).toBe('Alice');
  });

  it('treats empty resolved value as unresolved', () => {
    const result = resolveTokens('{{First Name}}', { first_name: '' }, { mode: 'preview' });
    expect(result.unresolved).toEqual(['First Name']);
  });
});
```

#### 🟢 Green: Minimal Implementation
**File:** `sequences/backend/services/sequences/tokenResolver.js`
```javascript
const TOKEN_MAP = {
  'first name': 'first_name',
  'last name': 'last_name',
  'current company': 'current_company',
  'job title': 'job_title',
  'education': 'education',
  'sender first name': 'sender_first_name',
};

export function resolveTokens(text, candidate, { mode = 'resolve' } = {}) {
  const unresolved = [];
  const resolved = text.replace(/\{\{(.+?)\}\}/g, (match, tokenName) => {
    const key = TOKEN_MAP[tokenName.trim().toLowerCase()];
    const value = key ? candidate[key] : undefined;
    if (!value) {
      unresolved.push(tokenName.trim());
      return mode === 'preview' ? `{{${tokenName.trim()}:MISSING}}` : match;
    }
    return value;
  });
  return { text: resolved, unresolved };
}

export function validateTokens(tokens, candidate) {
  const errors = [];
  for (const token of tokens) {
    const match = token.match(/\{\{(.+?)\}\}/);
    if (!match) continue;
    const key = TOKEN_MAP[match[1].trim().toLowerCase()];
    if (!key || !candidate[key]) {
      errors.push({ code: 'unresolved_token', token: match[1].trim() });
    }
  }
  return { valid: errors.length === 0, errors };
}
```

#### 🔵 Refactor: Improve Code
- [ ] No duplication: `TOKEN_MAP` is the single source of token→field mapping
- [ ] Reveals intent: `resolveTokens` and `validateTokens` are the two modes
- [ ] Complexity went down: regex replace with lookup
- [ ] No shallow wrappers: real resolution logic
- [ ] Fits existing patterns: candidate context shape matches existing enrollment/candidate models

### Success Criteria
**Automated:**
- [ ] `npm test -- tokenResolver.test.js` — all cases pass
- [ ] Known tokens resolve, missing tokens surface
- [ ] Case insensitive, empty values detected

**Manual:**
- [ ] Preview in the wizard shows resolved/missing tokens correctly

---

## Behavior 6: zigBrowser Execution Plan Reader (Python SDK Extension)

### Test Specification

**Given:** zigBrowser's Python SDK connects to the Phase 0 API
**When:** It fetches an approved sequence's automation plan
**Then:** The plan is deserialized into `AutomationPlan` objects with typed `CommandSequence` entries that can be dispatched via the existing `ZigBrowser.dom.*` and `ZigBrowser.page.*` methods

**Given:** An automation plan with a LinkedIn step
**When:** zigBrowser reads the plan
**Then:** The LinkedIn step's commands are dispatched through the social namespace: `ZigBrowser.social.linkedin_view_profile()` followed by `ZigBrowser.social.linkedin_connect()`

**Given:** A step execution fails with `element_not_found`
**When:** zigBrowser reports the result via the Phase 0 API
**Then:** The enrollment's `current_step_index` is NOT advanced, a `sequence_event` with the error is recorded, and the enrollment status may transition to `paused` (depending on error policy)

**Edge Cases:**
- Network disconnection during execution: step result is NOT reported, enrollment stays at current index, next execution attempt retries
- Rate-limited by pacing layer: `platform_rate_limited` error reported, enrollment paused
- Candidate context unavailable: skip enrollment, record skip reason

### Files touched
- `sdk/python/src/zigbrowser/sequences.py` (new: plan reader + executor)
- `sdk/python/tests/test_sequences.py` (new)

### TDD Cycle

#### 🔴 Red: Write Failing Test
**File:** `sdk/python/tests/test_sequences.py`
```python
import pytest
from zigbrowser.sequences import AutomationPlan, StepExecutor

def test_plan_deserialization():
    plan_json = {
        "version": 1,
        "automation_steps": [
            {
                "step_id": "step-1",
                "step_index": 0,
                "command_sequence": [
                    {"method": "page.navigate", "params": {"url": "https://mail.example.com/compose"}},
                    {"method": "dom.waitFor", "params": {"selector": "#subject"}},
                    {"method": "dom.fill", "params": {"selector": "#subject", "value": "Hello Alice"}},
                    {"method": "dom.fill", "params": {"selector": "#body", "value": "Your work..."}},
                ],
                "scheduling": {"wait_before": None},
            },
        ],
    }

    plan = AutomationPlan.from_dict(plan_json)
    assert len(plan.steps) == 1
    assert plan.steps[0].command_sequence[0].method == "page.navigate"
    assert plan.steps[0].scheduling.wait_before is None

def test_step_executor_dispatches_commands(mock_zigbrowser):
    executor = StepExecutor(mock_zigbrowser)
    step = AutomationPlan.from_dict(SAMPLE_PLAN).steps[0]

    result = executor.execute_step(step)

    assert result.success is True
    assert mock_zigbrowser.call_count == 4  # navigate, waitFor, fill, fill

def test_step_executor_reports_failure(mock_zigbrowser):
    mock_zigbrowser.dom.fill.side_effect = AutomationError(
        code=-32001, name="element_not_found",
        trace_id="trace-1", command_id="cmd-1",
    )
    executor = StepExecutor(mock_zigbrowser)
    step = AutomationPlan.from_dict(SAMPLE_PLAN).steps[0]

    result = executor.execute_step(step)

    assert result.success is False
    assert result.error.name == "element_not_found"
    assert result.failed_at_command == 2  # third command (dom.fill subject)
```

#### 🟢 Green: Minimal Implementation
**File:** `sdk/python/src/zigbrowser/sequences.py`
```python
from dataclasses import dataclass
from typing import Optional

@dataclass
class SchedulingDirective:
    wait_before: Optional[dict] = None

@dataclass
class AutomationCommand:
    method: str
    params: dict

@dataclass
class AutomationStep:
    step_id: str
    step_index: int
    command_sequence: list[AutomationCommand]
    scheduling: SchedulingDirective

@dataclass
class AutomationPlan:
    version: int
    steps: list[AutomationStep]

    @classmethod
    def from_dict(cls, data: dict) -> 'AutomationPlan':
        steps = [
            AutomationStep(
                step_id=s['step_id'],
                step_index=s['step_index'],
                command_sequence=[AutomationCommand(**c) for c in s['command_sequence']],
                scheduling=SchedulingDirective(**s.get('scheduling', {})),
            )
            for s in data['automation_steps']
        ]
        return cls(version=data['version'], steps=steps)
```

#### 🔵 Refactor: Improve Code
- [ ] No duplication: dataclass models shared with SDK types
- [ ] Reveals intent: `AutomationPlan.from_dict()` is the entry point
- [ ] Complexity went down: flat mapping
- [ ] No shallow wrappers: real deserialization
- [ ] Fits existing patterns: matches `sdk/python/src/zigbrowser/types.py` style

### Success Criteria
**Automated:**
- [ ] `pytest tests/test_sequences.py` — plan deserialization and execution tests pass
- [ ] Commands dispatch in order
- [ ] Failures are captured with failed_at_command index

**Manual:**
- [ ] Real zigBrowser instance can read and execute a plan against a test page

---

## Workflow Closure

### Production Operation Chain

```
[wizard create] -> [POST /sequences] -> [sequence_messages rows] -> [approval]
    -> [buildAutomationPlan] -> [approved_plan JSONB] -> [zigBrowser reads plan]
    -> [command dispatch per step] -> [POST result] -> [enrollment advance]
    -> [sequence_events ledger]
```

### Closure Test: Sequence approval writes automation-executable plan that zigBrowser can dispatch [BLOCKING]

- **SOURCE (seed only):** `sequences` table (draft row), `sequence_messages` table (step rows)
- **TRIGGER (start):** `approveSequence()` : `sequenceExecutionService.js:80`
- **DRIVERS (async edges):** None — approval is synchronous DB write
- **OBSERVE (assert via):** `SELECT approved_plan FROM sequences WHERE id = $1` : production read path
- **FORBIDDEN SPAN:** `buildAutomationPlan` internals, `validateStepsForApproval` internals — test seeds a draft and calls `approveSequence`, observing only the written plan
- **RED-AT-SEAM proof:** Remove `buildAutomationPlan` call → `approved_plan.automation_steps` is absent → red
- **DRIVABILITY:** Store seam present (test DB); no async edge → no clock needed
- **EXECUTION:** Requires PostgreSQL test instance (existing test infra); if absent, test FAILS-CLOSED (red)

### Closure Test: zigBrowser reads approved plan and dispatches commands in order [BLOCKING]

- **SOURCE (seed only):** `sequences` table (with `approved_plan` set), mock zigBrowser UDS
- **TRIGGER (start):** `StepExecutor.execute_step()` : `sdk/python/src/zigbrowser/sequences.py`
- **DRIVERS (async edges):** UDS JSON-RPC round-trip → mock server in test
- **OBSERVE (assert via):** Mock server received commands list : `conftest.py` mock assertion
- **FORBIDDEN SPAN:** JSON-RPC framing, router dispatch — test uses mock server
- **RED-AT-SEAM proof:** Corrupt plan `command_sequence[0].method` → dispatch fails → red
- **DRIVABILITY:** Mock UDS server present (existing `conftest.py` pattern); no real browser needed
- **EXECUTION:** Requires Python + pytest (existing SDK test infra); if absent, test FAILS-CLOSED

---

## Integration & E2E Testing

### Integration scenarios:
1. **Full wizard → plan:** Create sequence via API, add steps, approve, verify `approved_plan` has valid command sequences
2. **Plan → execution:** Read approved plan via Phase 0 API, dispatch each command via mock zigBrowser, verify all commands sent in order
3. **Failure recovery:** Simulate step failure mid-execution, verify enrollment NOT advanced, event recorded

### E2E test (requires both repos running):
1. Start sequences app backend + PostgreSQL
2. Start zigBrowser with `--automation-api`
3. Create sequence via API
4. Add email steps with tokens
5. Approve sequence
6. Read automation plan via API
7. Execute step commands via Python SDK against a test page
8. Verify DOM changes match expectations

## References

- PRD 9.3: `sequences/thoughts/searchable/shared/prds/sequences/9.3-new-sequence-creation.md`
- PRD 9.4: `sequences/thoughts/searchable/shared/prds/sequences/9.4-sequence-step-authoring.md`
- zigBrowser command verbs: `src/automation/router.zig:6-20`
- zigBrowser JSON-RPC: `src/automation_rpc.zig:1-156`
- zigBrowser Python SDK: `sdk/python/src/zigbrowser/client.py:13-75`
- Phase 5 social commands: `thoughts/searchable/shared/plans/2026-07-09-phase5-sdks-social-contracts-tdd-plan.md`
- Sequences foundation: `sequences/database/migrations/090_sequences_foundation.sql`
- Send pipeline state: `sequences/database/migrations/100_send_pipeline_state.sql`
- Sequences engine: `sequences/database/migrations/110_sequences_engine.sql`
- Approved plan usage: `sequences/backend/services/sequences/sequenceExecutionService.js:82`
- Send store step tracking: `sequences/backend/services/sequences/sendStore.js:17-93`
- Phase 0 API contract: `2026-07-09-sequences-integration-api-db-layer-plan.md` (pending — sibling agent)
