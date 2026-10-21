//! The runner the site flows (x.*, linkedin.*, instagram.*) execute their
//! steps through: one router command per step via Engine.External, so every
//! step gets retries, actionability checks and telemetry under the flow
//! command's single root span.
const std = @import("std");
const engine_mod = @import("engine.zig");
const script_command = @import("script_command.zig");
const errors = @import("error.zig");
const telemetry = @import("telemetry.zig");

/// N20: a rateLimitScan never takes longer than this (bounded by the flow).
pub const scan_timeout_ms: u64 = 5_000;

/// Runner for the site flows (src/x.zig, src/linkedin.zig, src/instagram.zig;
/// contract in src/flow_steps.zig): one command per
/// call, keeping the last result (borrowed by the flow until the next call)
/// and the latest failure. A failure stays until a newer one replaces it
/// (a later successful lookup, like the login-link probe after a failed
/// composer wait, must not erase the failure that stopped the flow). Every
/// failure it hands out carries the x.* command's trace_id/command_id.
pub const StepObserver = struct {
    ctx: *anyopaque,
    on_step: *const fn (ctx: *anyopaque, method: []const u8, params_json: []const u8, ok: bool, duration_ms: u64) void,
};

/// S8 ("S8 in detail" decision 2, phases B and C): an approved real run's navigation and the
/// document it committed. Phase A (the window as the card showed it) ran before the flow started.
/// S8: an approval's expectation of a flow's window (strings borrowed from the request).
pub const Expect = struct {
    origin: []const u8,
    load_serial: u64,
    url: []const u8,
    /// S8 decision 13: the LinkedIn slug a conversation message's approval names.
    recipient: ?[]const u8 = null,
};

/// `expect: {origin: non-empty string, load_serial: integer >= 0, url: non-empty string,
/// recipient?: a LinkedIn slug}`, no other key, else InvalidParams. Which flows may carry a
/// recipient is the route's rule.
pub fn parseExpect(value: std.json.Value) error{InvalidParams}!Expect {
    const object = switch (value) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    var keys = object.iterator();
    while (keys.next()) |entry| {
        if (!inList(&.{ "origin", "load_serial", "url", "recipient" }, entry.key_ptr.*)) return error.InvalidParams;
    }
    const text = struct {
        fn of(o: std.json.ObjectMap, key: []const u8) error{InvalidParams}![]const u8 {
            return switch (o.get(key) orelse return error.InvalidParams) {
                .string => |t| if (t.len > 0) t else error.InvalidParams,
                else => error.InvalidParams,
            };
        }
    };
    const load_serial: u64 = switch (object.get("load_serial") orelse return error.InvalidParams) {
        .integer => |n| std.math.cast(u64, n) orelse return error.InvalidParams,
        else => return error.InvalidParams,
    };
    const recipient: ?[]const u8 = if (object.get("recipient") != null) try text.of(object, "recipient") else null;
    if (recipient) |r| if (!isRecipientSlug(r)) return error.InvalidParams;
    return .{ .origin = try text.of(object, "origin"), .load_serial = load_serial, .url = try text.of(object, "url"), .recipient = recipient };
}

/// A LinkedIn profile slug: 1 to 100 of A-Z, a-z, 0-9, `_`, `.`, `%`, `-`.
fn isRecipientSlug(slug: []const u8) bool {
    if (slug.len == 0 or slug.len > 100) return false;
    for (slug) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '%' or c == '-')) return false;
    return true;
}

/// S8 phase A ("S8 in detail" decision 2): the bound window as the approval card showed it (its
/// origin and load_serial), read inside the flow's own ticket before its session gate, pacing
/// or any page input. The refusal, or null to go on. As for the verbs (RoseCat db43ca1): a stop,
/// then a check that used up the budget, then what the check found.
pub fn phaseA(gpa: std.mem.Allocator, ext: *engine_mod.External, expect: Expect, deadline_ms: u64) error{OutOfMemory}!?engine_mod.Outcome {
    const ids = ext.ids();
    var found: ?engine_mod.Outcome = switch (try ext.boundWindow(gpa, deadline_ms -| ext.nowMs())) {
        .refused => |refused| refused,
        .window => |window| blk: {
            defer window.deinit(gpa);
            break :blk try engine_mod.windowRefusal(gpa, window, .{ .origin = expect.origin, .load_serial = expect.load_serial }, ids);
        },
    };
    if (ext.cancelled() or ext.nowMs() >= deadline_ms) {
        if (found) |*f| f.deinit(gpa);
        if (ext.cancelled()) return try engine_mod.automationFailure(gpa, .cancelled, null, ids);
        return try engine_mod.automationFailure(gpa, .action_timeout, "expect_used_deadline", ids);
    }
    return found;
}

