//! Automation engine: runs one parsed router command against a PagePort and
//! turns the outcome into a JSON-RPC result or an automation error.
//!
//! The engine owns deadlines and error mapping. It never imports GTK or any
//! other platform type; everything page-side goes through `PagePort`.
const std = @import("std");
const errors = @import("error.zig");
const router = @import("router.zig");
const page_port = @import("page_port.zig");
const script_command = @import("script_command.zig");

pub const default_timeout_ms: u64 = 30000;

/// M7: delay between retries of a retryable script failure.
pub const poll_interval_ms: u64 = 16;

/// Script `data.reason` values that can never succeed on retry, even though
/// automation.js marks them retryable.
const non_retryable_reasons = [_][]const u8{ "malformed_selector", "malformed_command", "unknown_op", "missing_attribute_name" };

/// JSON-RPC "Internal error"; used for failures outside the automation
/// taxonomy (native eval failure, malformed script answer, JS exception).
pub const internal_error_code: i64 = -32603;

/// Monotonic milliseconds plus a sleeper, injectable for tests.
pub const Clock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        nowMs: *const fn (ptr: *anyopaque) u64,
        sleepMs: *const fn (ptr: *anyopaque, ms: u64) void,
    };

    pub fn nowMs(self: Clock) u64 {
        return self.vtable.nowMs(self.ptr);
    }

    pub fn sleepMs(self: Clock, ms: u64) void {
        self.vtable.sleepMs(self.ptr, ms);
    }
};

/// Real clock backed by `std.Io` (monotonic `.awake` clock).
pub const IoClock = struct {
    io: std.Io,

    pub fn clock(self: *IoClock) Clock {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Clock.VTable{ .nowMs = nowMs, .sleepMs = sleepMs };

    fn nowMs(ptr: *anyopaque) u64 {
        const self: *IoClock = @ptrCast(@alignCast(ptr));
        const ms = std.Io.Clock.now(.awake, self.io).toMilliseconds();
        return if (ms < 0) 0 else @intCast(ms);
    }

    fn sleepMs(ptr: *anyopaque, ms: u64) void {
        const self: *IoClock = @ptrCast(@alignCast(ptr));
        self.io.sleep(.fromMilliseconds(@intCast(@min(ms, std.math.maxInt(i64)))), .awake) catch {};
    }
};

pub const Failure = struct {
    code: i64,
    /// Static string: the automation error name, or a fixed internal message.
    message: []const u8,
    /// Optional JSON object for the JSON-RPC `error.data` member.
    data_json: ?[]u8 = null,
};

pub const Outcome = union(enum) {
    /// JSON text for the JSON-RPC `result` member.
    result: []u8,
    failure: Failure,

    pub fn deinit(self: *Outcome, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .result => |json| gpa.free(json),
            .failure => |failure| if (failure.data_json) |data| gpa.free(data),
        }
        self.* = undefined;
    }
};

/// Extra native deadline on top of a waitFor's own timeout, so the script's
/// authoritative JS timeout settles before the native call gives up.
pub const wait_for_native_grace_ms: u64 = 1000;

/// Upper bound for any command deadline. JS timers overflow above 2^31-1 ms
/// and the native ABI takes a 32-bit timeout, so larger values are clamped
/// (leaving room for the waitFor grace).
pub const max_timeout_ms: u64 = std.math.maxInt(i32) - wait_for_native_grace_ms;

