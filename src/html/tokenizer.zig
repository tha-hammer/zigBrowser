const std = @import("std");
const dom = @import("dom.zig");
const entities = @import("entities.zig");

pub const Token = union(enum) {
    doctype: []const u8,
    start_tag: struct { name: []const u8, attrs: []dom.Attribute, self_closing: bool },
    end_tag: []const u8,
    comment: []const u8,
    character: []const u8,
    eof,
};

pub const TokenizeError = std.mem.Allocator.Error;

pub fn tokenize(arena: std.mem.Allocator, input: []const u8) TokenizeError![]Token {
    var tokens = std.ArrayList(Token).empty;
    errdefer tokens.deinit(arena);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '<') {
            if (i + 3 < input.len and std.ascii.eqlIgnoreCase(input[i + 1 .. @min(i + 4, input.len)], "!--")) {
                const comment_parsed = try parseComment(arena, input, i + 4);
                try tokens.append(arena, .{ .comment = comment_parsed.comment });
                i = comment_parsed.next_index;
                continue;
            }

            if (i + 2 < input.len and input[i + 1] == '!') {
                if (parseDoctype(arena, input, i + 2)) |dt| {
                    try tokens.append(arena, .{ .doctype = dt.name });
                    i = dt.next_index;
                    continue;
                }
            }

            if (i + 1 < input.len and input[i + 1] == '/') {
                var j = i + 2;
                const name_start = j;
                while (j < input.len and isTagNameChar(input[j])) : (j += 1) {}
                const raw_name = input[name_start..j];
                if (j < input.len and input[j] == '>') j += 1;
                try tokens.append(arena, .{ .end_tag = try lowerDup(arena, raw_name) });
                i = j;
                continue;
            }

            if (i + 1 < input.len and isTagNameChar(input[i + 1])) {
                const parsed = try parseStartTag(arena, input, i + 1);
                try tokens.append(arena, .{
                    .start_tag = .{
                        .name = parsed.name,
                        .attrs = parsed.attrs,
                        .self_closing = parsed.self_closing,
                    },
                });

                if (!parsed.self_closing and isRawTextTag(parsed.name)) {
                    const raw = try consumeRawText(arena, input, parsed.next_index, parsed.name);
                    if (raw.text.len > 0) {
                        try tokens.append(arena, .{ .character = raw.text });
                    }
                    if (raw.closed) {
                        try tokens.append(arena, .{ .end_tag = try arena.dupe(u8, parsed.name) });
                    }
                    i = raw.next_index;
                    continue;
                }

                i = parsed.next_index;
                continue;
            }
        }

        const text_start = i;
        while (i < input.len and input[i] != '<') : (i += 1) {}
        if (i > text_start) {
            const decoded = try entities.decodeEntities(arena, input[text_start..i]);
            try tokens.append(arena, .{ .character = decoded });
        } else {
            const decoded = try entities.decodeEntities(arena, input[text_start .. text_start + 1]);
            try tokens.append(arena, .{ .character = decoded });
            i += 1;
        }
    }

    try tokens.append(arena, .eof);
    return tokens.toOwnedSlice(arena);
}

const ParsedTag = struct {
    name: []const u8,
    attrs: []dom.Attribute,
    self_closing: bool,
    next_index: usize,
};

fn parseStartTag(arena: std.mem.Allocator, input: []const u8, start: usize) TokenizeError!ParsedTag {
    var i = start;
    const name_start = i;
    while (i < input.len and isTagNameChar(input[i])) : (i += 1) {}
    const name = try lowerDup(arena, input[name_start..i]);

    var attrs = std.ArrayList(dom.Attribute).empty;
    errdefer attrs.deinit(arena);
    var self_closing = false;

    while (i < input.len) {
        skipWs(input, &i);
        if (i >= input.len) break;

        if (input[i] == '>') {
            i += 1;
            break;
        }

        if (input[i] == '/') {
            self_closing = true;
            i += 1;
            skipWs(input, &i);
            if (i < input.len and input[i] == '>') i += 1;
            break;
        }

        const attr_name_start = i;
        while (i < input.len and isAttrNameChar(input[i])) : (i += 1) {}
        if (i == attr_name_start) {
            i += 1;
            continue;
        }
        const attr_name = try lowerDup(arena, input[attr_name_start..i]);
        skipWs(input, &i);

        var attr_value: []const u8 = "";
        if (i < input.len and input[i] == '=') {
            i += 1;
            skipWs(input, &i);
            if (i < input.len and (input[i] == '"' or input[i] == '\'')) {
                const quote = input[i];
                i += 1;
                const value_start = i;
                while (i < input.len and input[i] != quote) : (i += 1) {}
                attr_value = try entities.decodeEntities(arena, input[value_start..@min(i, input.len)]);
                if (i < input.len and input[i] == quote) i += 1;
            } else {
                const value_start = i;
                while (i < input.len and !isWs(input[i]) and input[i] != '>' and input[i] != '/') : (i += 1) {}
                attr_value = try entities.decodeEntities(arena, input[value_start..i]);
            }
        }

        if (!hasAttr(attrs.items, attr_name)) {
            try attrs.append(arena, .{ .name = attr_name, .value = attr_value });
        }
    }

    return .{
        .name = name,
        .attrs = try attrs.toOwnedSlice(arena),
        .self_closing = self_closing,
        .next_index = i,
    };
}