pub const Approval = struct {
    /// The one navigation the user approved, exactly.
    url: []const u8,
    /// That navigation was dispatched: no other navigation runs after it, even if it failed.
    navigated: bool = false,
    /// The window's load_serial once that navigation committed (phase C); null before it.
    load_serial: ?u64 = null,
    /// automation.js's token of the document it committed (phase C; owned by the runner).
    document_token: ?[]u8 = null,
    /// S8 decision 13: the recipient a conversation message's approval names (a LinkedIn slug).
    recipient: ?[]const u8 = null,
};

pub const Runner = struct {
    gpa: std.mem.Allocator,
    ext: *engine_mod.External,
    deadline_ms: u64,
    /// data.reason when the flow budget runs out (e.g. "x_flow_deadline").
    deadline_reason: []const u8,
    /// Called after every step that ran (telemetry).
    observer: ?StepObserver = null,
    last_result: ?engine_mod.Outcome = null,
    failure: ?engine_mod.Outcome = null,
    /// Set once the flow budget stopped a step, or a platform signal was
    /// detected: every later step fails too (no fallback probe may run, or
    /// reinterpret the stop; nothing is clicked after a detection).
    expired: bool = false,
    /// N20: the platform ("x", "linkedin", "instagram") whose rate-limit,
    /// CAPTCHA and checkpoint signals the page is scanned for (automation.js
    /// rateLimitScan): after every navigation; before the flow's first
    /// action, and before any action that follows an action (a click may
    /// open a limit dialog); after a failed step (to report the real
    /// cause); and in `finish` when an action ran since the last scan (a
    /// limit toast after the final click). A detection stops the flow with
    /// -32010 platform_rate_limited and `data.{signal, platform}`; nothing
    /// runs after it. Null: no scans (read-only flows never act or
    /// navigate, so they never scan either).
    platform: ?[]const u8 = null,
    /// An action or navigation ran since the last clean scan.
    scan_due: bool = false,
    clean_scans: u32 = 0,
    /// Steps run so far (the observer sees each one, in the same order).
    steps: u32 = 0,
    /// The index of the step whose own failure the runner holds; null when
    /// the held failure came from elsewhere (the flow's own refusal, an
    /// unusable answer, a platform signal, the budget, a cancellation).
    failed_step: ?u32 = null,
    /// S8: set for an approved real run; every step is checked against it.
    approval: ?Approval = null,
    /// S8 decision 13: the `options.guard` every later action of an approved run carries (owned
    /// JSON object); set by the flow per stage, never without an approval.
    guard: ?[]u8 = null,

    pub fn run(self: *Runner, method: []const u8, params_json: []const u8) error{OutOfMemory}!?[]const u8 {
        // No step starts without budget; a waitFor also needs room for the
        // engine's native grace on top of its (clamped) JS timeout.
        if (self.expired) return null;
        if (self.ext.cancelled()) return self.cancelStop();
        const needed: u64 = if (std.mem.eql(u8, method, "dom.waitFor")) engine_mod.wait_for_native_grace_ms else 0;
        if (self.remainingMs() <= needed) return self.deadlineStop();
        const action = isAction(method);
        if (self.approval != null and try self.approvalRefuses(method, params_json, action)) return null;
        var guarded: ?[]u8 = null;
        defer if (guarded) |g| self.gpa.free(g);
        if (action) if (self.guard) |guard| {
            guarded = (try withGuard(self.gpa, params_json, guard)) orelse {
                try self.malformed();
                return null;
            };
        };
        const sent_params = guarded orelse params_json;
        var clamped: ?[]u8 = null;
        defer if (clamped) |c| self.gpa.free(c);
        if (action and (self.scan_due or self.clean_scans == 0)) {
            if (try self.scan() == .detected) return null;
            if (self.ext.cancelled()) return self.cancelStop();
            // The scan took time: the action may only start with budget
            // left, and never with the timeout it was built with before.
            if (self.remainingMs() <= needed) return self.deadlineStop();
            clamped = try clampTimeouts(self.gpa, sent_params, self.remainingMs());
        }
        const started = self.ext.nowMs();
        const index = self.steps;
        self.steps += 1;
        const outcome = try self.ext.runCommand(self.gpa, method, clamped orelse sent_params);
        if (self.observer) |o| o.on_step(o.ctx, method, params_json, outcome == .result, self.ext.nowMs() -| started);
        switch (outcome) {
            .result => |json| {
                self.dropResult();
                self.last_result = outcome;
                // A click may open a dialog or navigate; scan before the next
                // action. After a navigation, scan now.
                if (action) self.scan_due = true;
                if (isNavigation(method)) {
                    if (self.approval != null and !try self.approvalCommitted()) return null;
                    self.scan_due = true;
                    const result = try self.scan();
                    if (result != .detected and self.ext.cancelled()) return self.cancelStop();
                    switch (result) {
                        .detected => return null,
                        // A required scan that could not run in the budget.
                        .unknown => if (self.remainingMs() == 0) return self.deadlineStop(),
                        .clean, .skipped => {},
                    }
                }
                return json;
            },
            .failure => {
                self.setFailure(outcome);
                self.failed_step = index;
                // A step that failed on a challenge or limit page: report that
                // (otherwise the step's own failure stands). Never after a
                // cancellation: no page work once the command is cancelled.
                const cancelled_step = outcome.failure.code == errors.downstreamCode(.cancelled);
                // A cancelled step stops the flow: no fallback probe either.
                // A cancellation is not the step's own failure: no step.
                if (cancelled_step) self.failed_step = null;
                if (cancelled_step or self.ext.cancelled()) {
                    self.expired = true;
                    return null;
                }
                if (self.platform != null) {
                    // A stop during this scan: -32012 is the answer. A signal
                    // the scan found first still wins (the page showed it).
                    if (try self.scan() != .detected and self.ext.cancelled()) return self.cancelStop();
                }
                return null;
            },
        }
    }

    /// S8 phase B, and phase C's guard before each later action: an approved run navigates only
    /// to its approved URL, once and before any other step, and acts only while the window still
    /// shows the document that navigation committed. True when it refused (the flow stops).
    fn approvalRefuses(self: *Runner, method: []const u8, params_json: []const u8, action: bool) error{OutOfMemory}!bool {
        const approval = self.approval.?;
        if (isNavigation(method)) {
            const approved = !approval.navigated and std.mem.eql(u8, method, "page.navigate") and try navigatesTo(self.gpa, params_json, approval.url);
            if (approved) {
                self.approval.?.navigated = true;
                return false;
            }
            return self.approvalStop(try engine_mod.automationFailure(self.gpa, .expectation_mismatch, "unapproved_navigation", self.ext.ids()));
        }
        // Until phase C has captured the approved navigation's document, nothing else runs, not even
        // a read (RoseCat 7155); after it, reads go on and every action is guarded.
        const serial = approval.load_serial orelse
            return self.approvalStop(try engine_mod.automationFailure(self.gpa, .expectation_mismatch, "unapproved_navigation", self.ext.ids()));
        if (!action) return false;
        return switch (try self.ext.boundWindow(self.gpa, self.remainingMs())) {
            .refused => |refused| self.approvalStop(refused),
            .window => |window| blk: {
                defer window.deinit(self.gpa);
                const refused = try engine_mod.windowRefusal(self.gpa, window, .{ .load_serial = serial }, self.ext.ids());
                if (refused) |r| break :blk self.approvalStop(r);
                break :blk try self.documentRefuses(approval.document_token.?);
            },
        };
    }

    /// The window still shows the document phase C captured: automation.js's token is the same.
    /// True when it refused.
    fn documentRefuses(self: *Runner, captured: []const u8) error{OutOfMemory}!bool {
        const token = try self.documentToken() orelse
            return self.approvalStop(try engine_mod.automationFailure(self.gpa, .expectation_mismatch, "document_token_unreadable", self.ext.ids()));
        defer self.gpa.free(token);
        if (std.mem.eql(u8, token, captured)) return false;
        return self.approvalStop(try engine_mod.automationFailure(self.gpa, .expectation_mismatch, "document_token_changed", self.ext.ids()));
    }

    /// automation.js's token of the current document (op documentToken, in the isolated world),
    /// owned; null when it could not be read.
    fn documentToken(self: *Runner) error{OutOfMemory}!?[]u8 {
        const timeout_ms = @min(scan_timeout_ms, self.remainingMs());
        if (timeout_ms == 0) return null;
        const ids = self.ext.ids();
        const arg = try std.json.Stringify.valueAlloc(self.gpa, .{
            .op = "documentToken",
            .trace_id = ids.trace_id,
            .parent_span_id = ids.parent_span_id,
            .command_id = ids.command_id,
        }, .{});
        defer self.gpa.free(arg);
        const text = self.ext.evalJson(self.gpa, .automation, script_command.handle_body, arg, timeout_ms) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer self.gpa.free(text);
        var answer = script_command.parseScriptResult(self.gpa, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedScriptResult => return null,
        };
        defer answer.deinit();
        if (!answer.ok) return null;
        const value = switch (answer.value) {
            .object => |o| o.get("documentToken") orelse return null,
            else => return null,
        };
        return switch (value) {
            .string => |t| if (t.len > 0) try self.gpa.dupe(u8, t) else null,
            else => null,
        };
    }

    /// S8 phase C, right after the approved navigation: it committed exactly the approved URL;
    /// its load_serial is captured for every later action. False when it refused.
    fn approvalCommitted(self: *Runner) error{OutOfMemory}!bool {
        const approval = &self.approval.?;
        switch (try self.ext.boundWindow(self.gpa, self.remainingMs())) {
            .refused => |refused| return !self.approvalStop(refused),
            .window => |window| {
                defer window.deinit(self.gpa);
                if (try engine_mod.windowRefusal(self.gpa, window, .{ .url = approval.url }, self.ext.ids())) |refused| return !self.approvalStop(refused);
                const token = try self.documentToken() orelse
                    return !self.approvalStop(try engine_mod.automationFailure(self.gpa, .expectation_mismatch, "document_token_unreadable", self.ext.ids()));
                approval.load_serial = window.load_serial;
                approval.document_token = token;
                return true;
            },
        }
    }

    /// The approval no longer holds: its refusal is the flow's answer and nothing runs after it.
    fn approvalStop(self: *Runner, refused: engine_mod.Outcome) bool {
        self.setFailure(refused);
        self.failed_step = null;
        self.expired = true;
        return true;
    }

    /// The command was cancelled (server stop): -32012, and the flow is
    /// stopped before any more page work.
    fn cancelStop(self: *Runner) error{OutOfMemory}!?[]const u8 {
        self.setFailure(try engine_mod.automationFailure(self.gpa, .cancelled, null, self.ext.ids()));
        self.expired = true;
        return null;
    }

    /// The flow budget is spent: action_timeout `deadline_reason`, and the
    /// flow is stopped.
    fn deadlineStop(self: *Runner) error{OutOfMemory}!?[]const u8 {
        self.setFailure(try engine_mod.automationFailure(self.gpa, .action_timeout, self.deadline_reason, self.ext.ids()));
        self.expired = true;
        return null;
    }

    const ScanResult = enum {
        /// No platform: scanning is off.
        skipped,
        clean,
        /// No evidence either way: no time left, the scan failed, or the
        /// script is not ready.
        unknown,
        /// A signal: -32010 is recorded and the flow is stopped.
        detected,
    };

    /// One rateLimitScan of the current page, bounded by the flow budget.
    /// Nothing is dispatched once the command is cancelled (callers check
    /// cancellation again after it returns).
    fn scan(self: *Runner) error{OutOfMemory}!ScanResult {
        const platform = self.platform orelse return .skipped;
        if (self.ext.cancelled()) return .unknown;
        const timeout_ms = @min(scan_timeout_ms, self.remainingMs());
        if (timeout_ms == 0) return .unknown;
        const ids = self.ext.ids();
        const arg = try std.json.Stringify.valueAlloc(self.gpa, .{
            .op = "rateLimitScan",
            .options = .{ .platform = platform },
            .trace_id = ids.trace_id,
            .parent_span_id = ids.parent_span_id,
            .command_id = ids.command_id,
        }, .{});
        defer self.gpa.free(arg);
        const text = self.ext.evalJson(self.gpa, .automation, script_command.handle_body, arg, timeout_ms) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .unknown,
        };
        defer self.gpa.free(text);
        var answer = script_command.parseScriptResult(self.gpa, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedScriptResult => return .unknown,
        };
        defer answer.deinit();
        if (answer.ok) {
            self.scan_due = false;
            self.clean_scans += 1;
            self.scanSpan(platform, "none");
            return .clean;
        }
        if (!std.mem.eql(u8, answer.error_name orelse "", errors.name(.platform_rate_limited))) return .unknown;
        const signal = signalOf(&answer) orelse "unknown";
        self.scanSpan(platform, signal);
        const Data = struct { signal: []const u8, platform: []const u8, trace_id: []const u8, command_id: []const u8 };
        self.setFailure(.{ .failure = .{
            .code = errors.downstreamCode(.platform_rate_limited),
            .message = errors.name(.platform_rate_limited),
            .data_json = try std.json.Stringify.valueAlloc(self.gpa, Data{ .signal = signal, .platform = platform, .trace_id = ids.trace_id, .command_id = ids.command_id }, .{}),
        } });
        self.expired = true;
        return .detected;
    }

    /// Before a flow reports success: scan once more if it acted since the
    /// last scan. False when the flow must not report success (the runner
    /// holds the failure): a signal (-32010), or the scan could not run and
    /// the budget is spent (action_timeout `deadline_reason`).
    pub fn finish(self: *Runner) error{OutOfMemory}!bool {
        if (self.expired) return false;
        if (self.ext.cancelled()) return (try self.cancelStop()) != null;
        if (!self.scan_due) return true;
        const result = try self.scan();
        if (result != .detected and self.ext.cancelled()) return (try self.cancelStop()) != null;
        return switch (result) {
            .detected => false,
            .unknown => if (self.remainingMs() == 0) (try self.deadlineStop()) != null else true,
            .clean, .skipped => true,
        };
    }

    fn scanSpan(self: *Runner, platform: []const u8, signal: []const u8) void {
        self.ext.childSpan("automation.rate_limit_scan", &.{
            .{ .key = "platform", .value = platform },
            .{ .key = "signal", .value = signal },
        });
    }

    pub fn nowMs(self: *const Runner) u64 {
        return self.ext.nowMs();
    }

    pub fn remainingMs(self: *const Runner) u64 {
        return self.deadline_ms -| self.ext.nowMs();
    }

    pub fn pause(self: *Runner, ms: u64) bool {
        if (self.ext.pause(ms)) return true;
        const cancelled = engine_mod.automationFailure(self.gpa, .cancelled, null, self.ext.ids()) catch {
            self.clearFailure();
            return false;
        };
        self.setFailure(cancelled);
        return false;
    }

    /// The latest step succeeded but its answer was unusable.
    /// A guard mark (router.Guard.Mark's wire form).
    pub const Mark = struct {
        selector: []const u8,
        attribute: ?[]const u8 = null,
        path: ?bool = null,
        value: []const u8,
    };

    /// S8 decision 13, stage 1 (approved runs only): every later action requires the page at
    /// exactly `path`, the profile's `owner` mark (from the approval, never from the page;
    /// RoseCat 8b05366) and its own target.
    pub fn guardOpener(self: *Runner, path: []const u8, owner: Mark) error{OutOfMemory}!void {
        if (self.approval == null) return;
        self.setGuard(try std.json.Stringify.valueAlloc(self.gpa, .{ .path = path, .marks = .{owner}, .target = true }, .{ .emit_null_optional_fields = false }));
    }

    /// S8 decision 13, stage 2 (approved runs only): every later action requires the one visible
    /// `header_link` (the open thread's header link) to point at exactly `path`, and its own
    /// target.
    pub fn guardThread(self: *Runner, header_link: []const u8, path: []const u8) error{OutOfMemory}!void {
        if (self.approval == null) return;
        const mark = .{ .selector = header_link, .attribute = "href", .path = true, .value = path };
        self.setGuard(try std.json.Stringify.valueAlloc(self.gpa, .{ .marks = .{mark}, .target = true }, .{}));
    }

    /// The recipient an approved conversation message's approval names, else null.
    pub fn approvedRecipient(self: *const Runner) ?[]const u8 {
        const approval = self.approval orelse return null;
        return approval.recipient;
    }

    fn setGuard(self: *Runner, guard: []u8) void {
        if (self.guard) |old| self.gpa.free(old);
        self.guard = guard;
    }

    pub fn malformed(self: *Runner) error{OutOfMemory}!void {
        self.setFailure(try internalFailure(self.gpa, self.ext.ids()));
    }

    pub fn notFound(self: *Runner, reason: []const u8) error{OutOfMemory}!void {
        self.setFailure(try engine_mod.automationFailure(self.gpa, .element_not_found, reason, self.ext.ids()));
    }

    fn setFailure(self: *Runner, outcome: engine_mod.Outcome) void {
        self.clearFailure();
        self.failure = outcome;
        self.failed_step = null;
    }

    fn clearFailure(self: *Runner) void {
        if (self.failure) |*old| old.deinit(self.gpa);
        self.failure = null;
    }

    fn dropResult(self: *Runner) void {
        if (self.last_result) |*old| old.deinit(self.gpa);
        self.last_result = null;
    }

    pub fn deinit(self: *Runner) void {
        if (self.guard) |g| self.gpa.free(g);
        self.dropResult();
        if (self.failure) |*f| f.deinit(self.gpa);
        if (self.approval) |a| if (a.document_token) |t| self.gpa.free(t);
    }

    /// Hands the recorded failure to the caller. src/x.zig records one for
    /// every null it returns; if a flow ever stops without one, that is an
    /// internal error (still with ids), never a stale or missing failure.
    pub fn takeFailure(self: *Runner) error{OutOfMemory}!engine_mod.Outcome {
        const f = self.failure orelse return internalFailure(self.gpa, self.ext.ids());
        self.failure = null;
        return f;
    }
};

