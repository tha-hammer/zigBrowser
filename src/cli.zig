const std = @import("std");

pub const Command = union(enum) {
    version,
    open: []const u8,
    screenshot: struct {
        url: []const u8,
        out: []const u8,
        w: u32 = 1024,
        h: u32 = 768,
    },
    usage,
};

pub fn parseArgs(args: []const []const u8) Command {
    if (args.len <= 1) return .usage;

    const first = args[1];
    if (std.mem.eql(u8, first, "--version")) return .version;
    if (std.mem.eql(u8, first, "--screenshot")) {
        if (args.len != 4) return .usage;
        return .{
            .screenshot = .{
                .out = args[2],
                .url = args[3],
            },
        };
    }
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

test "parseArgs --screenshot yields .screenshot payload" {
    const cmd = parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com" });
    try std.testing.expect(cmd == .screenshot);
    try std.testing.expectEqualStrings("out.png", cmd.screenshot.out);
    try std.testing.expectEqualStrings("https://example.com", cmd.screenshot.url);
    try std.testing.expectEqual(@as(u32, 1024), cmd.screenshot.w);
    try std.testing.expectEqual(@as(u32, 768), cmd.screenshot.h);
}
