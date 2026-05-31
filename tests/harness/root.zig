const std = @import("std");

pub const Case = struct {
    name: []const u8,
    input: []const u8,
    expect: []const u8,
};

const Html5libSubset = struct {
    cases: []const Html5libRawCase,
};

const Html5libRawCase = struct {
    id: []const u8,
    input: []const u8,
    expect_dom: []const u8,
};

const WptSubset = struct {
    cases: []const WptRawCase,
};

const WptRawCase = struct {
    id: []const u8,
    html: []const u8,
    expect_dom: []const u8,
    expect_color: []const u8,
    expect_bg: []const u8,
    expect_width: f32,
    expect_height: f32,
};

test "html5lib subset: all cases assert" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try loadSubsetJson(Html5libSubset, arena, "tests/harness/html5lib_subset.json");
    defer parsed.deinit();

    const cases = try normalizeHtml5libCases(arena, parsed.value.cases);
    try std.testing.expect(cases.len > 0);

    for (cases) |case| {
        try assertCanonicalCase(case);
        try std.testing.expect(std.mem.startsWith(u8, case.input, "<"));
    }
}

test "wpt subset: all cases assert" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try loadSubsetJson(WptSubset, arena, "tests/harness/wpt_subset.json");
    defer parsed.deinit();

    const cases = try normalizeWptCases(arena, parsed.value.cases);
    try std.testing.expect(cases.len > 0);

    var saw_nonzero_width = false;
    var saw_zero_width = false;
    for (parsed.value.cases, cases) |raw, case| {
        try assertCanonicalCase(case);

        _ = try parseHexColor(raw.expect_color);
        _ = try parseHexColor(raw.expect_bg);
        try std.testing.expect(raw.expect_width >= 0);
        try std.testing.expect(raw.expect_height >= 0);

        if (raw.expect_width > 0) saw_nonzero_width = true;
        if (raw.expect_width == 0) saw_zero_width = true;
    }

    try std.testing.expect(saw_nonzero_width);
    try std.testing.expect(saw_zero_width);
}

test "loader modules are wired through harness aggregation" {
    _ = @import("html5lib_loader");
    _ = @import("css_corpus_loader");
    try std.testing.expect(true);
}

test "no orphaned *_loader.zig test files" {
    const known_loaders = [_][]const u8{
        "tests/corpus_css/css_corpus_loader.zig",
        "tests/html5lib/html5lib_loader.zig",
    };

    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "sh", "-c", "find tests -type f -name '*_loader.zig' | sort" },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }

    var found_count: usize = 0;
    var lines = std.mem.tokenizeAny(u8, result.stdout, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        found_count += 1;

        var known = false;
        for (known_loaders) |loader_path| {
            if (std.mem.eql(u8, line, loader_path)) {
                known = true;
                break;
            }
        }
        try std.testing.expect(known);
    }

    try std.testing.expectEqual(known_loaders.len, found_count);
}

fn loadSubsetJson(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(T) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(512 * 1024));
    defer allocator.free(bytes);

    return std.json.parseFromSlice(T, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });
}

fn normalizeHtml5libCases(arena: std.mem.Allocator, raw_cases: []const Html5libRawCase) ![]Case {
    const out = try arena.alloc(Case, raw_cases.len);
    for (raw_cases, 0..) |raw, idx| {
        out[idx] = .{
            .name = raw.id,
            .input = raw.input,
            .expect = raw.expect_dom,
        };
    }
    return out;
}

fn normalizeWptCases(arena: std.mem.Allocator, raw_cases: []const WptRawCase) ![]Case {
    const out = try arena.alloc(Case, raw_cases.len);
    for (raw_cases, 0..) |raw, idx| {
        out[idx] = .{
            .name = raw.id,
            .input = raw.html,
            .expect = raw.expect_dom,
        };
    }
    return out;
}

fn assertCanonicalCase(case: Case) !void {
    try std.testing.expect(case.name.len > 0);
    try std.testing.expect(case.input.len > 0);
    try std.testing.expect(case.expect.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, case.expect, "<html><body>"));
    try std.testing.expect(std.mem.endsWith(u8, case.expect, "</html>"));
}

fn parseHexColor(raw: []const u8) !u32 {
    if (!std.mem.startsWith(u8, raw, "0x")) return error.InvalidColor;
    return std.fmt.parseInt(u32, raw[2..], 16);
}
