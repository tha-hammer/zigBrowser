const std = @import("std");
const builtin = @import("builtin");

const agent_drawer = @import("agent_drawer.zig");
const agent_setup = @import("agent_setup.zig");
const automation_gtk_cookie_port = @import("automation_gtk_cookie_port.zig");
const automation_gtk_port = @import("automation_gtk_port.zig");
const automation_server = @import("automation_server.zig");
const automation_transport = @import("automation_transport.zig");
const cli = @import("cli.zig");
const render_config = @import("render_config.zig");
const errors = @import("errors.zig");
const uri = @import("uri.zig");
const webkit = @import("webkit.zig");

const c = @cImport({
    @cInclude("webkit_shim.h");
    @cInclude("agent_host.h");
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
        .usage => error.Usage,
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
        .route = spec.token_route,
        .e2e_protocol = spec.e2e_protocol,
        .claude_cli = getenvOwned(arena, agent_setup.claude_cli_env),
        .lang = getenvOwned(arena, "LANG"),
        .lc_all = getenvOwned(arena, "LC_ALL"),
        .spawn_delay = getenvOwned(arena, agent_setup.spawn_delay_env),
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
    const status = c.zb_agent_run_sync(argv.ptr, envp.ptr, setup_run.spawn_delay_ms);
    return if (status < 0) 1 else @intCast(@min(status, 255));
}

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
    // Before WebKit, EGL and the web processes start (they read the environment once).
    webkit.applyRender(render_config.resolve(spec.hw_policy, spec.renderer));
    // Before zb_app_run builds the first window (every window reads it when created).
    webkit.applyMediaSource(spec.media_source);
    const profile_dir = try applyProfileDir(arena, spec);
    // Before zb_app_run builds the first window; the icon's saved position
    // lives with the profile (agent-drawer.json), read only when it is on.
    if (webkit.applyAgentDrawer(spec.agent_drawer)) {
        agent_drawer.configure(io, arena, profile_dir, .{
            .demo = getenvOwned(arena, agent_drawer.demo_env_name),
            .anim_ms = getenvOwned(arena, agent_drawer.anim_env_name),
        }, spec.e2e_protocol);
    }

    if (spec.automation_api) {
        // automation.js must be registered before zb_app_run builds the window.
        automation_gtk_port.installScript();
        const config = buildAutomationConfig(arena, io, spec, profile_dir) catch |err| {
            if (err == error.EmptyTokenFile) std.debug.print("--automation-token-file is empty\n", .{});
            return error.WriteFailed;
        };
        var server = automation_server.AutomationApiServer.init(std.heap.smp_allocator, io, config) catch return error.WriteFailed;
        defer server.deinit();
        server.start() catch return error.WriteFailed;
        defer server.stop();

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

    const out_z = arena.dupeZ(u8, spec.out) catch return error.WriteFailed;
    // The same rendering and media settings as an open window (applied before WebKit starts).
    const code = webkit.runScreenshot(valid_uri, out_z, spec.print_title, render_config.resolve(spec.hw_policy, spec.renderer), spec.media_source);
    return @intCast(code);
}

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
        .page_port = automation_gtk_port.pagePort(),
        .cookie_port = automation_gtk_cookie_port.cookiePort(),
    };
}

fn automationSocketPath(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    if (getenvOwned(allocator, "ZIGBROWSER_SOCKET")) |socket_path| {
        return socket_path;
    }

    const base_dir = getenvOwned(allocator, "XDG_RUNTIME_DIR") orelse try allocator.dupe(u8, "/tmp");
    return automation_transport.planSocketPath(allocator, platform(), base_dir, try socketNonce(io));
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
