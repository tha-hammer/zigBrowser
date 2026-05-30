const std = @import("std");
const dom = @import("../html/dom.zig");
const page_mod = @import("../page.zig");
const script = @import("../script/engine.zig");
const url_mod = @import("../net/url.zig");
const paint_raster = @import("raster.zig");
const paint_text = @import("text.zig");

const tool_path = "tests/snapshots/pillow_tools.py";
const manifest_path = "tests/snapshots/manifest.json";
const deterministic_font_path = "tests/fonts/DejaVuSans.ttf";
const tmp_output_dir = ".zig-cache/snapshot_actual";

const CorpusManifest = struct {
    pages: []const CorpusPage,
};

const CorpusPage = struct {
    id: []const u8,
    html: []const u8,
    snapshot_png: []const u8,
    threshold: f32,
    width: u32,
    height: u32,
};

test "paint-snapshot fixture emits PNG and matches approved baseline" {
    if (!runtimeToolsAvailable(std.testing.allocator, std.testing.io)) return error.SkipZigTest;
    try assertDeterministicFontPresent(std.testing.io);

    var parsed = try loadManifest(std.testing.allocator, std.testing.io);
    defer parsed.deinit();

    if (parsed.value.pages.len == 0) return error.TestExpectedEqual;
    const page_spec = parsed.value.pages[0];

    var corpus_server = try CorpusServer.init(std.testing.allocator, std.testing.io, ".");
    defer corpus_server.deinit();

    var url_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer url_arena_state.deinit();
    const url_arena = url_arena_state.allocator();

    var page = page_mod.Page.init(std.testing.allocator, script.NoopEngine.make());
    defer page.deinit();

    const abs_url = try corpus_server.url(url_arena, page_spec.html);
    const parsed_url = try url_mod.parse(url_arena, abs_url);
    try page.navigate(std.testing.io, parsed_url);

    const argb = try renderNavigatedPageArgb(std.testing.allocator, &page, page_spec.width, page_spec.height);
    defer std.testing.allocator.free(argb);

    const actual_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}.png", .{ tmp_output_dir, page_spec.id });
    defer std.testing.allocator.free(actual_path);

    try exportArgbPng(std.testing.allocator, std.testing.io, page_spec.width, page_spec.height, argb, actual_path);
    const ratio = try perceptualDiffRatio(std.testing.allocator, std.testing.io, actual_path, page_spec.snapshot_png);
    try std.testing.expect(ratio <= page_spec.threshold);
}

test "corpus render gate reaches 90% threshold using approved snapshots" {
    if (!runtimeToolsAvailable(std.testing.allocator, std.testing.io)) return error.SkipZigTest;
    try assertDeterministicFontPresent(std.testing.io);

    var parsed = try loadManifest(std.testing.allocator, std.testing.io);
    defer parsed.deinit();

    if (parsed.value.pages.len == 0) return error.TestExpectedEqual;

    var corpus_server = try CorpusServer.init(std.testing.allocator, std.testing.io, ".");
    defer corpus_server.deinit();

    var url_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer url_arena_state.deinit();
    const url_arena = url_arena_state.allocator();

    var page = page_mod.Page.init(std.testing.allocator, script.NoopEngine.make());
    defer page.deinit();

    var pass_count: usize = 0;
    for (parsed.value.pages) |page_spec| {
        const abs_url = try corpus_server.url(url_arena, page_spec.html);
        const parsed_url = try url_mod.parse(url_arena, abs_url);
        try page.navigate(std.testing.io, parsed_url);

        const argb = try renderNavigatedPageArgb(std.testing.allocator, &page, page_spec.width, page_spec.height);
        defer std.testing.allocator.free(argb);

        const actual_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}.png", .{ tmp_output_dir, page_spec.id });
        defer std.testing.allocator.free(actual_path);

        try exportArgbPng(std.testing.allocator, std.testing.io, page_spec.width, page_spec.height, argb, actual_path);
        const ratio = try perceptualDiffRatio(std.testing.allocator, std.testing.io, actual_path, page_spec.snapshot_png);
        if (ratio <= page_spec.threshold) pass_count += 1;
    }

    const minimum = requiredPassCount(parsed.value.pages.len, 0.90);
    try std.testing.expect(pass_count >= minimum);
}