/// What a dry run reports about the daily cap it bypassed: the actions left
/// and, at the cap, the error the real call would give.
pub const CapNote = struct { remaining: u32, cap_reason: []const u8 };

/// A dry run's result (`{"dry_run":true,...,"checks":[...]}`, from
/// flow_steps.dryRunResult) with the route's checks added (owned): the
/// runner's clean rate-limit scans, and a `daily_cap` note. Anything else
/// comes back unchanged (a copy).
pub fn withRouteChecks(gpa: std.mem.Allocator, result_json: []const u8, clean_scans: u32, cap: CapNote) error{OutOfMemory}![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, result_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return gpa.dupe(u8, result_json),
    };
    defer parsed.deinit();
    const checks = switch (parsed.value) {
        .object => |*o| o.getPtr("checks") orelse return gpa.dupe(u8, result_json),
        else => return gpa.dupe(u8, result_json),
    };
    switch (checks.*) {
        .array => |*list| {
            const check = try std.json.ObjectMap.init(parsed.arena.allocator(), &.{ "name", "result", "count" }, &.{
                .{ .string = "rate_limit_scans" },
                .{ .string = "pass" },
                .{ .integer = clean_scans },
            });
            try list.append(.{ .object = check });
            const arena = parsed.arena.allocator();
            const reason = if (cap.remaining == 0)
                try std.fmt.allocPrint(arena, "the real call would be refused now: {s}", .{cap.cap_reason})
            else
                "a dry run is not counted";
            try list.append(.{ .object = try std.json.ObjectMap.init(arena, &.{ "name", "result", "count", "reason" }, &.{
                .{ .string = "daily_cap" },
                .{ .string = "note" },
                .{ .integer = cap.remaining },
                .{ .string = reason },
            }) });
        },
        else => return gpa.dupe(u8, result_json),
    }
    return std.json.Stringify.valueAlloc(gpa, parsed.value, .{});
}

