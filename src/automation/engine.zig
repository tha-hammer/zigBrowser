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
const telemetry = @import("telemetry.zig");

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

pub const ExecuteOptions = struct {
    /// Checked before the command starts and before every retry attempt
    /// (the per-page queue sets it on shutdown).
    cancel: ?*const std.atomic.Value(bool) = null,
    /// Time the command spent queued behind same-page commands. It counts
    /// against the command's deadline.
    queue_wait_ms: u64 = 0,
    /// Page/window identity and the telemetry sink (M11). Without a sink no
    /// spans are recorded.
    route: router.RouteContext = .{},
};

/// State for one command execution.
const Run = struct {
    ids: script_command.Ids,
    cancel: ?*const std.atomic.Value(bool),
    sink: ?*telemetry.InMemoryTelemetrySink,
    /// Monotonic across the whole command (retries and per-character ops).
    attempts: u32 = 0,

    fn cancelled(self: *const Run) bool {
        const flag = self.cancel orelse return false;
        return flag.load(.acquire);
    }
};

pub const Engine = struct {
    port: page_port.PagePort,
    clock: Clock,
    next_command_id: std.atomic.Value(u64) = .init(1),

    pub fn init(port: page_port.PagePort, clock: Clock) Engine {
        return .{ .port = port, .clock = clock };
    }

    pub fn execute(self: *Engine, gpa: std.mem.Allocator, command: *const router.ParsedCommand) error{OutOfMemory}!Outcome {
        return self.executeWith(gpa, command, .{});
    }

    /// Runs one command and records exactly one root `automation.command`
    /// span for it (when a sink is configured).
    pub fn executeWith(self: *Engine, gpa: std.mem.Allocator, command: *const router.ParsedCommand, options: ExecuteOptions) error{OutOfMemory}!Outcome {
        var ids_buf: IdsBuf = undefined;
        var run = Run{ .ids = self.nextIds(&ids_buf), .cancel = options.cancel, .sink = options.route.telemetry_sink };
        const started = self.clock.nowMs();
        const outcome = try self.executeRun(gpa, command, options, &run);
        recordRootSpan(command, options, &run, &outcome, self.clock.nowMs() -| started);
        return outcome;
    }

    fn executeRun(self: *Engine, gpa: std.mem.Allocator, command: *const router.ParsedCommand, options: ExecuteOptions, run: *Run) error{OutOfMemory}!Outcome {
        const ids = run.ids;
        if (run.cancelled()) return automationFailure(gpa, .cancelled, null, ids);
        const requested_ms = commandTimeout(command);
        if (options.queue_wait_ms > 0 and options.queue_wait_ms >= requested_ms) {
            return timeoutWithReason(gpa, timeoutErrorFor(command.verb), "queued_past_deadline", ids, 0);
        }
        const timeout_ms = requested_ms - options.queue_wait_ms;
        return switch (command.verb) {
            .page_url => {
                const started = self.clock.nowMs();
                const value = self.port.url(gpa, timeout_ms) catch |err| {
                    self.platformSpan(run, "url", null, 0, 0, started, "error");
                    return portFailure(gpa, err, .action, ids);
                };
                defer gpa.free(value);
                self.platformSpan(run, "url", null, 0, value.len, started, "ok");
                return stringResult(gpa, "url", value);
            },
            .page_title => {
                const started = self.clock.nowMs();
                const value = self.port.title(gpa, timeout_ms) catch |err| {
                    self.platformSpan(run, "title", null, 0, 0, started, "error");
                    return portFailure(gpa, err, .action, ids);
                };
                defer gpa.free(value);
                self.platformSpan(run, "title", null, 0, value.len, started, "ok");
                return stringResult(gpa, "title", value);
            },
            .page_navigate => {
                const started = self.clock.nowMs();
                self.port.navigate(command.url.?, timeout_ms) catch |err| {
                    self.platformSpan(run, "navigate", null, command.url.?.len, 0, started, "error");
                    return portFailure(gpa, err, .navigation, ids);
                };
                self.platformSpan(run, "navigate", null, command.url.?.len, 0, started, "ok");
                return okResult(gpa);
            },
            .page_reload => {
                const started = self.clock.nowMs();
                self.port.reload(timeout_ms) catch |err| {
                    self.platformSpan(run, "reload", null, 0, 0, started, "error");
                    return portFailure(gpa, err, .navigation, ids);
                };
                self.platformSpan(run, "reload", null, 0, 0, started, "ok");
                return okResult(gpa);
            },
            .page_evaluate => self.evaluate(gpa, command.expression.?, timeout_ms, run),
            .page_screenshot => .{ .failure = .{ .code = internal_error_code, .message = "page.screenshot is not supported" } },
            .dom_query,
            .dom_click,
            .dom_fill,
            .dom_type,
            .dom_get_text,
            .dom_get_attribute,
            .dom_wait_for,
            => self.runDom(gpa, command, timeout_ms, run),
        };
    }

    fn evaluate(self: *Engine, gpa: std.mem.Allocator, expression: []const u8, timeout_ms: u64, run: *Run) error{OutOfMemory}!Outcome {
        const ids = run.ids;
        const body = try script_command.buildEvaluateBody(gpa, expression);
        defer gpa.free(body);
        const started = self.clock.nowMs();
        const text = self.port.evalJson(gpa, .page, body, "null", timeout_ms) catch |err| {
            self.platformSpan(run, "evalJson", .page, body.len, 0, started, "error");
            return portFailure(gpa, err, .action, ids);
        };
        defer gpa.free(text);
        self.platformSpan(run, "evalJson", .page, body.len, text.len, started, "ok");

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

    fn runDom(self: *Engine, gpa: std.mem.Allocator, command: *const router.ParsedCommand, timeout_ms: u64, run: *Run) error{OutOfMemory}!Outcome {
        const deadline = self.clock.nowMs() +| timeout_ms;
        if (command.verb == .dom_type and command.text.?.len > 0) {
            if (command.delay_ms) |delay_ms| {
                if (delay_ms > 0) return self.typeWithDelay(gpa, command, delay_ms, deadline, run);
            }
        }
        return self.runDomUntil(gpa, command, deadline, run);
    }

    /// dom.type with delay_ms: one `type` op per character (UTF-8 code
    /// point), sleeping delay_ms between characters. Stops at the first
    /// failing character; never sleeps past the command deadline.
    fn typeWithDelay(self: *Engine, gpa: std.mem.Allocator, command: *const router.ParsedCommand, delay_ms: u64, deadline: u64, run: *Run) error{OutOfMemory}!Outcome {
        const view = std.unicode.Utf8View.init(command.text.?) catch return self.runDomUntil(gpa, command, deadline, run);
        var characters = view.iterator();
        var first = true;
        while (characters.nextCodepointSlice()) |character| {
            if (!first) {
                const now = self.clock.nowMs();
                if (now +| delay_ms >= deadline) return timeoutWithReason(gpa, .action_timeout, "type_delay_exceeds_timeout", run.ids, run.attempts);
                self.clock.sleepMs(delay_ms);
            }
            first = false;

            var single = command.*;
            single.text = character;
            var outcome = try self.runDomUntil(gpa, &single, deadline, run);
            switch (outcome) {
                .failure => return outcome,
                .result => outcome.deinit(gpa),
            }
        }
        return okResult(gpa);
    }

    /// M7 retry loop: retryable script failures are retried every
    /// `poll_interval_ms` while a full poll interval still fits before
    /// `deadline`. The first attempt always runs (so `timeout_ms: 0` means
    /// "exactly one attempt"); no later attempt starts at or after the
    /// deadline, and no native call is given more than the remaining time.
    /// waitFor owns its own wait in JS, so only a missing script is retried
    /// for it.
    fn runDomUntil(self: *Engine, gpa: std.mem.Allocator, command: *const router.ParsedCommand, deadline: u64, run: *Run) error{OutOfMemory}!Outcome {
        const is_wait = command.verb == .dom_wait_for;
        var ids = run.ids;
        var last: LastFailure = .{};
        while (true) {
            if (run.cancelled()) return automationFailure(gpa, .cancelled, null, ids);
            ids.attempt_index = run.attempts;
            run.attempts += 1;
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

            const started = self.clock.nowMs();
            const text = self.port.evalJson(gpa, .automation, script_command.handle_body, command_json, native_timeout) catch |err| {
                self.platformSpanAttempt(run, ids.attempt_index, command_json.len, 0, started, "error");
                return portFailure(gpa, err, .action, ids);
            };
            defer gpa.free(text);
            self.platformSpanAttempt(run, ids.attempt_index, command_json.len, text.len, started, "ok");

            var script_result = script_command.parseScriptResult(gpa, text) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.MalformedScriptResult => return malformedResult(),
            };
            defer script_result.deinit();
            forwardScriptSpans(run, &script_result);

            if (script_result.ok) {
                return .{ .result = try std.json.Stringify.valueAlloc(gpa, script_result.value, .{}) };
            }
            if (!shouldRetry(&script_result, is_wait)) return scriptFailure(gpa, &script_result, ids);
            last.record(&script_result);

            const now = self.clock.nowMs();
            if (now +| poll_interval_ms >= deadline) return deadlineFailure(gpa, &last, ids, run.attempts);
            self.clock.sleepMs(poll_interval_ms);
        }
    }

    fn platformSpan(self: *Engine, run: *const Run, op: []const u8, world: ?page_port.World, payload_bytes: usize, result_bytes: usize, started: u64, status: []const u8) void {
        self.recordPlatformSpan(run, op, world, 0, payload_bytes, result_bytes, started, status);
    }

    fn platformSpanAttempt(self: *Engine, run: *const Run, attempt_index: u32, payload_bytes: usize, result_bytes: usize, started: u64, status: []const u8) void {
        self.recordPlatformSpan(run, "evalJson", .automation, attempt_index, payload_bytes, result_bytes, started, status);
    }

    /// `automation.platform.eval` child span: sizes and timing only, never
    /// the script, expression, URL or result bodies.
    fn recordPlatformSpan(self: *Engine, run: *const Run, op: []const u8, world: ?page_port.World, attempt_index: u32, payload_bytes: usize, result_bytes: usize, started: u64, status: []const u8) void {
        const sink = run.sink orelse return;
        var bufs: [4][24]u8 = undefined;
        const entries = [_]telemetry.AttrMap.Entry{
            .{ .key = "page_port.op", .value = op },
            .{ .key = "script.world", .value = if (world) |w| @tagName(w) else "none" },
            .{ .key = "attempt.index", .value = std.fmt.bufPrint(&bufs[0], "{d}", .{attempt_index}) catch unreachable },
            .{ .key = "payload.bytes", .value = std.fmt.bufPrint(&bufs[1], "{d}", .{payload_bytes}) catch unreachable },
            .{ .key = "result.bytes", .value = std.fmt.bufPrint(&bufs[2], "{d}", .{result_bytes}) catch unreachable },
            .{ .key = "duration_ms", .value = std.fmt.bufPrint(&bufs[3], "{d}", .{self.clock.nowMs() -| started}) catch unreachable },
            .{ .key = "result.status", .value = status },
        };
        sink.recordChildSpan("automation.platform.eval", run.ids.trace_id, null, run.ids.parent_span_id, run.ids.command_id, &entries) catch {};
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

fn commandTimeout(command: *const router.ParsedCommand) u64 {
    return @min(command.timeout_ms orelse default_timeout_ms, max_timeout_ms);
}

fn timeoutErrorFor(verb: router.Verb) errors.AutomationError {
    return switch (verb) {
        .page_navigate, .page_reload => .navigation_timeout,
        else => .action_timeout,
    };
}

fn actionName(verb: router.Verb) ?[]const u8 {
    return switch (verb) {
        .dom_click, .dom_fill, .dom_type => script_command.opName(verb),
        else => null,
    };
}

fn recordRootSpan(command: *const router.ParsedCommand, options: ExecuteOptions, run: *const Run, outcome: *const Outcome, duration_ms: u64) void {
    const sink = run.sink orelse return;
    const automation_error: ?[]const u8 = switch (outcome.*) {
        .result => null,
        .failure => |failure| if (failure.code <= errors.downstreamCode(.element_not_found) and failure.code >= errors.downstreamCode(.cancelled)) failure.message else null,
    };
    sink.recordCommandSpan(.{
        .trace_id = run.ids.trace_id,
        .span_id = run.ids.parent_span_id,
        .command_id = run.ids.command_id,
        .method = command.method,
        .namespace = @tagName(command.namespace),
        .page_id = options.route.page_id,
        .window_id = options.route.window_id,
        .selector = command.selector,
        .selector_strict = if (command.selector != null) command.strict else null,
        .typed_value = command.value orelse command.text,
        .url = command.url,
        .action_name = actionName(command.verb),
        .action_force = command.force,
        .action_trial = command.trial,
        .timeout_ms = commandTimeout(command),
        .queue_wait_ms = options.queue_wait_ms,
        .duration_ms = duration_ms,
        .retry_count = run.attempts -| 1,
        .result_status = if (outcome.* == .result) "ok" else "error",
        .automation_error = automation_error,
    }) catch {};
}

/// Re-parents allowlisted automation.js child spans under the root span and
/// drops any attribute or span name the allowlist does not know.
fn forwardScriptSpans(run: *const Run, script_result: *const script_command.ScriptResult) void {
    const sink = run.sink orelse return;
    const spans = switch (script_result.telemetry orelse return) {
        .array => |array| array.items,
        else => return,
    };
    for (spans) |span_value| {
        const span = switch (span_value) {
            .object => |object| object,
            else => continue,
        };
        const name = stringField(span, "name") orelse continue;
        if (!inList(&telemetry.script_child_span_names, name)) continue;

        var entries: [telemetry.script_child_attribute_allowlist.len]telemetry.AttrMap.Entry = undefined;
        var count: usize = 0;
        if (span.get("attributes")) |attributes_value| switch (attributes_value) {
            .object => |attributes| {
                var it = attributes.iterator();
                while (it.next()) |entry| {
                    if (count == entries.len) break;
                    if (!inList(&telemetry.script_child_attribute_allowlist, entry.key_ptr.*)) continue;
                    const value: []const u8 = switch (entry.value_ptr.*) {
                        .string => |text| text,
                        .number_string => |text| text,
                        .bool => |b| if (b) "true" else "false",
                        else => continue,
                    };
                    entries[count] = .{ .key = entry.key_ptr.*, .value = value };
                    count += 1;
                }
            },
            else => {},
        };
        sink.recordChildSpan(name, run.ids.trace_id, stringField(span, "span_id"), run.ids.parent_span_id, run.ids.command_id, entries[0..count]) catch {};
    }
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

fn inList(list: []const []const u8, item: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, item)) return true;
    }
    return false;
}

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
