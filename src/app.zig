const std = @import("std");
const builtin = @import("builtin");

const agent_drawer = @import("agent_drawer.zig");
const agent_setup = @import("agent_setup.zig");
const agent_config = @import("agent_config.zig");
const agent_net = @import("agent_net.zig");
const agent_helper = @import("agent_helper.zig");
const agent_frames = @import("agent_frames.zig");
const agent_tools = @import("agent_tools.zig");
const agent_login = @import("agent_login.zig");
const automation_gtk_cookie_port = @import("automation_gtk_cookie_port.zig");
const automation_gtk_port = @import("automation_gtk_port.zig");
const automation_macos_cookie_port = @import("automation_macos_cookie_port.zig");
const automation_macos_port = @import("automation_macos_port.zig");
const automation_server = @import("automation_server.zig");
const automation_transport = @import("automation_transport.zig");
const cli = @import("cli.zig");
const render_config = @import("render_config.zig");
const owner_only = @import("owner_only.zig");
const backend_flag = @import("backend_flag.zig");
const errors = @import("errors.zig");
const uri = @import("uri.zig");
const webkit = @import("webkit.zig");

const c = @cImport({
    @cInclude("webkit_shim.h");
    @cInclude("agent_host.h");
    @cInclude("agent_helper.h");
    @cInclude("agent_login.h");
});

const OpenSpec = @TypeOf(@as(cli.Command, .{ .open = undefined }).open);
const ScreenshotSpec = @TypeOf(@as(cli.Command, .{ .screenshot = undefined }).screenshot);
const AgentSetupSpec = @TypeOf(@as(cli.Command, .{ .agent_setup = undefined }).agent_setup);

pub fn run(arena: std.mem.Allocator, command: cli.Command) errors.BrowserError!u8 {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    return runWithIo(arena, threaded.io(), command);
}

pub fn runWithIo(arena: std.mem.Allocator, io: std.Io, command: cli.Command) errors.BrowserError!u8 {
    return switch (command) {
        .version => 0,
        .usage, .agent_route_removed => error.Usage,
        .open => |spec| runOpen(arena, io, spec),
        .screenshot => |spec| runScreenshot(arena, spec),
        .agent_setup => |spec| runAgentSetup(arena, spec),
    };
}

