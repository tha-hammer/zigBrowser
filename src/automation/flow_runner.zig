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
        const needed: u64 = if (std.mem.eql(u8, method, "dom.waitFor")) engine_mod.wait_for_native_grace_ms else 0;
        if (self.remainingMs() <= needed) {
            self.setFailure(try engine_mod.automationFailure(self.gpa, .action_timeout, self.deadline_reason, self.ext.ids()));
            self.expired = true;
            return null;
        }
        const action = isAction(method);
        if (action and (self.scan_due or self.clean_scans == 0) and !(try self.scanClean())) return null;
        const started = self.ext.nowMs();
        const outcome = try self.ext.runCommand(self.gpa, method, params_json);
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
                    if (!(try self.scanClean())) return null;
                }
                return json;
            },
            .failure => {
                self.setFailure(outcome);
                // A step that failed on a challenge or limit page: report that.
                if (self.platform != null) _ = try self.scanClean();
                return null;
            },
        }
    }

    /// One rateLimitScan of the current page. True when the flow may go on:
    /// a clean page, no platform, or no evidence (no time left, the scan
    /// itself failed, the script is not ready yet). False after recording
    /// -32010 for a detected signal (the flow is stopped).
    fn scanClean(self: *Runner) error{OutOfMemory}!bool {
        const platform = self.platform orelse return true;
        const timeout_ms = @min(scan_timeout_ms, self.remainingMs());
        if (timeout_ms == 0) return true;
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
            else => return true,
        };
        defer self.gpa.free(text);
        var answer = script_command.parseScriptResult(self.gpa, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedScriptResult => return true,
        };
        defer answer.deinit();
        if (answer.ok) {
            self.scan_due = false;
            self.clean_scans += 1;
            self.scanSpan(platform, "none");
            return true;
        }
        if (!std.mem.eql(u8, answer.error_name orelse "", errors.name(.platform_rate_limited))) return true;
        const signal = signalOf(&answer) orelse "unknown";
        self.scanSpan(platform, signal);
        const Data = struct { signal: []const u8, platform: []const u8, trace_id: []const u8, command_id: []const u8 };
        self.setFailure(.{ .failure = .{
            .code = errors.downstreamCode(.platform_rate_limited),
            .message = errors.name(.platform_rate_limited),
            .data_json = try std.json.Stringify.valueAlloc(self.gpa, Data{ .signal = signal, .platform = platform, .trace_id = ids.trace_id, .command_id = ids.command_id }, .{}),
        } });
        self.expired = true;
        return false;
    }

    /// Before a flow reports success: scan once more if it acted since the
    /// last scan. False after recording -32010 (report runner's failure).
    pub fn finish(self: *Runner) error{OutOfMemory}!bool {
        if (self.expired or !self.scan_due) return !self.expired;
        return self.scanClean();
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
