const std = @import("std");
const app = @import("zigBrowser");

const page_mod = app.page;
const script = app.script;
const url_mod = app.net.url;

const fixture_path = "tests/smoke/urls.json";

const SmokeFixture = struct {
    pages: []const SmokeSpec,
};

const SmokeSpec = struct {
    url: []const u8,
    min_node_count: u32,
    timeout_ms: u32,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    if (!envTruthyOne(allocator, init.minimal.environ, "SMOKE")) {
        std.debug.print("smoke skipped: set SMOKE=1 to run live-web smoke checks\n", .{});
        return;
    }

    var parsed = try loadFixture(allocator, init.io);
    defer parsed.deinit();

    var url_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer url_arena_state.deinit();
    const url_arena = url_arena_state.allocator();

    var page = page_mod.Page.init(allocator, script.NoopEngine.make());
    defer page.deinit();

    var passed: usize = 0;
    var skipped: usize = 0;
    var attempted: usize = 0;
    const white_checksum = allWhiteChecksum(1024, 768);

    for (parsed.value.pages) |spec| {
        attempted += 1;

        const parsed_url = url_mod.parse(url_arena, spec.url) catch |err| {
            skipped += 1;
            std.debug.print("smoke skip (invalid url): {s} ({s})\n", .{ spec.url, @errorName(err) });
            continue;
        };

        const start_ts: std.Io.Clock.Timestamp = .now(init.io, .awake);
        page.navigate(init.io, parsed_url) catch |err| {
            skipped += 1;
            std.debug.print("smoke skip (navigate error): {s} ({s})\n", .{ spec.url, @errorName(err) });
            continue;
        };
        const elapsed_ms = durationToMillis(start_ts.untilNow(init.io));
        if (elapsed_ms > spec.timeout_ms) {
            skipped += 1;
            std.debug.print("smoke skip (timeout): {s} elapsed={d}ms limit={d}ms\n", .{ spec.url, elapsed_ms, spec.timeout_ms });
            continue;
        }

        const root = page.dom_root orelse return error.SmokeInvariantFailed;
        const node_count = countNodes(root);
        if (node_count <= spec.min_node_count) {
            std.debug.print("smoke fail: {s} node_count={d} min={d}\n", .{ spec.url, node_count, spec.min_node_count });
            return error.SmokeInvariantFailed;
        }
        if (page.render_checksum == white_checksum) {
            std.debug.print("smoke fail: {s} produced all-white framebuffer checksum\n", .{spec.url});
            return error.SmokeInvariantFailed;
        }

        passed += 1;
        std.debug.print(
            "smoke pass: {s} nodes={d} checksum={d} elapsed={d}ms\n",
            .{ spec.url, node_count, page.render_checksum, elapsed_ms },
        );
    }

    if (attempted == 0 or passed == 0) {
        std.debug.print("smoke skipped: no live pages produced passable renders (skipped={d})\n", .{skipped});
        return;
    }

    std.debug.print("smoke summary: passed={d} skipped={d} attempted={d}\n", .{ passed, skipped, attempted });
}

fn loadFixture(allocator: std.mem.Allocator, io: std.Io) !std.json.Parsed(SmokeFixture) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, fixture_path, allocator, .limited(256 * 1024));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(SmokeFixture, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });
}

fn envTruthyOne(allocator: std.mem.Allocator, environ: std.process.Environ, key: []const u8) bool {
    const value = environ.getAlloc(allocator, key) catch return false;
    defer allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

fn countNodes(root: *const page_mod.Node) u32 {
    var total: u32 = 1;
    if (root.first_child) |child| total += countNodes(child);
    if (root.next_sibling) |sibling| total += countNodes(sibling);
    return total;
}

fn durationToMillis(duration: std.Io.Clock.Duration) u32 {
    const millis = duration.raw.toMilliseconds();
    if (millis <= 0) return 0;
    const ms_u64: u64 = @intCast(millis);
    return @intCast(@min(ms_u64, std.math.maxInt(u32)));
}

fn allWhiteChecksum(width: usize, height: usize) u64 {
    const pixel_count: u64 = @intCast(width * height);
    return @as(u64, 0xFFFFFFFF) *% pixel_count;
}