/// `zigBrowser --agent-setup` (chat-drawer S3.1, S3.7): takes the agent
/// home's owner lock, then runs the helper's `setup` command synchronously
/// with an explicit environment (agent_setup.zig) and returns its status.
fn runAgentSetup(arena: std.mem.Allocator, spec: AgentSetupSpec) errors.BrowserError!u8 {
    if (comptime builtin.os.tag != .linux) {
        std.debug.print("zigBrowser: agent-setup: the Claude Agent is Linux-only\n", .{});
        return 1;
    }
    const user_home = getenvOwned(arena, "HOME");
    const home = (agent_setup.defaultHomeDir(arena, getenvOwned(arena, "XDG_DATA_HOME"), user_home) catch null) orelse {
        std.debug.print("zigBrowser: agent-setup: neither XDG_DATA_HOME nor HOME is usable\n", .{});
        return 1;
    };
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = std.c.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
    if (exe_len <= 0) return error.WriteFailed;
    const runtime = agent_setup.defaultRuntime(arena, exe_buf[0..@intCast(exe_len)]) catch return error.WriteFailed;
    const python = getenvOwned(arena, "ZB_AGENT_HOST_PYTHON") orelse runtime.python;
    const python_z = arena.dupeZ(u8, python) catch return error.WriteFailed;
    if (std.c.access(python_z.ptr, std.c.X_OK) != 0) {
        std.debug.print("zigBrowser: agent-setup: agent runtime missing at {s}\n", .{python});
        return 1;
    }
    const source = spec.sai_source orelse
        (std.fs.path.join(arena, &.{ user_home orelse "", ".claude" }) catch return error.WriteFailed);
    const setup_run = agent_setup.launch(arena, .{
        .home = home,
        .python = python,
        .package_dir = getenvOwned(arena, "ZB_AGENT_HOST_DIR") orelse runtime.package_dir,
        .sai_source = source,
        .source_home = user_home orelse "",
        .source_path = getenvOwned(arena, "PATH") orelse "/usr/bin:/bin",
        .e2e_protocol = spec.e2e_protocol,
        .claude_cli = getenvOwned(arena, agent_setup.claude_cli_env),
        .lang = getenvOwned(arena, "LANG"),
        .lc_all = getenvOwned(arena, "LC_ALL"),
        .spawn_delay = getenvOwned(arena, agent_setup.spawn_delay_env),
        .setup_pause = getenvOwned(arena, agent_setup.setup_pause_env),
    }) catch |err| switch (err) {
        error.RelativeCliPath => {
            std.debug.print("zigBrowser: {s} must be an absolute path\n", .{agent_setup.claude_cli_env});
            return 2;
        },
        error.BadSourceHome => {
            std.debug.print("zigBrowser: agent-setup: HOME must be an absolute directory\n", .{});
            return 2;
        },
        error.OutOfMemory => return error.WriteFailed,
    };
    if (setup_run.warning) |line| std.debug.print("{s}\n", .{line});

    const home_z = arena.dupeZ(u8, home) catch return error.WriteFailed;
    switch (c.zb_agent_home_lock(home_z.ptr)) {
        0 => {},
        -2 => {
            std.debug.print("zigBrowser: agent-setup: another zigBrowser is using the agent home\n", .{});
            return 1;
        },
        else => {
            std.debug.print("zigBrowser: agent-setup: cannot lock {s}\n", .{home});
            return 1;
        },
    }
    const argv = toCStrings(arena, setup_run.argv) catch return error.WriteFailed;
    const envp = toCStrings(arena, setup_run.env) catch return error.WriteFailed;
    const status = c.zb_agent_run_sync(argv.ptr, envp.ptr, c.zb_spawn_policy_linux(setup_run.spawn_delay_ms));
    return if (status < 0) 1 else @intCast(@min(status, 255));
}

/// Chat drawer S3n2 (plan rev 16.2 §3c.2): when the agent home has a published
/// build (`current`), hands netd's argv, built environment and socket directory
/// to agent_host.c, which starts netd on the drawer's first Send. No
/// XDG_RUNTIME_DIR, or a bad e2e seam (read only with --e2e-protocol),
/// configures a refusal line instead. Without a provisioned home nothing is
/// configured, and Send says the runtime is not set up (S5.5). Returns what
/// the helper's launch needs (S3b), or null without a provisioned home.
fn configureAgentNet(arena: std.mem.Allocator, io: std.Io, e2e: bool) !?AgentNet {
    if (comptime builtin.os.tag != .linux) return null;
    const home = (agent_setup.defaultHomeDir(arena, getenvOwned(arena, "XDG_DATA_HOME"), getenvOwned(arena, "HOME")) catch null) orelse return null;
    const current = try std.fs.path.joinZ(arena, &.{ home, "current" });
    if (std.c.access(current.ptr, 0) != 0) return null; // F_OK: not set up
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = std.c.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
    if (exe_len <= 0) return error.NoExecutablePath;
    const runtime = try agent_setup.defaultRuntime(arena, exe_buf[0..@intCast(exe_len)]);
    const python = getenvOwned(arena, "ZB_AGENT_HOST_PYTHON") orelse runtime.python;
    const package_dir = getenvOwned(arena, "ZB_AGENT_HOST_DIR") orelse runtime.package_dir;

    var refusal: ?[]const u8 = null;
    var random: [8]u8 = undefined;
    try io.randomSecure(&random);
    const pid: u32 = @intCast(std.os.linux.getpid());
    const sockdir = agent_net.sockdirPath(arena, getenvOwned(arena, "XDG_RUNTIME_DIR"), pid, random) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => blk: {
            refusal = "zigBrowser: agent: network unavailable (XDG_RUNTIME_DIR)";
            break :blk "";
        },
    };
    var seam: ?agent_net.NetTest = null;
    var test_ca: ?[]const u8 = null;
    if (e2e) {
        if (getenvOwned(arena, agent_net.net_test_env)) |value| {
            seam = agent_net.parseNetTest(value) catch blk: {
                refusal = refusal orelse "zigBrowser: agent: bad " ++ agent_net.net_test_env;
                break :blk null;
            };
        }
        if (getenvOwned(arena, agent_net.net_test_ca_env)) |path| {
            if (agent_net.checkTestCa(path)) |_| {
                test_ca = path;
            } else |_| {
                refusal = refusal orelse "zigBrowser: agent: bad " ++ agent_net.net_test_ca_env;
            }
        }
    }
    const argv = try toCStrings(arena, try agent_net.netdArgv(arena, python, package_dir, sockdir, "/usr/bin/bwrap", try agent_net.netManifestPath(arena, home), seam));
    const envp = try toCStrings(arena, try agent_net.netdEnv(arena, getenvOwned(arena, "LANG"), getenvOwned(arena, "LC_ALL")));
    const refusal_z: ?[*:0]const u8 = if (refusal) |line| (try arena.dupeZ(u8, line)).ptr else null;
    c.zb_agent_net_configure(argv.ptr, envp.ptr, (try arena.dupeZ(u8, sockdir)).ptr, refusal_z, @intFromBool(e2e));
    return .{ .home = home, .python = python, .package_dir = package_dir, .sockdir = sockdir, .test_ca = test_ca };
}

