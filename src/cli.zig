const std = @import("std");

pub const Command = union(enum) {
    version,
    open: struct {
        url: []const u8,
        print_title: bool = false,
        e2e_protocol: bool = false,
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
    if (args.len <= 1) return .{ .open = .{ .url = "https://cosmic-hr-development.up.railway.app/" } };

    const first = args[1];

    if (std.mem.eql(u8, first, "--version")) {
        return .version;
    }

    if (std.mem.eql(u8, first, "--screenshot")) {
        return parseScreenshotArgs(args[1..]);
    }

    return parseOpenArgs(args[1..]);
}

fn parseScreenshotArgs(tokens: []const []const u8) Command {
    if (tokens.len != 3 and tokens.len != 4) return .usage;
    if (!std.mem.eql(u8, tokens[0], "--screenshot")) return .usage;
    if (std.mem.startsWith(u8, tokens[1], "-")) return .usage;

    var print_title = false;
    if (tokens.len == 4) {
        if (!std.mem.eql(u8, tokens[3], "--print-title")) return .usage;
        print_title = true;
    }

    return .{ .screenshot = .{
        .out = tokens[1],
        .url = tokens[2],
        .print_title = print_title,
    } };
}

fn parseOpenArgs(tokens: []const []const u8) Command {
    var url: ?[]const u8 = null;
    var print_title = false;
    var e2e_protocol = false;

    for (tokens) |token| {
        if (std.mem.eql(u8, token, "--print-title")) {
            print_title = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--e2e-protocol")) {
            e2e_protocol = true;
            continue;
        }
        if (std.mem.startsWith(u8, token, "-")) {
            return .usage;
        }
        if (url != null) {
            return .usage;
        }
        url = token;
    }

    if (url == null) return .usage;

    return .{ .open = .{
        .url = url.?,
        .print_title = print_title,
        .e2e_protocol = e2e_protocol,
    } };
}

test "parseArgs no args yields open with default URL" {
    const cmd = parseArgs(&.{"zigBrowser"});
    try std.testing.expect(cmd == .open);
    try std.testing.expectEqualStrings("https://cosmic-hr-development.up.railway.app/", cmd.open.url);
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
    try std.testing.expect(!cmd.open.e2e_protocol);
}

test "parseArgs URL --print-title sets flag" {
    const cmd = parseArgs(&.{ "zigBrowser", "https://example.com", "--print-title" });
    try std.testing.expect(cmd == .open);
    try std.testing.expect(cmd.open.print_title);
    try std.testing.expect(!cmd.open.e2e_protocol);
}

test "parseArgs --print-title URL is accepted" {
    const cmd = parseArgs(&.{ "zigBrowser", "--print-title", "https://example.com" });
    try std.testing.expect(cmd == .open);
    try std.testing.expect(cmd.open.print_title);
    try std.testing.expectEqualStrings("https://example.com", cmd.open.url);
}

test "parseArgs URL --e2e-protocol sets protocol flag" {
    const cmd = parseArgs(&.{ "zigBrowser", "https://example.com", "--e2e-protocol" });
    try std.testing.expect(cmd == .open);
    try std.testing.expect(cmd.open.e2e_protocol);
    try std.testing.expect(!cmd.open.print_title);
}

test "parseArgs supports both open flags" {
    const cmd = parseArgs(&.{ "zigBrowser", "--e2e-protocol", "--print-title", "https://example.com" });
    try std.testing.expect(cmd == .open);
    try std.testing.expect(cmd.open.e2e_protocol);
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