/// `outcome` with `"step": step` added to its failure data (a JSON object;
/// anything else is left as it is).
pub fn withFailedStep(gpa: std.mem.Allocator, outcome: engine_mod.Outcome, step: []const u8) error{OutOfMemory}!engine_mod.Outcome {
    var failure = switch (outcome) {
        .failure => |f| f,
        .result => return outcome,
    };
    const data_json = failure.data_json orelse return outcome;
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, data_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return outcome,
    };
    defer parsed.deinit();
    switch (parsed.value) {
        .object => |*o| try o.put(parsed.arena.allocator(), "step", .{ .string = step }),
        else => return outcome,
    }
    const updated = try std.json.Stringify.valueAlloc(gpa, parsed.value, .{});
    gpa.free(data_json);
    failure.data_json = updated;
    return .{ .failure = failure };
}

/// `params_json` with its `timeout_ms` and `options.timeout_ms` lowered to
/// at most `max_ms`; null when nothing needed lowering (or the params are
/// not an object).
/// `params_json` with `options.guard` set to `guard_json` (owned), or null when either is not a
/// JSON object.
fn withGuard(gpa: std.mem.Allocator, params_json: []const u8, guard_json: []const u8) error{OutOfMemory}!?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, params_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    const arena = parsed.arena.allocator();
    const guard = std.json.parseFromSliceLeaky(std.json.Value, arena, guard_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (guard != .object) return null;
    var root = switch (parsed.value) {
        .object => |*o| o,
        else => return null,
    };
    const options = try root.getOrPut(arena, "options");
    if (!options.found_existing) options.value_ptr.* = .{ .object = .empty };
    switch (options.value_ptr.*) {
        .object => |*o| try o.put(arena, "guard", guard),
        else => return null,
    }
    return try std.json.Stringify.valueAlloc(gpa, parsed.value, .{});
}