/// What configureAgentNet resolved, for the helper's launch (S3b).
const AgentNet = struct {
    home: []const u8,
    python: []const u8,
    package_dir: []const u8,
    sockdir: []const u8,
    test_ca: ?[]const u8,
};

/// Chat drawer S3b (plan D7, S3.2, S3.6; rev 16 §3c): with a provisioned agent
/// home, hands the helper's launch argv, built environment and hello to
/// agent_helper.c, which starts it on the first Send once netd is ready. A
/// missing runtime or a changed one makes the agent unavailable up front; the
/// e2e seams are read only with --e2e-protocol (agent_helper.zig).
fn configureAgentHelper(arena: std.mem.Allocator, io: std.Io, e2e: bool, net: AgentNet) !void {
    if (comptime builtin.os.tag != .linux) return;
    const runtime_dir = try std.fs.path.join(arena, &.{ net.home, "runtime" });
    var path_dirs: []const []const u8 = &.{};
    if (readSmall(arena, io, try std.fs.path.join(arena, &.{ runtime_dir, "path.json" }))) |text| {
        path_dirs = std.json.parseFromSliceLeaky([]const []const u8, arena, text, .{}) catch &.{};
    }
    const installed = readSmall(arena, io, try std.fs.path.join(arena, &.{ net.package_dir, "runtime.json" }));
    const recorded = readSmall(arena, io, try std.fs.path.join(arena, &.{ runtime_dir, "host.json" }));
    var unavailable: ?[:0]const u8 = null;
    var bubble: ?[:0]const u8 = null;
    const python_z = try arena.dupeZ(u8, net.python);
    if (std.c.access(python_z.ptr, 1) != 0) { // X_OK
        unavailable = "runtime-missing";
        bubble = "Agent runtime not set up: run zigBrowser --agent-setup";
    } else switch (agent_helper.checkRuntime(arena, recorded, installed)) {
        .ok => {},
        .missing => {
            unavailable = "runtime-missing";
            bubble = "Agent runtime not set up: run zigBrowser --agent-setup";
        },
        .changed => {
            unavailable = "config-changed";
            bubble = "Claude Agent runtime changed: run zigBrowser --agent-setup again";
        },
    }
    const launch = try agent_helper.launch(arena, .{
        .python = net.python,
        .home = net.home,
        .net_dir = net.sockdir,
        .path_dirs = path_dirs,
        .lang = getenvOwned(arena, "LANG"),
        .lc_all = getenvOwned(arena, "LC_ALL"),
        .e2e_protocol = e2e,
        .bwrap = getenvOwned(arena, agent_helper.bwrap_env),
        .host_cmd = getenvOwned(arena, agent_helper.host_cmd_env),
        .test_base_url = getenvOwned(arena, agent_helper.test_base_url_env),
        .test_ca = net.test_ca,
    });
    for (launch.warnings) |line| std.debug.print("{s}\n", .{line});
    try agent_frames.setHello(net.home, launch.hello_e2e);
    const argv = try toCStrings(arena, launch.argv);
    const envp = try toCStrings(arena, launch.env);
    const refusal_z: ?[*:0]const u8 = if (launch.refusal) |line| (try arena.dupeZ(u8, line)).ptr else null;
    c.zb_agent_helper_configure(argv.ptr, envp.ptr, (try arena.dupeZ(u8, net.home)).ptr,
        if (unavailable) |s| s.ptr else null, if (bubble) |s| s.ptr else null, refusal_z, @intFromBool(e2e));
}

