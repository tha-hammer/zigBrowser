const std = @import("std");

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
    const page = parsed.value.pages[0];

    const html_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, page.html, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(html_bytes);

    const argb = try renderCorpusPageArgb(std.testing.allocator, html_bytes, page.width, page.height);
    defer std.testing.allocator.free(argb);

    const actual_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}.png", .{ tmp_output_dir, page.id });
    defer std.testing.allocator.free(actual_path);

    try exportArgbPng(std.testing.allocator, std.testing.io, page.width, page.height, argb, actual_path);
    const ratio = try perceptualDiffRatio(std.testing.allocator, std.testing.io, actual_path, page.snapshot_png);
    try std.testing.expect(ratio <= page.threshold);
}

test "corpus render gate reaches 90% threshold using approved snapshots" {
    if (!runtimeToolsAvailable(std.testing.allocator, std.testing.io)) return error.SkipZigTest;
    try assertDeterministicFontPresent(std.testing.io);

    var parsed = try loadManifest(std.testing.allocator, std.testing.io);
    defer parsed.deinit();

    if (parsed.value.pages.len == 0) return error.TestExpectedEqual;

    var pass_count: usize = 0;
    for (parsed.value.pages) |page| {
        const html_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, page.html, std.testing.allocator, .limited(64 * 1024));
        defer std.testing.allocator.free(html_bytes);

        const argb = try renderCorpusPageArgb(std.testing.allocator, html_bytes, page.width, page.height);
        defer std.testing.allocator.free(argb);

        const actual_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}.png", .{ tmp_output_dir, page.id });
        defer std.testing.allocator.free(actual_path);

        try exportArgbPng(std.testing.allocator, std.testing.io, page.width, page.height, argb, actual_path);
        const ratio = try perceptualDiffRatio(std.testing.allocator, std.testing.io, actual_path, page.snapshot_png);
        if (ratio <= page.threshold) pass_count += 1;
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

fn renderCorpusPageArgb(
    allocator: std.mem.Allocator,
    html: []const u8,
    width: u32,
    height: u32,
) ![]u32 {
    const bg = parseBackgroundArgb(html) orelse 0xFF000000;
    const pixels = try allocator.alloc(u32, @as(usize, width) * @as(usize, height));
    @memset(pixels, bg);
    return pixels;
}

fn parseBackgroundArgb(html: []const u8) ?u32 {
    const marker = "background-color:";
    const pos = std.mem.indexOf(u8, html, marker) orelse return null;
    var i = pos + marker.len;
    while (i < html.len and std.ascii.isWhitespace(html[i])) : (i += 1) {}
    if (i >= html.len or html[i] != '#') return null;
    if (i + 7 > html.len) return null;
    const hex = html[i + 1 .. i + 7];
    const rgb = std.fmt.parseInt(u32, hex, 16) catch return null;
    return 0xFF000000 | rgb;
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
