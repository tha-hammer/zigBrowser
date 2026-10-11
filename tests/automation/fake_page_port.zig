//! Test double for automation.page_port.PagePort, plus a fake clock.
const std = @import("std");
const automation = @import("automation");

const page_port = automation.page_port;
const engine = automation.engine;

pub const EvalCall = struct {
    world: page_port.World,
    body: []u8,
    arg: []u8,
    timeout_ms: u64,
};

pub const EvalReply = union(enum) {
    json: []const u8,
    err: page_port.PortError,
};

pub const NativeCall = struct {
    /// settle: v3.7 settlePointer (x/y unused).
    kind: enum { click, key, text, move, scroll, settle },
    x: f64 = 0,
    y: f64 = 0,
    /// Scroll calls: the wheel's CSS px deltas.
    delta_x: f64 = 0,
    delta_y: f64 = 0,
    /// Key name or typed text.
    data: []u8 = &.{},
    modifiers: u8 = 0,
    /// The document token the call was bound to (null: none).
    document: ?[]u8 = null,
    timeout_ms: u64,
    /// Fake clock time when the call started.
    at_ms: u64 = 0,
};

/// rateLimitScan answers (automation.js shapes).
pub const clean_scan = "{\"ok\":true,\"value\":{\"signals\":[]},\"telemetry\":[]}";
pub fn detectedScan(comptime signal: []const u8, comptime platform: []const u8) []const u8 {
    return "{\"ok\":false,\"error\":\"platform_rate_limited\",\"retryable\":false,\"data\":{\"signal\":\"" ++ signal ++
        "\",\"platform\":\"" ++ platform ++ "\",\"signals\":[{\"kind\":\"" ++ signal ++ "\",\"text_hash\":\"\",\"confidence\":0.95}]}}";
}