/// Chat drawer S6b1 (plan rev 16.18.3): the one-shot sign-in. Its own login netd
/// (runtime/net-login.json in `<chat sockdir>-login`, egress only) and the login
/// helper's launch (`launch --command login`); ZIGBROWSER_AGENT_CLAUDE_CLI reaches
/// it only as `--e2e-claude-cli` and only with --e2e-protocol (S6.1).
fn configureAgentLogin(arena: std.mem.Allocator, io: std.Io, e2e: bool, net: AgentNet) !void {
    if (comptime builtin.os.tag != .linux) return;
    if (net.sockdir.len == 0) return; // no runtime dir: no network, so no sign-in either
    var path_dirs: []const []const u8 = &.{};
    if (readSmall(arena, io, try std.fs.path.join(arena, &.{ net.home, "runtime", "path.json" }))) |text| {
        path_dirs = std.json.parseFromSliceLeaky([]const []const u8, arena, text, .{}) catch &.{};
    }
    const login_dir = try agent_login.loginNetDir(arena, net.sockdir);
    const launch = agent_login.launch(arena, .{
        .python = net.python,
        .home = net.home,
        .login_net_dir = login_dir,
        .path_dirs = path_dirs,
        .lang = getenvOwned(arena, "LANG"),
        .lc_all = getenvOwned(arena, "LC_ALL"),
        .e2e_protocol = e2e,
        .claude_cli = getenvOwned(arena, agent_login.claude_cli_env),
        .bwrap = getenvOwned(arena, agent_helper.bwrap_env),
    }) catch |err| switch (err) {
        error.RelativeCliPath => {
            std.debug.print("zigBrowser: agent: {s} must be an absolute path\n", .{agent_login.claude_cli_env});
            return;
        },
        else => return err,
    };
    if (launch.warning) |line| std.debug.print("{s}\n", .{line});
    const manifest = try std.fs.path.join(arena, &.{ net.home, "runtime", "net-login.json" });
    var netd_args: std.ArrayList([]const u8) = .empty;
    try netd_args.appendSlice(arena, try agent_net.netdArgv(arena, net.python, net.package_dir, login_dir, "/usr/bin/bwrap", manifest, null));
    // Rev 16.18.4: under --e2e-protocol only, the login netd's census of CONNECT
    // targets (host:port allowed|refused), which the real-screen check records.
    if (e2e) try netd_args.append(arena, "--census");
    const netd_argv = try toCStrings(arena, netd_args.items);
    const netd_env = try toCStrings(arena, try agent_net.netdEnv(arena, getenvOwned(arena, "LANG"), getenvOwned(arena, "LC_ALL")));
    c.zb_login_configure(netd_argv.ptr, netd_env.ptr, (try arena.dupeZ(u8, login_dir)).ptr,
        (try toCStrings(arena, launch.argv)).ptr, (try toCStrings(arena, launch.env)).ptr);
}

/// A small file's bytes, or null when it cannot be read.
fn readSmall(arena: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch null;
}

// The helper's frame exports (src/agent_frames.zig) are linked where
// agent_helper.c, which calls them, is built.
comptime {
    if (builtin.os.tag == .linux) _ = agent_frames;
    // A drawer's tool calls (src/agent_tools.zig), for agent_helper.c (S7b).
    if (builtin.os.tag == .linux) _ = agent_tools;
    // The sign-in's frame exports (src/agent_login.zig), for agent_login.c.
    if (builtin.os.tag == .linux) _ = agent_login;
}

