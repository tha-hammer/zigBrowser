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
    /// N23: the page this command (and every step of a flow) acts on, e.g.
    /// a targeted window's port; null = the engine's own port.
    port: ?page_port.PagePort = null,
    /// N23: `data.reason` when that page is gone (PortError.NoPage).
    no_page_reason: ?[]const u8 = null,
    /// S8: the targeted window's id (`window_id`), which `options.expect` is checked against.
    window: ?page_port.WindowId = null,
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
        const value = self.run.port.url(gpa, timeout_ms) catch |err| {
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
        const text = self.run.port.evalJson(gpa, world, body, arg_json, timeout_ms) catch |err| {
            self.engine.platformSpan(self.run, "evalJson", world, body.len, 0, started, @errorName(err));
            return err;
        };
        self.engine.platformSpan(self.run, "evalJson", world, body.len, text.len, started, "ok");
        return text;
    }

    /// N23: PagePort.listWindows with an automation.platform.eval child span
    /// (op "listWindows"; sizes only, never URLs or titles).
    pub fn listWindows(self: *External, gpa: std.mem.Allocator, timeout_ms: u64) page_port.PortError![]page_port.WindowInfo {
        self.run.native_timeout_ms = timeout_ms;
        const started = self.engine.clock.nowMs();
        const windows = self.run.port.listWindows(gpa, timeout_ms) catch |err| {
            self.engine.platformSpan(self.run, "listWindows", null, 0, 0, started, @errorName(err));
            return err;
        };
        self.engine.platformSpan(self.run, "listWindows", null, 0, windows.len, started, "ok");
        return windows;
    }

    /// S8: the command's bound window (`window_id`), read from the registry; for a flow's approval
    /// phases (flow_runner.Approval, social_flow_routes).
    pub fn boundWindow(self: *External, gpa: std.mem.Allocator, timeout_ms: u64) error{OutOfMemory}!WindowRead {
        return self.engine.readWindow(gpa, self.options.window, timeout_ms, self.run.ids);
    }

    /// N23: PagePort.closeWindow with an automation.platform.eval child span.
    pub fn closeWindow(self: *External, id: page_port.WindowId, timeout_ms: u64) page_port.PortError!void {
        self.run.native_timeout_ms = timeout_ms;
        const started = self.engine.clock.nowMs();
        self.run.port.closeWindow(id, timeout_ms) catch |err| {
            self.engine.platformSpan(self.run, "closeWindow", null, 0, 0, started, @errorName(err));
            return err;
        };
        self.engine.platformSpan(self.run, "closeWindow", null, 0, 0, started, "ok");
    }

    /// Watchdog: PagePort.recoverWindows with an automation.platform.eval
    /// child span (op "recoverWindows"; counts only, never URLs).
    pub fn recoverWindows(self: *External, gpa: std.mem.Allocator, windows: []const page_port.WindowId, timeout_ms: u64) page_port.PortError![]page_port.RecoveredWindow {
        self.run.native_timeout_ms = timeout_ms;
        const started = self.engine.clock.nowMs();
        const recovered = self.run.port.recoverWindows(gpa, windows, timeout_ms) catch |err| {
            self.engine.platformSpan(self.run, "recoverWindows", null, windows.len, 0, started, @errorName(err));
            return err;
        };
        self.engine.platformSpan(self.run, "recoverWindows", null, windows.len, recovered.len, started, "ok");
        return recovered;
    }

    /// v3.6: PagePort.listDialogs with an automation.platform.eval child
    /// span (op "listDialogs"; counts only, never messages).
    pub fn listDialogs(self: *External, gpa: std.mem.Allocator, timeout_ms: u64) page_port.PortError![]page_port.DialogInfo {
        self.run.native_timeout_ms = timeout_ms;
        const started = self.engine.clock.nowMs();
        const dialogs = self.run.port.listDialogs(gpa, timeout_ms) catch |err| {
            self.engine.platformSpan(self.run, "listDialogs", null, 0, 0, started, @errorName(err));
            return err;
        };
        self.engine.platformSpan(self.run, "listDialogs", null, 0, dialogs.len, started, "ok");
        return dialogs;
    }

    /// v3.6: PagePort.respondDialog with an automation.platform.eval child
    /// span (never the prompt text).
    pub fn respondDialog(self: *External, id: page_port.WindowId, accept: bool, text: ?[]const u8, timeout_ms: u64) page_port.PortError!void {
        self.run.native_timeout_ms = timeout_ms;
        const started = self.engine.clock.nowMs();
        self.run.port.respondDialog(id, accept, text, timeout_ms) catch |err| {
            self.engine.platformSpan(self.run, "respondDialog", null, 0, 0, started, @errorName(err));
            return err;
        };
        self.engine.platformSpan(self.run, "respondDialog", null, 0, 0, started, "ok");
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
    /// The page this command acts on (ExecuteOptions.port, else the
    /// engine's port).
    port: page_port.PagePort,
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
    /// Chunks of a guarded dom.type after the first: attempts, but not retries.
    extra_chunks: u32 = 0,
    /// Set when runDomUntil's failure may have come after the script acted (the page call
    /// failed, the answer was malformed, or the script threw), so what it sent is unknown.
    dispatch_unknown: bool = false,
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
            .port = options.port orelse self.port,
            .ids = withNoPageReason(self.nextIds(&ids_buf), options.no_page_reason),
            .cancel = options.cancel,
            .sink = options.route.telemetry_sink,
            .route = options.route,
            .build = options.build,
        };
        const started = self.clock.nowMs();
        var outcome = try self.executeRun(gpa, command, options, &run);
        // Cancelled while a page call ran (page.recover ended the page's web
        // process, or the browser stopped): that call's own failure is a
        // consequence, so the one reply says cancelled.
        if (outcome == .failure and run.cancelled() and outcome.failure.code != errors.downstreamCode(.cancelled)) {
            outcome.deinit(gpa);
            outcome = try automationFailure(gpa, .cancelled, null, run.ids);
        }
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
            .port = options.port orelse self.port,
            .ids = withNoPageReason(self.nextIds(&ids_buf), options.no_page_reason),
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
        var timeout_ms = requested_ms - options.queue_wait_ms;
        run.native_timeout_ms = timeout_ms;
        if (command.expect) |expect| {
            const checked_from = self.clock.nowMs();
            var refused = try self.checkExpect(gpa, expect, options.window, timeout_ms, run);
            // The check shares the command's one deadline and its cancellation (RoseCat 0c1132b,
            // db43ca1), in this order: a stop that came while it ran, then a check that used up
            // the time, then what it found. Only a check that matched with time left starts the
            // action, and the action gets only what is left.
            const spent = self.clock.nowMs() -| checked_from;
            if (run.cancelled() or spent >= timeout_ms) {
                if (refused) |*found| found.deinit(gpa);
                if (run.cancelled()) return automationFailure(gpa, .cancelled, null, ids);
                return timeoutWithReason(gpa, timeoutErrorFor(command.verb), "expect_used_deadline", ids, 0);
            }
            if (refused) |found| return found;
            timeout_ms -= spent;
            run.native_timeout_ms = timeout_ms;
        }
        return switch (command.verb) {
            .page_url => {
                const started = self.clock.nowMs();
                const value = run.port.url(gpa, timeout_ms) catch |err| {
                    self.platformSpan(run, "url", null, 0, 0, started, @errorName(err));
                    return portFailure(gpa, err, .action, ids);
                };
                defer gpa.free(value);
                self.platformSpan(run, "url", null, 0, value.len, started, "ok");
                return stringResult(gpa, "url", value);
            },
            .page_title => {
                const started = self.clock.nowMs();
                const value = run.port.title(gpa, timeout_ms) catch |err| {
                    self.platformSpan(run, "title", null, 0, 0, started, @errorName(err));
                    return portFailure(gpa, err, .action, ids);
                };
                defer gpa.free(value);
                self.platformSpan(run, "title", null, 0, value.len, started, "ok");
                return stringResult(gpa, "title", value);
            },
            .page_navigate => {
                const started = self.clock.nowMs();
                const before_unload: page_port.BeforeUnload = switch (command.before_unload) {
                    .fail => .fail,
                    .accept => .accept,
                    .dismiss => .dismiss,
                };
                run.port.navigateWithPolicy(command.url.?, before_unload, timeout_ms) catch |err| {
                    self.platformSpan(run, "navigate", null, command.url.?.len, 0, started, @errorName(err));
                    return portFailure(gpa, err, .navigation, ids);
                };
                self.platformSpan(run, "navigate", null, command.url.?.len, 0, started, "ok");
                return okResult(gpa);
            },
            .page_reload => {
                const started = self.clock.nowMs();
                run.port.reload(timeout_ms) catch |err| {
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

    /// S8 phase A (chat-drawer plan, "S8 in detail" decision 2): the approval card's state of the
    /// bound window, read here, inside the run's own FIFO ticket and before any page input. Null
    /// while it still holds; otherwise the refusal, and nothing has reached the page.
    fn checkExpect(self: *Engine, gpa: std.mem.Allocator, expect: router.Expect, window: ?page_port.WindowId, timeout_ms: u64, run: *Run) error{OutOfMemory}!?Outcome {
        switch (try self.readWindow(gpa, window, timeout_ms, run.ids)) {
            .refused => |refused| return refused,
            .window => |bound| {
                defer bound.deinit(gpa);
                return windowRefusal(gpa, bound, .{ .origin = expect.origin, .load_serial = expect.load_serial }, run.ids);
            },
        }
    }

    /// S8: the bound window's registry entry, or the refusal when it has none (no window bound,
    /// the registry unreadable, the window gone).
    fn readWindow(self: *Engine, gpa: std.mem.Allocator, window: ?page_port.WindowId, timeout_ms: u64, ids: script_command.Ids) error{OutOfMemory}!WindowRead {
        const id = window orelse return .{ .refused = try failureWithReason(gpa, invalid_params_code, "Invalid params", "expect_needs_window", ids) };
        const windows = self.port.listWindows(gpa, timeout_ms) catch |err| return .{ .refused = try portFailure(gpa, err, .action, ids) };
        defer page_port.freeWindows(gpa, windows);
        const info = for (windows) |w| {
            if (w.id == id) break w;
        } else return .{ .refused = try automationFailure(gpa, .session_invalid, "no_window", ids) };
        return .{ .window = .{
            .url = try gpa.dupe(u8, info.url),
            .load_serial = info.load_serial,
            .dialog_open = info.dialog_open,
            .crashed = info.terminated != null,
        } };
    }

    /// page.screenshot (v3.4): `{data: base64 PNG, width, height}`. A
    /// backend without screenshots keeps the -32603 "not supported" answer.
    /// The deadline bounds the capture: a PNG that arrives at or after it is
    /// action_timeout "screenshot_deadline". Encoding then is bounded by
    /// size (at most max_screenshot_bytes in, 4/3 of that out).
    fn screenshot(self: *Engine, gpa: std.mem.Allocator, full_page: bool, timeout_ms: u64, run: *Run) error{OutOfMemory}!Outcome {
        const started = self.clock.nowMs();
        const deadline = started +| timeout_ms;
        const shot = run.port.screenshot(gpa, full_page, timeout_ms) catch |err| {
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
        const text = run.port.evalJson(gpa, .page, body, "null", timeout_ms) catch |err| {
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
        if (command.verb == .dom_type and command.guard != null and command.text.?.len > 0) return self.typeInChunks(gpa, command, deadline, run);
        if (command.verb == .dom_type and command.text.?.len > 0) {
            if (command.delay_ms) |delay_ms| {
                if (delay_ms > 0) return self.typeWithDelay(gpa, command, delay_ms, deadline, run);
            }
        }
        return self.runDomUntil(gpa, command, deadline, run);
    }

    /// S8 decision 15: a guarded dom.type runs `type_chunk_codepoints` code points per automation.js
    /// evaluation, split at code-point boundaries, so the command's cancellation is seen between
    /// chunks (runDomUntil checks it before each) and the page's own event loop runs between them.
    /// The chunks are one action (RoseCat on 76cb14a): chunk 1 returns its target element's and
    /// its document's tokens, every later chunk carries both, and none starts at or after the
    /// deadline. One cumulative `data.sent` covers the completed chunks and the one that stopped
    /// when that one is known to have sent nothing more or reports its own counts; after an
    /// ambiguous failure the completed chunks are only `data.sent_at_least`.
    fn typeInChunks(self: *Engine, gpa: std.mem.Allocator, command: *const router.ParsedCommand, deadline: u64, run: *Run) error{OutOfMemory}!Outcome {
        var total = GuardSent{ .events = 0, .chars = 0 };
        var bound: ?ChunkAck = null;
        defer if (bound) |*ack| ack.deinit(gpa);
        var rest = command.text.?;
        while (rest.len > 0) {
            if (bound != null) {
                if (self.clock.nowMs() >= deadline) {
                    return withPriorSent(gpa, try timeoutWithReason(gpa, .action_timeout, "type_chunk_deadline", run.ids, run.attempts), total, .exact);
                }
                run.extra_chunks += 1;
            }
            const end = chunkEnd(rest, type_chunk_codepoints);
            var chunk = command.*;
            chunk.text = rest[0..end];
            chunk.chunk = true;
            if (bound) |ack| {
                chunk.chunk_target = ack.target;
                chunk.chunk_document = ack.document;
            }
            run.dispatch_unknown = false;
            var outcome = try self.runDomUntil(gpa, &chunk, deadline, run);
            switch (outcome) {
                .failure => return withPriorSent(gpa, outcome, total, if (run.dispatch_unknown) .at_least else .exact),
                .result => |json| {
                    const parsed = try chunkAck(gpa, json);
                    outcome.deinit(gpa);
                    var ack = parsed orelse return withPriorSent(gpa, internalError(), total, .at_least);
                    total = .{
                        .events = std.math.add(u64, total.events, ack.sent.events) catch {
                            ack.deinit(gpa);
                            return withPriorSent(gpa, internalError(), total, .at_least);
                        },
                        .chars = std.math.add(u64, total.chars, ack.sent.chars) catch {
                            ack.deinit(gpa);
                            return withPriorSent(gpa, internalError(), total, .at_least);
                        },
                    };
                    if (bound == null) bound = ack else ack.deinit(gpa);
                },
            }
            rest = rest[end..];
        }
        return okResult(gpa);
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
                const barrier = run.port.url(gpa, @max(deadline -| self.clock.nowMs(), 1)) catch |err| return portFailure(gpa, err, .action, ids);
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
                run.port.setInputFiles(gpa, script_command.handle_body, command_json, command.paths, native_timeout)
            else
                run.port.evalJson(gpa, .automation, script_command.handle_body, command_json, native_timeout);
            const text = answer catch |err| {
                self.platformSpanAttempt(run, ids.attempt_index, command_json.len, 0, started, @errorName(err));
                if (err == error.Timeout) {
                    // A page call cut short by the command deadline after
                    // earlier retryable failures: that evidence is the
                    // answer. (A Timeout before the deadline stays one.)
                    if (last.recorded and self.clock.nowMs() >= deadline) {
                        run.dispatch_unknown = true;
                        return deadlineFailure(gpa, &last, ids, run.attempts);
                    }
                    run.ended_on_bare_port_timeout = true;
                }
                run.dispatch_unknown = true;
                return portFailure(gpa, err, .action, ids);
            };
            defer gpa.free(text);
            self.platformSpanAttempt(run, ids.attempt_index, command_json.len, text.len, started, "ok");

            var script_result = script_command.parseScriptResult(gpa, text) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.MalformedScriptResult => {
                    run.dispatch_unknown = true;
                    return malformedResult();
                },
            };
            defer script_result.deinit();
            forwardScriptSpans(run, &script_result);
            captureMatchCount(run, &script_result);

            if (script_result.ok) {
                return .{ .result = try std.json.Stringify.valueAlloc(gpa, script_result.value, .{}) };
            }
            if (!shouldRetry(&script_result, is_wait)) {
                if (std.mem.eql(u8, script_result.error_name.?, script_command.script_exception)) run.dispatch_unknown = true;
                return scriptFailure(gpa, &script_result, ids);
            }
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
        if (!run.port.supportsNativeInput()) return automationFailure(gpa, .session_invalid, "unsupported", run.ids);
        // A hover, and a humanized click, move the pointer: without
        // nativeMove, say so now.
        const moves = command.verb == .dom_hover or (command.humanize and command.verb == .dom_click);
        if (moves and !run.port.supportsNativeMove()) {
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
        if (!run.port.supportsNativeScroll()) return automationFailure(gpa, .session_invalid, "unsupported", run.ids);
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
            const settled = run.port.nativeScroll(centre.x, centre.y, delta.x, delta.y, target.document(), remaining) catch |err| {
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
            .click => run.port.nativeClick(target.x, target.y, target.document(), remaining),
            .move => run.port.nativeMove(target.x, target.y, target.document(), remaining),
            .key => run.port.nativeKey(command.key.?, modifierBits(command.modifiers), target.document(), remaining),
        };
        dispatched catch |err| {
            self.platformSpan(run, op, null, payload_bytes, 0, started, @errorName(err));
            if (err == error.DocumentChanged and target.document() != null) return .relocate;
            return .{ .done = try portFailure(gpa, err, .action, run.ids) };
        };
        self.platformSpan(run, op, null, payload_bytes, 0, started, "ok");
        if (kind == .move) return self.settleHover(gpa, target, deadline, run);
        return .{ .done = try okResult(gpa) };
    }

    /// A native hover answers only once the page has the pointer's final
    /// move (v3.7 settlePointer): the backend may hold a move behind
    /// earlier mouse events while the caller's next page evaluation (a
    /// :hover check) overtakes it. The move was sent: a document change
    /// now is terminal document_changed (no re-locate, never success).
    fn settleHover(self: *Engine, gpa: std.mem.Allocator, target: *const Target, deadline: u64, run: *Run) error{OutOfMemory}!NativeStep {
        const remaining = deadline -| self.clock.nowMs(); // 0: the port times out at once
        const started = self.clock.nowMs();
        run.port.settlePointer(target.document(), remaining) catch |err| {
            self.platformSpan(run, "settlePointer", null, 0, 0, started, @errorName(err));
            if (err == error.DocumentChanged) return .{ .done = try automationFailure(gpa, .element_not_found, "document_changed", run.ids) };
            return .{ .done = try portFailure(gpa, err, .action, run.ids) };
        };
        self.platformSpan(run, "settlePointer", null, 0, 0, started, "ok");
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
        const cached = run.port.pointer();
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
            run.port.nativeMove(point.x, point.y, target.document(), remaining) catch |err| {
                self.platformSpan(run, "nativeMove", null, 0, 0, started, @errorName(err));
                if (err == error.DocumentChanged) {
                    if (i == 0) return .relocate;
                    return .{ .done = try automationFailure(gpa, .element_not_found, "document_changed", run.ids) };
                }
                return .{ .done = try portFailure(gpa, err, .action, run.ids) };
            };
            self.platformSpan(run, "nativeMove", null, 0, 0, started, "ok");
        }
        if (gesture == .hover) return self.settleHover(gpa, target, deadline, run);
        if (!self.sleepUnlessCancelled(dwell_ms, run)) return .{ .done = try automationFailure(gpa, .cancelled, null, run.ids) };
        const remaining = deadline -| self.clock.nowMs();
        if (remaining == 0) return .{ .done = try timeoutWithReason(gpa, .action_timeout, "deadline_before_input", run.ids, run.attempts) };
        run.native_timeout_ms = remaining;
        const started = self.clock.nowMs();
        run.port.nativeClick(goal.x, goal.y, target.document(), remaining) catch |err| {
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
        run.port.nativeText(text, target.document(), remaining, &sent) catch |err| {
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

/// S8: what an approval found of its bound window (`url` owned by `gpa`).
pub const BoundWindow = struct {
    url: []u8,
    load_serial: u64,
    dialog_open: bool,
    crashed: bool,

    pub fn deinit(self: BoundWindow, gpa: std.mem.Allocator) void {
        gpa.free(self.url);
    }
};

pub const WindowRead = union(enum) { window: BoundWindow, refused: Outcome };

/// S8: what an approval expects of its window; null fields are not compared.
pub const WindowWant = struct {
    origin: ?[]const u8 = null,
    /// The exact URL a flow's approved navigation must have committed (phase C).
    url: ?[]const u8 = null,
    load_serial: ?u64 = null,
};

/// S8 ("S8 in detail" decision 2): the refusal for a window that no longer matches, in one order:
/// a dialog (-32013), then -32015 `crashed`, `origin_changed`, `url_changed`, `load_serial_changed`.
/// Null while it matches.
pub fn windowRefusal(gpa: std.mem.Allocator, window: BoundWindow, want: WindowWant, ids: script_command.Ids) error{OutOfMemory}!?Outcome {
    if (window.dialog_open) return try automationFailure(gpa, .dialog_open, null, ids);
    if (window.crashed) return try automationFailure(gpa, .expectation_mismatch, "crashed", ids);
    if (want.origin) |origin| {
        const actual = try originOf(gpa, window.url);
        defer gpa.free(actual);
        if (!std.mem.eql(u8, actual, origin)) return try automationFailure(gpa, .expectation_mismatch, "origin_changed", ids);
    }
    if (want.url) |exact| if (!std.mem.eql(u8, window.url, exact)) return try automationFailure(gpa, .expectation_mismatch, "url_changed", ids);
    if (want.load_serial) |serial| if (window.load_serial != serial) return try automationFailure(gpa, .expectation_mismatch, "load_serial_changed", ids);
    return null;
}

/// S8: a page URL's origin as an approval card shows and binds it: the lowercased scheme, "://",
/// and the lowercased authority without any userinfo (host and an explicit port, as the URL has
/// them). `file:` URLs give "file://"; a URL with no authority gives "null". Owned by `gpa`.
pub fn originOf(gpa: std.mem.Allocator, url: []const u8) error{OutOfMemory}![]u8 {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return gpa.dupe(u8, "null");
    const scheme = url[0..colon];
    const rest = url[colon + 1 ..];
    if (scheme.len == 0 or !std.mem.startsWith(u8, rest, "//")) return gpa.dupe(u8, "null");
    const after = rest[2..];
    const end = std.mem.indexOfAny(u8, after, "/?#") orelse after.len;
    var authority = after[0..end];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    const out = try std.mem.concat(gpa, u8, &.{ scheme, "://", authority });
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn withNoPageReason(ids: script_command.Ids, reason: ?[]const u8) script_command.Ids {
    var out = ids;
    out.no_page_reason = reason;
    return out;
}

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
        .failure => |failure| if (errors.isAutomationCode(failure.code)) failure.message else null,
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
        .retry_count = run.attempts -| 1 -| run.extra_chunks,
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

pub const PortContext = enum { action, navigation };

/// The standard PagePort error -> JSON-RPC failure mapping (also used by
/// routes that reach the page through External).
pub fn portFailure(gpa: std.mem.Allocator, err: page_port.PortError, context: PortContext, ids: script_command.Ids) error{OutOfMemory}!Outcome {
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
        error.NoPage => return automationFailure(gpa, .session_invalid, ids.no_page_reason, ids),
        // A page dialog blocks the page; dialog.get / dialog.respond.
        error.DialogOpen => .dialog_open,
        error.NoDialog => return failureWithReason(gpa, invalid_params_code, "Invalid params", "no_dialog", ids),
        // onBeforeUnload "dismiss": the page asked and stayed.
        error.BeforeUnloadDismissed => return automationFailure(gpa, .navigation_failed, "beforeunload_dismissed", ids),
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
pub fn failureWithReason(gpa: std.mem.Allocator, code: i64, message: []const u8, reason: []const u8, ids: script_command.Ids) error{OutOfMemory}!Outcome {
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
    /// S8 decision 14: a guard stop's exact counts, from automation.js.
    sent: ?GuardSent = null,
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
        error.NavigationFailed, error.BeforeUnloadDismissed => .navigation_failed,
        error.DialogOpen => .dialog_open,
        error.NoDialog => return partialInternal(gpa, "Internal error", sent_chars, run),
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
    if (automation_error == .expectation_mismatch) return guardStop(gpa, script_result, ids);
    return automationFailure(gpa, automation_error, script_result.reason, ids);
}

pub const GuardSent = struct { events: u64, chars: u64 };

/// S8 decision 15: the code points per evaluation of a guarded dom.type.
pub const type_chunk_codepoints = 16;

/// The byte length of `text`'s first `max` code points (all of it when shorter); a malformed
/// byte counts as one, so a chunk never splits inside a well-formed character.
fn chunkEnd(text: []const u8, max: usize) usize {
    var index: usize = 0;
    var count: usize = 0;
    while (index < text.len and count < max) : (count += 1) {
        const len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        index = @min(text.len, index + len);
    }
    return index;
}

/// A chunk's success result (`value`): its own counts and its target element's and document's
/// tokens (owned).
const ChunkAck = struct {
    sent: GuardSent,
    target: []u8,
    document: []u8,

    fn deinit(self: *ChunkAck, gpa: std.mem.Allocator) void {
        gpa.free(self.target);
        gpa.free(self.document);
    }
};

/// Null when the result lacks the counts or either token.
fn chunkAck(gpa: std.mem.Allocator, json: []const u8) error{OutOfMemory}!?ChunkAck {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const counts = switch (object.get("sent") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const sent = GuardSent{ .events = countOf(counts.get("events")) orelse return null, .chars = countOf(counts.get("chars")) orelse return null };
    const target = switch (object.get("target") orelse return null) {
        .string => |t| t,
        else => return null,
    };
    const document = switch (object.get("document") orelse return null) {
        .string => |d| d,
        else => return null,
    };
    if (target.len == 0 or document.len == 0) return null;
    const owned_target = try gpa.dupe(u8, target);
    errdefer gpa.free(owned_target);
    return .{ .sent = sent, .target = owned_target, .document = try gpa.dupe(u8, document) };
}

fn internalError() Outcome {
    return .{ .failure = .{ .code = internal_error_code, .message = "Internal error" } };
}

/// How the completed chunks' counts join a later chunk's failure.
const PriorSent = enum {
    /// The failing chunk sent nothing more, or reports its own counts: one exact `sent`.
    exact,
    /// The failing chunk may have acted: the completed chunks are only `sent_at_least`.
    at_least,
};

/// A chunk's failure, with the completed chunks' counts: added to its own `sent` (or as its
/// `sent` when it has none) when exact, else as `sent_at_least`. With nothing completed it is
/// returned as it is.
fn withPriorSent(gpa: std.mem.Allocator, outcome: Outcome, prior: GuardSent, mode: PriorSent) error{OutOfMemory}!Outcome {
    if (prior.events == 0 and prior.chars == 0) return outcome;
    var failure = outcome.failure;
    const old = failure.data_json orelse "{}";
    const Own = struct { sent: ?GuardSent = null };
    const own: GuardSent = if (mode == .at_least) .{ .events = 0, .chars = 0 } else blk: {
        const parsed = std.json.parseFromSlice(Own, gpa, old, .{ .ignore_unknown_fields = true }) catch break :blk .{ .events = 0, .chars = 0 };
        defer parsed.deinit();
        break :blk parsed.value.sent orelse .{ .events = 0, .chars = 0 };
    };
    const key = if (mode == .exact) "\"sent\":{" else "\"sent_at_least\":{";
    const counts = try std.fmt.allocPrint(gpa, "{s}\"events\":{d},\"chars\":{d}}}", .{ key, prior.events +| own.events, prior.chars +| own.chars });
    defer gpa.free(counts);
    // Data objects are flat but for `sent` (AutomationErrorData): replace it, or add it first.
    const data_json = if (mode == .exact and std.mem.indexOf(u8, old, key) != null) blk: {
        const at = std.mem.indexOf(u8, old, key).?;
        const close = std.mem.indexOfScalarPos(u8, old, at + key.len, '}') orelse break :blk try gpa.dupe(u8, old);
        break :blk try std.mem.concat(gpa, u8, &.{ old[0..at], counts, old[close + 1 ..] });
    } else if (old.len >= 2 and old[0] == '{') blk: {
        const sep: []const u8 = if (std.mem.trim(u8, old[1 .. old.len - 1], " ").len == 0) "" else ",";
        break :blk try std.mem.concat(gpa, u8, &.{ "{", counts, sep, old[1..] });
    } else try std.fmt.allocPrint(gpa, "{{{s}}}", .{counts});
    if (failure.data_json) |owned| gpa.free(owned);
    failure.data_json = data_json;
    return .{ .failure = failure };
}

/// S8 decision 14: automation.js stopped an action at its guard. -32015 with the reason and the
/// exact `sent` counts (events dispatched, characters written); a malformed count is not
/// reported as zero: the stop then carries no `sent`.
fn guardStop(gpa: std.mem.Allocator, script_result: *const script_command.ScriptResult, ids: script_command.Ids) error{OutOfMemory}!Outcome {
    const sent: ?GuardSent = blk: {
        const data = script_result.data orelse break :blk null;
        const object = switch (data) {
            .object => |o| o,
            else => break :blk null,
        };
        const counts = switch (object.get("sent") orelse break :blk null) {
            .object => |o| o,
            else => break :blk null,
        };
        const events = countOf(counts.get("events")) orelse break :blk null;
        const chars = countOf(counts.get("chars")) orelse break :blk null;
        break :blk .{ .events = events, .chars = chars };
    };
    const data = AutomationErrorData{ .reason = script_result.reason, .sent = sent, .trace_id = ids.trace_id, .command_id = ids.command_id };
    return .{ .failure = .{
        .code = errors.downstreamCode(.expectation_mismatch),
        .message = errors.name(.expectation_mismatch),
        .data_json = try std.json.Stringify.valueAlloc(gpa, data, .{ .emit_null_optional_fields = false }),
    } };
}

fn countOf(value: ?std.json.Value) ?u64 {
    return switch (value orelse return null) {
        .integer => |n| std.math.cast(u64, n),
        // Script results keep numbers as text (script_command.parseScriptResult).
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
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
