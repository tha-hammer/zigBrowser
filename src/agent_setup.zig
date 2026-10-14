//! `zigBrowser --agent-setup` (chat-drawer plan S3.1, S3.7): where the agent
//! home is, and the exact argv and environment of the synchronous setup
//! helper run. Pure: app.zig gathers the inputs and spawns
//! (src/agent_host.c).
//!
//! The helper gets an explicit environment, never the browser's. The
//! e2e-only seam ZIGBROWSER_AGENT_CLAUDE_CLI is app-owned (plan section 7,
//! rev 14): honoured only with --e2e-protocol, and then passed only as the
//! launch option `--e2e-claude-cli <path>`, never in an environment.

const std = @import("std");
const xdg = @import("xdg.zig");

pub const home_subpath = "zigbrowser/agent-home";
pub const claude_cli_env = "ZIGBROWSER_AGENT_CLAUDE_CLI";
/// Where the helper's runtime is installed unless ZB_AGENT_HOST_PYTHON /
/// ZB_AGENT_HOST_DIR say otherwise (development checkouts, the gate).
pub const default_python = "/usr/lib/zigbrowser/agent-host/bin/python";
pub const default_package_dir = "/usr/lib/zigbrowser/agent-host";

pub const Route = enum { r1, env };

pub const Inputs = struct {
    home: []const u8,
    python: []const u8,
    package_dir: []const u8,
    sai_source: []const u8,
    /// The browser's HOME and PATH: the source prefix to rewrite, and where
    /// a hook's bare command is looked up.
    source_home: []const u8,
    source_path: []const u8,
    route: Route,
    e2e_protocol: bool,
    /// ZIGBROWSER_AGENT_CLAUDE_CLI's value (null: unset).
    claude_cli: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    lc_all: ?[]const u8 = null,
};

pub const Launch = struct {
    argv: []const []const u8,
    env: []const []const u8,
    /// One line for stderr when a seam was refused.
    warning: ?[]const u8 = null,
};

pub const Error = error{ RelativeCliPath, OutOfMemory };

pub fn launch(gpa: std.mem.Allocator, in: Inputs) Error!Launch {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{
        in.python,        "-m",           "zb_agent_host", "setup",
        "--home",         in.home,        "--sai-source",  in.sai_source,
        "--source-home",  in.source_home, "--source-path", in.source_path,
        "--python",       in.python,      "--route",       @tagName(in.route),
    });
    var warning: ?[]const u8 = null;
    if (in.claude_cli) |cli| {
        if (!in.e2e_protocol) {
            warning = "zigBrowser: " ++ claude_cli_env ++ " ignored without --e2e-protocol";
        } else {
            if (!std.fs.path.isAbsolute(cli)) return error.RelativeCliPath;
            try argv.appendSlice(gpa, &.{ "--e2e-claude-cli", cli });
        }
    }

    var env: std.ArrayList([]const u8) = .empty;
    try env.appendSlice(gpa, &.{
        "PATH=/usr/bin:/bin",
        try std.fmt.allocPrint(gpa, "HOME={s}", .{in.home}),
        try std.fmt.allocPrint(gpa, "CLAUDE_CONFIG_DIR={s}/.claude", .{in.home}),
        try std.fmt.allocPrint(gpa, "TMPDIR={s}/scratchpad/tmp", .{in.home}),
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1",
        try std.fmt.allocPrint(gpa, "PYTHONPATH={s}", .{in.package_dir}),
        "PYTHONDONTWRITEBYTECODE=1",
    });
    if (in.lang) |v| try env.append(gpa, try std.fmt.allocPrint(gpa, "LANG={s}", .{v}));
    if (in.lc_all) |v| try env.append(gpa, try std.fmt.allocPrint(gpa, "LC_ALL={s}", .{v}));
    return .{ .argv = try argv.toOwnedSlice(gpa), .env = try env.toOwnedSlice(gpa), .warning = warning };
}

