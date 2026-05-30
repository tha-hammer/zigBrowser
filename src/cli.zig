const std = @import("std");

pub const Command = union(enum) {
    version,
    open: []const u8,
    usage,
};

pub fn parseArgs(args: []const []const u8) Command {
    if (args.len <= 1) return .usage;

    const first = args[1];
    if (std.mem.eql(u8, first, "--version")) return .version;
    if (std.mem.startsWith(u8, first, "-")) return .usage;
    return .{ .open = first };
}

test "parseArgs --version yields .version" {
    const cmd = parseArgs(&.{ "zigBrowser", "--version" });
    try std.testing.expect(cmd == .version);
}

test "parseArgs URL yields .open payload" {
    const cmd = parseArgs(&.{ "zigBrowser", "https://example.com" });
    try std.testing.expect(cmd == .open);
    try std.testing.expectEqualStrings("https://example.com", cmd.open);
}
