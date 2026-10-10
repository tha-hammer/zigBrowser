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
    kind: enum { click, key, text },
    x: f64 = 0,
    y: f64 = 0,
    /// Key name or typed text.
    data: []u8 = &.{},
    modifiers: u8 = 0,
    timeout_ms: u64,
};

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
    url_result: ?page_port.PortError = null,
    last_read_timeout_ms: u64 = 0,
    /// When set, every eval advances this clock (simulates work taking time).
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
    native_failed_sent: usize = 0,
    native_cost_ms: u64 = 0,
    /// When set, a successful text call reports this many code points
    /// (simulates a backend that stopped short).
    native_success_sent: ?usize = null,

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
        for (self.native_calls.items) |call| self.gpa.free(call.data);
        self.native_calls.deinit(self.gpa);
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

    fn recordNative(self: *FakePagePort, call: NativeCall) page_port.PortError!?page_port.PortError {
        const index = self.native_calls.items.len;
        // Takes ownership of call.data, also when the append fails.
        self.native_calls.append(self.gpa, call) catch {
            self.gpa.free(call.data);
            return error.OutOfMemory;
        };
        if (self.clock) |clock| clock.now_ms += self.native_cost_ms;
        // As an optional payload: a bare error value would take the error branch.
        if (self.native_fail_at) |at| if (at == index) return @as(?page_port.PortError, self.native_error);
        return null;
    }

    fn nativeClick(ptr: *anyopaque, x: f64, y: f64, timeout_ms: u64) page_port.PortError!void {
        const self = from(ptr);
        if (try self.recordNative(.{ .kind = .click, .x = x, .y = y, .timeout_ms = timeout_ms })) |err| return err;
    }

    fn nativeKey(ptr: *anyopaque, key: []const u8, modifiers: u8, timeout_ms: u64) page_port.PortError!void {
        const self = from(ptr);
        const data = self.gpa.dupe(u8, key) catch return error.OutOfMemory;
        if (try self.recordNative(.{ .kind = .key, .data = data, .modifiers = modifiers, .timeout_ms = timeout_ms })) |err| return err;
    }

    fn nativeText(ptr: *anyopaque, text: []const u8, timeout_ms: u64, sent_chars: *usize) page_port.PortError!void {
        const self = from(ptr);
        const data = self.gpa.dupe(u8, text) catch return error.OutOfMemory;
        if (try self.recordNative(.{ .kind = .text, .data = data, .timeout_ms = timeout_ms })) |err| {
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
        const index = self.eval_calls.items.len;
        self.eval_calls.append(self.gpa, .{
            .world = world,
            .body = self.gpa.dupe(u8, body) catch return error.OutOfMemory,
            .arg = self.gpa.dupe(u8, arg_json) catch return error.OutOfMemory,
            .timeout_ms = timeout_ms,
        }) catch return error.OutOfMemory;
        if (self.clock) |clock| clock.now_ms += self.eval_cost_ms;
        if (self.eval_replies.len == 0) return error.EvalFailed;
        const reply = self.eval_replies[@min(index, self.eval_replies.len - 1)];
        return switch (reply) {
            .json => |text| gpa.dupe(u8, text),
            .err => |err| err,
        };
    }

    fn navigate(ptr: *anyopaque, url_text: []const u8, timeout_ms: u64) page_port.PortError!void {
        const self = from(ptr);
        self.navigate_calls.append(self.gpa, self.gpa.dupe(u8, url_text) catch return error.OutOfMemory) catch return error.OutOfMemory;
        self.navigate_timeouts.append(self.gpa, timeout_ms) catch return error.OutOfMemory;
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
