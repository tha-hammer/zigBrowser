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
const bezier = @import("bezier.zig");
const gaussian = @import("gaussian.zig");

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
    /// Backend/version dimensions for spans.
    build: telemetry.BuildInfo = .{},
};

/// Handle given to `executeExternal` bodies: the command's ids plus
/// instrumented PagePort access and child-span recording under its root.
pub const External = struct {
    engine: *Engine,
    run: *Run,
    options: ExecuteOptions,

    /// Runs one router command (e.g. a dom.* step of an x.* flow) inside
    /// this command's lifecycle: same trace/ids, cancel flag and sink, so
    /// its page calls become children of the one root span.
    pub fn runCommand(self: *External, gpa: std.mem.Allocator, method: []const u8, params_json: []const u8) error{OutOfMemory}!Outcome {
        var command = router.parse(gpa, method, params_json, .{ .page_id = self.options.route.page_id, .window_id = self.options.route.window_id }) catch |err| return .{ .failure = .{
            .code = switch (err) {
                error.UnknownCommand => -32601,
                error.BadArgs => -32602,
            },
            .message = switch (err) {
                error.UnknownCommand => "Method not found",
                error.BadArgs => "Invalid params",
            },
        } };
        defer command.deinit();
        var step_options = self.options;
        step_options.queue_wait_ms = 0;
        return self.engine.executeRun(gpa, &command, step_options, self.run);
    }

    pub fn ids(self: *const External) script_command.Ids {
        return self.run.ids;
    }

    pub fn nowMs(self: *const External) u64 {
        return self.engine.clock.nowMs();
    }

    /// True once the command was cancelled (server stop / queue shutdown).
    pub fn cancelled(self: *const External) bool {
        return self.run.cancelled();
    }

    /// Sleeps `ms` in poll-interval slices; false if cancelled meanwhile.
    pub fn pause(self: *External, ms: u64) bool {
        return self.engine.sleepUnlessCancelled(ms, self.run);
    }

    pub fn route(self: *const External) router.RouteContext {
        return self.run.route;
    }

    pub fn build(self: *const External) telemetry.BuildInfo {
        return self.run.build;
    }

    /// PagePort.url with an automation.platform.eval child span.
    pub fn url(self: *External, gpa: std.mem.Allocator, timeout_ms: u64) page_port.PortError![]u8 {
        self.run.native_timeout_ms = timeout_ms;
        const started = self.engine.clock.nowMs();
        const value = self.engine.port.url(gpa, timeout_ms) catch |err| {
            self.engine.platformSpan(self.run, "url", null, 0, 0, started, @errorName(err));
            return err;
        };
        self.engine.platformSpan(self.run, "url", null, 0, value.len, started, "ok");
        return value;
    }

    /// PagePort.evalJson with an automation.platform.eval child span.
    pub fn evalJson(self: *External, gpa: std.mem.Allocator, world: page_port.World, body: []const u8, arg_json: []const u8, timeout_ms: u64) page_port.PortError![]u8 {
        self.run.native_timeout_ms = timeout_ms;
        const started = self.engine.clock.nowMs();
        const text = self.engine.port.evalJson(gpa, world, body, arg_json, timeout_ms) catch |err| {
            self.engine.platformSpan(self.run, "evalJson", world, body.len, 0, started, @errorName(err));
            return err;
        };
        self.engine.platformSpan(self.run, "evalJson", world, body.len, text.len, started, "ok");
        return text;
    }

    /// Records a child span under this command's root. Attributes must
    /// already be redacted.
    /// A child span with an explicit span id and parent (e.g. a compound
    /// span under the root, and step events under the compound).
    pub fn childSpanUnder(self: *External, name: []const u8, span_id: ?[]const u8, parent_span_id: []const u8, attributes: []const telemetry.AttrMap.Entry) void {
        const sink = self.run.sink orelse return;
        sink.recordChildSpan(.{
            .name = name,
            .trace_id = self.run.ids.trace_id,
            .span_id = span_id,
            .parent_span_id = parent_span_id,
            .command_id = self.run.ids.command_id,
            .attributes = attributes,
        }) catch {};
    }

    pub fn childSpan(self: *External, name: []const u8, attributes: []const telemetry.AttrMap.Entry) void {
        const sink = self.run.sink orelse return;
        sink.recordChildSpan(.{
            .name = name,
            .trace_id = self.run.ids.trace_id,
            .parent_span_id = self.run.ids.parent_span_id,
            .command_id = self.run.ids.command_id,
            .attributes = attributes,
        }) catch {};
    }
};

/// State for one command execution.
const Run = struct {
    ids: script_command.Ids,
    cancel: ?*const std.atomic.Value(bool),
    sink: ?telemetry.TelemetrySink,
    route: router.RouteContext,
    build: telemetry.BuildInfo,
    /// Deadline handed to the native layer for the current call.
    native_timeout_ms: u64 = 0,
    /// Set when runDomUntil's failure is a PagePort Timeout with no script
    /// evidence before it (internal provenance; never inferred from the
    /// public error code).
    ended_on_bare_port_timeout: bool = false,
    /// Monotonic across the whole command (retries and per-character ops).
    attempts: u32 = 0,
    /// selector.match_count from the script's latest selector.resolve span.
    match_count_buf: [16]u8 = undefined,
    match_count_len: usize = 0,

    fn matchCount(self: *const Run) ?[]const u8 {
        return if (self.match_count_len == 0) null else self.match_count_buf[0..self.match_count_len];
    }

    fn cancelled(self: *const Run) bool {
        const flag = self.cancel orelse return false;
        return flag.load(.acquire);
    }
};