pub const Engine = struct {
    port: page_port.PagePort,
    clock: Clock,
    next_command_id: std.atomic.Value(u64) = .init(1),

    pub fn init(port: page_port.PagePort, clock: Clock) Engine {
        return .{ .port = port, .clock = clock };
    }

    pub fn execute(self: *Engine, gpa: std.mem.Allocator, command: *const router.ParsedCommand) error{OutOfMemory}!Outcome {
        var ids_buf: IdsBuf = undefined;
        const ids = self.nextIds(&ids_buf);
        const timeout_ms = @min(command.timeout_ms orelse default_timeout_ms, max_timeout_ms);
        return switch (command.verb) {
            .page_url => {
                const value = self.port.url(gpa, timeout_ms) catch |err| return portFailure(gpa, err, .action, ids);
                defer gpa.free(value);
                return stringResult(gpa, "url", value);
            },
            .page_title => {
                const value = self.port.title(gpa, timeout_ms) catch |err| return portFailure(gpa, err, .action, ids);
                defer gpa.free(value);
                return stringResult(gpa, "title", value);
            },
            .page_navigate => {
                self.port.navigate(command.url.?, timeout_ms) catch |err| return portFailure(gpa, err, .navigation, ids);
                return okResult(gpa);
            },
            .page_reload => {
                self.port.reload(timeout_ms) catch |err| return portFailure(gpa, err, .navigation, ids);
                return okResult(gpa);
            },
            .page_evaluate => self.evaluate(gpa, command.expression.?, timeout_ms, ids),
            .page_screenshot => .{ .failure = .{ .code = internal_error_code, .message = "page.screenshot is not supported" } },
            .dom_query,
            .dom_click,
            .dom_fill,
            .dom_type,
            .dom_get_text,
            .dom_get_attribute,
            .dom_wait_for,
            => self.runDom(gpa, command, timeout_ms, ids),
        };
    }

    fn evaluate(self: *Engine, gpa: std.mem.Allocator, expression: []const u8, timeout_ms: u64, ids: script_command.Ids) error{OutOfMemory}!Outcome {
        const body = try script_command.buildEvaluateBody(gpa, expression);
        defer gpa.free(body);
        const text = self.port.evalJson(gpa, .page, body, "null", timeout_ms) catch |err| return portFailure(gpa, err, .action, ids);
        defer gpa.free(text);

        var script_result = script_command.parseScriptResult(gpa, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedScriptResult => return malformedResult(),
        };
        defer script_result.deinit();

        if (!script_result.ok) return scriptFailure(gpa, &script_result, ids);
        const value_json = try std.json.Stringify.valueAlloc(gpa, script_result.value, .{});
        defer gpa.free(value_json);
        return .{ .result = try std.fmt.allocPrint(gpa, "{{\"result\":{s}}}", .{value_json}) };
    }

    fn runDom(self: *Engine, gpa: std.mem.Allocator, command: *const router.ParsedCommand, timeout_ms: u64, ids: script_command.Ids) error{OutOfMemory}!Outcome {
        const deadline = self.clock.nowMs() +| timeout_ms;
        // One monotonic attempt counter for the whole command, including the
        // per-character ops of a delayed dom.type.
        var attempts: u32 = 0;
        if (command.verb == .dom_type and command.text.?.len > 0) {
            if (command.delay_ms) |delay_ms| {
                if (delay_ms > 0) return self.typeWithDelay(gpa, command, delay_ms, deadline, ids, &attempts);
            }
        }
        return self.runDomUntil(gpa, command, deadline, ids, &attempts);
    }

    /// dom.type with delay_ms: one `type` op per character (UTF-8 code
    /// point), sleeping delay_ms between characters. Stops at the first
    /// failing character; never sleeps past the command deadline.
    fn typeWithDelay(self: *Engine, gpa: std.mem.Allocator, command: *const router.ParsedCommand, delay_ms: u64, deadline: u64, ids: script_command.Ids, attempts: *u32) error{OutOfMemory}!Outcome {
        const view = std.unicode.Utf8View.init(command.text.?) catch return self.runDomUntil(gpa, command, deadline, ids, attempts);
        var characters = view.iterator();
        var first = true;
        while (characters.nextCodepointSlice()) |character| {
            if (!first) {
                const now = self.clock.nowMs();
                if (now +| delay_ms >= deadline) return timeoutWithReason(gpa, .action_timeout, "type_delay_exceeds_timeout", ids, attempts.*);
                self.clock.sleepMs(delay_ms);
            }
            first = false;

            var single = command.*;
            single.text = character;
            var outcome = try self.runDomUntil(gpa, &single, deadline, ids, attempts);
            switch (outcome) {
                .failure => return outcome,
                .result => outcome.deinit(gpa),
            }
        }
        return okResult(gpa);
    }

    /// M7 retry loop: retryable script failures are retried every
    /// `poll_interval_ms` while a full poll interval still fits before
    /// `deadline`; no attempt starts at or after the deadline and no native
    /// call is given more than the remaining time. waitFor owns its own wait
    /// in JS, so only a missing script is retried for it.
    fn runDomUntil(self: *Engine, gpa: std.mem.Allocator, command: *const router.ParsedCommand, deadline: u64, base_ids: script_command.Ids, attempts: *u32) error{OutOfMemory}!Outcome {
        const is_wait = command.verb == .dom_wait_for;
        var ids = base_ids;
        var last: LastFailure = .{};
        while (true) {
            ids.attempt_index = attempts.*;
            attempts.* += 1;
            const remaining = deadline -| self.clock.nowMs();
            // waitFor: the script's JS timeout is authoritative; the native
            // call gets extra grace on top so JS settles first.
            const script_timeout: ?u64 = if (is_wait) remaining else null;
            const native_timeout = if (is_wait) remaining + wait_for_native_grace_ms else @max(remaining, 1);

            const command_json = script_command.buildCommandJson(gpa, command, ids, script_timeout) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NotADomCommand => unreachable,
            };
            defer gpa.free(command_json);

            const text = self.port.evalJson(gpa, .automation, script_command.handle_body, command_json, native_timeout) catch |err| return portFailure(gpa, err, .action, ids);
            defer gpa.free(text);

            var script_result = script_command.parseScriptResult(gpa, text) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.MalformedScriptResult => return malformedResult(),
            };
            defer script_result.deinit();

            if (script_result.ok) {
                return .{ .result = try std.json.Stringify.valueAlloc(gpa, script_result.value, .{}) };
            }
            if (!shouldRetry(&script_result, is_wait)) return scriptFailure(gpa, &script_result, ids);
            last.record(&script_result);

            const now = self.clock.nowMs();
            if (now +| poll_interval_ms >= deadline) return deadlineFailure(gpa, &last, ids, attempts.*);
            self.clock.sleepMs(poll_interval_ms);
        }
    }

    const IdsBuf = struct {
        trace: [32]u8,
        span: [16]u8,
        command: [24]u8,
    };

    fn nextIds(self: *Engine, buf: *IdsBuf) script_command.Ids {
        const n = self.next_command_id.fetchAdd(1, .monotonic);
        const seed = self.clock.nowMs();
        const hi = std.hash.Wyhash.hash(seed, std.mem.asBytes(&n));
        const lo = std.hash.Wyhash.hash(hi, std.mem.asBytes(&seed));
        const span = std.hash.Wyhash.hash(lo, std.mem.asBytes(&n));
        return .{
            .trace_id = std.fmt.bufPrint(&buf.trace, "{x:0>16}{x:0>16}", .{ hi, lo }) catch unreachable,
            .parent_span_id = std.fmt.bufPrint(&buf.span, "{x:0>16}", .{span}) catch unreachable,
            .command_id = std.fmt.bufPrint(&buf.command, "cmd-{d}", .{n}) catch unreachable,
        };
    }
};