fn loadManifest(allocator: std.mem.Allocator, io: std.Io) !std.json.Parsed(CorpusManifest) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(256 * 1024));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(CorpusManifest, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

fn renderNavigatedPageArgb(
    allocator: std.mem.Allocator,
    page: *const page_mod.Page,
    width: u32,
    height: u32,
) ![]u32 {
    const box_root = page.box_root orelse return error.TestExpectedEqual;
    const style_for = page.style_for orelse return error.TestExpectedEqual;

    var body_style = page_mod.ComputedStyle{};
    if (box_root.source) |source_node| {
        if (style_for.get(@constCast(source_node))) |style| body_style = style;
    }

    var framebuffer = try paint_raster.Framebuffer.init(allocator, width, height);
    defer framebuffer.deinit();

    paint_raster.clear(&framebuffer, 0xFFFFFFFF);

    paint_raster.drawRect(&framebuffer, .{
        .x = box_root.x,
        .y = box_root.y,
        .width = box_root.width,
        .height = box_root.height,
    }, body_style.background_color);

    if (box_root.source) |source_node| {
        const text = try collectTextContent(allocator, source_node);
        defer allocator.free(text);

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

    const argb = try allocator.alloc(u32, framebuffer.pixels.len);
    @memcpy(argb, framebuffer.pixels);
    return argb;
}

fn collectTextContent(allocator: std.mem.Allocator, root: *const dom.Node) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    try collectTextContentWalk(allocator, &buffer, root);
    return buffer.toOwnedSlice(allocator);
}

fn collectTextContentWalk(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), node: *const dom.Node) !void {
    switch (node.kind) {
        .text => |txt| {
            if (buffer.items.len > 0 and txt.len > 0) try buffer.append(allocator, ' ');
            try buffer.appendSlice(allocator, txt);
        },
        else => {},
    }

    if (node.first_child) |child| try collectTextContentWalk(allocator, buffer, child);
    if (node.next_sibling) |sibling| try collectTextContentWalk(allocator, buffer, sibling);
}

fn exportArgbPng(
    allocator: std.mem.Allocator,
    io: std.Io,
    width: u32,
    height: u32,
    argb: []const u32,
    out_png_path: []const u8,
) !void {
    try ensureParentPath(io, out_png_path);
    try std.Io.Dir.cwd().createDirPath(io, tmp_output_dir);

    const raw_path = try std.fmt.allocPrint(allocator, "{s}.rgba", .{out_png_path});
    defer allocator.free(raw_path);

    const raw_bytes = try argbToRgbaBytes(allocator, argb);
    defer allocator.free(raw_bytes);

    try writeFileBytes(io, raw_path, raw_bytes);
    defer std.Io.Dir.cwd().deleteFile(io, raw_path) catch {};

    const width_str = try std.fmt.allocPrint(allocator, "{d}", .{width});
    defer allocator.free(width_str);
    const height_str = try std.fmt.allocPrint(allocator, "{d}", .{height});
    defer allocator.free(height_str);

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "python3", tool_path, "write", raw_path, out_png_path, width_str, height_str },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("snapshot write failed ({d}): {s}\n", .{ code, result.stderr });
                return error.SnapshotWriteFailed;
            }
        },
        else => return error.SnapshotWriteFailed,
    }
}

fn perceptualDiffRatio(
    allocator: std.mem.Allocator,
    io: std.Io,
    actual_png_path: []const u8,
    expected_png_path: []const u8,
) !f32 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "python3", tool_path, "diff", actual_png_path, expected_png_path },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("snapshot diff failed ({d}): {s}\n", .{ code, result.stderr });
                return error.SnapshotDiffFailed;
            }
        },
        else => return error.SnapshotDiffFailed,
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    return std.fmt.parseFloat(f32, trimmed) catch error.InvalidDiffOutput;
}

fn runtimeToolsAvailable(allocator: std.mem.Allocator, io: std.Io) bool {
    if (!commandExists(allocator, io, "python3")) return false;
    if (!commandExists(allocator, io, "curl")) return false;

    const probe = std.process.run(allocator, io, .{
        .argv = &.{ "python3", tool_path, "check" },
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

fn argbToRgbaBytes(allocator: std.mem.Allocator, argb: []const u32) ![]u8 {
    const out = try allocator.alloc(u8, argb.len * 4);
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

fn requiredPassCount(total: usize, threshold: f32) usize {
    const scaled = @as(f64, @floatFromInt(total)) * @as(f64, threshold);
    return @as(usize, @intFromFloat(@ceil(scaled)));
}

fn assertDeterministicFontPresent(io: std.Io) !void {
    var file = try std.Io.Dir.cwd().openFile(io, deterministic_font_path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    try std.testing.expect(stat.size > 0);
}

const CorpusServer = struct {
    io: std.Io,
    child: std.process.Child,
    port: u16,

    fn init(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !CorpusServer {
        var attempt: usize = 0;
        while (attempt < 32) : (attempt += 1) {
            const port: u16 = @as(u16, 39500) + @as(u16, @intCast(attempt));
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

    fn deinit(self: *CorpusServer) void {
        self.child.kill(self.io);
    }

    fn url(self: *const CorpusServer, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
        const normalized_path = if (std.mem.startsWith(u8, path, "/")) path else try std.fmt.allocPrint(arena, "/{s}", .{path});
        return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}{s}", .{ self.port, normalized_path });
    }
};

fn waitUntilReady(allocator: std.mem.Allocator, io: std.Io, port: u16) !void {
    const probe_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/tests/corpus_pages/page01.html", .{port});
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
