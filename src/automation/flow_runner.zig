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

    pub fn run(self: *Runner, method: []const u8, params_json: []const u8) error{OutOfMemory}!?[]const u8 {
        // No step starts without budget; a waitFor also needs room for the
        // engine's native grace on top of its (clamped) JS timeout.
        if (self.expired) return null;
        if (self.ext.cancelled()) return self.cancelStop();
        const needed: u64 = if (std.mem.eql(u8, method, "dom.waitFor")) engine_mod.wait_for_native_grace_ms else 0;
        if (self.remainingMs() <= needed) return self.deadlineStop();
        const action = isAction(method);
        var clamped: ?[]u8 = null;
        defer if (clamped) |c| self.gpa.free(c);
        if (action and (self.scan_due or self.clean_scans == 0)) {
            if (try self.scan() == .detected) return null;
            if (self.ext.cancelled()) return self.cancelStop();
            // The scan took time: the action may only start with budget
            // left, and never with the timeout it was built with before.
            if (self.remainingMs() <= needed) return self.deadlineStop();
            clamped = try clampTimeouts(self.gpa, params_json, self.remainingMs());
        }
        const started = self.ext.nowMs();
        const outcome = try self.ext.runCommand(self.gpa, method, clamped orelse params_json);
        if (self.observer) |o| o.on_step(o.ctx, method, params_json, outcome == .result, self.ext.nowMs() -| started);
        switch (outcome) {
            .result => |json| {
                self.dropResult();
                self.last_result = outcome;
                // A click may open a dialog or navigate; scan before the next
                // action. After a navigation, scan now.
                if (action) self.scan_due = true;
                if (isNavigation(method)) {
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
                // A step that failed on a challenge or limit page: report that
                // (otherwise the step's own failure stands). Never after a
                // cancellation: no page work once the command is cancelled.
                const cancelled_step = outcome.failure.code == errors.downstreamCode(.cancelled);
                // A cancelled step stops the flow: no fallback probe either.
                if (cancelled_step or self.ext.cancelled()) {
                    self.expired = true;
                    return null;
                }
                if (self.platform != null) _ = try self.scan();
                return null;
            },
        }
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
    pub fn malformed(self: *Runner) error{OutOfMemory}!void {
        self.setFailure(try internalFailure(self.gpa, self.ext.ids()));
    }

    pub fn notFound(self: *Runner, reason: []const u8) error{OutOfMemory}!void {
        self.setFailure(try engine_mod.automationFailure(self.gpa, .element_not_found, reason, self.ext.ids()));
    }

    fn setFailure(self: *Runner, outcome: engine_mod.Outcome) void {
        self.clearFailure();
        self.failure = outcome;
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
        self.dropResult();
        if (self.failure) |*f| f.deinit(self.gpa);
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

/// `params_json` with its `timeout_ms` and `options.timeout_ms` lowered to
/// at most `max_ms`; null when nothing needed lowering (or the params are
/// not an object).
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
