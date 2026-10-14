const std = @import("std");
const agent_config = @import("agent_config.zig");
const agent_setup = @import("agent_setup.zig");
const config = @import("config.zig");
const media_config = @import("media_config.zig");
const render_config = @import("render_config.zig");

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
        /// --hardware-acceleration <never|always|webkit>; null = built-in default.
        hw_policy: ?render_config.HwPolicy = null,
        /// --renderer <default|shm|mesa-egl>; null = built-in default.
        renderer: ?render_config.Renderer = null,
        /// --media-source <on|off>; null = ZIGBROWSER_MEDIA_SOURCE, else on.
        media_source: ?media_config.MediaSource = null,
        /// --agent-drawer <on|off>; null = ZIGBROWSER_AGENT_DRAWER, else off.
        agent_drawer: ?agent_config.AgentDrawer = null,
    },
    screenshot: struct {
        url: []const u8,
        out: []const u8,
        w: u32 = 1024,
        h: u32 = 768,
        print_title: bool = false,
        /// Same as `open`: null = built-in default.
        hw_policy: ?render_config.HwPolicy = null,
        renderer: ?render_config.Renderer = null,
        media_source: ?media_config.MediaSource = null,
    },
    /// --agent-setup [--sai-source DIR] [--agent-token-route r1|env]
    /// [--e2e-protocol]: provisions the Claude Agent home (chat-drawer S3).
    agent_setup: struct {
        sai_source: ?[]const u8 = null,
        token_route: TokenRoute = .r1,
        e2e_protocol: bool = false,
    },
    usage,
};

/// The token route --agent-setup selects (plan D11): R1 (a descriptor,
/// probed on the installed CLI) unless the environment route is asked for.
pub const TokenRoute = agent_setup.Route;

pub fn parseArgs(args: []const []const u8) Command {
    if (args.len <= 1) return .{ .open = .{ .url = config.default_url } };

    const first = args[1];

    if (std.mem.eql(u8, first, "--version")) {
        return .version;
    }

    if (std.mem.eql(u8, first, "--screenshot")) {
        return parseScreenshotArgs(args[1..]);
    }

    if (std.mem.eql(u8, first, "--agent-setup")) {
        return parseAgentSetupArgs(args[2..]);
    }

    return parseOpenArgs(args[1..]);
}

fn parseScreenshotArgs(tokens: []const []const u8) Command {
    if (tokens.len < 3) return .usage;
    if (!std.mem.eql(u8, tokens[0], "--screenshot")) return .usage;
    if (std.mem.startsWith(u8, tokens[1], "-")) return .usage;

    var print_title = false;
    var hw_policy: ?render_config.HwPolicy = null;
    var renderer: ?render_config.Renderer = null;
    var media_source: ?media_config.MediaSource = null;
    var i: usize = 3;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        if (std.mem.eql(u8, token, "--print-title")) {
            if (print_title) return .usage;
            print_title = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--hardware-acceleration")) {
            i += 1;
            if (i >= tokens.len or hw_policy != null) return .usage;
            hw_policy = render_config.parseHwPolicy(tokens[i]) orelse return .usage;
            continue;
        }
        if (std.mem.eql(u8, token, "--renderer")) {
            i += 1;
            if (i >= tokens.len or renderer != null) return .usage;
            renderer = render_config.parseRenderer(tokens[i]) orelse return .usage;
            continue;
        }
        if (std.mem.eql(u8, token, "--media-source")) {
            i += 1;
            if (i >= tokens.len or media_source != null) return .usage;
            media_source = media_config.parse(tokens[i]) orelse return .usage;
            continue;
        }
        return .usage;
    }

    return .{ .screenshot = .{
        .out = tokens[1],
        .url = tokens[2],
        .print_title = print_title,
        .hw_policy = hw_policy,
        .renderer = renderer,
        .media_source = media_source,
    } };
}

fn parseAgentSetupArgs(tokens: []const []const u8) Command {
    var sai_source: ?[]const u8 = null;
    var token_route: ?TokenRoute = null;
    var e2e_protocol = false;
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const token = tokens[i];
        if (std.mem.eql(u8, token, "--e2e-protocol")) {
            if (e2e_protocol) return .usage;
            e2e_protocol = true;
            continue;
        }
        if (std.mem.eql(u8, token, "--sai-source")) {
            i += 1;
            if (i >= tokens.len or sai_source != null) return .usage;
            const path = tokens[i];
            if (path.len == 0 or std.mem.startsWith(u8, path, "-")) return .usage;
            sai_source = path;
            continue;
        }
        if (std.mem.eql(u8, token, "--agent-token-route")) {
            i += 1;
            if (i >= tokens.len or token_route != null) return .usage;
            token_route = std.meta.stringToEnum(TokenRoute, tokens[i]) orelse return .usage;
            continue;
        }
        return .usage;
    }
    return .{ .agent_setup = .{ .sai_source = sai_source, .token_route = token_route orelse .r1, .e2e_protocol = e2e_protocol } };
}