test "the setup run gets exactly the allowlisted environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run = try launch(arena.allocator(), .{
        .home = "/d/zigbrowser/agent-home", .python = "/v/bin/python", .package_dir = "/pkg",
        .sai_source = "/u/.claude", .source_home = "/u", .source_path = "/u/bin:/usr/bin",
        .route = .r1, .e2e_protocol = false, .lang = "C.UTF-8",
    });
    const want = [_][]const u8{
        "PATH=/usr/bin:/bin",
        "HOME=/d/zigbrowser/agent-home",
        "CLAUDE_CONFIG_DIR=/d/zigbrowser/agent-home/.claude",
        "TMPDIR=/d/zigbrowser/agent-home/scratchpad/tmp",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1",
        "PYTHONPATH=/pkg",
        "PYTHONDONTWRITEBYTECODE=1",
        "LANG=C.UTF-8",
    };
    try std.testing.expectEqual(want.len, run.env.len);
    for (want, run.env) |w, got| try std.testing.expectEqualStrings(w, got);
    const argv = [_][]const u8{
        "/v/bin/python",   "-m",               "zb_agent_host", "setup",
        "--home",          "/d/zigbrowser/agent-home",            "--sai-source", "/u/.claude",
        "--source-home",   "/u",               "--source-path", "/u/bin:/usr/bin",
        "--python",        "/v/bin/python",    "--route",       "r1",
    };
    try std.testing.expectEqual(argv.len, run.argv.len);
    for (argv, run.argv) |w, got| try std.testing.expectEqualStrings(w, got);
    try std.testing.expect(run.warning == null);
}

test "the CLI seam is a launch option only with --e2e-protocol, and refused otherwise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var in: Inputs = .{
        .home = "/h", .python = "/p", .package_dir = "/k", .sai_source = "/s", .source_home = "/u",
        .source_path = "/usr/bin", .route = .env, .e2e_protocol = true, .claude_cli = "/fake/claude",
    };
    const on = try launch(arena.allocator(), in);
    try std.testing.expectEqualStrings("--e2e-claude-cli", on.argv[on.argv.len - 2]);
    try std.testing.expectEqualStrings("/fake/claude", on.argv[on.argv.len - 1]);
    try std.testing.expectEqualStrings("env", on.argv[on.argv.len - 3]);
    for (on.env) |entry| try std.testing.expect(std.mem.indexOf(u8, entry, "/fake/claude") == null);

    in.e2e_protocol = false;
    const off = try launch(arena.allocator(), in);
    for (off.argv) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "--e2e-claude-cli"));
        try std.testing.expect(!std.mem.eql(u8, arg, "/fake/claude"));
    }
    try std.testing.expectEqualStrings("zigBrowser: ZIGBROWSER_AGENT_CLAUDE_CLI ignored without --e2e-protocol", off.warning.?);

    in.e2e_protocol = true;
    in.claude_cli = "relative/claude";
    try std.testing.expectError(error.RelativeCliPath, launch(arena.allocator(), in));
}

test "property: no input reaches the environment except the fixed names and the given LANG/LC_ALL" {
    var prng = std.Random.DefaultPrng.init(0x5E7_0003);
    const random = prng.random();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const names = [_][]const u8{ "PATH=", "HOME=", "CLAUDE_CONFIG_DIR=", "TMPDIR=", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=", "PYTHONPATH=", "PYTHONDONTWRITEBYTECODE=", "LANG=", "LC_ALL=" };
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const run = try launch(arena.allocator(), .{
            .home = "/h", .python = "/p", .package_dir = "/k", .sai_source = "/s", .source_home = "/u",
            .source_path = "/a:/b", .route = if (random.boolean()) .r1 else .env, .e2e_protocol = random.boolean(),
            .claude_cli = if (random.boolean()) "/c" else null,
            .lang = if (random.boolean()) "en_US.UTF-8" else null, .lc_all = if (random.boolean()) "C" else null,
        });
        for (run.env) |entry| {
            var known = false;
            for (names) |n| known = known or std.mem.startsWith(u8, entry, n);
            try std.testing.expect(known);
        }
    }
}

test "the agent home sits beside the profile: XDG_DATA_HOME, then HOME/.local/share" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/x/zigbrowser/agent-home", (try defaultHomeDir(a, "/x", "/u")).?);
    try std.testing.expectEqualStrings("/u/.local/share/zigbrowser/agent-home", (try defaultHomeDir(a, "rel", "/u")).?);
    try std.testing.expect((try defaultHomeDir(a, null, null)) == null);
}

/// $XDG_DATA_HOME/zigbrowser/agent-home, else $HOME/.local/share/...: beside
/// the profile, not inside it (plan D6).
pub fn defaultHomeDir(gpa: std.mem.Allocator, xdg_data_home: ?[]const u8, home: ?[]const u8) !?[]u8 {
    return xdg.dataSubdir(gpa, xdg_data_home, home, home_subpath);
}
