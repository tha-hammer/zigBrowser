const std = @import("std");

pub const DestroyCallbacks = struct {
    ctx: ?*anyopaque = null,
    destroy_renderer: ?*const fn (?*anyopaque) void = null,
    destroy_window: ?*const fn (?*anyopaque) void = null,
    quit_sdl: ?*const fn (?*anyopaque) void = null,
};

pub const Window = struct {
    viewport_height: f32,
    content_height: f32,
    scroll_y: f32 = 0,
    repaint_requested: bool = false,
    callbacks: DestroyCallbacks = .{},

    pub fn init(viewport_height: f32, content_height: f32) Window {
        return .{
            .viewport_height = viewport_height,
            .content_height = content_height,
        };
    }

    pub fn maxScrollY(self: *const Window) f32 {
        const max_scroll = self.content_height - self.viewport_height;
        return if (max_scroll > 0) max_scroll else 0;
    }

    pub fn applyScrollDelta(self: *Window, delta: f32) void {
        const prior = self.scroll_y;
        self.scroll_y = std.math.clamp(prior + delta, 0, self.maxScrollY());
        if (self.scroll_y != prior) self.repaint_requested = true;
    }

    pub fn deinit(self: *Window) void {
        if (self.callbacks.destroy_renderer) |cb| cb(self.callbacks.ctx);
        if (self.callbacks.destroy_window) |cb| cb(self.callbacks.ctx);
        if (self.callbacks.quit_sdl) |cb| cb(self.callbacks.ctx);
    }
};

test "scroll clamps top and bottom and toggles repaint flag" {
    var win = Window.init(200, 600);
    try std.testing.expectApproxEqAbs(@as(f32, 0), win.scroll_y, 0.0001);

    win.applyScrollDelta(120);
    try std.testing.expect(win.repaint_requested);
    try std.testing.expectApproxEqAbs(@as(f32, 120), win.scroll_y, 0.0001);

    win.repaint_requested = false;
    win.applyScrollDelta(-500);
    try std.testing.expectApproxEqAbs(@as(f32, 0), win.scroll_y, 0.0001);
    try std.testing.expect(win.repaint_requested);

    win.repaint_requested = false;
    win.applyScrollDelta(9999);
    try std.testing.expectApproxEqAbs(@as(f32, 400), win.scroll_y, 0.0001);
    try std.testing.expect(win.repaint_requested);
}

test "Window.deinit invokes SDL destroy callbacks in order" {
    const Step = enum { destroy_renderer, destroy_window, quit };
    const Recorder = struct {
        allocator: std.mem.Allocator,
        calls: std.ArrayList(Step) = .empty,

        fn destroyRenderer(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls.append(self.allocator, .destroy_renderer) catch unreachable;
        }

        fn destroyWindow(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls.append(self.allocator, .destroy_window) catch unreachable;
        }

        fn quit(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls.append(self.allocator, .quit) catch unreachable;
        }
    };

    var recorder = Recorder{ .allocator = std.testing.allocator };
    defer recorder.calls.deinit(std.testing.allocator);

    var win = Window.init(200, 300);
    win.callbacks = .{
        .ctx = @ptrCast(&recorder),
        .destroy_renderer = Recorder.destroyRenderer,
        .destroy_window = Recorder.destroyWindow,
        .quit_sdl = Recorder.quit,
    };

    win.deinit();
    const expected = [_]Step{ .destroy_renderer, .destroy_window, .quit };
    try std.testing.expectEqualSlices(Step, &expected, recorder.calls.items);
}
