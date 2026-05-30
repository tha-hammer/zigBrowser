const std = @import("std");
const script = @import("../script/engine.zig");
const window_mod = @import("window.zig");

pub const Event = union(enum) {
    scroll: f32,
    click,
    resize,
    key,
};

pub const TurnSummary = struct {
    events_processed: usize,
    microtasks_pumped: usize,
    painted: bool,
};

pub const PaintHook = struct {
    ctx: ?*anyopaque = null,
    on_paint: ?*const fn (?*anyopaque) void = null,
};

pub fn runTurn(
    engine: script.ScriptEngine,
    win: *window_mod.Window,
    events: []const Event,
    hook: PaintHook,
) TurnSummary {
    var dirty = false;
    for (events) |event| {
        switch (event) {
            .scroll => |delta| {
                win.applyScrollDelta(delta);
                if (win.repaint_requested) dirty = true;
            },
            .click, .resize, .key => {
                dirty = true;
            },
        }
    }

    engine.pumpMicrotasks();

    var painted = false;
    if (dirty or win.repaint_requested) {
        painted = true;
        if (hook.on_paint) |paint_fn| paint_fn(hook.ctx);
        win.repaint_requested = false;
    }

    return .{
        .events_processed = events.len,
        .microtasks_pumped = 1,
        .painted = painted,
    };
}

test "microtask pump is invoked once per turn after event drain and before paint" {
    const Step = enum { pump, paint };
    const State = struct {
        allocator: std.mem.Allocator,
        steps: std.ArrayList(Step) = .empty,

        fn pump(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.steps.append(self.allocator, .pump) catch unreachable;
        }

        fn paint(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.steps.append(self.allocator, .paint) catch unreachable;
        }
    };

    var state = State{ .allocator = std.testing.allocator };
    defer state.steps.deinit(std.testing.allocator);

    const V = script.ScriptEngine.VTable{
        .stopScript = noop,
        .severHandles = noop,
        .drainFinalizers = noop,
        .teardownIsolate = noop,
        .runScript = noopRun,
        .pumpMicrotasks = State.pump,
    };
    const engine = script.ScriptEngine{ .ptr = @ptrCast(&state), .vtable = &V };

    var win = window_mod.Window.init(200, 800);
    const summary = runTurn(engine, &win, &.{
        .{ .scroll = 20 },
        .click,
        .resize,
    }, .{
        .ctx = @ptrCast(&state),
        .on_paint = State.paint,
    });

    try std.testing.expectEqual(@as(usize, 3), summary.events_processed);
    try std.testing.expectEqual(@as(usize, 1), summary.microtasks_pumped);
    try std.testing.expect(summary.painted);

    const expected = [_]Step{ .pump, .paint };
    try std.testing.expectEqualSlices(Step, &expected, state.steps.items);
}

fn noop(_: *anyopaque) void {}

fn noopRun(_: *anyopaque, _: []const u8) script.NavError!void {}
