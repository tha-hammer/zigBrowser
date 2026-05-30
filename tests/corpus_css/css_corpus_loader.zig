const std = @import("std");

pub const CorpusPage = struct {
    id: []const u8,
    css: []const u8,
    source_html: []const u8,
};

pub const CorpusManifest = struct {
    version: u32,
    source_manifest: []const u8,
    pages: []CorpusPage,
};

const manifest_json = @embedFile("manifest.json");

pub fn loadManifest(allocator: std.mem.Allocator) !std.json.Parsed(CorpusManifest) {
    return std.json.parseFromSlice(CorpusManifest, allocator, manifest_json, .{ .allocate = .alloc_always });
}

pub fn loadCssSources(arena: std.mem.Allocator) ![]const []const u8 {
    const parsed = try loadManifest(arena);
    defer parsed.deinit();

    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(arena);

    for (parsed.value.pages) |page| {
        const css = cssById(page.id) orelse return error.UnknownCorpusPage;
        try out.append(arena, try arena.dupe(u8, css));
    }
    return out.toOwnedSlice(arena);
}

fn cssById(id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, id, "page01")) return @embedFile("page01.css");
    if (std.mem.eql(u8, id, "page02")) return @embedFile("page02.css");
    if (std.mem.eql(u8, id, "page03")) return @embedFile("page03.css");
    if (std.mem.eql(u8, id, "page04")) return @embedFile("page04.css");
    if (std.mem.eql(u8, id, "page05")) return @embedFile("page05.css");
    if (std.mem.eql(u8, id, "page06")) return @embedFile("page06.css");
    if (std.mem.eql(u8, id, "page07")) return @embedFile("page07.css");
    if (std.mem.eql(u8, id, "page08")) return @embedFile("page08.css");
    if (std.mem.eql(u8, id, "page09")) return @embedFile("page09.css");
    if (std.mem.eql(u8, id, "page10")) return @embedFile("page10.css");
    if (std.mem.eql(u8, id, "page11")) return @embedFile("page11.css");
    if (std.mem.eql(u8, id, "page12")) return @embedFile("page12.css");
    if (std.mem.eql(u8, id, "page13")) return @embedFile("page13.css");
    if (std.mem.eql(u8, id, "page14")) return @embedFile("page14.css");
    if (std.mem.eql(u8, id, "page15")) return @embedFile("page15.css");
    if (std.mem.eql(u8, id, "page16")) return @embedFile("page16.css");
    if (std.mem.eql(u8, id, "page17")) return @embedFile("page17.css");
    if (std.mem.eql(u8, id, "page18")) return @embedFile("page18.css");
    if (std.mem.eql(u8, id, "page19")) return @embedFile("page19.css");
    if (std.mem.eql(u8, id, "page20")) return @embedFile("page20.css");
    if (std.mem.eql(u8, id, "page21")) return @embedFile("page21.css");
    if (std.mem.eql(u8, id, "page22")) return @embedFile("page22.css");
    if (std.mem.eql(u8, id, "page23")) return @embedFile("page23.css");
    if (std.mem.eql(u8, id, "page24")) return @embedFile("page24.css");
    if (std.mem.eql(u8, id, "page25")) return @embedFile("page25.css");
    if (std.mem.eql(u8, id, "page26")) return @embedFile("page26.css");
    if (std.mem.eql(u8, id, "page27")) return @embedFile("page27.css");
    if (std.mem.eql(u8, id, "page28")) return @embedFile("page28.css");
    if (std.mem.eql(u8, id, "page29")) return @embedFile("page29.css");
    if (std.mem.eql(u8, id, "page30")) return @embedFile("page30.css");
    if (std.mem.eql(u8, id, "page31")) return @embedFile("page31.css");
    if (std.mem.eql(u8, id, "page32")) return @embedFile("page32.css");
    if (std.mem.eql(u8, id, "page33")) return @embedFile("page33.css");
    if (std.mem.eql(u8, id, "page34")) return @embedFile("page34.css");
    if (std.mem.eql(u8, id, "page35")) return @embedFile("page35.css");
    if (std.mem.eql(u8, id, "page36")) return @embedFile("page36.css");
    if (std.mem.eql(u8, id, "page37")) return @embedFile("page37.css");
    if (std.mem.eql(u8, id, "page38")) return @embedFile("page38.css");
    if (std.mem.eql(u8, id, "page39")) return @embedFile("page39.css");
    if (std.mem.eql(u8, id, "page40")) return @embedFile("page40.css");
    if (std.mem.eql(u8, id, "page41")) return @embedFile("page41.css");
    if (std.mem.eql(u8, id, "page42")) return @embedFile("page42.css");
    if (std.mem.eql(u8, id, "page43")) return @embedFile("page43.css");
    if (std.mem.eql(u8, id, "page44")) return @embedFile("page44.css");
    if (std.mem.eql(u8, id, "page45")) return @embedFile("page45.css");
    if (std.mem.eql(u8, id, "page46")) return @embedFile("page46.css");
    if (std.mem.eql(u8, id, "page47")) return @embedFile("page47.css");
    if (std.mem.eql(u8, id, "page48")) return @embedFile("page48.css");
    if (std.mem.eql(u8, id, "page49")) return @embedFile("page49.css");
    if (std.mem.eql(u8, id, "page50")) return @embedFile("page50.css");
    return null;
}

test "css corpus loader resolves 50 pages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try loadManifest(arena);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 50), parsed.value.pages.len);

    const css = try loadCssSources(arena);
    try std.testing.expectEqual(@as(usize, 50), css.len);
    try std.testing.expect(css[0].len > 0);
}