/// Chat drawer S4a (plan D11, S4.1): with a provisioned agent home, the
/// Secrets window gets the home and the store flag (--agent-secret-store), and
/// the drawer's Send asks the active store after starting netd. Without one
/// nothing is configured. Linux only, like the drawer.
fn configureAgentSecrets(arena: std.mem.Allocator, store: ?agent_config.SecretStore, e2e: bool) !void {
    if (comptime builtin.os.tag != .linux) return;
    const home = (agent_setup.defaultHomeDir(arena, getenvOwned(arena, "XDG_DATA_HOME"), getenvOwned(arena, "HOME")) catch null) orelse return;
    const current = try std.fs.path.joinZ(arena, &.{ home, "current" });
    if (std.c.access(current.ptr, 0) != 0) return; // F_OK: not set up
    // -1: no flag; the window then uses the file when one exists (the explicit
    // file choice persisting), else the Secret Service (RoseCat 5648).
    const chosen: c_int = if (store) |s| @intFromEnum(s) else -1;
    secrets_window.zb_secrets_window_setup(chosen, (try arena.dupeZ(u8, home)).ptr, @intFromBool(e2e));
}

// The token store's C exports (src/agent_secrets.zig) are linked where the
// GTK backend's C files that call them are built.
comptime {
    if (builtin.os.tag == .linux) _ = @import("agent_secrets.zig");
}

/// src/agent_secrets_window.c (GTK only; its header needs GTK, so the one
/// plain-C entry point is declared here).
const secrets_window = struct {
    extern fn zb_secrets_window_setup(store: c_int, agent_home: [*:0]const u8, e2e_protocol: c_int) void;
};

/// A NULL-terminated C string array of `items`.
fn toCStrings(arena: std.mem.Allocator, items: []const []const u8) ![:null]?[*:0]const u8 {
    const out = try arena.allocSentinel(?[*:0]const u8, items.len, null);
    for (items, 0..) |item, i| out[i] = (try arena.dupeZ(u8, item)).ptr;
    return out;
}

fn runOpen(arena: std.mem.Allocator, io: std.Io, spec: OpenSpec) errors.BrowserError!u8 {
    const valid_uri = uri.validate(arena, spec.url) catch |err| {
        return mapUriErr(err);
    };
    // Before the automation server's threads and before WebKit starts its network process.
    webkit.preferHttp1();
    // j76: every present flag decided for this OS, then the resolved configuration applied once,
    // before WebKit, EGL and the web processes start (they read the environment once) and
    // before zb_app_run builds the first window (every window reads it when created).
    var sink: OpenSink = .{};
    backend_flag.startup(&sink, spec.hw_policy, spec.renderer, spec.media_source) catch return error.Usage;
    const profile_dir = try applyProfileDir(arena, spec);
    // At quit, after the main loop (a no-op when netd never started). Linux
    // only: agent_host.c is GTK-only, and the cross builds must not name it.
    defer if (comptime builtin.os.tag == .linux) c.zb_agent_net_stop();
    // Before netd stops (defers run in reverse): the helper's shutdown, 2 s,
    // SIGTERM to its group, 1 s, SIGKILL (D7). A no-op when none started.
    defer if (comptime builtin.os.tag == .linux) c.zb_agent_helper_stop();
    // Before zb_app_run builds the first window; the icon's saved position
    // lives with the profile (agent-drawer.json), read only when it is on.
    // S7b: the drawer's tools need the automation core (Linux, like the drawer).
    const drawer_on = webkit.applyAgentDrawer(spec.agent_drawer) and builtin.os.tag == .linux;
    if (drawer_on) {
        agent_drawer.configure(io, arena, profile_dir, .{
            .demo = getenvOwned(arena, agent_drawer.demo_env_name),
            .anim_ms = getenvOwned(arena, agent_drawer.anim_env_name),
        }, spec.e2e_protocol);
        const net = configureAgentNet(arena, io, spec.e2e_protocol) catch return error.WriteFailed;
        configureAgentSecrets(arena, spec.agent_secret_store, spec.e2e_protocol) catch return error.WriteFailed;
        if (net) |n| configureAgentHelper(arena, io, spec.e2e_protocol, n) catch return error.WriteFailed;
        if (net) |n| configureAgentLogin(arena, io, spec.e2e_protocol, n) catch return error.WriteFailed;
    }

    if (spec.automation_api or drawer_on) {
        // automation.js must be registered before zb_app_run builds the window. macOS uses the
        // WKWebView port (MS2a); every other target uses the GTK port.
        if (builtin.os.tag == .macos) automation_macos_port.installScript() else automation_gtk_port.installScript();
        const config = buildAutomationConfig(arena, io, spec, profile_dir) catch |err| {
            if (err == error.EmptyTokenFile) std.debug.print("--automation-token-file is empty\n", .{});
            return error.WriteFailed;
        };
        var server = automation_server.AutomationApiServer.init(std.heap.smp_allocator, io, config) catch return error.WriteFailed;
        defer server.deinit();
        // S7.1: with the drawer alone the core runs in process, with no socket and no token
        // sidecar; with --automation-api the socket starts as before.
        if (spec.automation_api) server.start() catch return error.WriteFailed else server.startCore() catch return error.WriteFailed;
        defer server.stop();
        // After the GTK loop and before the core stops: the drawers' brokers detached and
        // their Reaper joined (a call still waiting for GTK then gives up, NO_LOOP).
        if (comptime builtin.os.tag == .linux) {
            if (drawer_on) agent_tools.start(&server);
        }
        defer if (comptime builtin.os.tag == .linux) agent_tools.stop();

        const code = c.zb_app_run(valid_uri.ptr, if (spec.print_title) 1 else 0,
            if (spec.e2e_protocol) 1 else 0);
        return @intCast(code);
    }

    const code = c.zb_app_run(valid_uri.ptr, if (spec.print_title) 1 else 0,
        if (spec.e2e_protocol) 1 else 0);
    return @intCast(code);
}

