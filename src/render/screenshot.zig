const std = @import("std");
const dom = @import("../html/dom.zig");
const page_mod = @import("../page.zig");
const paint_raster = @import("../paint/raster.zig");
const paint_text = @import("../paint/text.zig");
const script = @import("../script/engine.zig");
const url_mod = @import("../net/url.zig");

const tool_path = "tests/snapshots/pillow_tools.py";
const tmp_output_dir = ".zig-cache/snapshot_actual";

pub const ScreenshotError = error{
    RenderFailed,
    EncodeFailed,
    WriteFailed,
} || page_mod.NavError;

pub fn renderNavigatedPageArgb(
    arena: std.mem.Allocator,
    page: *page_mod.Page,
    width: u32,
    height: u32,
) ScreenshotError![]u32 {
    const box_root = page.box_root orelse return error.RenderFailed;
    const style_for = page.style_for orelse return error.RenderFailed;

    var body_style = page_mod.ComputedStyle{};
    if (box_root.source) |source_node| {
        if (style_for.get(@constCast(source_node))) |style| body_style = style;
    }

    var framebuffer = paint_raster.Framebuffer.init(arena, width, height) catch return error.RenderFailed;
    defer framebuffer.deinit();

    paint_raster.clear(&framebuffer, 0xFFFFFFFF);

    paint_raster.drawRect(&framebuffer, .{
        .x = box_root.x,
        .y = box_root.y,
        .width = box_root.width,
        .height = box_root.height,
    }, body_style.background_color);

    if (box_root.source) |source_node| {
        const text = collectTextContent(arena, source_node) catch return error.RenderFailed;
        defer arena.free(text);

        if (text.len > 0) {
            const baseline = box_root.y + paint_text.lineHeightPx(body_style.font_size, body_style.line_height);
            const text_width = paint_text.measureTextWidth(text, 10);
            paint_raster.drawRect(&framebuffer, .{
                .x = box_root.x,
                .y = baseline - 8,
                .width = text_width,
                .height = 10,
            }, body_style.color);
        }
    }

    const argb = arena.alloc(u32, framebuffer.pixels.len) catch return error.RenderFailed;
    @memcpy(argb, framebuffer.pixels);
    return argb;
}

pub fn exportArgbPng(
    allocator: std.mem.Allocator,
    io: std.Io,
    width: u32,
    height: u32,
    argb: []const u32,
    out_png_path: []const u8,
) ScreenshotError!void {
    const expected_len = @as(usize, width) * @as(usize, height);
    if (argb.len != expected_len) return error.EncodeFailed;

    ensureParentPath(io, out_png_path) catch return error.WriteFailed;
    std.Io.Dir.cwd().createDirPath(io, tmp_output_dir) catch return error.WriteFailed;

    const tmp_png_path = std.fmt.allocPrint(allocator, "{s}.tmp", .{out_png_path}) catch return error.WriteFailed;
    defer allocator.free(tmp_png_path);

    const raw_path = std.fmt.allocPrint(allocator, "{s}.rgba", .{tmp_png_path}) catch return error.WriteFailed;
    defer allocator.free(raw_path);
    defer std.Io.Dir.cwd().deleteFile(io, raw_path) catch {};

    const raw_bytes = argbToRgbaBytes(allocator, argb) catch return error.EncodeFailed;
    defer allocator.free(raw_bytes);

    writeFileBytes(io, raw_path, raw_bytes) catch return error.WriteFailed;
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_png_path) catch {};

    const width_str = std.fmt.allocPrint(allocator, "{d}", .{width}) catch return error.WriteFailed;
    defer allocator.free(width_str);
    const height_str = std.fmt.allocPrint(allocator, "{d}", .{height}) catch return error.WriteFailed;
    defer allocator.free(height_str);

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "python3", tool_path, "write", raw_path, tmp_png_path, width_str, height_str },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    }) catch return error.WriteFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("snapshot write failed ({d}): {s}\n", .{ code, result.stderr });
                return error.EncodeFailed;
            }
        },
        else => return error.EncodeFailed,
    }

    std.Io.Dir.cwd().rename(tmp_png_path, std.Io.Dir.cwd(), out_png_path, io) catch return error.WriteFailed;
}

fn collectTextContent(allocator: std.mem.Allocator, root: *const dom.Node) error{RenderFailed}![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    try collectTextContentWalk(allocator, &buffer, root);
    return buffer.toOwnedSlice(allocator) catch return error.RenderFailed;
}

fn collectTextContentWalk(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    node: *const dom.Node,
) error{RenderFailed}!void {
    switch (node.kind) {
        .text => |txt| {
            if (buffer.items.len > 0 and txt.len > 0) buffer.append(allocator, ' ') catch return error.RenderFailed;
            buffer.appendSlice(allocator, txt) catch return error.RenderFailed;
        },
        else => {},
    }

    if (node.first_child) |child| try collectTextContentWalk(allocator, buffer, child);
    if (node.next_sibling) |sibling| try collectTextContentWalk(allocator, buffer, sibling);
}

fn argbToRgbaBytes(allocator: std.mem.Allocator, argb: []const u32) error{EncodeFailed}![]u8 {
    const out = allocator.alloc(u8, argb.len * 4) catch return error.EncodeFailed;
    for (argb, 0..) |px, idx| {
        const base = idx * 4;
        out[base + 0] = @as(u8, @truncate((px >> 16) & 0xFF));
        out[base + 1] = @as(u8, @truncate((px >> 8) & 0xFF));
        out[base + 2] = @as(u8, @truncate(px & 0xFF));
        out[base + 3] = @as(u8, @truncate((px >> 24) & 0xFF));
    }
    return out;
}

fn ensureParentPath(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
}

fn writeFileBytes(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

test "renderNavigatedPageArgb produces a 1024x768 []u32 for a fixture page" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var server = @import("fixture_static").Server.init(std.testing.allocator, std.testing.io) catch |err| {
        std.debug.print("failed to start static fixture: {s}\n", .{@errorName(err)});
        return err;
    };
    defer server.deinit();

    const url = try server.url(arena, "/index.html");
    const parsed = try url_mod.parse(arena, url);

    var page = page_mod.Page.init(arena, script.NoopEngine.make());
    defer page.deinit();
    try page.navigate(std.testing.io, parsed);

    const argb = try renderNavigatedPageArgb(arena, &page, 1024, 768);
    try std.testing.expectEqual(@as(usize, 1024 * 768), argb.len);
}
