const std = @import("std");
const cssom = @import("cssom.zig");
const tokenizer = @import("tokenizer.zig");

pub const ParseError = error{
    InvalidSelector,
} || std.mem.Allocator.Error;

pub fn parseStylesheet(arena: std.mem.Allocator, input: []const u8) ParseError![]cssom.Rule {
    _ = try tokenizer.tokenize(arena, input);

    var rules = std.ArrayList(cssom.Rule).empty;
    errdefer rules.deinit(arena);

    var i: usize = 0;
    while (true) {
        skipWs(input, &i);
        if (i >= input.len) break;

        if (input[i] == '@') {
            skipAtRule(input, &i);
            continue;
        }

        const sel_start = i;
        while (i < input.len and input[i] != '{') : (i += 1) {}
        if (i >= input.len) break;
        const selector_src = std.mem.trim(u8, input[sel_start..i], " \t\r\n");
        i += 1; // consume '{'

        const decl_start = i;
        while (i < input.len and input[i] != '}') : (i += 1) {}
        const decl_src = input[decl_start..@min(i, input.len)];
        if (i < input.len and input[i] == '}') i += 1;

        if (selector_src.len == 0) continue;
        const selectors = try parseSelectorList(arena, selector_src);
        const decls = try parseDeclarations(arena, decl_src);
        if (selectors.len == 0) continue;

        try rules.append(arena, .{
            .selectors = selectors,
            .decls = decls,
        });
    }

    return rules.toOwnedSlice(arena);
}

fn parseSelectorList(arena: std.mem.Allocator, src: []const u8) ParseError![][]cssom.SelectorPart {
    var selectors = std.ArrayList([]cssom.SelectorPart).empty;
    errdefer selectors.deinit(arena);

    var start: usize = 0;
    var i: usize = 0;
    while (i <= src.len) : (i += 1) {
        if (i == src.len or src[i] == ',') {
            const part = std.mem.trim(u8, src[start..i], " \t\r\n");
            if (part.len > 0) {
                try selectors.append(arena, try parseSelector(arena, part));
            }
            start = i + 1;
        }
    }

    return selectors.toOwnedSlice(arena);
}

fn parseSelector(arena: std.mem.Allocator, src: []const u8) ParseError![]cssom.SelectorPart {
    var parts = std.ArrayList(cssom.SelectorPart).empty;
    errdefer parts.deinit(arena);

    var i: usize = 0;
    while (i < src.len) {
        skipWs(src, &i);
        if (i >= src.len) break;

        var simple = std.ArrayList(cssom.SimpleSelector).empty;
        errdefer simple.deinit(arena);

        if (src[i] == '*') {
            try simple.append(arena, .universal);
            i += 1;
        } else if (isIdentStart(src[i])) {
            const start = i;
            i += 1;
            while (i < src.len and isIdentChar(src[i])) : (i += 1) {}
            try simple.append(arena, .{ .type_sel = try arena.dupe(u8, src[start..i]) });
        }

        while (i < src.len) {
            if (src[i] == '.') {
                i += 1;
                const start = i;
                while (i < src.len and isIdentChar(src[i])) : (i += 1) {}
                try simple.append(arena, .{ .class = try arena.dupe(u8, src[start..i]) });
                continue;
            }
            if (src[i] == '#') {
                i += 1;
                const start = i;
                while (i < src.len and isIdentChar(src[i])) : (i += 1) {}
                try simple.append(arena, .{ .id = try arena.dupe(u8, src[start..i]) });
                continue;
            }
            if (src[i] == ':') {
                i += 1;
                const start = i;
                while (i < src.len and isIdentChar(src[i])) : (i += 1) {}
                try simple.append(arena, .{ .pseudo = try arena.dupe(u8, src[start..i]) });
                continue;
            }
            break;
        }

        if (simple.items.len == 0) return error.InvalidSelector;

        const comb = parseCombinator(src, i);
        i = comb.next_index;
        try parts.append(arena, .{
            .simple = try simple.toOwnedSlice(arena),
            .combinator = comb.combinator,
        });
    }

    if (parts.items.len > 0) {
        parts.items[parts.items.len - 1].combinator = null;
    }
    return parts.toOwnedSlice(arena);
}

const ParsedCombinator = struct {
    combinator: ?cssom.Combinator,
    next_index: usize,
};