/// Persistent profile for cookies and site data: --profile-dir, else the
/// default under $XDG_DATA_HOME or ~/.local/share. An explicit directory that
/// cannot be created is an error; when the default cannot be resolved or
/// created, the browser runs on WebKit's default context. Returns the
/// profile directory in use, or null when there is none.
fn applyProfileDir(arena: std.mem.Allocator, spec: OpenSpec) errors.BrowserError!?[]const u8 {
    if (comptime builtin.os.tag == .macos) {
        // MS3.1: only an explicit --profile-dir binds a profile store on macOS (the path is the identity
        // seed; the shim maps it to an isolated persistent store on macOS 14+, else the shared default).
        const dir = spec.profile_dir orelse return null;
        const dir_z = arena.dupeZ(u8, dir) catch return error.WriteFailed;
        var err: [*c]u8 = null;
        if (c.zb_app_set_profile_dir(dir_z.ptr, &err) == c.ZB_AUTO_OK) return dir;
        defer c.zb_automation_free(err);
        std.debug.print("profile: {s}\n", .{if (err != null) std.mem.span(err) else dir});
        return error.WriteFailed;
    }
    if (comptime builtin.os.tag != .linux) return null;
    const explicit = spec.profile_dir != null;
    const dir = spec.profile_dir orelse
        (cli.defaultProfileDir(arena, getenvOwned(arena, "XDG_DATA_HOME"), getenvOwned(arena, "HOME")) catch null) orelse {
        // No profile resolved: make sure no earlier run's profile lingers.
        _ = c.zb_app_set_profile_dir(null, null);
        return null;
    };
    const dir_z = arena.dupeZ(u8, dir) catch return error.WriteFailed;

    var err: [*c]u8 = null;
    if (c.zb_app_set_profile_dir(dir_z.ptr, &err) == c.ZB_AUTO_OK) return dir;
    defer c.zb_automation_free(err);
    // On failure the shim already cleared any previous profile.
    std.debug.print("profile: {s}\n", .{if (err != null) std.mem.span(err) else dir});
    if (explicit) return error.WriteFailed;
    return null;
}