fn hasAttr(attrs: []const dom.Attribute, name: []const u8) bool {
    for (attrs) |attr| {
        if (std.ascii.eqlIgnoreCase(attr.name, name)) return true;
    }
    return false;
}

fn isTagNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_';
}

fn isAttrNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == ':';
}

fn isWs(ch: u8) bool {
    return ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t' or ch == '\x0c';
}

fn skipWs(input: []const u8, i: *usize) void {
    while (i.* < input.len and isWs(input[i.*])) : (i.* += 1) {}
}

fn lowerDup(arena: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    const duped = try arena.dupe(u8, s);
    for (duped) |*ch| ch.* = std.ascii.toLower(ch.*);
    return duped;
}

fn isRawTextTag(name: []const u8) bool {
    return std.mem.eql(u8, name, "script") or std.mem.eql(u8, name, "style");
}

const RawTextParsed = struct {
    text: []const u8,
    closed: bool,
    next_index: usize,
};

fn consumeRawText(arena: std.mem.Allocator, input: []const u8, start: usize, tag_name: []const u8) std.mem.Allocator.Error!RawTextParsed {
    var i = start;
    while (i < input.len) : (i += 1) {
        if (input[i] == '<' and i + 2 + tag_name.len <= input.len and input[i + 1] == '/') {
            const end_name = input[i + 2 .. i + 2 + tag_name.len];
            if (std.ascii.eqlIgnoreCase(end_name, tag_name)) {
                const j = i + 2 + tag_name.len;
                if (j < input.len and input[j] == '>') {
                    const text = try arena.dupe(u8, input[start..i]);
                    return .{ .text = text, .closed = true, .next_index = j + 1 };
                }
            }
        }
    }
    const text = try arena.dupe(u8, input[start..]);
    return .{ .text = text, .closed = false, .next_index = input.len };
}

const ParsedComment = struct {
    comment: []const u8,
    next_index: usize,
};

fn parseComment(arena: std.mem.Allocator, input: []const u8, start: usize) std.mem.Allocator.Error!ParsedComment {
    var i = start;
    while (i + 2 < input.len) : (i += 1) {
        if (input[i] == '-' and input[i + 1] == '-' and input[i + 2] == '>') {
            return .{
                .comment = try arena.dupe(u8, input[start..i]),
                .next_index = i + 3,
            };
        }
    }
    return .{
        .comment = try arena.dupe(u8, input[start..]),
        .next_index = input.len,
    };
}

const ParsedDoctype = struct {
    name: []const u8,
    next_index: usize,
};

fn parseDoctype(arena: std.mem.Allocator, input: []const u8, start: usize) ?ParsedDoctype {
    var i = start;
    while (i < input.len and isWs(input[i])) : (i += 1) {}
    const keyword = "doctype";
    if (i + keyword.len > input.len or !std.ascii.eqlIgnoreCase(input[i .. i + keyword.len], keyword)) {
        return null;
    }
    i += keyword.len;
    while (i < input.len and isWs(input[i])) : (i += 1) {}
    const name_start = i;
    while (i < input.len and !isWs(input[i]) and input[i] != '>') : (i += 1) {}
    const name = lowerDup(arena, input[name_start..i]) catch return null;
    while (i < input.len and input[i] != '>') : (i += 1) {}
    if (i < input.len and input[i] == '>') i += 1;
    return .{ .name = name, .next_index = i };
}

test "cycle 2.1 tokenize tags and text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tokens = try tokenize(arena, "<p class=x>Hi</p>");
    try std.testing.expectEqual(@as(usize, 4), tokens.len);

    switch (tokens[0]) {
        .start_tag => |tag| {
            try std.testing.expectEqualStrings("p", tag.name);
            try std.testing.expectEqual(@as(usize, 1), tag.attrs.len);
            try std.testing.expectEqualStrings("class", tag.attrs[0].name);
            try std.testing.expectEqualStrings("x", tag.attrs[0].value);
            try std.testing.expect(!tag.self_closing);
        },
        else => return error.TestExpectedEqual,
    }
    switch (tokens[1]) {
        .character => |text| try std.testing.expectEqualStrings("Hi", text),
        else => return error.TestExpectedEqual,
    }
    switch (tokens[2]) {
        .end_tag => |name| try std.testing.expectEqualStrings("p", name),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expect(tokens[3] == .eof);
}

test "cycle 2.1 uppercase normalize self-closing and duplicate attrs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tokens = try tokenize(arena, "<BR CLASS=X class=Y/>");
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    switch (tokens[0]) {
        .start_tag => |tag| {
            try std.testing.expectEqualStrings("br", tag.name);
            try std.testing.expect(tag.self_closing);
            try std.testing.expectEqual(@as(usize, 1), tag.attrs.len);
            try std.testing.expectEqualStrings("class", tag.attrs[0].name);
            try std.testing.expectEqualStrings("X", tag.attrs[0].value);
        },
        else => return error.TestExpectedEqual,
    }
}

test "cycle 2.1 eof mid tag still emits tag then eof" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tokens = try tokenize(arena, "<p class=x");
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    switch (tokens[0]) {
        .start_tag => |tag| {
            try std.testing.expectEqualStrings("p", tag.name);
            try std.testing.expectEqual(@as(usize, 1), tag.attrs.len);
            try std.testing.expectEqualStrings("class", tag.attrs[0].name);
            try std.testing.expectEqualStrings("x", tag.attrs[0].value);
        },
        else => return error.TestExpectedEqual,
    }
    try std.testing.expect(tokens[1] == .eof);
}
