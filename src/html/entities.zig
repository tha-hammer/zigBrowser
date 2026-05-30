const std = @import("std");

pub fn decodeEntities(arena: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(arena);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '&') {
            try out.append(arena, input[i]);
            i += 1;
            continue;
        }

        if (i + 1 >= input.len) {
            try out.append(arena, '&');
            i += 1;
            continue;
        }

        if (input[i + 1] == '#') {
            const parsed = parseNumericEntity(input, i);
            if (parsed.decoded) |cp| {
                var buf: [4]u8 = undefined;
                const encoded = std.unicode.utf8Encode(cp, &buf) catch {
                    _ = try out.appendSlice(arena, "\xEF\xBF\xBD");
                    i = parsed.next_index;
                    continue;
                };
                try out.appendSlice(arena, buf[0..encoded]);
                i = parsed.next_index;
                continue;
            }
        } else {
            if (matchNamedEntity(input[i..])) |match| {
                try out.appendSlice(arena, match.replacement);
                i += match.consumed;
                continue;
            }
        }

        try out.append(arena, '&');
        i += 1;
    }

    return out.toOwnedSlice(arena);
}

pub fn decodeEntity(arena: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    return decodeEntities(arena, input);
}

const NamedMatch = struct {
    consumed: usize,
    replacement: []const u8,
};

fn matchNamedEntity(s: []const u8) ?NamedMatch {
    const table = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "amp", .value = "&" },
        .{ .name = "lt", .value = "<" },
        .{ .name = "gt", .value = ">" },
        .{ .name = "quot", .value = "\"" },
        .{ .name = "apos", .value = "'" },
        .{ .name = "nbsp", .value = "\xC2\xA0" },
    };

    for (table) |entry| {
        if (s.len >= entry.name.len + 1 and std.mem.eql(u8, s[1 .. 1 + entry.name.len], entry.name)) {
            const after = 1 + entry.name.len;
            if (after < s.len and s[after] == ';') {
                return .{ .consumed = entry.name.len + 2, .replacement = entry.value };
            }
            if (after == s.len or isLegacyBoundary(s[after])) {
                return .{ .consumed = entry.name.len + 1, .replacement = entry.value };
            }
        }
    }
    return null;
}

fn isLegacyBoundary(ch: u8) bool {
    return ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t' or ch == '<' or ch == '&';
}

const NumericParsed = struct {
    decoded: ?u21,
    next_index: usize,
};

fn parseNumericEntity(s: []const u8, start: usize) NumericParsed {
    var i = start + 2;
    var base: u32 = 10;
    if (i < s.len and (s[i] == 'x' or s[i] == 'X')) {
        base = 16;
        i += 1;
    }
    const digits_start = i;
    while (i < s.len and isDigitBase(s[i], base)) : (i += 1) {}
    if (i == digits_start) return .{ .decoded = null, .next_index = start + 1 };

    var value: u32 = 0;
    for (s[digits_start..i]) |ch| {
        value = value * base + digitValue(ch, base);
        if (value > 0x10FFFF) {
            return .{ .decoded = 0xFFFD, .next_index = if (i < s.len and s[i] == ';') i + 1 else i };
        }
    }

    if (i < s.len and s[i] == ';') i += 1;
    const cp: u21 = if (value == 0 or value > 0x10FFFF) 0xFFFD else @intCast(value);
    return .{ .decoded = cp, .next_index = i };
}

fn isDigitBase(ch: u8, base: u32) bool {
    if (base == 10) return ch >= '0' and ch <= '9';
    return (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
}

fn digitValue(ch: u8, base: u32) u32 {
    _ = base;
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return 10 + ch - 'a';
    return 10 + ch - 'A';
}

test "cycle 2.2 decodes named, numeric, legacy, and overflow entities" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const decoded = try decodeEntities(arena, "&amp; &#65; &nbsp;");
    try std.testing.expectEqualStrings("& A \xC2\xA0", decoded);

    const legacy = try decodeEntities(arena, "x=&amp y");
    try std.testing.expectEqualStrings("x=& y", legacy);

    const unknown = try decodeEntities(arena, "hello &bogus; world");
    try std.testing.expectEqualStrings("hello &bogus; world", unknown);

    const overflow = try decodeEntities(arena, "&#99999999;");
    try std.testing.expectEqualStrings("\xEF\xBF\xBD", overflow);
}
