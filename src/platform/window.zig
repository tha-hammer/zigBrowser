const std = @import("std");
const page_mod = @import("../page.zig");
const script_mod = @import("../script/engine.zig");
const url_mod = @import("../net/url.zig");
const dom_mod = @import("../html/dom.zig");

pub const DestroyCallbacks = struct {
    ctx: ?*anyopaque = null,
    destroy_renderer: ?*const fn (?*anyopaque) void = null,
    destroy_window: ?*const fn (?*anyopaque) void = null,
    quit_sdl: ?*const fn (?*anyopaque) void = null,
};

pub const QuitCallbacks = struct {
    ctx: ?*anyopaque = null,
    stop_loop: ?*const fn (?*anyopaque) void = null,
    page_deinit: ?*const fn (?*anyopaque) void = null,
    display_deinit: ?*const fn (?*anyopaque) void = null,
    present: ?*const fn (?*anyopaque) void = null,
};

pub const LinkHit = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    href: []const u8,
};

pub const LinkNavigateResult = enum {
    no_target,
    fragment_only,
    navigated,
};

pub const Window = struct {
    viewport_width: f32 = 1024,
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

    pub fn setViewport(self: *Window, width: f32, height: f32) void {
        self.viewport_width = width;
        self.viewport_height = height;
        self.repaint_requested = true;
    }

    pub fn setContentHeight(self: *Window, content_height: f32) void {
        self.content_height = content_height;
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

    pub fn clickNavigate(
        self: *Window,
        io: std.Io,
        page: *page_mod.Page,
        links: []const LinkHit,
        click_x: f32,
        click_y: f32,
    ) page_mod.NavError!LinkNavigateResult {
        const href = hitTestLink(links, click_x, click_y) orelse return .no_target;

        if (href.len > 0 and href[0] == '#') {
            self.repaint_requested = true;
            return .fragment_only;
        }

        try page.navigateLink(io, href);
        self.repaint_requested = true;
        return .navigated;
    }
};

pub fn collectLinkHits(arena: std.mem.Allocator, root: ?*dom_mod.Node, viewport_width: f32) ![]LinkHit {
    var links = std.ArrayList(LinkHit).empty;
    errdefer links.deinit(arena);

    if (root) |node| {
        var ordinal: usize = 0;
        try collectLinkHitsWalk(arena, node, viewport_width, &ordinal, &links);
    }

    return links.toOwnedSlice(arena);
}

pub fn handleQuitComposition(running: *bool, callbacks: QuitCallbacks) void {
    running.* = false;
    if (callbacks.stop_loop) |cb| cb(callbacks.ctx);
    if (callbacks.page_deinit) |cb| cb(callbacks.ctx);
    if (callbacks.display_deinit) |cb| cb(callbacks.ctx);
}

pub fn maybePresentAfterTurn(running: bool, callbacks: QuitCallbacks) void {
    if (!running) return;
    if (callbacks.present) |cb| cb(callbacks.ctx);
}

fn hitTestLink(links: []const LinkHit, click_x: f32, click_y: f32) ?[]const u8 {
    var i = links.len;
    while (i > 0) {
        i -= 1;
        const link = links[i];
        if (!pointInRect(click_x, click_y, link)) continue;
        return link.href;
    }
    return null;
}

fn pointInRect(click_x: f32, click_y: f32, link: LinkHit) bool {
    return click_x >= link.x and
        click_y >= link.y and
        click_x < link.x + link.width and
        click_y < link.y + link.height;
}

fn collectLinkHitsWalk(
    arena: std.mem.Allocator,
    node: *dom_mod.Node,
    viewport_width: f32,
    ordinal: *usize,
    out: *std.ArrayList(LinkHit),
) !void {
    switch (node.kind) {
        .element => |el| {
            if (std.mem.eql(u8, el.tag_name, "a")) {
                if (findHref(el.attributes)) |href| {
                    const top = @as(f32, @floatFromInt(ordinal.*)) * 28;
                    try out.append(arena, .{
                        .x = 0,
                        .y = top,
                        .width = @max(viewport_width, 1.0),
                        .height = 28,
                        .href = href,
                    });
                    ordinal.* += 1;
                }
            }
        },
        else => {},
    }

    if (node.first_child) |child| try collectLinkHitsWalk(arena, child, viewport_width, ordinal, out);
    if (node.next_sibling) |sibling| try collectLinkHitsWalk(arena, sibling, viewport_width, ordinal, out);
}

fn findHref(attributes: []const dom_mod.Attribute) ?[]const u8 {
    for (attributes) |attr| {
        if (std.mem.eql(u8, attr.name, "href")) return attr.value;
    }
    return null;
}

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

test "0b.4 quit composition deinitializes page before display and blocks present after teardown" {
    const Step = enum { present, stop_loop, page_deinit, display_deinit };
    const Recorder = struct {
        allocator: std.mem.Allocator,
        steps: std.ArrayList(Step) = .empty,

        fn present(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.steps.append(self.allocator, .present) catch unreachable;
        }

        fn stop(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.steps.append(self.allocator, .stop_loop) catch unreachable;
        }

        fn pageDeinit(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.steps.append(self.allocator, .page_deinit) catch unreachable;
        }

        fn displayDeinit(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.steps.append(self.allocator, .display_deinit) catch unreachable;
        }
    };

    var recorder = Recorder{ .allocator = std.testing.allocator };
    defer recorder.steps.deinit(std.testing.allocator);

    var running = true;
    const callbacks = QuitCallbacks{
        .ctx = @ptrCast(&recorder),
        .stop_loop = Recorder.stop,
        .page_deinit = Recorder.pageDeinit,
        .display_deinit = Recorder.displayDeinit,
        .present = Recorder.present,
    };

    maybePresentAfterTurn(running, callbacks);
    handleQuitComposition(&running, callbacks);
    maybePresentAfterTurn(running, callbacks);

    const expected = [_]Step{ .present, .stop_loop, .page_deinit, .display_deinit };
    try std.testing.expectEqualSlices(Step, &expected, recorder.steps.items);
}

test "link-navigate hit-test routes through shared Page.navigate teardown path" {
    if (!commandExists(std.testing.allocator, std.testing.io, "python3")) return error.SkipZigTest;
    if (!commandExists(std.testing.allocator, std.testing.io, "curl")) return error.SkipZigTest;

    const spy_mod = @import("spy_engine");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var server = try TestHttpServer.init(std.testing.allocator, std.testing.io, "tests/fixtures/www");
    defer server.deinit();

    var spy = spy_mod.SpyScriptEngine.init(std.testing.allocator);
    defer spy.deinit();

    const vtable = script_mod.ScriptEngine.VTable{
        .stopScript = spy_mod.SpyScriptEngine.stopScript,
        .severHandles = spy_mod.SpyScriptEngine.severHandles,
        .drainFinalizers = spy_mod.SpyScriptEngine.drainFinalizers,
        .teardownIsolate = spy_mod.SpyScriptEngine.teardownIsolate,
        .runScript = spy_mod.SpyScriptEngine.runScript,
        .pumpMicrotasks = spy_mod.SpyScriptEngine.pumpMicrotasks,
    };

    var page = page_mod.Page.init(arena, .{
        .ptr = @ptrCast(&spy),
        .vtable = &vtable,
    });
    defer page.deinit();

    const first_url = try url_mod.parse(arena, try server.url(arena, "/index.html"));
    try page.navigate(std.testing.io, first_url);
    const initial_checksum = page.render_checksum;

    var window = Window.init(320, 2000);

    const links = [_]LinkHit{
        .{ .x = 0, .y = 0, .width = 120, .height = 40, .href = "next.html" },
        .{ .x = 0, .y = 60, .width = 120, .height = 40, .href = "#overview" },
    };

    const outside = try window.clickNavigate(std.testing.io, &page, &links, 400, 400);
    try std.testing.expectEqual(LinkNavigateResult.no_target, outside);
    try std.testing.expectEqual(@as(usize, 0), spy.calls.items.len);

    const fragment = try window.clickNavigate(std.testing.io, &page, &links, 10, 65);
    try std.testing.expectEqual(LinkNavigateResult.fragment_only, fragment);
    try std.testing.expectEqual(initial_checksum, page.render_checksum);
    try std.testing.expectEqual(@as(usize, 0), spy.calls.items.len);
    try std.testing.expect(window.repaint_requested);

    window.repaint_requested = false;
    const navigated = try window.clickNavigate(std.testing.io, &page, &links, 10, 10);
    try std.testing.expectEqual(LinkNavigateResult.navigated, navigated);
    try std.testing.expect(window.repaint_requested);
    try expectSharedTeardownOrder(spy.calls.items);

    const current = page.current_url orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("/next.html", current.path);
}

fn expectSharedTeardownOrder(calls: []const @import("spy_engine").Step) !void {
    const spy_mod = @import("spy_engine");
    const expected = [_]spy_mod.Step{
        .stop_script,
        .sever_handles,
        .drain_finalizers,
        .teardown_isolate,
    };
    try std.testing.expect(calls.len >= expected.len);
    try std.testing.expectEqualSlices(spy_mod.Step, &expected, calls[0..expected.len]);
}

const TestHttpServer = struct {
    io: std.Io,
    child: std.process.Child,
    port: u16,

    fn init(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !TestHttpServer {
        var attempt: usize = 0;
        while (attempt < 32) : (attempt += 1) {
            const port: u16 = @as(u16, 39400) + @as(u16, @intCast(attempt));
            const port_text = try std.fmt.allocPrint(allocator, "{d}", .{port});
            defer allocator.free(port_text);

            var child = std.process.spawn(io, .{
                .argv = &.{
                    "python3",
                    "-m",
                    "http.server",
                    port_text,
                    "--bind",
                    "127.0.0.1",
                    "--directory",
                    directory,
                },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch |err| switch (err) {
                error.FileNotFound => return error.FileNotFound,
                else => continue,
            };

            waitUntilReady(allocator, io, port) catch {
                child.kill(io);
                continue;
            };

            return .{ .io = io, .child = child, .port = port };
        }

        return error.ConnectionRefused;
    }

    fn deinit(self: *TestHttpServer) void {
        self.child.kill(self.io);
    }

    fn url(self: *const TestHttpServer, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
        const normalized = if (std.mem.startsWith(u8, path, "/")) path else try std.fmt.allocPrint(arena, "/{s}", .{path});
        return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}{s}", .{ self.port, normalized });
    }
};

fn waitUntilReady(allocator: std.mem.Allocator, io: std.Io, port: u16) !void {
    const probe_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/index.html", .{port});
    defer allocator.free(probe_url);

    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        const result = std.process.run(allocator, io, .{
            .argv = &.{ "curl", "--silent", "--output", "/dev/null", "--connect-timeout", "1", "--max-time", "2", probe_url },
            .stdout_limit = .unlimited,
            .stderr_limit = .unlimited,
        }) catch continue;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
    }

    return error.ConnectionRefused;
}

fn commandExists(allocator: std.mem.Allocator, io: std.Io, binary: []const u8) bool {
    const probe = std.process.run(allocator, io, .{
        .argv = &.{ "sh", "-c", "command -v \"$1\" >/dev/null 2>&1", "sh", binary },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    }) catch return false;
    defer allocator.free(probe.stdout);
    defer allocator.free(probe.stderr);

    return switch (probe.term) {
        .exited => |code| code == 0,
        else => false,
    };
}
