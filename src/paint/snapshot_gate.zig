const std = @import("std");
const page_mod = @import("../page.zig");
const screenshot_mod = @import("../render/screenshot.zig");
const script = @import("../script/engine.zig");
const url_mod = @import("../net/url.zig");

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
    try requireSnapshotToolsOrSkip(std.testing.allocator, std.testing.io, tool_path);
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

    const argb = try screenshot_mod.renderNavigatedPageArgb(std.testing.allocator, &page, page_spec.width, page_spec.height);
    defer std.testing.allocator.free(argb);

    const actual_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}.png", .{ tmp_output_dir, page_spec.id });
    defer std.testing.allocator.free(actual_path);

    try screenshot_mod.exportArgbPng(std.testing.allocator, std.testing.io, page_spec.width, page_spec.height, argb, actual_path);
    const ratio = try perceptualDiffRatio(std.testing.allocator, std.testing.io, actual_path, page_spec.snapshot_png);
    try std.testing.expect(ratio <= page_spec.threshold);
}

test "corpus render gate reaches 90% threshold using approved snapshots" {
    try requireSnapshotToolsOrSkip(std.testing.allocator, std.testing.io, tool_path);
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

        const argb = try screenshot_mod.renderNavigatedPageArgb(std.testing.allocator, &page, page_spec.width, page_spec.height);
        defer std.testing.allocator.free(argb);

        const actual_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}.png", .{ tmp_output_dir, page_spec.id });
        defer std.testing.allocator.free(actual_path);

        try screenshot_mod.exportArgbPng(std.testing.allocator, std.testing.io, page_spec.width, page_spec.height, argb, actual_path);
        const ratio = try perceptualDiffRatio(std.testing.allocator, std.testing.io, actual_path, page_spec.snapshot_png);
        if (ratio <= page_spec.threshold) pass_count += 1;
    }

    const minimum = requiredPassCount(parsed.value.pages.len, 0.90);
    try std.testing.expect(pass_count >= minimum);
}

test "corpus gate hard-fails when REQUIRE_SNAPSHOTS=1 and Pillow missing" {
    try std.testing.expectError(
        error.TestUnexpectedResult,
        requireSnapshotToolsOrSkipWithFlag(
            std.testing.allocator,
            std.testing.io,
            true,
            "tests/snapshots/missing_tools_probe.py",
        ),
    );
}

fn loadManifest(allocator: std.mem.Allocator, io: std.Io) !std.json.Parsed(CorpusManifest) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(256 * 1024));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(CorpusManifest, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
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

fn requireSnapshotToolsOrSkip(allocator: std.mem.Allocator, io: std.Io, probe_tool_path: []const u8) !void {
    const require_snapshots = envTruthyOne(allocator, "REQUIRE_SNAPSHOTS");
    return requireSnapshotToolsOrSkipWithFlag(allocator, io, require_snapshots, probe_tool_path);
}

fn requireSnapshotToolsOrSkipWithFlag(
    allocator: std.mem.Allocator,
    io: std.Io,
    require_snapshots: bool,
    probe_tool_path: []const u8,
) !void {
    if (runtimeToolsAvailableAtPath(allocator, io, probe_tool_path)) return;
    if (require_snapshots) return error.TestUnexpectedResult;
    return error.SkipZigTest;
}

fn runtimeToolsAvailable(allocator: std.mem.Allocator, io: std.Io) bool {
    return runtimeToolsAvailableAtPath(allocator, io, tool_path);
}

fn runtimeToolsAvailableAtPath(allocator: std.mem.Allocator, io: std.Io, probe_tool_path: []const u8) bool {
    if (!commandExists(allocator, io, "python3")) return false;
    if (!commandExists(allocator, io, "curl")) return false;

    const probe = std.process.run(allocator, io, .{
        .argv = &.{ "python3", probe_tool_path, "check" },
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

fn envTruthyOne(allocator: std.mem.Allocator, key: []const u8) bool {
    const value = getEnvVarOwned(allocator, key) catch return false;
    defer allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const key_z = try allocator.dupeZ(u8, key);
    defer allocator.free(key_z);

    const raw = std.c.getenv(key_z.ptr) orelse return error.EnvironmentVariableMissing;
    return allocator.dupe(u8, std.mem.span(raw));
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
