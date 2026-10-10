const std = @import("std");
const config = @import("config.zig");

pub const Command = union(enum) {
    version,
    open: struct {
        url: []const u8,
        print_title: bool = false,
        e2e_protocol: bool = false,
        automation_api: bool = false,
        automation_token_file: ?[]const u8 = null,
        /// --profile-dir <path>: persistent cookies/storage. null = caller
        /// uses `defaultProfileDir`.
        profile_dir: ?[]const u8 = null,
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
    if (args.len <= 1) return .{ .open = .{ .url = config.default_url } };

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
    var automation_api = false;
    var automation_token_file: ?[]const u8 = null;
    var profile_dir: ?[]const u8 = null;

    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        if (std.mem.eql(u8, token, "--print-title")) {
            print_title = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--e2e-protocol")) {
            e2e_protocol = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--automation-api")) {
            automation_api = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--automation-token-file")) {
            i += 1;
            if (i >= tokens.len) return .usage;
            const path = tokens[i];
            if (std.mem.startsWith(u8, path, "-")) return .usage;
            if (automation_token_file != null) return .usage;
            automation_token_file = path;
            continue;
        }
        if (std.mem.eql(u8, token, "--profile-dir")) {
            i += 1;
            if (i >= tokens.len) return .usage;
            const path = tokens[i];
            if (path.len == 0 or std.mem.startsWith(u8, path, "-")) return .usage;
            if (profile_dir != null) return .usage;
            profile_dir = path;
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
    if (automation_token_file != null and !automation_api) return .usage;

    return .{ .open = .{
        .url = url.?,
        .print_title = print_title,
        .e2e_protocol = e2e_protocol,
        .automation_api = automation_api,
        .automation_token_file = automation_token_file,
        .profile_dir = profile_dir,
    } };
}

const profile_subpath = "zigbrowser/profile";

/// Default profile directory: $XDG_DATA_HOME/zigbrowser/profile, else
/// $HOME/.local/share/zigbrowser/profile. A relative or empty XDG_DATA_HOME
/// is ignored (XDG Base Directory spec). Returns null when neither is usable.
pub fn defaultProfileDir(allocator: std.mem.Allocator, xdg_data_home: ?[]const u8, home: ?[]const u8) !?[]u8 {
    if (xdg_data_home) |dir| {
        if (std.fs.path.isAbsolute(dir)) return try std.fs.path.join(allocator, &.{ dir, profile_subpath });
    }
    const home_dir = home orelse return null;
    if (home_dir.len == 0) return null;
    return try std.fs.path.join(allocator, &.{ home_dir, ".local/share", profile_subpath });
}

test "parseArgs no args yields open with config default URL" {
    const cmd = parseArgs(&.{"zigBrowser"});
    try std.testing.expect(cmd == .open);
    try std.testing.expectEqualStrings(config.default_url, cmd.open.url);
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

test "parseArgs URL --automation-api sets automation flag" {
    const cmd = parseArgs(&.{ "zigBrowser", "https://example.com", "--automation-api" });
    try std.testing.expect(cmd == .open);
    try std.testing.expect(cmd.open.automation_api);
    try std.testing.expect(cmd.open.automation_token_file == null);
}

test "parseArgs --automation-api URL is accepted" {
    const cmd = parseArgs(&.{ "zigBrowser", "--automation-api", "https://example.com" });
    try std.testing.expect(cmd == .open);
    try std.testing.expect(cmd.open.automation_api);
    try std.testing.expectEqualStrings("https://example.com", cmd.open.url);
}

test "parseArgs duplicate --automation-api remains idempotent" {
    const cmd = parseArgs(&.{ "zigBrowser", "--automation-api", "https://example.com", "--automation-api" });
    try std.testing.expect(cmd == .open);
    try std.testing.expect(cmd.open.automation_api);
}

test "parseArgs --automation-token-file captures token path" {
    const cmd = parseArgs(&.{ "zigBrowser", "--automation-api", "--automation-token-file", "/tmp/zb.token", "https://example.com" });
    try std.testing.expect(cmd == .open);
    try std.testing.expect(cmd.open.automation_api);
    try std.testing.expectEqualStrings("/tmp/zb.token", cmd.open.automation_token_file.?);
}

test "parseArgs --automation-token-file path starting with dash is usage" {
    const cmd = parseArgs(&.{ "zigBrowser", "--automation-api", "--automation-token-file", "-bad", "https://example.com" });
    try std.testing.expect(cmd == .usage);
}

test "parseArgs rejects automation flags for screenshot" {
    const cmd = parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com", "--automation-api" });
    try std.testing.expect(cmd == .usage);
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

test "parseArgs --profile-dir captures the path (with or without automation)" {
    const plain = parseArgs(&.{ "zigBrowser", "--profile-dir", "/tmp/zb-profile", "https://example.com" });
    try std.testing.expect(plain == .open);
    try std.testing.expectEqualStrings("/tmp/zb-profile", plain.open.profile_dir.?);

    const with_api = parseArgs(&.{ "zigBrowser", "https://example.com", "--automation-api", "--profile-dir", "rel/profile" });
    try std.testing.expect(with_api == .open);
    try std.testing.expectEqualStrings("rel/profile", with_api.open.profile_dir.?);
}

test "parseArgs without --profile-dir leaves profile_dir null" {
    const cmd = parseArgs(&.{ "zigBrowser", "https://example.com" });
    try std.testing.expect(cmd.open.profile_dir == null);
}

test "parseArgs --profile-dir errors are usage" {
    const cases = [_][]const []const u8{
        &.{ "zigBrowser", "https://example.com", "--profile-dir" },
        &.{ "zigBrowser", "--profile-dir", "-x", "https://example.com" },
        &.{ "zigBrowser", "--profile-dir", "", "https://example.com" },
        &.{ "zigBrowser", "--profile-dir", "/a", "--profile-dir", "/b", "https://example.com" },
        &.{ "zigBrowser", "--screenshot", "out.png", "https://example.com", "--profile-dir" },
    };
    for (cases) |args| try std.testing.expect(parseArgs(args) == .usage);
}

test "defaultProfileDir prefers XDG_DATA_HOME, then HOME/.local/share" {
    const allocator = std.testing.allocator;
    const xdg = (try defaultProfileDir(allocator, "/xdg/data", "/home/u")).?;
    defer allocator.free(xdg);
    try std.testing.expectEqualStrings("/xdg/data/zigbrowser/profile", xdg);

    const home = (try defaultProfileDir(allocator, null, "/home/u")).?;
    defer allocator.free(home);
    try std.testing.expectEqualStrings("/home/u/.local/share/zigbrowser/profile", home);

    // XDG spec: relative/empty XDG_DATA_HOME is ignored.
    const relative = (try defaultProfileDir(allocator, "relative/dir", "/home/u")).?;
    defer allocator.free(relative);
    try std.testing.expectEqualStrings("/home/u/.local/share/zigbrowser/profile", relative);
    const empty = (try defaultProfileDir(allocator, "", "/home/u")).?;
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("/home/u/.local/share/zigbrowser/profile", empty);

    try std.testing.expect((try defaultProfileDir(allocator, null, null)) == null);
    try std.testing.expect((try defaultProfileDir(allocator, null, "")) == null);
}
