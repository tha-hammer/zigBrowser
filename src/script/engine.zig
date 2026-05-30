const std = @import("std");
const errors = @import("../errors.zig");

pub const NavError = errors.NavError;

pub const ScriptEngine = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        stopScript: *const fn (*anyopaque) void,
        severHandles: *const fn (*anyopaque) void,
        drainFinalizers: *const fn (*anyopaque) void,
        teardownIsolate: *const fn (*anyopaque) void,
        runScript: *const fn (*anyopaque, source: []const u8) NavError!void,
        pumpMicrotasks: *const fn (*anyopaque) void,
    };

    pub fn stopScript(self: ScriptEngine) void {
        self.vtable.stopScript(self.ptr);
    }

    pub fn severHandles(self: ScriptEngine) void {
        self.vtable.severHandles(self.ptr);
    }

    pub fn drainFinalizers(self: ScriptEngine) void {
        self.vtable.drainFinalizers(self.ptr);
    }

    pub fn teardownIsolate(self: ScriptEngine) void {
        self.vtable.teardownIsolate(self.ptr);
    }

    pub fn runScript(self: ScriptEngine, source: []const u8) NavError!void {
        return self.vtable.runScript(self.ptr, source);
    }

    pub fn pumpMicrotasks(self: ScriptEngine) void {
        self.vtable.pumpMicrotasks(self.ptr);
    }
};

pub const NoopEngine = struct {
    pub fn make() ScriptEngine {
        return .{
            .ptr = @ptrCast(@constCast(&state)),
            .vtable = &vtable,
        };
    }

    fn stopScript(_: *anyopaque) void {}
    fn severHandles(_: *anyopaque) void {}
    fn drainFinalizers(_: *anyopaque) void {}
    fn teardownIsolate(_: *anyopaque) void {}
    fn runScript(_: *anyopaque, _: []const u8) NavError!void {}
    fn pumpMicrotasks(_: *anyopaque) void {}

    var state: u8 = 0;
    const vtable = ScriptEngine.VTable{
        .stopScript = stopScript,
        .severHandles = severHandles,
        .drainFinalizers = drainFinalizers,
        .teardownIsolate = teardownIsolate,
        .runScript = runScript,
        .pumpMicrotasks = pumpMicrotasks,
    };
};
