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
/// e2e-only (app-owned): the setup child sleeps this long before it sets
/// PR_SET_PDEATHSIG, so the parent-death race is reproducible (RoseCat 5330).
pub const spawn_delay_env = "ZIGBROWSER_AGENT_SPAWN_DELAY_MS";
/// e2e-only (app-owned): the setup helper stops at this cut of its publish
/// (plan rev 15.5: `swap:before` or `swap:after`), so a test can kill the
/// browser there. Passed on only as `--e2e-pause-at <cut>`.
pub const setup_pause_env = "ZIGBROWSER_AGENT_SETUP_PAUSE";
const pause_cuts = [_][]const u8{ "swap:before", "swap:after" };
/// The helper runtime lives beside the binary: <prefix>/lib/zigbrowser/
/// agent-host/{venv, zb_agent_host, runtime.json}, installed by
/// tools/install_agent_runtime.sh (`zig build agent-runtime`). For
/// /usr/bin/zigBrowser that is /usr/lib/zigbrowser/agent-host.
/// ZB_AGENT_HOST_PYTHON / ZB_AGENT_HOST_DIR override it (developer checkouts).
pub const runtime_subpath = "lib/zigbrowser/agent-host";

pub const Runtime = struct { python: []u8, package_dir: []u8 };

/// The runtime for the binary at `exe_path` (its real path), Linux's rule.
pub fn defaultRuntime(gpa: std.mem.Allocator, exe_path: []const u8) !Runtime {
    return runtimeFor(gpa, .linux, exe_path);
}

/// macOS plan rev 14 item 3 / rev 16 item 1: on macOS the runtime is nested code, signed where code is
/// signed (JadeBeacon 6756), so it is always `<exe dir>/../Frameworks/agent-host`, never under Resources:
/// `<X>.app/Contents/MacOS` -> `Contents/Frameworks`, and a dev or staging tree `zig-out/bin` ->
/// `zig-out/Frameworks`, like the shim and the tree the census scans. Linux keeps
/// `<prefix>/lib/zigbrowser/agent-host` and its venv.
pub fn runtimeFor(gpa: std.mem.Allocator, os: std.Target.Os.Tag, exe_path: []const u8) !Runtime {
    const bin = std.fs.path.dirname(exe_path) orelse "/";
    const prefix = std.fs.path.dirname(bin) orelse "/";
    if (os == .macos) {
        const package_dir = try std.fs.path.join(gpa, &.{ prefix, mac_runtime_subpath });
        return .{ .python = try std.fs.path.join(gpa, &.{ package_dir, mac_python_subpath }), .package_dir = package_dir };
    }
    const package_dir = try std.fs.path.join(gpa, &.{ prefix, runtime_subpath });
    return .{ .python = try std.fs.path.join(gpa, &.{ package_dir, "venv/bin/python" }), .package_dir = package_dir };
}

/// Relative to `<exe dir>/..` on macOS (an app's Contents, or a dev tree's prefix).
pub const mac_runtime_subpath = "Frameworks/agent-host";
/// The python.org CPython 3.12 universal2 framework's fat launcher, inside agent-host (the user's decision,
/// 6ea1064). No venv on macOS: a venv records an absolute home, and the app moves.
pub const mac_python_subpath = "Python.framework/Versions/3.12/bin/python3.12";

/// Whether `--agent-setup` may run on this OS (macOS plan rev 14 item 6): Linux runs; macOS refuses
/// until MS6's Seatbelt backend is accepted, so setup never runs unsandboxed; anything else keeps
/// the Linux-only refusal.
pub const Gate = union(enum) { run, refuse: []const u8 };
pub const macos_unsandboxed_refusal = "zigBrowser: agent-setup: the macOS sandbox is not ready; setup will not run unsandboxed";
pub const linux_only_refusal = "zigBrowser: agent-setup: the Claude Agent is Linux-only";
/// The MS6 acceptance fact (4pa.66, D2). Readiness is derived from it, so it cannot be flipped on its own.
pub const seatbelt_gate = @import("seatbelt_gate.zig");
/// True only once MS6's acceptance commit names its gate run in seatbelt_gate.zig.
pub const seatbelt_ready = seatbelt_gate.accepted_commit != null;

pub fn platformGate(os: std.Target.Os.Tag, sandbox_ready: bool) Gate {
    return switch (os) {
        .linux => .run,
        .macos => if (sandbox_ready) .run else .{ .refuse = macos_unsandboxed_refusal },
        else => .{ .refuse = linux_only_refusal },
    };
}