/// N21: the pacing state lives with the profile it belongs to
/// ("<profile>/automation-pacing.json"); without a profile it stays in
/// memory ("").
fn pacingStatePath(allocator: std.mem.Allocator, profile_dir: ?[]const u8) ![]const u8 {
    const dir = profile_dir orelse return "";
    return std.fs.path.join(allocator, &.{ dir, "automation-pacing.json" });
}

test "the pacing state file sits in the profile in use, or nowhere without one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("/home/u/.local/share/zigbrowser/profile/automation-pacing.json", try pacingStatePath(arena.allocator(), "/home/u/.local/share/zigbrowser/profile"));
    try std.testing.expectEqualStrings("/tmp/p/automation-pacing.json", try pacingStatePath(arena.allocator(), "/tmp/p/"));
    try std.testing.expectEqualStrings("", try pacingStatePath(arena.allocator(), null));
}

fn runScreenshot(arena: std.mem.Allocator, spec: ScreenshotSpec) errors.BrowserError!u8 {
    const valid_uri = uri.validate(arena, spec.url) catch |err| {
        return mapUriErr(err);
    };

    // The same flag step as an open window (j76); runScreenshot applies the resolved settings
    // before WebKit starts.
    var sink: ScreenshotSink = .{};
    backend_flag.startup(&sink, spec.hw_policy, spec.renderer, spec.media_source) catch return error.Usage;
    const out_z = arena.dupeZ(u8, spec.out) catch return error.WriteFailed;
    const code = webkit.runScreenshot(valid_uri, out_z, spec.print_title, sink.render, sink.media);
    return @intCast(code);
}

/// backend_flag.startup's `decide` for this build: the seam for its own OS; a refusal prints the
/// exact message (Windows plan WS3.2), and the caller makes it a usage error (exit 1).
fn decideFlag(flag: []const u8, value: []const u8) error{UnsupportedFlag}!void {
    webkit.applyBackendFlag(builtin.os.tag, flag, value) catch |err| {
        var buf: [160]u8 = undefined;
        std.debug.print("{s}\n", .{backend_flag.refusalMessage(&buf, builtin.os.tag, flag, value) catch "zigBrowser: a flag is not supported here"});
        return err;
    };
}

/// The open window's sink: the resolved configuration is applied here, once.
const OpenSink = struct {
    pub fn decide(_: *OpenSink, flag: []const u8, value: []const u8) error{UnsupportedFlag}!void {
        return decideFlag(flag, value);
    }
    pub fn applyResolved(_: *OpenSink, cfg: render_config.RenderConfig, media: ?backend_flag.media_config.MediaSource) void {
        webkit.applyRender(cfg);
        webkit.applyMediaSource(media);
    }
};

/// The screenshot's sink: runScreenshot applies what it keeps, before WebKit starts.
const ScreenshotSink = struct {
    render: render_config.RenderConfig = render_config.default_render,
    media: ?backend_flag.media_config.MediaSource = null,
    pub fn decide(_: *ScreenshotSink, flag: []const u8, value: []const u8) error{UnsupportedFlag}!void {
        return decideFlag(flag, value);
    }
    pub fn applyResolved(self: *ScreenshotSink, cfg: render_config.RenderConfig, media: ?backend_flag.media_config.MediaSource) void {
        self.render = cfg;
        self.media = media;
    }
};

fn mapUriErr(err: uri.UriError) errors.BrowserError {
    return switch (err) {
        error.InvalidUri => error.InvalidUri,
        error.UnsupportedScheme => error.UnsupportedScheme,
        error.RelativeUri => error.InvalidUri,
    };
}

fn buildAutomationConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    spec: OpenSpec,
    profile_dir: ?[]const u8,
) !automation_server.Config {
    const socket_path = try automationSocketPath(allocator, io);
    const credentials = try automationCredentials(allocator, io, spec.automation_token_file, socket_path);
    return .{
        .pacing_state_path = try pacingStatePath(allocator, profile_dir),
        .enabled = true,
        .socket_path = socket_path,
        .token = credentials.token,
        .token_file_path = credentials.token_file_path,
        .page_port = if (builtin.os.tag == .macos) automation_macos_port.pagePort() else automation_gtk_port.pagePort(),
        .cookie_port = if (builtin.os.tag == .macos) automation_macos_cookie_port.cookiePort() else automation_gtk_cookie_port.cookiePort(),
    };
}