fn parseCombinator(src: []const u8, from: usize) ParsedCombinator {
    var i = from;
    var had_ws = false;
    while (i < src.len and isWs(src[i])) : (i += 1) had_ws = true;
    if (i >= src.len) return .{ .combinator = null, .next_index = i };

    if (src[i] == '>') {
        i += 1;
        while (i < src.len and isWs(src[i])) : (i += 1) {}
        return .{ .combinator = .child, .next_index = i };
    }
    if (src[i] == '+') {
        i += 1;
        while (i < src.len and isWs(src[i])) : (i += 1) {}
        return .{ .combinator = .adjacent, .next_index = i };
    }
    if (had_ws) return .{ .combinator = .descendant, .next_index = i };
    return .{ .combinator = null, .next_index = i };
}

fn parseDeclarations(arena: std.mem.Allocator, src: []const u8) ParseError![]cssom.Declaration {
    var decls = std.ArrayList(cssom.Declaration).empty;
    errdefer decls.deinit(arena);

    var start: usize = 0;
    var i: usize = 0;
    while (i <= src.len) : (i += 1) {
        if (i == src.len or src[i] == ';') {
            const chunk = std.mem.trim(u8, src[start..i], " \t\r\n");
            if (chunk.len > 0) {
                if (std.mem.indexOfScalar(u8, chunk, ':')) |colon| {
                    const name = std.mem.trim(u8, chunk[0..colon], " \t\r\n");
                    const value = std.mem.trim(u8, chunk[colon + 1 ..], " \t\r\n");
                    if (name.len > 0 and value.len > 0) {
                        try decls.append(arena, .{
                            .name = try arena.dupe(u8, name),
                            .value = try arena.dupe(u8, value),
                        });
                    }
                }
            }
            start = i + 1;
        }
    }

    return decls.toOwnedSlice(arena);
}

fn skipAtRule(src: []const u8, i: *usize) void {
    var depth: usize = 0;
    while (i.* < src.len) : (i.* += 1) {
        if (src[i.*] == '{') depth += 1;
        if (src[i.*] == '}') {
            if (depth == 0) {
                i.* += 1;
                return;
            }
            depth -= 1;
            if (depth == 0) {
                i.* += 1;
                return;
            }
        }
        if (depth == 0 and src[i.*] == ';') {
            i.* += 1;
            return;
        }
    }
}

fn skipWs(src: []const u8, i: *usize) void {
    while (i.* < src.len and isWs(src[i.*])) : (i.* += 1) {}
}

fn isWs(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '\x0c';
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch == '-';
}

fn isIdentChar(ch: u8) bool {
    return isIdentStart(ch) or std.ascii.isDigit(ch);
}

test "cycle 3.1 parse selector chain and declaration" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rules = try parseStylesheet(arena, "a.b > #c { color: red }");
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(@as(usize, 1), rules[0].selectors.len);
    try std.testing.expectEqual(@as(usize, 2), rules[0].selectors[0].len);

    const first = rules[0].selectors[0][0];
    try std.testing.expectEqual(@as(?cssom.Combinator, .child), first.combinator);
    try std.testing.expectEqual(@as(usize, 2), first.simple.len);
    switch (first.simple[0]) {
        .type_sel => |name| try std.testing.expectEqualStrings("a", name),
        else => return error.TestExpectedEqual,
    }
    switch (first.simple[1]) {
        .class => |name| try std.testing.expectEqualStrings("b", name),
        else => return error.TestExpectedEqual,
    }
    switch (rules[0].selectors[0][1].simple[0]) {
        .id => |name| try std.testing.expectEqualStrings("c", name),
        else => return error.TestExpectedEqual,
    }

    try std.testing.expectEqual(@as(usize, 1), rules[0].decls.len);
    try std.testing.expectEqualStrings("color", rules[0].decls[0].name);
    try std.testing.expectEqualStrings("red", rules[0].decls[0].value);
}

test "cycle 3.1 selector list with comma parses into multiple selector entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rules = try parseStylesheet(arena, "h1, h2.title { font-weight: 700; }");
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(@as(usize, 2), rules[0].selectors.len);
}

test "cycle 3.2 malformed declaration skipped and valid ones kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rules = try parseStylesheet(arena, "a { color: red; broken ; margin: 0 }");
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(@as(usize, 2), rules[0].decls.len);
    try std.testing.expectEqualStrings("color", rules[0].decls[0].name);
    try std.testing.expectEqualStrings("margin", rules[0].decls[1].name);
}

test "cycle 3.2 malformed blocks and at-rules do not crash parser" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const samples = [_][]const u8{
        "@media screen { .x { color: red; } } .y { width: 10px }",
        "a{color:red",
        "@unknown foo;",
        "div > { broken: 1; } p { ok: yes; }",
    };
    for (samples) |sample| {
        _ = try parseStylesheet(arena, sample);
    }
}