const PortContext = enum { action, navigation };

fn portFailure(gpa: std.mem.Allocator, err: page_port.PortError, context: PortContext, ids: script_command.Ids) error{OutOfMemory}!Outcome {
    const automation_error: errors.AutomationError = switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EvalFailed => return .{ .failure = .{ .code = internal_error_code, .message = "Evaluation failed" } },
        error.NoPage => .session_invalid,
        error.Cancelled => .cancelled,
        error.NavigationFailed => .navigation_failed,
        error.Timeout => switch (context) {
            .action => .action_timeout,
            .navigation => .navigation_timeout,
        },
    };
    return automationFailure(gpa, automation_error, null, ids);
}

/// Automation errors carry `data.{reason?,trace_id,command_id}`; the SDKs read
/// trace_id/command_id from there.
fn automationFailure(gpa: std.mem.Allocator, automation_error: errors.AutomationError, reason: ?[]const u8, ids: script_command.Ids) error{OutOfMemory}!Outcome {
    const data = AutomationErrorData{ .reason = reason, .trace_id = ids.trace_id, .command_id = ids.command_id };
    return .{ .failure = .{
        .code = errors.downstreamCode(automation_error),
        .message = errors.name(automation_error),
        .data_json = try std.json.Stringify.valueAlloc(gpa, data, .{ .emit_null_optional_fields = false }),
    } };
}

const AutomationErrorData = struct {
    reason: ?[]const u8 = null,
    /// For action_timeout: the last retryable automation error observed.
    last_error: ?[]const u8 = null,
    /// For deadline failures: how many attempts ran.
    attempts: ?u32 = null,
    trace_id: []const u8,
    command_id: []const u8,
};

fn shouldRetry(script_result: *const script_command.ScriptResult, is_wait: bool) bool {
    const error_name = script_result.error_name.?;
    if (std.mem.eql(u8, error_name, script_command.script_not_ready)) return true;
    if (is_wait or !script_result.retryable) return false;
    const automation_error = errors.fromName(error_name) catch return false;
    if (!errors.isRetryable(automation_error)) return false;
    const reason = script_result.reason orelse return true;
    for (non_retryable_reasons) |fatal| {
        if (std.mem.eql(u8, reason, fatal)) return false;
    }
    return true;
}