pub const FakePagePort = struct {
    gpa: std.mem.Allocator,
    eval_calls: std.ArrayListUnmanaged(EvalCall) = .empty,
    /// Replies returned in order; the last one repeats once exhausted.
    eval_replies: []const EvalReply = &.{},
    navigate_calls: std.ArrayListUnmanaged([]u8) = .empty,
    navigate_timeouts: std.ArrayListUnmanaged(u64) = .empty,
    navigate_result: page_port.PortError!void = {},
    reload_calls: usize = 0,
    reload_result: page_port.PortError!void = {},
    current_url: []const u8 = "about:blank",
    current_title: []const u8 = "",
    /// When set, a navigate makes its URL the current one (flows that check
    /// where they landed, e.g. a LinkedIn profile).
    navigate_sets_url: bool = false,
    url_result: ?page_port.PortError = null,
    last_read_timeout_ms: u64 = 0,
    /// When set, every eval advances this clock (simulates work taking time).
    /// Like a real port it never runs past the timeout it was given: a cost
    /// above the timeout consumes the timeout and returns Timeout.
    clock: ?*FakeClock = null,
    eval_cost_ms: u64 = 0,
    /// Simulated readiness wait inside url() (advances `clock`).
    url_cost_ms: u64 = 0,
    url_calls: usize = 0,
    native_calls: std.ArrayListUnmanaged(NativeCall) = .empty,
    /// The native call with this index fails with `native_error`, after
    /// typing `native_failed_sent` code points (text calls).
    native_fail_at: ?usize = null,
    native_error: page_port.PortError = error.Timeout,
    /// Every native call from `native_fail_at` on fails (not just that one).
    native_fail_onwards: bool = false,
    native_failed_sent: usize = 0,
    native_cost_ms: u64 = 0,
    /// When set, a successful text call reports this many code points
    /// (simulates a backend that stopped short).
    native_success_sent: ?usize = null,
    /// While `hold` is set and true, every eval blocks (and sets `held`).
    hold: ?*std.atomic.Value(bool) = null,
    held: std.atomic.Value(bool) = .init(false),
    /// Simulated per-window pointer cache: set after a move or click was
    /// dispatched (not on a failed call).
    pointer_pos: ?page_port.Point = null,
    /// Simulated page scroll offsets: each successful nativeScroll adds its
    /// deltas (clamped at 0) and returns the result.
    scroll_pos: page_port.ScrollOffsets = .{ .x = 0, .y = 0 },
    /// setInputFiles: the paths of each call, joined with '\n'.
    files_calls: std.ArrayListUnmanaged([]u8) = .empty,
    /// setInputFiles failure: BadFile fails before the op runs (no eval
    /// recorded); any other error after the op ran.
    files_error: ?page_port.PortError = null,
    screenshot_calls: usize = 0,
    screenshot_full_page: ?bool = null,
    screenshot_error: ?page_port.PortError = null,
    screenshot_png: []const u8 = "\x89PNG\r\n\x1a\nfake",
    /// Simulated capture time on `clock`.
    screenshot_cost_ms: u64 = 0,
    /// N20: automation.js rateLimitScan evals are answered from here (in
    /// order; the last repeats), cost no time, and are counted in
    /// `scan_calls` instead of `eval_calls`, so flow tests keep their step
    /// sequences. Default: a clean page.
    scan_replies: []const EvalReply = &.{.{ .json = clean_scan }},
    /// Simulated time each scan takes on `clock` (by scan index; the last
    /// repeats). A cost above the scan's timeout consumes the timeout and
    /// returns Timeout, like a real port.
    scan_costs_ms: []const u64 = &.{0},
    scan_calls: usize = 0,
    /// The timeout each scan was given.
    scan_timeouts: [64]u64 = undefined,
    /// Sets `cancel` while scan number `cancel_at_scan` runs (a server stop
    /// arriving mid-scan).
    cancel: ?*std.atomic.Value(bool) = null,
    cancel_at_scan: usize = 0,
    /// The platform each scan asked about (last one).
    scan_platform: [16]u8 = undefined,
    scan_platform_len: usize = 0,
    /// eval_calls.len when each scan ran (where it sat between steps).
    scan_positions: [64]usize = undefined,

    pub fn init(gpa: std.mem.Allocator) FakePagePort {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FakePagePort) void {
        for (self.eval_calls.items) |call| {
            self.gpa.free(call.body);
            self.gpa.free(call.arg);
        }
        self.eval_calls.deinit(self.gpa);
        for (self.navigate_calls.items) |u| self.gpa.free(u);
        self.navigate_calls.deinit(self.gpa);
        self.navigate_timeouts.deinit(self.gpa);
        for (self.native_calls.items) |call| {
            self.gpa.free(call.data);
            if (call.document) |d| self.gpa.free(d);
        }
        self.native_calls.deinit(self.gpa);
        for (self.files_calls.items) |f| self.gpa.free(f);
        self.files_calls.deinit(self.gpa);
    }

    /// The typed texts of the native text calls, concatenated.
    pub fn nativeTyped(self: *const FakePagePort, buf: []u8) []const u8 {
        var len: usize = 0;
        for (self.native_calls.items) |call| {
            if (call.kind != .text) continue;
            @memcpy(buf[len..][0..call.data.len], call.data);
            len += call.data.len;
        }
        return buf[0..len];
    }

    pub fn port(self: *FakePagePort) page_port.PagePort {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = page_port.PagePort.VTable{
        .evalJson = evalJson,
        .navigate = navigate,
        .reload = reload,
        .url = url,
        .title = title,
        .nativeClick = nativeClick,
        .nativeKey = nativeKey,
        .nativeText = nativeText,
        .nativeMove = nativeMove,
        .pointer = pointer,
        .setInputFiles = setInputFiles,
        .nativeScroll = nativeScroll,
        .screenshot = screenshot,
        .settlePointer = settlePointer,
    };

    /// A port with native click/key/text but no pointer motion (v3.1).
    /// v3.3/v3.4 keep their Unsupported defaults.
    pub fn portWithoutMove(self: *FakePagePort) page_port.PagePort {
        return .{ .ptr = self, .vtable = &v31_vtable };
    }

    const v31_vtable = page_port.PagePort.VTable{
        .evalJson = evalJson,
        .navigate = navigate,
        .reload = reload,
        .url = url,
        .title = title,
        .nativeClick = nativeClick,
        .nativeKey = nativeKey,
        .nativeText = nativeText,
    };

    /// A port with the v2 vtable only (no native input), like a non-GTK
    /// backend.
    pub fn portWithoutNative(self: *FakePagePort) page_port.PagePort {
        return .{ .ptr = self, .vtable = &v2_vtable };
    }

    const v2_vtable = page_port.PagePort.VTable{
        .evalJson = evalJson,
        .navigate = navigate,
        .reload = reload,
        .url = url,
        .title = title,
    };

    fn recordNative(self: *FakePagePort, call_in: NativeCall) page_port.PortError!?page_port.PortError {
        var call = call_in;
        call.at_ms = if (self.clock) |clock| clock.now_ms else 0;
        const index = self.native_calls.items.len;
        // Takes ownership of call.data/document, also when the append fails.
        self.native_calls.append(self.gpa, call) catch {
            self.gpa.free(call.data);
            if (call.document) |d| self.gpa.free(d);
            return error.OutOfMemory;
        };
        if (self.clock) |clock| clock.now_ms += self.native_cost_ms;
        // As an optional payload: a bare error value would take the error branch.
        if (self.native_fail_at) |at| if (at == index or (self.native_fail_onwards and index > at)) return @as(?page_port.PortError, self.native_error);
        return null;
    }

    fn dupeDocument(self: *FakePagePort, document: ?[]const u8) page_port.PortError!?[]u8 {
        const d = document orelse return null;
        return self.gpa.dupe(u8, d) catch error.OutOfMemory;
    }

    fn nativeClick(ptr: *anyopaque, x: f64, y: f64, document: ?[]const u8, timeout_ms: u64) page_port.PortError!void {
        const self = from(ptr);
        const doc = try self.dupeDocument(document);
        if (try self.recordNative(.{ .kind = .click, .x = x, .y = y, .document = doc, .timeout_ms = timeout_ms })) |err| return err;
        self.pointer_pos = .{ .x = x, .y = y };
    }

    fn nativeMove(ptr: *anyopaque, x: f64, y: f64, document: ?[]const u8, timeout_ms: u64) page_port.PortError!void {
        const self = from(ptr);
        const doc = try self.dupeDocument(document);
        if (try self.recordNative(.{ .kind = .move, .x = x, .y = y, .document = doc, .timeout_ms = timeout_ms })) |err| return err;
        self.pointer_pos = .{ .x = x, .y = y };
    }

    fn settlePointer(ptr: *anyopaque, document: ?[]const u8, timeout_ms: u64) page_port.PortError!void {
        const self = from(ptr);
        const doc = try self.dupeDocument(document);
        if (try self.recordNative(.{ .kind = .settle, .document = doc, .timeout_ms = timeout_ms })) |err| return err;
    }

    fn pointer(ptr: *anyopaque) ?page_port.Point {
        return from(ptr).pointer_pos;
    }

    fn nativeScroll(ptr: *anyopaque, x: f64, y: f64, delta_x: f64, delta_y: f64, document: ?[]const u8, timeout_ms: u64) page_port.PortError!page_port.ScrollOffsets {
        const self = from(ptr);
        const doc = try self.dupeDocument(document);
        if (try self.recordNative(.{ .kind = .scroll, .x = x, .y = y, .delta_x = delta_x, .delta_y = delta_y, .document = doc, .timeout_ms = timeout_ms })) |err| return err;
        self.scroll_pos = .{ .x = @max(0, self.scroll_pos.x + delta_x), .y = @max(0, self.scroll_pos.y + delta_y) };
        return self.scroll_pos;
    }

    fn setInputFiles(ptr: *anyopaque, gpa: std.mem.Allocator, body: []const u8, arg_json: []const u8, paths: []const []const u8, timeout_ms: u64) page_port.PortError![]u8 {
        const self = from(ptr);
        const joined = std.mem.join(self.gpa, "\n", paths) catch return error.OutOfMemory;
        self.files_calls.append(self.gpa, joined) catch {
            self.gpa.free(joined);
            return error.OutOfMemory;
        };
        if (self.files_error) |err| if (err == error.BadFile) return err;
        const answer = try evalJson(ptr, gpa, .automation, body, arg_json, timeout_ms);
        if (self.files_error) |err| {
            gpa.free(answer);
            return err;
        }
        return answer;
    }

    fn screenshot(ptr: *anyopaque, gpa: std.mem.Allocator, full_page: bool, timeout_ms: u64) page_port.PortError!page_port.Screenshot {
        const self = from(ptr);
        self.last_read_timeout_ms = timeout_ms;
        self.screenshot_calls += 1;
        self.screenshot_full_page = full_page;
        if (self.clock) |clock| clock.now_ms += self.screenshot_cost_ms;
        if (self.screenshot_error) |err| return err;
        return .{ .png = try gpa.dupe(u8, self.screenshot_png), .width = 800, .height = 600 };
    }

    /// Native calls of one kind.
    pub fn nativeOf(self: *const FakePagePort, kind: @FieldType(NativeCall, "kind"), buf: []NativeCall) []NativeCall {
        var n: usize = 0;
        for (self.native_calls.items) |call| {
            if (call.kind != kind) continue;
            buf[n] = call;
            n += 1;
        }
        return buf[0..n];
    }

    fn nativeKey(ptr: *anyopaque, key: []const u8, modifiers: u8, document: ?[]const u8, timeout_ms: u64) page_port.PortError!void {
        const self = from(ptr);
        const doc = try self.dupeDocument(document);
        const data = self.gpa.dupe(u8, key) catch {
            if (doc) |d| self.gpa.free(d);
            return error.OutOfMemory;
        };
        if (try self.recordNative(.{ .kind = .key, .data = data, .modifiers = modifiers, .document = doc, .timeout_ms = timeout_ms })) |err| return err;
    }

    fn nativeText(ptr: *anyopaque, text: []const u8, document: ?[]const u8, timeout_ms: u64, sent_chars: *usize) page_port.PortError!void {
        const self = from(ptr);
        const doc = try self.dupeDocument(document);
        const data = self.gpa.dupe(u8, text) catch {
            if (doc) |d| self.gpa.free(d);
            return error.OutOfMemory;
        };
        if (try self.recordNative(.{ .kind = .text, .data = data, .document = doc, .timeout_ms = timeout_ms })) |err| {
            sent_chars.* = self.native_failed_sent;
            return err;
        }
        sent_chars.* = self.native_success_sent orelse (std.unicode.utf8CountCodepoints(text) catch text.len);
    }

    fn from(ptr: *anyopaque) *FakePagePort {
        return @ptrCast(@alignCast(ptr));
    }

    fn evalJson(ptr: *anyopaque, gpa: std.mem.Allocator, world: page_port.World, body: []const u8, arg_json: []const u8, timeout_ms: u64) page_port.PortError![]u8 {
        const self = from(ptr);
        if (std.mem.indexOf(u8, arg_json, "\"op\":\"rateLimitScan\"") != null) return self.scan(gpa, arg_json, timeout_ms);
        const index = self.eval_calls.items.len;
        self.eval_calls.append(self.gpa, .{
            .world = world,
            .body = self.gpa.dupe(u8, body) catch return error.OutOfMemory,
            .arg = self.gpa.dupe(u8, arg_json) catch return error.OutOfMemory,
            .timeout_ms = timeout_ms,
        }) catch return error.OutOfMemory;
        if (self.hold) |hold| {
            while (hold.load(.acquire)) {
                self.held.store(true, .release);
                std.atomic.spinLoopHint();
            }
        }
        if (self.clock) |clock| {
            if (self.eval_cost_ms > timeout_ms) {
                clock.now_ms += timeout_ms;
                return error.Timeout;
            }
            clock.now_ms += self.eval_cost_ms;
        }
        if (self.eval_replies.len == 0) return error.EvalFailed;
        const reply = self.eval_replies[@min(index, self.eval_replies.len - 1)];
        return switch (reply) {
            .json => |text| gpa.dupe(u8, text),
            .err => |err| err,
        };
    }

    fn scan(self: *FakePagePort, gpa: std.mem.Allocator, arg_json: []const u8, timeout_ms: u64) page_port.PortError![]u8 {
        const index = self.scan_calls;
        if (index < self.scan_positions.len) self.scan_positions[index] = self.eval_calls.items.len;
        if (index < self.scan_timeouts.len) self.scan_timeouts[index] = timeout_ms;
        self.scan_calls += 1;
        if (self.cancel) |flag| if (index == self.cancel_at_scan) flag.store(true, .release);
        if (self.clock) |clock| if (self.scan_costs_ms.len > 0) {
            const cost = self.scan_costs_ms[@min(index, self.scan_costs_ms.len - 1)];
            if (cost > timeout_ms) {
                clock.now_ms += timeout_ms;
                return error.Timeout;
            }
            clock.now_ms += cost;
        };
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, arg_json, .{}) catch return error.EvalFailed;
        defer parsed.deinit();
        if (parsed.value.object.get("options")) |options| if (options.object.get("platform")) |platform| {
            const name = platform.string;
            const n = @min(name.len, self.scan_platform.len);
            @memcpy(self.scan_platform[0..n], name[0..n]);
            self.scan_platform_len = n;
        };
        if (self.scan_replies.len == 0) return error.EvalFailed;
        return switch (self.scan_replies[@min(index, self.scan_replies.len - 1)]) {
            .json => |text| gpa.dupe(u8, text),
            .err => |err| err,
        };
    }

    pub fn scannedPlatform(self: *const FakePagePort) []const u8 {
        return self.scan_platform[0..self.scan_platform_len];
    }

    fn navigate(ptr: *anyopaque, url_text: []const u8, timeout_ms: u64) page_port.PortError!void {
        const self = from(ptr);
        self.navigate_calls.append(self.gpa, self.gpa.dupe(u8, url_text) catch return error.OutOfMemory) catch return error.OutOfMemory;
        self.navigate_timeouts.append(self.gpa, timeout_ms) catch return error.OutOfMemory;
        if (self.navigate_sets_url) self.current_url = self.navigate_calls.items[self.navigate_calls.items.len - 1];
        return self.navigate_result;
    }

    fn reload(ptr: *anyopaque, timeout_ms: u64) page_port.PortError!void {
        _ = timeout_ms;
        const self = from(ptr);
        self.reload_calls += 1;
        return self.reload_result;
    }

    fn url(ptr: *anyopaque, gpa: std.mem.Allocator, timeout_ms: u64) page_port.PortError![]u8 {
        const self = from(ptr);
        self.last_read_timeout_ms = timeout_ms;
        self.url_calls += 1;
        if (self.clock) |clock| clock.now_ms += self.url_cost_ms;
        if (self.url_result) |err| return err;
        return gpa.dupe(u8, self.current_url);
    }

    fn title(ptr: *anyopaque, gpa: std.mem.Allocator, timeout_ms: u64) page_port.PortError![]u8 {
        const self = from(ptr);
        self.last_read_timeout_ms = timeout_ms;
        return gpa.dupe(u8, self.current_title);
    }
};

pub const FakeClock = struct {
    gpa: std.mem.Allocator,
    now_ms: u64 = 0,
    sleeps: std.ArrayListUnmanaged(u64) = .empty,

    pub fn init(gpa: std.mem.Allocator) FakeClock {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FakeClock) void {
        self.sleeps.deinit(self.gpa);
    }

    pub fn clock(self: *FakeClock) engine.Clock {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = engine.Clock.VTable{ .nowMs = nowMs, .sleepMs = sleepMs };

    fn nowMs(ptr: *anyopaque) u64 {
        const self: *FakeClock = @ptrCast(@alignCast(ptr));
        return self.now_ms;
    }

    fn sleepMs(ptr: *anyopaque, ms: u64) void {
        const self: *FakeClock = @ptrCast(@alignCast(ptr));
        self.sleeps.append(self.gpa, ms) catch {};
        self.now_ms += ms;
    }
};
