const dom = @import("dom.zig");

pub const Token = union(enum) {
    doctype: []const u8,
    start_tag: struct { name: []const u8, attrs: []dom.Attribute, self_closing: bool },
    end_tag: []const u8,
    comment: []const u8,
    character: []const u8,
    eof,
};
