const std = @import("std");

pub const Token = union(enum) {
    ident: []const u8,
    hash: []const u8,
    class: []const u8,
    pseudo: []const u8,
    universal,
    comma,
    brace_open,
    brace_close,
    colon,
    semicolon,
    greater,
    plus,
    eof,
};

pub fn tokenize(arena: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]Token {
    var out = std.ArrayList(Token).empty;
    errdefer out.deinit(arena);

    var i: usize = 0;
    while (i < input.len) {
        const ch = input[i];
        if (isWs(ch)) {
            i += 1;
            continue;
        }

        switch (ch) {
            ',' => {
                try out.append(arena, .comma);
                i += 1;
            },
            '{' => {
                try out.append(arena, .brace_open);
                i += 1;
            },
            '}' => {
                try out.append(arena, .brace_close);
                i += 1;
            },
            ':' => {
                try out.append(arena, .colon);
                i += 1;
            },
            ';' => {
                try out.append(arena, .semicolon);
                i += 1;
            },
            '>' => {
                try out.append(arena, .greater);
                i += 1;
            },
            '+' => {
                try out.append(arena, .plus);
                i += 1;
            },
            '*' => {
                try out.append(arena, .universal);
                i += 1;
            },
            '#' => {
                i += 1;
                const start = i;
                while (i < input.len and isIdentChar(input[i])) : (i += 1) {}
                try out.append(arena, .{ .hash = try arena.dupe(u8, input[start..i]) });
            },
            '.' => {
                i += 1;
                const start = i;
                while (i < input.len and isIdentChar(input[i])) : (i += 1) {}
                try out.append(arena, .{ .class = try arena.dupe(u8, input[start..i]) });
            },
            else => {
                if (ch == '@') {
                    i += 1;
                    const start = i;
                    while (i < input.len and isIdentChar(input[i])) : (i += 1) {}
                    try out.append(arena, .{ .ident = try arena.dupe(u8, input[start..i]) });
                    continue;
                }
                if (isIdentStart(ch)) {
                    const start = i;
                    i += 1;
                    while (i < input.len and isIdentChar(input[i])) : (i += 1) {}
                    try out.append(arena, .{ .ident = try arena.dupe(u8, input[start..i]) });
                } else if (ch == ':') {
                    i += 1;
                    const start = i;
                    while (i < input.len and isIdentChar(input[i])) : (i += 1) {}
                    try out.append(arena, .{ .pseudo = try arena.dupe(u8, input[start..i]) });
                } else {
                    i += 1;
                }
            },
        }
    }
    try out.append(arena, .eof);
    return out.toOwnedSlice(arena);
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch == '-';
}

fn isIdentChar(ch: u8) bool {
    return isIdentStart(ch) or std.ascii.isDigit(ch);
}

fn isWs(ch: u8) bool {
    return ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t' or ch == '\x0c';
}
