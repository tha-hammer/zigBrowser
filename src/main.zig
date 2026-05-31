const std = @import("std");

const app = @import("zigBrowser");
const display_mod = @import("display.zig");
const sdl_backend = @import("sdl_backend.zig");
const event_loop = @import("platform/event_loop.zig");
const window_mod = @import("platform/window.zig");

const default_viewport_width: u32 = 1024;
const default_viewport_height: u32 = 768;
const max_events_per_turn: usize = 64;

fn screenshotExitCode(err: anyerror) u8 {
    return switch (err) {
        error.InvalidUrl => 1,
        error.DnsFailed,
        error.ConnectionRefused,
        error.Timeout,
        error.CertInvalid,
        error.TlsError,
        error.TransferFailed,
        => 2,
        error.MalformedDocument,
        error.RenderFailed,
        => 3,
        error.EncodeFailed,
        error.WriteFailed,
        => 4,
        else => 4,
    };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const command = app.cli.parseArgs(args);

    switch (command) {
        .version => {
            var out_buffer: [64]u8 = undefined;
            var writer: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
            try writer.interface.writeAll("zigBrowser 0.1.0\n");
            try writer.interface.flush();
        },
        .open => |url_text| {
            const parsed = try app.net.url.parse(arena, url_text);
            try runInteractiveOpen(init, parsed);
        },
        .screenshot => |spec| {
            const parsed = app.net.url.parse(arena, spec.url) catch std.process.exit(1);

            var page = app.page.Page.init(arena, app.script.NoopEngine.make());
            defer page.deinit();
            page.navigate(init.io, parsed) catch |err| std.process.exit(screenshotExitCode(err));

            const argb = app.render.screenshot.renderNavigatedPageArgb(arena, &page, spec.w, spec.h) catch |err| {
                std.process.exit(screenshotExitCode(err));
            };
            app.render.screenshot.exportArgbPng(arena, init.io, spec.w, spec.h, argb, spec.out) catch |err| {
                std.process.exit(screenshotExitCode(err));
            };
            std.process.exit(0);
        },
        .usage => {
            var err_buffer: [512]u8 = undefined;
            var writer: std.Io.File.Writer = .init(.stderr(), init.io, &err_buffer);
            try writer.interface.writeAll(
                \\usage: zigBrowser [--version|URL]
                \\       zigBrowser --screenshot <out.png> <URL>
                \\screenshot exit codes:
                \\  0 success
                \\  1 URL parse failure
                \\  2 fetch failure
                \\  3 render failure
                \\  4 PNG write/encode failure
                \\
            );
            try writer.interface.flush();
            return error.InvalidArguments;
        },
    }
}

fn runInteractiveOpen(init: std.process.Init, parsed: app.page.ParsedUrl) !void {
    var display_backend = try sdl_backend.SdlDisplay.init(default_viewport_width, default_viewport_height);
    defer display_backend.deinitOwned();

    var page = app.page.Page.init(init.arena.allocator(), app.script.NoopEngine.make());
    defer page.deinit();
    try page.navigate(init.io, parsed);

    var window = window_mod.Window.init(
        @as(f32, @floatFromInt(default_viewport_height)),
        pageContentHeight(&page, @as(f32, @floatFromInt(default_viewport_height))),
    );
    window.viewport_width = @as(f32, @floatFromInt(default_viewport_width));

    var viewport_width = default_viewport_width;
    var viewport_height = default_viewport_height;
    try renderAndPresent(&page, display_backend.display(), viewport_width, viewport_height, window.scroll_y);

    var running = true;
    var pending: [max_events_per_turn]event_loop.Event = undefined;

    while (running) {
        var event_count: usize = 0;
        while (event_count < pending.len) {
            const polled = sdl_backend.pollOneEvent() orelse break;
            switch (polled) {
                .quit => {
                    window_mod.handleQuitComposition(&running, .{});
                    break;
                },
                .event => |event| {
                    switch (event) {
                        .click => |click| {
                            const links = try window_mod.collectLinkHits(
                                std.heap.page_allocator,
                                page.dom_root,
                                window.viewport_width,
                            );
                            defer std.heap.page_allocator.free(links);

                            const result = try window.clickNavigate(
                                init.io,
                                &page,
                                links,
                                click.x,
                                click.y + window.scroll_y,
                            );
                            if (result == .navigated) {
                                window.scroll_y = 0;
                                window.setContentHeight(pageContentHeight(
                                    &page,
                                    @as(f32, @floatFromInt(viewport_height)),
                                ));
                            }
                        },
                        .resize => |size| {
                            viewport_width = clampViewportDimension(size.w);
                            viewport_height = clampViewportDimension(size.h);
                            window.setViewport(
                                @as(f32, @floatFromInt(viewport_width)),
                                @as(f32, @floatFromInt(viewport_height)),
                            );
                            window.setContentHeight(pageContentHeight(
                                &page,
                                @as(f32, @floatFromInt(viewport_height)),
                            ));
                        },
                        else => {},
                    }
                    pending[event_count] = event;
                    event_count += 1;
                },
            }
        }

        if (!running) break;

        const turn = event_loop.runTurn(page.engine, &window, pending[0..event_count], .{});
        if (turn.painted) {
            try renderAndPresent(&page, display_backend.display(), viewport_width, viewport_height, window.scroll_y);
        }
    }
}

fn renderAndPresent(
    page: *app.page.Page,
    display: display_mod.Display,
    width: u32,
    height: u32,
    scroll_y: f32,
) !void {
    const frame = try app.render.screenshot.renderNavigatedPageArgb(std.heap.page_allocator, page, width, height);
    defer std.heap.page_allocator.free(frame);

    const shifted = try applyScrollOffset(std.heap.page_allocator, frame, width, height, scroll_y);
    defer if (shifted.ptr != frame.ptr) std.heap.page_allocator.free(shifted);

    try display.present(shifted, width, height);
}

fn applyScrollOffset(
    allocator: std.mem.Allocator,
    pixels: []const u32,
    width: u32,
    height: u32,
    scroll_y: f32,
) ![]u32 {
    const rows_to_scroll = clampScrollRows(scroll_y, height);
    if (rows_to_scroll == 0) return pixels;

    const shifted = try allocator.alloc(u32, pixels.len);
    @memset(shifted, 0xFFFFFFFF);

    const row_width: usize = @intCast(width);
    const visible_rows: usize = @intCast(height - rows_to_scroll);
    var row: usize = 0;
    while (row < visible_rows) : (row += 1) {
        const src_start = (row + @as(usize, rows_to_scroll)) * row_width;
        const dst_start = row * row_width;
        @memcpy(shifted[dst_start .. dst_start + row_width], pixels[src_start .. src_start + row_width]);
    }
    return shifted;
}

fn clampScrollRows(scroll_y: f32, height: u32) u32 {
    if (height == 0) return 0;
    if (!std.math.isFinite(scroll_y) or scroll_y <= 0) return 0;

    const max_rows = height - 1;
    const clamped = @min(scroll_y, @as(f32, @floatFromInt(max_rows)));
    return @as(u32, @intFromFloat(clamped));
}

fn clampViewportDimension(value: f32) u32 {
    if (!std.math.isFinite(value) or value <= 1) return 1;

    const max_u32_f = @as(f32, @floatFromInt(std.math.maxInt(u32)));
    if (value >= max_u32_f) return std.math.maxInt(u32);
    return @as(u32, @intFromFloat(value));
}

fn pageContentHeight(page: *const app.page.Page, fallback: f32) f32 {
    const root = page.box_root orelse return fallback;
    if (root.height > fallback) return root.height;
    return fallback;
}