/// Copy of the last retryable failure (the script result it came from is
/// freed every attempt).
const LastFailure = struct {
    automation_error: errors.AutomationError = .element_not_found,
    reason_buf: [64]u8 = undefined,
    reason_len: usize = 0,

    /// Keeps the most specific evidence: once a match failed an
    /// actionability check, a later "not found" does not erase it.
    fn record(self: *LastFailure, script_result: *const script_command.ScriptResult) void {
        const error_name = script_result.error_name.?;
        const observed = errors.fromName(error_name) catch .element_not_found;
        if (observed == .element_not_found and self.automation_error != .element_not_found) return;
        self.automation_error = observed;
        const text = script_result.reason orelse error_name;
        self.reason_len = @min(text.len, self.reason_buf.len);
        @memcpy(self.reason_buf[0..self.reason_len], text[0..self.reason_len]);
    }

    fn reason(self: *const LastFailure) ?[]const u8 {
        return if (self.reason_len == 0) null else self.reason_buf[0..self.reason_len];
    }
};

fn timeoutWithReason(gpa: std.mem.Allocator, automation_error: errors.AutomationError, reason: []const u8, ids: script_command.Ids, attempts: u32) error{OutOfMemory}!Outcome {
    const data = AutomationErrorData{ .reason = reason, .attempts = attempts, .trace_id = ids.trace_id, .command_id = ids.command_id };
    return .{ .failure = .{
        .code = errors.downstreamCode(automation_error),
        .message = errors.name(automation_error),
        .data_json = try std.json.Stringify.valueAlloc(gpa, data, .{ .emit_null_optional_fields = false }),
    } };
}

/// Deadline reached while retrying: never matched -> element_not_found;
/// matched but never actionable -> action_timeout carrying the last error.
fn deadlineFailure(gpa: std.mem.Allocator, last: *const LastFailure, ids: script_command.Ids, attempts: u32) error{OutOfMemory}!Outcome {
    const timed_out_error: errors.AutomationError = if (last.automation_error == .element_not_found) .element_not_found else .action_timeout;
    const data = AutomationErrorData{
        .reason = last.reason(),
        .last_error = if (timed_out_error == .action_timeout) errors.name(last.automation_error) else null,
        .attempts = attempts,
        .trace_id = ids.trace_id,
        .command_id = ids.command_id,
    };
    return .{ .failure = .{
        .code = errors.downstreamCode(timed_out_error),
        .message = errors.name(timed_out_error),
        .data_json = try std.json.Stringify.valueAlloc(gpa, data, .{ .emit_null_optional_fields = false }),
    } };
}

fn malformedResult() Outcome {
    return .{ .failure = .{ .code = internal_error_code, .message = "Malformed script result" } };
}

fn scriptFailure(gpa: std.mem.Allocator, script_result: *const script_command.ScriptResult, ids: script_command.Ids) error{OutOfMemory}!Outcome {
    const error_name = script_result.error_name.?;
    if (std.mem.eql(u8, error_name, script_command.script_exception)) {
        return .{ .failure = .{
            .code = internal_error_code,
            .message = script_command.script_exception,
            .data_json = try exceptionData(gpa, script_result),
        } };
    }
    if (std.mem.eql(u8, error_name, script_command.script_not_ready)) {
        return automationFailure(gpa, .element_not_found, script_command.script_not_ready, ids);
    }
    const automation_error = errors.fromName(error_name) catch {
        return .{ .failure = .{ .code = internal_error_code, .message = "Internal error" } };
    };
    return automationFailure(gpa, automation_error, script_result.reason, ids);
}

/// `{"name":<exception class>}` only; never the exception message.
fn exceptionData(gpa: std.mem.Allocator, script_result: *const script_command.ScriptResult) error{OutOfMemory}!?[]u8 {
    const data = script_result.data orelse return null;
    const obj = switch (data) {
        .object => |o| o,
        else => return null,
    };
    const exception_name = switch (obj.get("name") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    return try std.fmt.allocPrint(gpa, "{{\"name\":{f}}}", .{std.json.fmt(exception_name, .{})});
}

fn stringResult(gpa: std.mem.Allocator, comptime key: []const u8, value: []const u8) error{OutOfMemory}!Outcome {
    return .{ .result = try std.fmt.allocPrint(gpa, "{{\"" ++ key ++ "\":{f}}}", .{std.json.fmt(value, .{})}) };
}

fn okResult(gpa: std.mem.Allocator) error{OutOfMemory}!Outcome {
    return .{ .result = try gpa.dupe(u8, "{\"ok\":true}") };
}
