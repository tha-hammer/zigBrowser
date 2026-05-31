const std = @import("std");

pub const Command = union(enum) {
    version,
    open: struct {
        url: []const u8,
        print_title: bool = false,
    },
    screenshot: struct {
        url: []const u8,
        out: []const u8,
        w: u32 = 1024,
        h: u32 = 768,
        print_title: bool = false,
    },
    usage,
};

pub fn parseArgs(args: []const []const u8) Command {
    if (args.len <= 1) return .usage;

    const first = args[1];

    if (std.mem.eql(u8, first, "--version")) {
        return .version;
    }

    if (std.mem.eql(u8, first, "--screenshot")) {
        if (args.len != 4 and args.len != 5) return .usage;
        if (std.mem.startsWith(u8, args[2], "-")) return .usage;

        var print_title = false;
        if (args.len == 5) {
            if (!std.mem.eql(u8, args[4], "--print-title")) return .usage;
            print_title = true;
        }

        return .{ .screenshot = .{
            .out = args[2],
            .url = args[3],
            .print_title = print_title,
        } };
    }

    if (std.mem.startsWith(u8, first, "-")) return .usage;

    if (args.len == 2) {
        return .{ .open = .{ .url = first } };
    }

    if (args.len == 3 and std.mem.eql(u8, args[2], "--print-title")) {
        return .{ .open = .{ .url = first, .print_title = true } };
    }

    return .usage;
}

test "parseArgs --version yields .version" {
    const cmd = parseArgs(&.{ "zigBrowser", "--version" });
    try std.testing.expect(cmd == .version);
}

test "parseArgs URL yields .open payload" {
    const cmd = parseArgs(&.{ "zigBrowser", "https://example.com" });
    try std.testing.expect(cmd == .open);
    try std.testing.expectEqualStrings("https://example.com", cmd.open.url);
    try std.testing.expect(!cmd.open.print_title);
}

test "parseArgs URL --print-title sets flag" {
    const cmd = parseArgs(&.{ "zigBrowser", "https://example.com", "--print-title" });
    try std.testing.expect(cmd == .open);
    try std.testing.expect(cmd.open.print_title);
}

test "parseArgs --screenshot yields .screenshot payload" {
    const cmd = parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com" });
    try std.testing.expect(cmd == .screenshot);
    try std.testing.expectEqualStrings("out.png", cmd.screenshot.out);
    try std.testing.expectEqualStrings("https://example.com", cmd.screenshot.url);
    try std.testing.expectEqual(@as(u32, 1024), cmd.screenshot.w);
    try std.testing.expectEqual(@as(u32, 768), cmd.screenshot.h);
    try std.testing.expect(!cmd.screenshot.print_title);
}

test "parseArgs --screenshot ... --print-title sets flag" {
    const cmd = parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com", "--print-title" });
    try std.testing.expect(cmd == .screenshot);
    try std.testing.expect(cmd.screenshot.print_title);
}

test "parseArgs screenshot output starting with dash is usage" {
    const cmd = parseArgs(&.{ "zigBrowser", "--screenshot", "-bad.png", "https://example.com" });
    try std.testing.expect(cmd == .usage);
}
