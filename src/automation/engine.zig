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
        self.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
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
        const timeout_ms = command.timeout_ms orelse default_timeout_ms;
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
        const is_wait = command.verb == .dom_wait_for;
        // waitFor: the script owns the wait and its JS timeout is
        // authoritative; the native call gets extra grace on top.
        const script_timeout: ?u64 = if (is_wait) timeout_ms else null;
        const native_timeout = if (is_wait) timeout_ms + wait_for_native_grace_ms else timeout_ms;

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
        return scriptFailure(gpa, &script_result, ids);
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
    trace_id: []const u8,
    command_id: []const u8,
};

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
