const std = @import("std");

pub const Step = enum {
    stop_script,
    sever_handles,
    drain_finalizers,
    teardown_isolate,
    run_script,
    pump_microtasks,
};

pub const SpyScriptEngine = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayList(Step) = .empty,

    pub fn init(allocator: std.mem.Allocator) SpyScriptEngine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SpyScriptEngine) void {
        self.calls.deinit(self.allocator);
    }

    pub fn stopScript(ptr: *anyopaque) void {
        const self: *SpyScriptEngine = @ptrCast(@alignCast(ptr));
        self.calls.append(self.allocator, .stop_script) catch unreachable;
    }

    pub fn severHandles(ptr: *anyopaque) void {
        const self: *SpyScriptEngine = @ptrCast(@alignCast(ptr));
        self.calls.append(self.allocator, .sever_handles) catch unreachable;
    }

    pub fn drainFinalizers(ptr: *anyopaque) void {
        const self: *SpyScriptEngine = @ptrCast(@alignCast(ptr));
        self.calls.append(self.allocator, .drain_finalizers) catch unreachable;
    }

    pub fn teardownIsolate(ptr: *anyopaque) void {
        const self: *SpyScriptEngine = @ptrCast(@alignCast(ptr));
        self.calls.append(self.allocator, .teardown_isolate) catch unreachable;
    }

    pub fn runScript(ptr: *anyopaque, _: []const u8) error{ InvalidUrl, DnsFailed, ConnectionRefused, Timeout, CertInvalid, TlsError, TransferFailed, MalformedDocument }!void {
        const self: *SpyScriptEngine = @ptrCast(@alignCast(ptr));
        self.calls.append(self.allocator, .run_script) catch unreachable;
    }

    pub fn pumpMicrotasks(ptr: *anyopaque) void {
        const self: *SpyScriptEngine = @ptrCast(@alignCast(ptr));
        self.calls.append(self.allocator, .pump_microtasks) catch unreachable;
    }
};