fn automationSocketPath(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    if (getenvOwned(allocator, "ZIGBROWSER_SOCKET")) |socket_path| {
        return socket_path;
    }

    // WS2.0: Windows uses %LOCALAPPDATA%\zigbrowser\ only, made owner-only before the server
    // writes the token or binds the socket there; Linux and macOS keep XDG_RUNTIME_DIR, else /tmp.
    const base_dir = try automation_transport.socketBaseDir(platform(), getenvOwned(allocator, "XDG_RUNTIME_DIR"), getenvOwned(allocator, "LOCALAPPDATA"));
    const path = try automation_transport.planSocketPath(allocator, platform(), base_dir, try socketNonce(io));
    if (comptime builtin.os.tag == .windows) {
        const dir = std.fs.path.dirname(path) orelse return error.SocketPathTooLong;
        std.Io.Dir.cwd().createDir(io, dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        try owner_only.restrictToOwner(dir, .dir);
    }
    return path;
}

/// Unpredictable socket-name nonce from OS entropy (no PID, no fallback), so
/// another local user cannot guess the default socket path.
fn socketNonce(io: std.Io) !u64 {
    var bytes: [8]u8 = undefined;
    try io.randomSecure(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

test "default socket names use OS entropy, not the PID" {
    const io = std.testing.io;
    const a = try socketNonce(io);
    const b = try socketNonce(io);
    try std.testing.expect(a != b);
    try std.testing.expect(a != @as(u64, @intCast(std.c.getpid())));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const path = try automation_transport.planSocketPath(arena.allocator(), platform(), "/run/user/1000", a);
    var pid_hex: [32]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_hex, "{x}", .{@as(u64, @intCast(std.c.getpid()))});
    try std.testing.expect(std.mem.indexOf(u8, path, pid_text) == null or pid_text.len < 4);
}

fn getenvOwned(allocator: std.mem.Allocator, comptime name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return allocator.dupe(u8, std.mem.span(raw)) catch null;
}

const Credentials = struct {
    token: []const u8,
    /// Where the server publishes a generated token ("" for a user-supplied one).
    token_file_path: []const u8,
};

/// The automation API always requires a token. With --automation-token-file
/// the user supplies it (an empty or blank file is an error, never "no auth").
/// Otherwise a per-session token is generated from OS entropy and the server
/// writes it to <socket>.token (mode 0600) for local clients to read: any
/// process able to read that file, i.e. the same user, is trusted.
fn automationCredentials(
    allocator: std.mem.Allocator,
    io: std.Io,
    token_file: ?[]const u8,
    socket_path: []const u8,
) !Credentials {
    if (token_file) |path| {
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096));
        const token = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (token.len == 0) return error.EmptyTokenFile;
        return .{ .token = token, .token_file_path = "" };
    }
    return .{
        .token = try generateToken(allocator, io),
        .token_file_path = try std.fmt.allocPrint(allocator, "{s}.token", .{socket_path}),
    };
}

/// 32 bytes of OS entropy as 64 lower-case hex characters.
fn generateToken(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var bytes: [32]u8 = undefined;
    try io.randomSecure(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, &hex);
}

test "generated automation tokens are 64 hex chars from OS entropy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try generateToken(arena.allocator(), std.testing.io);
    const b = try generateToken(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(@as(usize, 64), a.len);
    for (a) |ch| try std.testing.expect(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'));
    try std.testing.expect(!std.mem.eql(u8, a, b));

    const creds = try automationCredentials(arena.allocator(), std.testing.io, null, "/run/zb.sock");
    try std.testing.expectEqual(@as(usize, 64), creds.token.len);
    try std.testing.expectEqualStrings("/run/zb.sock.token", creds.token_file_path);
}

fn platform() automation_transport.Platform {
    return switch (builtin.os.tag) {
        .windows => .windows,
        .macos => .macos,
        else => .linux,
    };
}