pub const Engine = struct {
    port: page_port.PagePort,
    clock: Clock,
    next_command_id: std.atomic.Value(u64) = .init(1),
    /// N8 humanize randomness. Null in production: each humanized command
    /// gets its own ChaCha CSPRNG seeded from OS entropy. Tests inject a
    /// seeded generator here; it only supplies each command's seed (under
    /// `random_lock`), so concurrent page queues never share PRNG state.
    random: ?std.Random = null,
    random_lock: std.atomic.Mutex = .unlocked,

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
        var run = Run{
            .ids = self.nextIds(&ids_buf),
            .cancel = options.cancel,
            .sink = options.route.telemetry_sink,
            .route = options.route,
            .build = options.build,
        };
        const started = self.clock.nowMs();
        const outcome = try self.executeRun(gpa, command, options, &run);
        // duration_ms covers enqueue -> completion (queue wait included).
        recordRootSpan(command, options, &run, &outcome, options.queue_wait_ms +| (self.clock.nowMs() -| started));
        return outcome;
    }

    /// Runs a command that is not a router verb (e.g. social.*, cookies.*)
    /// with the same lifecycle as `executeWith`: fresh ids, a cancel check,
    /// and exactly one root span. `body(context, gpa, ext)` produces the
    /// outcome; it reaches the page through `ext` so PagePort calls get
    /// automation.platform.eval children, and its failures should carry
    /// `ext.ids()`.
    pub fn executeExternal(
        self: *Engine,
        gpa: std.mem.Allocator,
        method: []const u8,
        namespace: []const u8,
        options: ExecuteOptions,
        context: anytype,
        comptime body: fn (@TypeOf(context), std.mem.Allocator, *External) error{OutOfMemory}!Outcome,
    ) error{OutOfMemory}!Outcome {
        var ids_buf: IdsBuf = undefined;
        var run = Run{
            .ids = self.nextIds(&ids_buf),
            .cancel = options.cancel,
            .sink = options.route.telemetry_sink,
            .route = options.route,
            .build = options.build,
        };
        const started = self.clock.nowMs();
        var ext = External{ .engine = self, .run = &run, .options = options };
        const outcome = if (run.cancelled())
            try automationFailure(gpa, .cancelled, null, run.ids)
        else
            try body(context, gpa, &ext);
        recordRoot(.{ .method = method, .namespace = namespace, .timeout_ms = 0 }, options, &run, &outcome, options.queue_wait_ms +| (self.clock.nowMs() -| started));
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
        run.native_timeout_ms = timeout_ms;
        return switch (command.verb) {
            .page_url => {
                const started = self.clock.nowMs();
                const value = self.port.url(gpa, timeout_ms) catch |err| {
                    self.platformSpan(run, "url", null, 0, 0, started, @errorName(err));
                    return portFailure(gpa, err, .action, ids);
                };
                defer gpa.free(value);
                self.platformSpan(run, "url", null, 0, value.len, started, "ok");
                return stringResult(gpa, "url", value);
            },
            .page_title => {
                const started = self.clock.nowMs();
                const value = self.port.title(gpa, timeout_ms) catch |err| {
                    self.platformSpan(run, "title", null, 0, 0, started, @errorName(err));
                    return portFailure(gpa, err, .action, ids);
                };
                defer gpa.free(value);
                self.platformSpan(run, "title", null, 0, value.len, started, "ok");
                return stringResult(gpa, "title", value);
            },
            .page_navigate => {
                const started = self.clock.nowMs();
                self.port.navigate(command.url.?, timeout_ms) catch |err| {
                    self.platformSpan(run, "navigate", null, command.url.?.len, 0, started, @errorName(err));
                    return portFailure(gpa, err, .navigation, ids);
                };
                self.platformSpan(run, "navigate", null, command.url.?.len, 0, started, "ok");
                return okResult(gpa);
            },
            .page_reload => {
                const started = self.clock.nowMs();
                self.port.reload(timeout_ms) catch |err| {
                    self.platformSpan(run, "reload", null, 0, 0, started, @errorName(err));
                    return portFailure(gpa, err, .navigation, ids);
                };
                self.platformSpan(run, "reload", null, 0, 0, started, "ok");
                return okResult(gpa);
            },
            .page_evaluate => self.evaluate(gpa, command.expression.?, timeout_ms, run),
            .page_screenshot => self.screenshot(gpa, command.full_page, timeout_ms, run),
            .dom_query,
            .dom_click,
            .dom_fill,
            .dom_type,
            .dom_get_text,
            .dom_get_attribute,
            .dom_wait_for,
            .dom_press,
            .dom_select_option,
            .dom_set_input_files,
            .dom_hover,
            .dom_scroll,
            => self.runDom(gpa, command, timeout_ms, run),
        };
    }

    /// page.screenshot (v3.4): `{data: base64 PNG, width, height}`. A
    /// backend without screenshots keeps the -32603 "not supported" answer.
    /// The deadline bounds the capture: a PNG that arrives at or after it is
    /// action_timeout "screenshot_deadline". Encoding then is bounded by
    /// size (at most max_screenshot_bytes in, 4/3 of that out).
    fn screenshot(self: *Engine, gpa: std.mem.Allocator, full_page: bool, timeout_ms: u64, run: *Run) error{OutOfMemory}!Outcome {
        const started = self.clock.nowMs();
        const deadline = started +| timeout_ms;
        const shot = self.port.screenshot(gpa, full_page, timeout_ms) catch |err| {
            self.platformSpan(run, "screenshot", null, 0, 0, started, @errorName(err));
            if (err == error.Unsupported) return .{ .failure = .{ .code = internal_error_code, .message = "page.screenshot is not supported" } };
            return portFailure(gpa, err, .action, run.ids);
        };
        defer gpa.free(shot.png);
        self.platformSpan(run, "screenshot", null, 0, shot.png.len, started, "ok");
        if (self.clock.nowMs() >= deadline) return automationFailure(gpa, .action_timeout, "screenshot_deadline", run.ids);
        const encoder = std.base64.standard.Encoder;
        const data = try gpa.alloc(u8, encoder.calcSize(shot.png.len));
        defer gpa.free(data);
        _ = encoder.encode(data, shot.png);
        return .{ .result = try std.fmt.allocPrint(gpa, "{{\"data\":\"{s}\",\"width\":{d},\"height\":{d}}}", .{ data, shot.width, shot.height }) };
    }

    fn evaluate(self: *Engine, gpa: std.mem.Allocator, expression: []const u8, timeout_ms: u64, run: *Run) error{OutOfMemory}!Outcome {
        const ids = run.ids;
        const body = try script_command.buildEvaluateBody(gpa, expression);
        defer gpa.free(body);
        const started = self.clock.nowMs();
        const text = self.port.evalJson(gpa, .page, body, "null", timeout_ms) catch |err| {
            self.platformSpan(run, "evalJson", .page, body.len, 0, started, @errorName(err));
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
        if (command.input == .native) {
            if (command.verb == .dom_scroll) return self.runNativeScroll(gpa, command, deadline, run);
            return self.runNative(gpa, command, deadline, run);
        }
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
                if (!self.sleepUnlessCancelled(delay_ms, run)) return automationFailure(gpa, .cancelled, null, run.ids);
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
            if (is_wait) {
                // Readiness barrier: PagePort ops wait for the first page
                // load. Doing that here, before the JS timeout is computed,
                // makes readiness come out of the same budget for JS and
                // native, so the script's timeout stays authoritative.
                const barrier = self.port.url(gpa, @max(deadline -| self.clock.nowMs(), 1)) catch |err| return portFailure(gpa, err, .action, ids);
                gpa.free(barrier);
            }
            const remaining = deadline -| self.clock.nowMs();
            // waitFor: the script's JS timeout is authoritative; the native
            // call gets extra grace on top so JS settles first.
            const script_timeout: ?u64 = if (is_wait) remaining else null;
            const native_timeout = if (is_wait) remaining + wait_for_native_grace_ms else @max(remaining, 1);
            run.native_timeout_ms = native_timeout;

            const command_json = script_command.buildCommandJson(gpa, command, ids, script_timeout) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NotADomCommand => unreachable,
            };
            defer gpa.free(command_json);

            const started = self.clock.nowMs();
            // dom.setInputFiles: the op runs inside the port's file-chooser
            // call, which answers the chooser with the paths. A refusal by
            // the op clicked nothing, so it is retried like any other.
            const answer = if (command.verb == .dom_set_input_files and command.locate == null)
                self.port.setInputFiles(gpa, script_command.handle_body, command_json, command.paths, native_timeout)
            else
                self.port.evalJson(gpa, .automation, script_command.handle_body, command_json, native_timeout);
            const text = answer catch |err| {
                self.platformSpanAttempt(run, ids.attempt_index, command_json.len, 0, started, @errorName(err));
                if (err == error.Timeout) {
                    // A page call cut short by the command deadline after
                    // earlier retryable failures: that evidence is the
                    // answer. (A Timeout before the deadline stays one.)
                    if (last.recorded and self.clock.nowMs() >= deadline) return deadlineFailure(gpa, &last, ids, run.attempts);
                    run.ended_on_bare_port_timeout = true;
                }
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
            captureMatchCount(run, &script_result);

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

    /// N7 native input (dom.click / dom.type / dom.press with
    /// `options.input: "native"`). One deadline covers everything: the
    /// `locate` op is retried like any action until it finds an actionable
    /// target (type/press also focus it, the caret at the end), then the
    /// PagePort sends real input with the time that is left, bound to the
    /// located document's token. If the page moved to another document
    /// before any input was sent, the target is located again; once input
    /// was dispatched nothing is retried. `trial` stops after locate: no
    /// focus, no input.
    fn runNative(self: *Engine, gpa: std.mem.Allocator, command: *const router.ParsedCommand, deadline: u64, run: *Run) error{OutOfMemory}!Outcome {
        const action: []const u8 = switch (command.verb) {
            .dom_click => "click",
            .dom_type => "type",
            .dom_press => "press",
            .dom_hover => "hover",
            else => unreachable, // the router accepts native for these only (scroll has its own path)
        };
        // A backend without native input says so before any page work.
        if (!self.port.supportsNativeInput()) return automationFailure(gpa, .session_invalid, "unsupported", run.ids);
        // A hover, and a humanized click, move the pointer: without
        // nativeMove, say so now.
        const moves = command.verb == .dom_hover or (command.humanize and command.verb == .dom_click);
        if (moves and !self.port.supportsNativeMove()) {
            return automationFailure(gpa, .session_invalid, "unsupported", run.ids);
        }
        var csprng: std.Random.DefaultCsprng = undefined;
        const random: ?std.Random = if (command.humanize) (self.humanizeRandom(&csprng) orelse
            return .{ .failure = .{ .code = internal_error_code, .message = "No entropy for humanize" } }) else null;
        var relocated = false;
        while (true) {
            var target: Target = .{};
            if (command.selector != null) {
                var locate_command = command.*;
                const pointer_only = command.verb == .dom_click or command.verb == .dom_hover;
                locate_command.locate = .{ .action = action, .focus = !pointer_only and !command.trial };
                run.ended_on_bare_port_timeout = false;
                var located = try self.runDomUntil(gpa, &locate_command, deadline, run);
                switch (located) {
                    .failure => {
                        // Out of time while chasing a document that kept
                        // changing: only a final locate that ended on a bare
                        // PagePort Timeout (no evidence from the new
                        // document) yields to that. Any other failure
                        // (actionability evidence, cancelled, internal,
                        // session, the script's own not-found) is reported
                        // as it is.
                        if (relocated and run.ended_on_bare_port_timeout and self.clock.nowMs() >= deadline) {
                            located.deinit(gpa);
                            return automationFailure(gpa, .element_not_found, "document_changed", run.ids);
                        }
                        return located;
                    },
                    .result => |json| {
                        defer located.deinit(gpa);
                        if (!parseTarget(gpa, json, &target)) return malformedResult();
                    },
                }
            }
            if (command.trial) return okResult(gpa);
            if (run.cancelled()) return automationFailure(gpa, .cancelled, null, run.ids);
            if (relocated and self.clock.nowMs() >= deadline) return automationFailure(gpa, .element_not_found, "document_changed", run.ids);

            const step: NativeStep = if (random) |r| switch (command.verb) {
                .dom_click => try self.humanPointer(gpa, r, &target, deadline, run, .click),
                .dom_hover => try self.humanPointer(gpa, r, &target, deadline, run, .hover),
                .dom_press => try self.humanPress(gpa, r, command, &target, deadline, run),
                .dom_type => try self.humanType(gpa, r, command, &target, deadline, run),
                else => unreachable,
            } else switch (command.verb) {
                .dom_click => try self.nativeSingle(gpa, .click, command, &target, deadline, run),
                .dom_hover => try self.nativeSingle(gpa, .move, command, &target, deadline, run),
                .dom_press => try self.nativeSingle(gpa, .key, command, &target, deadline, run),
                .dom_type => try self.nativeType(gpa, command, &target, deadline, run, null),
                else => unreachable,
            };
            switch (step) {
                .done => |outcome| return outcome,
                .relocate => {
                    // Nothing was sent: find the target in the new document,
                    // within the same deadline. A page that keeps replacing
                    // its document until the deadline ends as -32001
                    // element_not_found reason "document_changed" (the
                    // target never stayed put long enough), not as a
                    // retry-exhausted action_timeout.
                    if (self.clock.nowMs() +| poll_interval_ms >= deadline) return automationFailure(gpa, .element_not_found, "document_changed", run.ids);
                    if (!self.sleepUnlessCancelled(poll_interval_ms, run)) return automationFailure(gpa, .cancelled, null, run.ids);
                    relocated = true;
                },
            }
        }
    }

    /// N18 native dom.scroll: real wheel events at the viewport centre,
    /// each bound to the measured document. The `measure` op finds the
    /// target without scrolling (locate would scroll it into view itself).
    /// By offset: one wheel by (x, y), answered with the port's settled
    /// offsets. To a selector: wheels by (element centre - viewport centre)
    /// until a fresh measure shows the centre in the viewport (at most
    /// `max_scroll_wheels`, else action_timeout "scroll_not_reached"),
    /// answered with that measure's offsets; already centred: no wheel. A
    /// document change before the first wheel measures again; after one it
    /// is terminal. Answer: `{scrollX, scrollY}`, like the synthetic op.
    fn runNativeScroll(self: *Engine, gpa: std.mem.Allocator, command: *const router.ParsedCommand, deadline: u64, run: *Run) error{OutOfMemory}!Outcome {
        if (!self.port.supportsNativeScroll()) return automationFailure(gpa, .session_invalid, "unsupported", run.ids);
        var wheels: u32 = 0;
        // The document the wheels went to: every later measure must come
        // from it (a replacement document is never scrolled or reported).
        var wheeled_buf: [max_document_token_len]u8 = undefined;
        var wheeled: ?[]const u8 = null;
        while (true) {
            var measure_command = command.*;
            measure_command.locate = .{ .op = "measure", .action = "scroll", .focus = false };
            var target: Target = .{};
            var offsets: ?page_port.ScrollOffsets = null;
            var measured = try self.runDomUntil(gpa, &measure_command, deadline, run);
            switch (measured) {
                .failure => return measured,
                .result => |json| {
                    defer measured.deinit(gpa);
                    if (!parseTarget(gpa, json, &target) or target.viewport_width <= 0 or target.viewport_height <= 0) return malformedResult();
                    offsets = parseScrollOffsets(gpa, json);
                },
            }
            if (wheeled) |doc| if (!std.mem.eql(u8, doc, target.document().?)) {
                return automationFailure(gpa, .element_not_found, "document_changed", run.ids);
            };
            const centre = page_port.Point{ .x = target.viewport_width / 2, .y = target.viewport_height / 2 };
            var delta = page_port.Point{ .x = command.scroll_x orelse 0, .y = command.scroll_y orelse 0 };
            if (command.selector != null) {
                const current = offsets orelse return malformedResult();
                delta = .{ .x = target.x - centre.x, .y = target.y - centre.y };
                const in_view = target.x >= 0 and target.x < target.viewport_width and target.y >= 0 and target.y < target.viewport_height;
                if ((wheels > 0 and in_view) or (@abs(delta.x) < 1 and @abs(delta.y) < 1)) return scrollResult(gpa, current);
                if (wheels == max_scroll_wheels) return automationFailure(gpa, .action_timeout, "scroll_not_reached", run.ids);
            }
            if (run.cancelled()) return automationFailure(gpa, .cancelled, null, run.ids);
            const remaining = deadline -| self.clock.nowMs();
            if (remaining == 0) return timeoutWithReason(gpa, .action_timeout, "deadline_before_input", run.ids, run.attempts);
            run.native_timeout_ms = remaining;
            const started = self.clock.nowMs();
            const settled = self.port.nativeScroll(centre.x, centre.y, delta.x, delta.y, target.document(), remaining) catch |err| {
                self.platformSpan(run, "nativeScroll", null, 0, 0, started, @errorName(err));
                if (err != error.DocumentChanged) return portFailure(gpa, err, .action, run.ids);
                if (wheels > 0) return automationFailure(gpa, .element_not_found, "document_changed", run.ids);
                // Nothing was sent: measure the new document.
                if (self.clock.nowMs() +| poll_interval_ms >= deadline) return automationFailure(gpa, .element_not_found, "document_changed", run.ids);
                if (!self.sleepUnlessCancelled(poll_interval_ms, run)) return automationFailure(gpa, .cancelled, null, run.ids);
                continue;
            };
            self.platformSpan(run, "nativeScroll", null, 0, 0, started, "ok");
            if (wheeled == null) {
                const doc = target.document().?;
                @memcpy(wheeled_buf[0..doc.len], doc);
                wheeled = wheeled_buf[0..doc.len];
            }
            wheels += 1;
            if (command.selector == null) return scrollResult(gpa, settled);
        }
    }

    const NativeStep = union(enum) {
        done: Outcome,
        /// DocumentChanged before any input was sent.
        relocate,
    };

    /// One native click, pointer move (hover) or key press with the
    /// remaining deadline.
    fn nativeSingle(self: *Engine, gpa: std.mem.Allocator, comptime kind: enum { click, move, key }, command: *const router.ParsedCommand, target: *const Target, deadline: u64, run: *Run) error{OutOfMemory}!NativeStep {
        const op = switch (kind) {
            .click => "nativeClick",
            .move => "nativeMove",
            .key => "nativeKey",
        };
        const payload_bytes = if (kind == .key) command.key.?.len else 0;
        const remaining = deadline -| self.clock.nowMs();
        if (remaining == 0) return .{ .done = try timeoutWithReason(gpa, .action_timeout, "deadline_before_input", run.ids, run.attempts) };
        run.native_timeout_ms = remaining;
        const started = self.clock.nowMs();
        const dispatched = switch (kind) {
            .click => self.port.nativeClick(target.x, target.y, target.document(), remaining),
            .move => self.port.nativeMove(target.x, target.y, target.document(), remaining),
            .key => self.port.nativeKey(command.key.?, modifierBits(command.modifiers), target.document(), remaining),
        };
        dispatched catch |err| {
            self.platformSpan(run, op, null, payload_bytes, 0, started, @errorName(err));
            if (err == error.DocumentChanged and target.document() != null) return .relocate;
            return .{ .done = try portFailure(gpa, err, .action, run.ids) };
        };
        self.platformSpan(run, op, null, payload_bytes, 0, started, "ok");
        return .{ .done = try okResult(gpa) };
    }

    /// Native dom.type: the whole text in one PagePort call, or with
    /// delay_ms one code point per call with sleeps in between, every call
    /// bound to the located document. Progress is counted in code points; a
    /// failure after any was sent is terminal `partial_input` with
    /// `sent_chars`, and nothing is retyped.
    /// `delays`: per-code-point pause before each character (humanize);
    /// null uses `delay_ms` between characters.
    fn nativeType(self: *Engine, gpa: std.mem.Allocator, command: *const router.ParsedCommand, target: *const Target, deadline: u64, run: *Run, delays: ?[]const u64) error{OutOfMemory}!NativeStep {
        const text = command.text.?;
        if (text.len == 0) return .{ .done = try okResult(gpa) };
        var sent_total: usize = 0;
        if (delays == null and (command.delay_ms orelse 0) == 0) {
            const step = try self.nativeTextCall(gpa, text, target, deadline, run, &sent_total);
            return step orelse .{ .done = try okResult(gpa) };
        }
        var characters = (std.unicode.Utf8View.init(text) catch return .{ .done = malformedResult() }).iterator();
        var first = true;
        var index: usize = 0;
        while (characters.nextCodepointSlice()) |character| : (index += 1) {
            // delay_ms pauses between characters; humanize delays come
            // before every character, the first included.
            if (!first or delays != null) {
                const delay_ms = if (delays) |d| d[index] else command.delay_ms.?;
                if (self.clock.nowMs() +| delay_ms >= deadline) {
                    return .{ .done = try partialInput(gpa, .action_timeout, "type_delay_exceeds_timeout", sent_total, run) };
                }
                if (!self.sleepUnlessCancelled(delay_ms, run)) return .{ .done = try partialInput(gpa, .cancelled, null, sent_total, run) };
            }
            first = false;
            if (try self.nativeTextCall(gpa, character, target, deadline, run, &sent_total)) |step| return step;
        }
        return .{ .done = try okResult(gpa) };
    }

    // ---- N8 humanize ----
    //
    // The whole schedule (path steps, dwell, key delays) is computed before
    // anything is dispatched; if it does not fit the remaining deadline the
    // command fails with action_timeout reason "humanize_budget" and sends
    // nothing. Delays are never compressed.

    /// A per-command CSPRNG. Production seeds it from OS entropy (Zig
    /// 0.16 has no std.crypto.random; std.Io randomSecure is the OS-entropy
    /// source). An injected test RNG only provides the seed.
    fn humanizeRandom(self: *Engine, csprng: *std.Random.DefaultCsprng) ?std.Random {
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        if (self.random) |injected| {
            while (!self.random_lock.tryLock()) std.atomic.spinLoopHint();
            defer self.random_lock.unlock();
            injected.bytes(&seed);
        } else {
            std.Io.Threaded.global_single_threaded.io().randomSecure(&seed) catch return null;
        }
        csprng.* = .init(seed);
        return csprng.random();
    }

    /// Pointer path from the window's last dispatched pointer position (or
    /// an off-target in-viewport start); for a click, then the dwell and
    /// the click (a hover ends on the target). A document change before the
    /// first move re-locates; after any move it is terminal (no re-locate,
    /// no click in the new document).
    fn humanPointer(self: *Engine, gpa: std.mem.Allocator, random: std.Random, target: *const Target, deadline: u64, run: *Run, comptime gesture: enum { click, hover }) error{OutOfMemory}!NativeStep {
        const goal = page_port.Point{ .x = target.x, .y = target.y };
        // Never start on the target: a cached pointer already there (e.g.
        // a repeated click) gets an off-target start like an unknown one.
        const cached = self.port.pointer();
        const start = if (cached != null and distance(cached.?, goal) >= 1) cached.? else (offTargetStart(random, target) orelse return .{ .done = malformedResult() });
        const path = bezier.generateMousePath(gpa, random, .{ .x = start.x, .y = start.y }, .{ .x = goal.x, .y = goal.y }, .default()) catch return error.OutOfMemory;
        defer gpa.free(path.points);
        const gaps = path.points.len - 1;
        const step_ms: u64 = if (gaps == 0) 0 else ceilMs(path.duration_ms / @as(f64, @floatFromInt(gaps)));
        const dwell_ms = if (gesture == .click) ceilMs(path.dwell_ms) else 0;
        if (self.clock.nowMs() +| (step_ms *| gaps) +| dwell_ms >= deadline) {
            return .{ .done = try timeoutWithReason(gpa, .action_timeout, "humanize_budget", run.ids, run.attempts) };
        }
        for (path.points, 0..) |point, i| {
            if (i > 0 and !self.sleepUnlessCancelled(step_ms, run)) return .{ .done = try automationFailure(gpa, .cancelled, null, run.ids) };
            const remaining = deadline -| self.clock.nowMs();
            if (remaining == 0) return .{ .done = try timeoutWithReason(gpa, .action_timeout, "deadline_before_input", run.ids, run.attempts) };
            run.native_timeout_ms = remaining;
            const started = self.clock.nowMs();
            self.port.nativeMove(point.x, point.y, target.document(), remaining) catch |err| {
                self.platformSpan(run, "nativeMove", null, 0, 0, started, @errorName(err));
                if (err == error.DocumentChanged) {
                    if (i == 0) return .relocate;
                    return .{ .done = try automationFailure(gpa, .element_not_found, "document_changed", run.ids) };
                }
                return .{ .done = try portFailure(gpa, err, .action, run.ids) };
            };
            self.platformSpan(run, "nativeMove", null, 0, 0, started, "ok");
        }
        if (gesture == .hover) return .{ .done = try okResult(gpa) };
        if (!self.sleepUnlessCancelled(dwell_ms, run)) return .{ .done = try automationFailure(gpa, .cancelled, null, run.ids) };
        const remaining = deadline -| self.clock.nowMs();
        if (remaining == 0) return .{ .done = try timeoutWithReason(gpa, .action_timeout, "deadline_before_input", run.ids, run.attempts) };
        run.native_timeout_ms = remaining;
        const started = self.clock.nowMs();
        self.port.nativeClick(goal.x, goal.y, target.document(), remaining) catch |err| {
            self.platformSpan(run, "nativeClick", null, 0, 0, started, @errorName(err));
            if (err == error.DocumentChanged) return .{ .done = try automationFailure(gpa, .element_not_found, "document_changed", run.ids) };
            return .{ .done = try portFailure(gpa, err, .action, run.ids) };
        };
        self.platformSpan(run, "nativeClick", null, 0, 0, started, "ok");
        return .{ .done = try okResult(gpa) };
    }

    /// Per-code-point key delays from the typing profile (80-200 ms, word
    /// pauses 300-600 ms before a space), all scheduled up front.
    fn humanType(self: *Engine, gpa: std.mem.Allocator, random: std.Random, command: *const router.ParsedCommand, target: *const Target, deadline: u64, run: *Run) error{OutOfMemory}!NativeStep {
        const text = command.text.?;
        const delays = (try humanTypingDelays(gpa, random, text)) orelse return .{ .done = malformedResult() };
        defer gpa.free(delays);
        // Exactly the sequence dispatch consumes: one delay before every
        // code point, the first included.
        var planned: u64 = 0;
        for (delays) |ms| planned +|= ms;
        if (self.clock.nowMs() +| planned >= deadline) {
            return .{ .done = try timeoutWithReason(gpa, .action_timeout, "humanize_budget", run.ids, run.attempts) };
        }
        return self.nativeType(gpa, command, target, deadline, run, delays);
    }

    /// One key-delay dwell, then the key.
    fn humanPress(self: *Engine, gpa: std.mem.Allocator, random: std.Random, command: *const router.ParsedCommand, target: *const Target, deadline: u64, run: *Run) error{OutOfMemory}!NativeStep {
        const profile = gaussian.TypingProfile.default();
        const dwell_ms = ceilMs(gaussian.sampleClamped(random, profile.mu_ms, profile.sigma_ms, profile.min_ms, profile.max_ms));
        if (self.clock.nowMs() +| dwell_ms >= deadline) {
            return .{ .done = try timeoutWithReason(gpa, .action_timeout, "humanize_budget", run.ids, run.attempts) };
        }
        if (!self.sleepUnlessCancelled(dwell_ms, run)) return .{ .done = try automationFailure(gpa, .cancelled, null, run.ids) };
        return self.nativeSingle(gpa, .key, command, target, deadline, run);
    }

    /// One PagePort.nativeText call with the remaining deadline. Returns
    /// null on success, else the step to take: a failure (partial when
    /// anything was sent), or relocate when the document changed before
    /// any code point of this command was sent.
    fn nativeTextCall(self: *Engine, gpa: std.mem.Allocator, text: []const u8, target: *const Target, deadline: u64, run: *Run, sent_total: *usize) error{OutOfMemory}!?NativeStep {
        if (run.cancelled()) return .{ .done = try partialInput(gpa, .cancelled, null, sent_total.*, run) };
        const remaining = deadline -| self.clock.nowMs();
        if (remaining == 0) return .{ .done = try partialInput(gpa, .action_timeout, "deadline_before_input", sent_total.*, run) };
        run.native_timeout_ms = remaining;
        const started = self.clock.nowMs();
        var sent: usize = 0;
        self.port.nativeText(text, target.document(), remaining, &sent) catch |err| {
            sent_total.* += sent;
            self.platformSpan(run, "nativeText", null, text.len, 0, started, @errorName(err));
            if (sent_total.* > 0) return .{ .done = try partialPortFailure(gpa, err, sent_total.*, run) };
            if (err == error.DocumentChanged and target.document() != null) return .relocate;
            return .{ .done = try portFailure(gpa, err, .action, run.ids) };
        };
        sent_total.* += sent;
        self.platformSpan(run, "nativeText", null, text.len, 0, started, "ok");
        // Success means every requested code point was dispatched; a short
        // count is a partial side effect, never success and never replayed.
        const requested = std.unicode.utf8CountCodepoints(text) catch text.len;
        if (sent != requested) return .{ .done = try partialInternal(gpa, "Incomplete native input", sent_total.*, run) };
        return null;
    }

    /// Sleeps `ms` in poll-interval slices so cancellation is noticed within
    /// one slice. Returns false if cancelled.
    fn sleepUnlessCancelled(self: *Engine, ms: u64, run: *const Run) bool {
        var left = ms;
        while (left > 0) {
            if (run.cancelled()) return false;
            const slice = @min(left, poll_interval_ms);
            self.clock.sleepMs(slice);
            left -= slice;
        }
        return !run.cancelled();
    }

    /// `error_class`: "ok", or the PortError name (a bounded enum).
    fn platformSpan(self: *Engine, run: *const Run, op: []const u8, world: ?page_port.World, payload_bytes: usize, result_bytes: usize, started: u64, error_class: []const u8) void {
        self.recordPlatformSpan(run, op, world, 0, payload_bytes, result_bytes, started, error_class);
    }

    fn platformSpanAttempt(self: *Engine, run: *const Run, attempt_index: u32, payload_bytes: usize, result_bytes: usize, started: u64, error_class: []const u8) void {
        self.recordPlatformSpan(run, "evalJson", .automation, attempt_index, payload_bytes, result_bytes, started, error_class);
    }

    /// `automation.platform.eval` child span: sizes and timing only, never
    /// the script, expression, URL or result bodies.
    fn recordPlatformSpan(self: *Engine, run: *const Run, op: []const u8, world: ?page_port.World, attempt_index: u32, payload_bytes: usize, result_bytes: usize, started: u64, error_class: []const u8) void {
        const sink = run.sink orelse return;
        const ok = std.mem.eql(u8, error_class, "ok");
        var bufs: [5][24]u8 = undefined;
        const entries = [_]telemetry.AttrMap.Entry{
            .{ .key = "page_port.op", .value = op },
            .{ .key = "script.world", .value = if (world) |w| @tagName(w) else "none" },
            .{ .key = "attempt.index", .value = std.fmt.bufPrint(&bufs[0], "{d}", .{attempt_index}) catch unreachable },
            .{ .key = "payload.bytes", .value = std.fmt.bufPrint(&bufs[1], "{d}", .{payload_bytes}) catch unreachable },
            .{ .key = "result.bytes", .value = std.fmt.bufPrint(&bufs[2], "{d}", .{result_bytes}) catch unreachable },
            .{ .key = "duration_ms", .value = std.fmt.bufPrint(&bufs[3], "{d}", .{self.clock.nowMs() -| started}) catch unreachable },
            .{ .key = "result.status", .value = if (ok) "ok" else "error" },
            .{ .key = "platform.error_class", .value = if (ok) "" else error_class },
            .{ .key = "timeout_ms", .value = std.fmt.bufPrint(&bufs[4], "{d}", .{run.native_timeout_ms}) catch unreachable },
            .{ .key = "backend.name", .value = run.build.backend_name },
            .{ .key = "backend.version", .value = run.build.backend_version },
            .{ .key = "page.id", .value = run.route.page_id },
            .{ .key = "window.id", .value = run.route.window_id },
        };
        sink.recordChildSpan(.{
            .name = "automation.platform.eval",
            .trace_id = run.ids.trace_id,
            .parent_span_id = run.ids.parent_span_id,
            .command_id = run.ids.command_id,
            .attributes = &entries,
        }) catch {};
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
        .dom_click, .dom_fill, .dom_type, .dom_press, .dom_select_option, .dom_set_input_files, .dom_hover, .dom_scroll => script_command.opName(verb),
        else => null,
    };
}

/// Facts about a command for its root span (raw values are redacted in
/// recordRoot before the sink).
const RootFacts = struct {
    method: []const u8,
    namespace: []const u8,
    selector: ?[]const u8 = null,
    strict: bool = false,
    typed_value: ?[]const u8 = null,
    url: ?[]const u8 = null,
    action_name: ?[]const u8 = null,
    action_force: bool = false,
    action_trial: bool = false,
    input_mode: router.InputMode = .synthetic,
    input_humanize: bool = false,
    timeout_ms: u64,
};

fn recordRootSpan(command: *const router.ParsedCommand, options: ExecuteOptions, run: *const Run, outcome: *const Outcome, duration_ms: u64) void {
    recordRoot(.{
        .method = command.method,
        .namespace = @tagName(command.namespace),
        .selector = command.selector,
        .strict = command.strict,
        .typed_value = command.value orelse command.text,
        .url = command.url,
        .action_name = actionName(command.verb),
        .action_force = command.force,
        .action_trial = command.trial,
        .input_mode = command.input,
        .input_humanize = command.humanize,
        .timeout_ms = commandTimeout(command),
    }, options, run, outcome, duration_ms);
}

fn recordRoot(facts: RootFacts, options: ExecuteOptions, run: *const Run, outcome: *const Outcome, duration_ms: u64) void {
    const sink = run.sink orelse return;
    var redaction_bufs: telemetry.RedactionBuffers = .{};
    const automation_error: ?[]const u8 = switch (outcome.*) {
        .result => null,
        .failure => |failure| if (failure.code <= errors.downstreamCode(.element_not_found) and failure.code >= errors.downstreamCode(.cancelled)) failure.message else null,
    };
    sink.recordCommandSpan(.{
        .trace_id = run.ids.trace_id,
        .span_id = run.ids.parent_span_id,
        .command_id = run.ids.command_id,
        .method = facts.method,
        .namespace = facts.namespace,
        .page_id = options.route.page_id,
        .window_id = options.route.window_id,
        // Redaction happens here, before the sink boundary.
        .redacted = telemetry.redactCommand(&redaction_bufs, facts.selector, facts.strict, facts.typed_value, facts.url),
        .action_name = facts.action_name,
        .action_force = facts.action_force,
        .action_trial = facts.action_trial,
        .input_mode = @tagName(facts.input_mode),
        .input_humanize = facts.input_humanize,
        .selector_match_count = run.matchCount(),
        .build = options.build,
        .timeout_ms = facts.timeout_ms,
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
        var number_bufs: [telemetry.script_child_attribute_allowlist.len][32]u8 = undefined;
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
                        .integer => |n| std.fmt.bufPrint(&number_bufs[count], "{d}", .{n}) catch continue,
                        .float => |f| std.fmt.bufPrint(&number_bufs[count], "{d}", .{f}) catch continue,
                        .bool => |b| if (b) "true" else "false",
                        else => continue,
                    };
                    entries[count] = .{ .key = entry.key_ptr.*, .value = value };
                    count += 1;
                }
            },
            else => {},
        };
        sink.recordChildSpan(.{
            .name = name,
            .trace_id = run.ids.trace_id,
            .span_id = stringField(span, "span_id"),
            .parent_span_id = run.ids.parent_span_id,
            .command_id = run.ids.command_id,
            .attributes = entries[0..count],
        }) catch {};
    }
}

