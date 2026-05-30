const std = @import("std");

pub const TreeCase = struct {
    name: []const u8,
    input: []const u8,
    required_tags: []const []const u8,
};

pub const TreeSuite = struct {
    version: u32,
    suite: []const u8,
    cases: []TreeCase,
};

const curated_json = @embedFile("tree_construction_curated.json");

pub fn loadCuratedSuite(allocator: std.mem.Allocator) !std.json.Parsed(TreeSuite) {
    return std.json.parseFromSlice(TreeSuite, allocator, curated_json, .{ .allocate = .alloc_always });
}

test "html5lib loader parses curated tree-construction suite" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try loadCuratedSuite(arena);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 1), parsed.value.version);
    try std.testing.expectEqualStrings("tree-construction-curated", parsed.value.suite);
    try std.testing.expect(parsed.value.cases.len >= 6);
}