/// The owner development build may run the macOS drawer before Seatbelt lands.
/// A release-style build (`mac_unsandboxed_dev == false`) retains the ordinary
/// drawer platform gate unchanged.
pub fn platformGateForBuild(os: std.Target.Os.Tag, sandbox_ready: bool, mac_unsandboxed_dev: bool) Gate {
    if (os == .macos and mac_unsandboxed_dev) return .run;
    return platformGate(os, sandbox_ready);
}

/// Setup's macOS helper is trusted provisioning code, while every untrusted
/// CLI execution it starts is constrained by setup.py's Seatbelt profile.
/// Drawer admission remains on platformGateForBuild until MS6 is accepted.
pub fn setupPlatformGate(os: std.Target.Os.Tag) Gate {
    return switch (os) {
        .linux, .macos => .run,
        else => .{ .refuse = linux_only_refusal },
    };
}

test "macOS setup reaches its Seatbelt-enforced helper before drawer acceptance" {
    try std.testing.expect(setupPlatformGate(.linux) == .run);
    try std.testing.expect(setupPlatformGate(.macos) == .run);
    try std.testing.expectEqualStrings(linux_only_refusal, setupPlatformGate(.windows).refuse);
}

test "the runtime sits at <prefix>/lib/zigbrowser/agent-host beside <prefix>/bin/zigBrowser" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rt = try defaultRuntime(arena.allocator(), "/usr/bin/zigBrowser");
    try std.testing.expectEqualStrings("/usr/lib/zigbrowser/agent-host/venv/bin/python", rt.python);
    try std.testing.expectEqualStrings("/usr/lib/zigbrowser/agent-host", rt.package_dir);
    const local = try defaultRuntime(arena.allocator(), "/opt/zb/bin/zigBrowser");
    try std.testing.expectEqualStrings("/opt/zb/lib/zigbrowser/agent-host/venv/bin/python", local.python);
}

pub const Inputs = struct {
    home: []const u8,
    python: []const u8,
    package_dir: []const u8,
    sai_source: []const u8,
    /// The browser's HOME and PATH: the source prefix to rewrite, and where
    /// a hook's bare command is looked up.
    source_home: []const u8,
    source_path: []const u8,
    e2e_protocol: bool,
    /// ZIGBROWSER_AGENT_CLAUDE_CLI's value (null: unset).
    claude_cli: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    lc_all: ?[]const u8 = null,
    /// ZIGBROWSER_AGENT_SPAWN_DELAY_MS's value (null: unset).
    spawn_delay: ?[]const u8 = null,
    /// ZIGBROWSER_AGENT_SETUP_PAUSE's value (null: unset).
    setup_pause: ?[]const u8 = null,
    /// macOS plan rev 14 item 5: the browser's own pid, passed as `--browser-pid` so setup.py's Darwin
    /// parent watch arms on it (a getppid() captured inside setup could already be launchd's). Null on Linux,
    /// where PR_SET_PDEATHSIG does the job and the argv stays as it was.
    browser_pid: ?u32 = null,
};

pub const Launch = struct {
    argv: []const []const u8,
    env: []const []const u8,
    /// One line for stderr when a seam was refused.
    warning: ?[]const u8 = null,
    /// The e2e-only spawn delay in ms (0: none).
    spawn_delay_ms: u32 = 0,
};

pub const Error = error{ RelativeCliPath, BadSourceHome, OutOfMemory };

pub fn launch(gpa: std.mem.Allocator, in: Inputs) Error!Launch {
    // An empty or relative HOME would make every absolute path look like it
    // lives under it (RoseCat 5328).
    if (!std.fs.path.isAbsolute(in.source_home) or std.mem.trimEnd(u8, in.source_home, "/").len == 0)
        return error.BadSourceHome;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{
        in.python,        "-m",           "zb_agent_host", "setup",
        "--home",         in.home,        "--sai-source",  in.sai_source,
        "--source-home",  in.source_home, "--source-path", in.source_path,
        "--python",       in.python,
    });
    if (in.browser_pid) |pid| try argv.appendSlice(gpa, &.{ "--browser-pid", try std.fmt.allocPrint(gpa, "{d}", .{pid}) });
    var warning: ?[]const u8 = null;
    var spawn_delay_ms: u32 = 0;
    if (in.spawn_delay) |text| {
        if (!in.e2e_protocol) {
            warning = "zigBrowser: " ++ spawn_delay_env ++ " ignored without --e2e-protocol";
        } else if (std.fmt.parseInt(u32, text, 10)) |ms| {
            if (ms >= 1 and ms <= 5000) spawn_delay_ms = ms;
        } else |_| {}
    }
    if (in.setup_pause) |cut| {
        if (!in.e2e_protocol) {
            warning = "zigBrowser: " ++ setup_pause_env ++ " ignored without --e2e-protocol";
        } else for (pause_cuts) |known| {
            if (std.mem.eql(u8, cut, known)) try argv.appendSlice(gpa, &.{ "--e2e-pause-at", known });
        }
    }
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
    return .{ .argv = try argv.toOwnedSlice(gpa), .env = try env.toOwnedSlice(gpa), .warning = warning, .spawn_delay_ms = spawn_delay_ms };
}