/// Copies selector.match_count from the latest selector.resolve span (a
/// bounded decimal count) for the root span.
fn captureMatchCount(run: *Run, script_result: *const script_command.ScriptResult) void {
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
        if (!std.mem.eql(u8, name, "automation.selector.resolve")) continue;
        const attributes = switch (span.get("attributes") orelse continue) {
            .object => |object| object,
            else => continue,
        };
        const count = stringField(attributes, "selector.match_count") orelse continue;
        if (count.len == 0 or count.len > run.match_count_buf.len) continue;
        for (count) |c| if (!std.ascii.isDigit(c)) return;
        @memcpy(run.match_count_buf[0..count.len], count);
        run.match_count_len = count.len;
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
        // The backend lacks the capability (e.g. native input off GTK).
        error.Unsupported => return automationFailure(gpa, .session_invalid, "unsupported", ids),
        // Native input bound to a document that is gone; nothing was sent.
        error.DocumentChanged => return automationFailure(gpa, .element_not_found, "document_changed", ids),
        // Input was sent, then the page was replaced: terminal, same reason.
        error.DocumentReplaced => return automationFailure(gpa, .element_not_found, "document_changed", ids),
        // setInputFiles: the client's paths are unusable; nothing ran.
        error.BadFile => return failureWithReason(gpa, invalid_params_code, "Invalid params", "bad_file", ids),
        // setInputFiles: applied once, unconfirmed; never retried.
        error.FilesUnconfirmed => return automationFailure(gpa, .action_timeout, "files_unconfirmed", ids),
        error.TooLarge => return failureWithReason(gpa, internal_error_code, "Internal error", "screenshot_too_large", ids),
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

/// JSON-RPC invalid params (a parameter the router could not check, e.g. a
/// file path the backend refused).
pub const invalid_params_code: i64 = -32602;

/// A non-automation error code with `data.{reason,trace_id,command_id}`.
fn failureWithReason(gpa: std.mem.Allocator, code: i64, message: []const u8, reason: []const u8, ids: script_command.Ids) error{OutOfMemory}!Outcome {
    const data = AutomationErrorData{ .reason = reason, .trace_id = ids.trace_id, .command_id = ids.command_id };
    return .{ .failure = .{
        .code = code,
        .message = message,
        .data_json = try std.json.Stringify.valueAlloc(gpa, data, .{ .emit_null_optional_fields = false }),
    } };
}

/// Automation errors carry `data.{reason?,trace_id,command_id}`; the SDKs read
/// trace_id/command_id from there.
pub fn automationFailure(gpa: std.mem.Allocator, automation_error: errors.AutomationError, reason: ?[]const u8, ids: script_command.Ids) error{OutOfMemory}!Outcome {
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
    /// Native dom.type that stopped early: code points already typed.
    sent_chars: ?usize = null,
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
    /// At least one retryable failure was recorded.
    recorded: bool = false,

    /// Keeps the most specific evidence: once a match failed an
    /// actionability check, a later "not found" does not erase it.
    fn record(self: *LastFailure, script_result: *const script_command.ScriptResult) void {
        const error_name = script_result.error_name.?;
        const observed = errors.fromName(error_name) catch .element_not_found;
        if (observed == .element_not_found and self.automation_error != .element_not_found) return;
        self.recorded = true;
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

/// Where native input goes: the located centre and the token of the
/// document it was located in (none for dom.press without a selector),
/// plus the viewport size when the locate op reported it (0 = unknown).
const Target = struct {
    x: f64 = 0,
    y: f64 = 0,
    viewport_width: f64 = 0,
    viewport_height: f64 = 0,
    document_buf: [max_document_token_len]u8 = undefined,
    document_len: usize = 0,

    fn document(self: *const Target) ?[]const u8 {
        return if (self.document_len == 0) null else self.document_buf[0..self.document_len];
    }
};

/// automation.js document tokens: exactly 16 lowercase hex digits (the
/// shape the GTK adapter and shim accept; never contains NUL).
const max_document_token_len = 16;

/// `{x, y, document}` from the locate op: finite viewport CSS px and a
/// well-formed document token. Anything else is a malformed answer.
fn parseTarget(gpa: std.mem.Allocator, json: []const u8, target: *Target) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return false;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    target.x = jsonNumber(object.get("x") orelse return false) orelse return false;
    target.y = jsonNumber(object.get("y") orelse return false) orelse return false;
    if (!std.math.isFinite(target.x) or !std.math.isFinite(target.y)) return false;
    const token = switch (object.get("document") orelse return false) {
        .string => |text| text,
        else => return false,
    };
    if (token.len != max_document_token_len) return false;
    for (token) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    @memcpy(target.document_buf[0..token.len], token);
    target.document_len = token.len;
    if (object.get("viewport")) |viewport_value| {
        const viewport = switch (viewport_value) {
            .object => |o| o,
            else => return false,
        };
        target.viewport_width = jsonNumber(viewport.get("width") orelse return false) orelse return false;
        target.viewport_height = jsonNumber(viewport.get("height") orelse return false) orelse return false;
        if (!std.math.isFinite(target.viewport_width) or !std.math.isFinite(target.viewport_height)) return false;
        if (target.viewport_width < 0 or target.viewport_height < 0) return false;
    }
    return true;
}

/// N8: the humanized pointer path starts 80-240 px from the target in a
/// random direction, clamped into the viewport, never on the target
/// itself. Only that construction is used (retried a bounded number of
/// times); null when the viewport is unknown or no try leaves the target.
pub const humanize_start_min_px: f64 = 80;
pub const humanize_start_max_px: f64 = 240;

fn offTargetStart(random: std.Random, target: *const Target) ?page_port.Point {
    const max_x = target.viewport_width - 1;
    const max_y = target.viewport_height - 1;
    if (max_x < 1 or max_y < 1) return null;
    var attempt: usize = 0;
    while (attempt < 64) : (attempt += 1) {
        const radius = humanize_start_min_px + random.float(f64) * (humanize_start_max_px - humanize_start_min_px);
        const angle = random.float(f64) * 2.0 * std.math.pi;
        const point = page_port.Point{
            .x = std.math.clamp(target.x + radius * @cos(angle), 0, max_x),
            .y = std.math.clamp(target.y + radius * @sin(angle), 0, max_y),
        };
        if (distance(point, .{ .x = target.x, .y = target.y }) >= 1) return point;
    }
    return null;
}

fn distance(a: page_port.Point, b: page_port.Point) f64 {
    return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}

fn ceilMs(ms: f64) u64 {
    if (!(ms > 0)) return 0;
    return @intFromFloat(@min(@ceil(ms), @as(f64, @floatFromInt(max_timeout_ms))));
}

/// Typing-profile delay before each code point (the profile samples per
/// byte; a code point takes its first byte's sample, so a space keeps its
/// word pause). Null if `text` is not UTF-8.
fn humanTypingDelays(gpa: std.mem.Allocator, random: std.Random, text: []const u8) error{OutOfMemory}!?[]u64 {
    const per_byte = gaussian.computeTypingDelays(gpa, random, text, .default()) catch return error.OutOfMemory;
    defer gpa.free(per_byte);
    const count = std.unicode.utf8CountCodepoints(text) catch return null;
    const delays = try gpa.alloc(u64, count);
    var view = (std.unicode.Utf8View.init(text) catch {
        gpa.free(delays);
        return null;
    }).iterator();
    var i: usize = 0;
    while (view.nextCodepointSlice()) |slice| : (i += 1) {
        const byte_index = @intFromPtr(slice.ptr) - @intFromPtr(text.ptr);
        delays[i] = ceilMs(per_byte[byte_index]);
    }
    return delays;
}

/// Native dom.scroll to a selector: wheels before giving up.
pub const max_scroll_wheels: u32 = 3;

/// `scroll: {x, y}` (current page offsets) from a measure answer.
fn parseScrollOffsets(gpa: std.mem.Allocator, json: []const u8) ?page_port.ScrollOffsets {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const scroll = switch (object.get("scroll") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const x = jsonNumber(scroll.get("x") orelse return null) orelse return null;
    const y = jsonNumber(scroll.get("y") orelse return null) orelse return null;
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return null;
    return .{ .x = x, .y = y };
}

fn scrollResult(gpa: std.mem.Allocator, offsets: page_port.ScrollOffsets) error{OutOfMemory}!Outcome {
    return .{ .result = try std.json.Stringify.valueAlloc(gpa, .{ .scrollX = offsets.x, .scrollY = offsets.y }, .{}) };
}

/// A JSON number (never a string that looks like one).
fn jsonNumber(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch null,
        else => null,
    };
}

fn modifierBits(modifiers: []const []const u8) u8 {
    var bits: u8 = 0;
    for (modifiers) |name| {
        if (std.mem.eql(u8, name, "Shift")) bits |= page_port.modifier_shift;
        if (std.mem.eql(u8, name, "Control")) bits |= page_port.modifier_control;
        if (std.mem.eql(u8, name, "Alt")) bits |= page_port.modifier_alt;
        if (std.mem.eql(u8, name, "Meta")) bits |= page_port.modifier_meta;
    }
    return bits;
}

/// A native type that stopped early. With `sent_chars > 0` the reason is
/// always `partial_input`: the page already has that prefix.
fn partialInput(gpa: std.mem.Allocator, automation_error: errors.AutomationError, reason: ?[]const u8, sent_chars: usize, run: *const Run) error{OutOfMemory}!Outcome {
    return partialFailure(gpa, errors.downstreamCode(automation_error), errors.name(automation_error), reason, null, sent_chars, run);
}

/// A native type that failed after `sent_chars > 0` code points: the port
/// error keeps its own class (Timeout -> action_timeout, Cancelled ->
/// cancelled, NoPage/Unsupported -> session_invalid, EvalFailed -> -32603),
/// plus `reason: partial_input` and `sent_chars`.
fn partialPortFailure(gpa: std.mem.Allocator, err: page_port.PortError, sent_chars: usize, run: *const Run) error{OutOfMemory}!Outcome {
    const automation_error: errors.AutomationError = switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EvalFailed => return partialInternal(gpa, "Evaluation failed", sent_chars, run),
        // The target's document is gone: the rest was not typed anywhere.
        error.DocumentChanged, error.DocumentReplaced => return partialFailure(gpa, errors.downstreamCode(.element_not_found), errors.name(.element_not_found), null, "document_changed", sent_chars, run),
        error.Timeout, error.FilesUnconfirmed => .action_timeout,
        error.Cancelled => .cancelled,
        error.NoPage, error.Unsupported => .session_invalid,
        error.NavigationFailed => .navigation_failed,
        // Not text-input errors; still never lose the sent prefix.
        error.BadFile, error.TooLarge => return partialInternal(gpa, "Internal error", sent_chars, run),
    };
    return partialInput(gpa, automation_error, null, sent_chars, run);
}

fn partialInternal(gpa: std.mem.Allocator, message: []const u8, sent_chars: usize, run: *const Run) error{OutOfMemory}!Outcome {
    return partialFailure(gpa, internal_error_code, message, "partial_input", null, sent_chars, run);
}

fn partialFailure(gpa: std.mem.Allocator, code: i64, message: []const u8, reason: ?[]const u8, last_error: ?[]const u8, sent_chars: usize, run: *const Run) error{OutOfMemory}!Outcome {
    const data = AutomationErrorData{
        .reason = if (sent_chars > 0) "partial_input" else reason,
        .last_error = last_error,
        .sent_chars = if (sent_chars > 0) sent_chars else null,
        .attempts = run.attempts,
        .trace_id = run.ids.trace_id,
        .command_id = run.ids.command_id,
    };
    return .{ .failure = .{
        .code = code,
        .message = message,
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