fn clampTimeouts(gpa: std.mem.Allocator, params_json: []const u8, max_ms: u64) error{OutOfMemory}!?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, params_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    var root = switch (parsed.value) {
        .object => |*o| o,
        else => return null,
    };
    var changed = lower(root, max_ms);
    if (root.getPtr("options")) |options| switch (options.*) {
        .object => |*o| changed = lower(o, max_ms) or changed,
        else => {},
    };
    if (!changed) return null;
    return try std.json.Stringify.valueAlloc(gpa, parsed.value, .{});
}

fn lower(object: *std.json.ObjectMap, max_ms: u64) bool {
    const value = object.getPtr("timeout_ms") orelse return false;
    const current: u64 = switch (value.*) {
        .integer => |n| if (n >= 0) @intCast(n) else return false,
        else => return false,
    };
    if (current <= max_ms) return false;
    value.* = .{ .integer = @intCast(@min(max_ms, std.math.maxInt(i64))) };
    return true;
}

/// Steps that act on the page (a rate-limit scan runs before them).
fn isAction(method: []const u8) bool {
    const actions = [_][]const u8{ "dom.click", "dom.fill", "dom.type", "dom.press", "dom.selectOption", "dom.setInputFiles", "dom.hover", "dom.scroll" };
    for (actions) |name| if (std.mem.eql(u8, name, method)) return true;
    return false;
}