fn parseOpenArgs(tokens: []const []const u8) Command {
    var url: ?[]const u8 = null;
    var print_title = false;
    var e2e_protocol = false;
    var automation_api = false;
    var automation_token_file: ?[]const u8 = null;
    var profile_dir: ?[]const u8 = null;
    var hw_policy: ?render_config.HwPolicy = null;
    var renderer: ?render_config.Renderer = null;
    var media_source: ?media_config.MediaSource = null;
    var agent_drawer: ?agent_config.AgentDrawer = null;

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
        if (std.mem.eql(u8, token, "--hardware-acceleration")) {
            i += 1;
            if (i >= tokens.len or hw_policy != null) return .usage;
            hw_policy = render_config.parseHwPolicy(tokens[i]) orelse return .usage;
            continue;
        }
        if (std.mem.eql(u8, token, "--renderer")) {
            i += 1;
            if (i >= tokens.len or renderer != null) return .usage;
            renderer = render_config.parseRenderer(tokens[i]) orelse return .usage;
            continue;
        }
        if (std.mem.eql(u8, token, "--media-source")) {
            i += 1;
            if (i >= tokens.len or media_source != null) return .usage;
            media_source = media_config.parse(tokens[i]) orelse return .usage;
            continue;
        }
        if (std.mem.eql(u8, token, "--agent-drawer")) {
            i += 1;
            if (i >= tokens.len or agent_drawer != null) return .usage;
            agent_drawer = agent_config.parse(tokens[i]) orelse return .usage;
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
        .hw_policy = hw_policy,
        .renderer = renderer,
        .media_source = media_source,
        .agent_drawer = agent_drawer,
    } };
}

const profile_subpath = "zigbrowser/profile";
const xdg_dirs = @import("xdg.zig");

/// Default profile directory: $XDG_DATA_HOME/zigbrowser/profile, else
/// $HOME/.local/share/zigbrowser/profile. A relative or empty XDG_DATA_HOME
/// is ignored (XDG Base Directory spec). Returns null when neither is usable.
pub fn defaultProfileDir(allocator: std.mem.Allocator, xdg_data_home: ?[]const u8, home: ?[]const u8) !?[]u8 {
    return xdg_dirs.dataSubdir(allocator, xdg_data_home, home, profile_subpath);
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

test "parseArgs --hardware-acceleration and --renderer set the rendering config; no flag leaves it to the default" {
    const cmd = parseArgs(&.{ "zigBrowser", "--hardware-acceleration", "webkit", "https://example.com", "--renderer", "mesa-egl" });
    try std.testing.expect(cmd == .open);
    try std.testing.expectEqual(render_config.HwPolicy.webkit, cmd.open.hw_policy.?);
    try std.testing.expectEqual(render_config.Renderer.mesa_egl, cmd.open.renderer.?);
    const shm = parseArgs(&.{ "zigBrowser", "https://example.com", "--renderer", "shm" });
    try std.testing.expectEqual(render_config.Renderer.shm, shm.open.renderer.?);
    try std.testing.expect(shm.open.hw_policy == null);
    const plain = parseArgs(&.{ "zigBrowser", "https://example.com" });
    try std.testing.expect(plain.open.hw_policy == null);
    try std.testing.expect(plain.open.renderer == null);
}

test "parseArgs rendering flag errors are usage" {
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "https://example.com", "--hardware-acceleration" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "https://example.com", "--hardware-acceleration", "on-demand" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "https://example.com", "--renderer", "gbm" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "https://example.com", "--renderer", "shm", "--renderer", "shm" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "https://example.com", "--hardware-acceleration", "never", "--hardware-acceleration", "always" }) == .usage);
}

test "parseArgs --screenshot takes the same rendering flags after the URL" {
    const plain = parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com" });
    try std.testing.expect(plain.screenshot.hw_policy == null);
    try std.testing.expect(plain.screenshot.renderer == null);
    const cmd = parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com", "--renderer", "default", "--print-title", "--hardware-acceleration", "never" });
    try std.testing.expect(cmd == .screenshot);
    try std.testing.expectEqual(render_config.HwPolicy.never, cmd.screenshot.hw_policy.?);
    try std.testing.expectEqual(render_config.Renderer.default, cmd.screenshot.renderer.?);
    try std.testing.expect(cmd.screenshot.print_title);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com", "--renderer" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com", "--renderer", "gbm" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com", "--renderer", "shm", "--renderer", "shm" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com", "--print-title", "--print-title" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com", "https://two.example" }) == .usage);
}

