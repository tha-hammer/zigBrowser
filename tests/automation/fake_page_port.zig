//! Test double for automation.page_port.PagePort, plus a fake clock.
const std = @import("std");
const automation = @import("automation");

const page_port = automation.page_port;
const engine = automation.engine;

pub const EvalCall = struct {
    world: page_port.World,
    body: []u8,
    timeout_ms: u64,
};

pub const EvalReply = union(enum) {
    json: []const u8,
    err: page_port.PortError,
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
    /// When set, every eval advances this clock (simulates work taking time).
    clock: ?*FakeClock = null,
    eval_cost_ms: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) FakePagePort {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FakePagePort) void {
        for (self.eval_calls.items) |call| self.gpa.free(call.body);
        self.eval_calls.deinit(self.gpa);
        for (self.navigate_calls.items) |u| self.gpa.free(u);
        self.navigate_calls.deinit(self.gpa);
        self.navigate_timeouts.deinit(self.gpa);
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
    };

    fn from(ptr: *anyopaque) *FakePagePort {
        return @ptrCast(@alignCast(ptr));
    }

    fn evalJson(ptr: *anyopaque, gpa: std.mem.Allocator, world: page_port.World, body: []const u8, timeout_ms: u64) page_port.PortError![]u8 {
        const self = from(ptr);
        const index = self.eval_calls.items.len;
        self.eval_calls.append(self.gpa, .{
            .world = world,
            .body = self.gpa.dupe(u8, body) catch return error.OutOfMemory,
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

    fn url(ptr: *anyopaque, gpa: std.mem.Allocator) page_port.PortError![]u8 {
        const self = from(ptr);
        if (self.url_result) |err| return err;
        return gpa.dupe(u8, self.current_url);
    }

    fn title(ptr: *anyopaque, gpa: std.mem.Allocator) page_port.PortError![]u8 {
        const self = from(ptr);
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