/// A page.navigate step's `url` is exactly `url`.
fn navigatesTo(gpa: std.mem.Allocator, params_json: []const u8, url: []const u8) error{OutOfMemory}!bool {
    const parsed = std.json.parseFromSlice(struct { url: []const u8 = "" }, gpa, params_json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    return std.mem.eql(u8, parsed.value.url, url);
}

fn isNavigation(method: []const u8) bool {
    return std.mem.eql(u8, method, "page.navigate") or std.mem.eql(u8, method, "page.reload");
}

/// `data.signal` of a detection: a short identifier from automation.js's
/// fixed kinds (anything else is reported as "unknown", never echoed).
fn signalOf(answer: *const script_command.ScriptResult) ?[]const u8 {
    const data = answer.data orelse return null;
    const object = switch (data) {
        .object => |o| o,
        else => return null,
    };
    const signal = switch (object.get("signal") orelse return null) {
        .string => |text| text,
        else => return null,
    };
    if (signal.len == 0 or signal.len > 32) return null;
    for (signal) |c| if (!std.ascii.isLower(c) and c != '_') return null;
    return signal;
}

/// -32603 "Unexpected page answer" with `data.{trace_id, command_id}`.
pub fn internalFailure(gpa: std.mem.Allocator, ids: script_command.Ids) error{OutOfMemory}!engine_mod.Outcome {
    const Data = struct { trace_id: []const u8, command_id: []const u8 };
    return .{ .failure = .{
        .code = engine_mod.internal_error_code,
        .message = "Unexpected page answer",
        .data_json = try std.json.Stringify.valueAlloc(gpa, Data{ .trace_id = ids.trace_id, .command_id = ids.command_id }, .{}),
    } };
}

fn inList(list: []const []const u8, item: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, item)) return true;
    }
    return false;
}