test "the setup run gets exactly the allowlisted environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run = try launch(arena.allocator(), .{
        .home = "/d/zigbrowser/agent-home", .python = "/v/bin/python", .package_dir = "/pkg",
        .sai_source = "/u/.claude", .source_home = "/u", .source_path = "/u/bin:/usr/bin",
        .e2e_protocol = false, .lang = "C.UTF-8",
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
        "--python",        "/v/bin/python",
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
        .source_path = "/usr/bin", .e2e_protocol = true, .claude_cli = "/fake/claude",
    };
    const on = try launch(arena.allocator(), in);
    try std.testing.expectEqualStrings("--e2e-claude-cli", on.argv[on.argv.len - 2]);
    try std.testing.expectEqualStrings("/fake/claude", on.argv[on.argv.len - 1]);
    for (on.argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--route")); // R3 is gone (§3c.1)
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
            .source_path = "/a:/b", .e2e_protocol = random.boolean(),
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

test "the source HOME must be an absolute directory other than /" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "", "relative", "/" }) |home| {
        try std.testing.expectError(error.BadSourceHome, launch(arena.allocator(), .{
            .home = "/h", .python = "/p", .package_dir = "/k", .sai_source = "/s", .source_home = home,
            .source_path = "/usr/bin", .e2e_protocol = false,
        }));
    }
}

test "the spawn-delay seam counts only with --e2e-protocol and within 1..5000 ms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var in: Inputs = .{ .home = "/h", .python = "/p", .package_dir = "/k", .sai_source = "/s", .source_home = "/u",
        .source_path = "/usr/bin", .e2e_protocol = true, .spawn_delay = "500" };
    try std.testing.expectEqual(@as(u32, 500), (try launch(arena.allocator(), in)).spawn_delay_ms);
    in.spawn_delay = "0";
    try std.testing.expectEqual(@as(u32, 0), (try launch(arena.allocator(), in)).spawn_delay_ms);
    in.spawn_delay = "9999";
    try std.testing.expectEqual(@as(u32, 0), (try launch(arena.allocator(), in)).spawn_delay_ms);
    in.spawn_delay = "500";
    in.e2e_protocol = false;
    const off = try launch(arena.allocator(), in);
    try std.testing.expectEqual(@as(u32, 0), off.spawn_delay_ms);
    try std.testing.expectEqualStrings("zigBrowser: ZIGBROWSER_AGENT_SPAWN_DELAY_MS ignored without --e2e-protocol", off.warning.?);
}

test "the setup pause seam reaches the helper only with --e2e-protocol and only as a known cut" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var in: Inputs = .{ .home = "/h", .python = "/p", .package_dir = "/k", .sai_source = "/s", .source_home = "/u",
        .source_path = "/usr/bin", .e2e_protocol = true, .setup_pause = "swap:after" };
    const on = try launch(arena.allocator(), in);
    try std.testing.expectEqualStrings("--e2e-pause-at", on.argv[on.argv.len - 2]);
    try std.testing.expectEqualStrings("swap:after", on.argv[on.argv.len - 1]);
    in.setup_pause = "swap:sideways";
    const bad = try launch(arena.allocator(), in);
    for (bad.argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--e2e-pause-at"));
    in.setup_pause = "swap:before";
    in.e2e_protocol = false;
    const off = try launch(arena.allocator(), in);
    for (off.argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--e2e-pause-at"));
    for (off.env) |kv| try std.testing.expect(std.mem.indexOf(u8, kv, "PAUSE") == null);
    try std.testing.expectEqualStrings("zigBrowser: ZIGBROWSER_AGENT_SETUP_PAUSE ignored without --e2e-protocol", off.warning.?);
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