test "parseArgs --media-source on|off, for an open window and a screenshot; no flag leaves it to the variable and the default" {
    const off = parseArgs(&.{ "zigBrowser", "https://example.com", "--media-source", "off" });
    try std.testing.expectEqual(media_config.MediaSource.off, off.open.media_source.?);
    const on = parseArgs(&.{ "zigBrowser", "--media-source", "on", "https://example.com", "--automation-api" });
    try std.testing.expectEqual(media_config.MediaSource.on, on.open.media_source.?);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "https://example.com" }).open.media_source == null);
    const shot = parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com", "--media-source", "off", "--print-title" });
    try std.testing.expectEqual(media_config.MediaSource.off, shot.screenshot.media_source.?);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com" }).screenshot.media_source == null);
}

test "parseArgs --media-source errors are usage" {
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "https://example.com", "--media-source" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "https://example.com", "--media-source", "0" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "https://example.com", "--media-source", "OFF" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "https://example.com", "--media-source", "off", "--media-source", "off" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com", "--media-source" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com", "--media-source", "no" }) == .usage);
}

test "parseArgs --agent-drawer on|off for an open window; no flag leaves it to the variable and the default" {
    const on = parseArgs(&.{ "zigBrowser", "https://example.com", "--agent-drawer", "on" });
    try std.testing.expectEqual(agent_config.AgentDrawer.on, on.open.agent_drawer.?);
    const off = parseArgs(&.{ "zigBrowser", "--agent-drawer", "off", "https://example.com", "--automation-api" });
    try std.testing.expectEqual(agent_config.AgentDrawer.off, off.open.agent_drawer.?);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "https://example.com" }).open.agent_drawer == null);
}

test "parseArgs --agent-drawer errors are usage, and a screenshot rejects the flag" {
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "https://example.com", "--agent-drawer" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "https://example.com", "--agent-drawer", "1" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "https://example.com", "--agent-drawer", "ON" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "https://example.com", "--agent-drawer", "on", "--agent-drawer", "on" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com", "--agent-drawer", "on" }) == .usage);
    try std.testing.expect(parseArgs(&.{ "zigBrowser", "--screenshot", "out.png", "https://example.com", "--agent-drawer", "off" }) == .usage);
}

test "parseArgs --agent-setup with a SAI source, a token route and the e2e protocol" {
    const plain = parseArgs(&.{ "zigBrowser", "--agent-setup" });
    try std.testing.expect(plain.agent_setup.sai_source == null);
    try std.testing.expectEqual(TokenRoute.r1, plain.agent_setup.token_route);
    try std.testing.expect(!plain.agent_setup.e2e_protocol);
    const full = parseArgs(&.{ "zigBrowser", "--agent-setup", "--sai-source", "/src/sai", "--agent-token-route", "env", "--e2e-protocol" });
    try std.testing.expectEqualStrings("/src/sai", full.agent_setup.sai_source.?);
    try std.testing.expectEqual(TokenRoute.env, full.agent_setup.token_route);
    try std.testing.expect(full.agent_setup.e2e_protocol);
    const r1 = parseArgs(&.{ "zigBrowser", "--agent-setup", "--agent-token-route", "r1" });
    try std.testing.expectEqual(TokenRoute.r1, r1.agent_setup.token_route);
}

test "parseArgs --agent-setup errors are usage" {
    for ([_][]const []const u8{
        &.{ "zigBrowser", "--agent-setup", "--sai-source" },
        &.{ "zigBrowser", "--agent-setup", "--sai-source", "" },
        &.{ "zigBrowser", "--agent-setup", "--sai-source", "-x" },
        &.{ "zigBrowser", "--agent-setup", "--sai-source", "a", "--sai-source", "b" },
        &.{ "zigBrowser", "--agent-setup", "--agent-token-route", "r3" },
        &.{ "zigBrowser", "--agent-setup", "--agent-token-route", "env", "--agent-token-route", "env" },
        &.{ "zigBrowser", "--agent-setup", "https://example.com" },
        &.{ "zigBrowser", "--agent-setup", "--print-title" },
        &.{ "zigBrowser", "https://example.com", "--agent-setup" },
    }) |args| {
        try std.testing.expect(parseArgs(args) == .usage);
    }
}
