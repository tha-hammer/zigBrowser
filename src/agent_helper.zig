//! The browser's side of starting the chat helper (chat-drawer plan D7, D7b,
//! S3.2, S3.6; rev 16 §3c.2, §3c.4; S3b): the launch argv and its built
//! environment, the e2e seams, the app → helper frames, the runtime-lock check
//! and the restart backoff. Pure; app.zig gathers the inputs and
//! src/agent_helper.c spawns.
//!
//! The browser spawns `<python> -m zb_agent_host launch ...` with
//! PYTHONPATH=<home>/runtime/host (setup's read-only package copy) and nothing
//! of its own environment but the locale. `launch` builds the sandbox and
//! execs bwrap in place with exactly the helper's environment.
//!
//! Seams (section 7), read only with --e2e-protocol:
//! - ZIGBROWSER_AGENT_BWRAP (app-owned): passed to launch as `--bwrap`;
//! - ZIGBROWSER_AGENT_HOST_CMD (app-owned): replaces the whole argv (the
//!   frame-validation fake, S3.3), with the same environment and fd 3;
//! - ZIGBROWSER_AGENT_TEST_BASE_URL (helper-carried, in hello's e2e object):
//!   rev 16 reaches the fake API only through relay → netd, so the one
//!   accepted value is https://fake.zb.invalid (§3c.4);
//! - ZIGBROWSER_AGENT_TEST_TOOL_DEADLINE_S (helper-carried, in hello's e2e object, S7b):
//!   exactly an integer from 1 to agent_protocol.tool_deadline_s (120); the helper answers a
//!   browser tool call that long without a tool_result, and the app's brokers use it as H;
//! - ZIGBROWSER_AGENT_NET_TEST_CA (agent_net.zig checks it): `--test-ca`.
//! Without --e2e-protocol each app-owned seam gets one stderr line and is
//! ignored; the helper-carried ones are dropped.

const std = @import("std");
const protocol = @import("agent_protocol.zig");

pub const bwrap_env = "ZIGBROWSER_AGENT_BWRAP";
pub const host_cmd_env = "ZIGBROWSER_AGENT_HOST_CMD";
pub const test_base_url_env = "ZIGBROWSER_AGENT_TEST_BASE_URL";
pub const test_base_url = "https://fake.zb.invalid";
pub const tool_deadline_env = "ZIGBROWSER_AGENT_TEST_TOOL_DEADLINE_S";
const tool_deadline_refusal = std.fmt.comptimePrint("zigBrowser: agent: test tool deadline must be an integer from 1 to {d}", .{protocol.tool_deadline_s});
pub const max_prompt: usize = 64 * 1024;

/// How the helper's sandbox reaches netd (MS6.8 slice 2a, SilverRidge d751d158): one backend's realization. Linux
/// binds netd's socket directory into bwrap (`launch --net-dir`); macOS hands the inner helper netd's loopback egress
/// port (`launch --egress-port`), and refuses 0. The Darwin arm has no browser caller until 4pa.27/MS8.
pub const Realization = union(enum) {
    linux: []const u8,
    darwin: u16,
};

pub const bwrap_refusal = "zigBrowser: agent: " ++ bwrap_env ++ " is the Linux sandbox's only";
pub const host_cmd_refusal = "zigBrowser: agent: " ++ host_cmd_env ++ " would bypass the macOS launch";
pub const port_refusal = "zigBrowser: agent: the macOS egress port must be 1..65535";

pub const Inputs = struct {
    /// The runtime's venv python (agent_setup.defaultRuntime or its override).
    python: []const u8,
    home: []const u8,
    /// netd's socket directory (Linux) or loopback egress port (macOS), once netd is ready.
    realization: Realization,
    /// runtime/path.json: the hook command directories.
    path_dirs: []const []const u8 = &.{},
    lang: ?[]const u8 = null,
    lc_all: ?[]const u8 = null,
    e2e_protocol: bool,
    bwrap: ?[]const u8 = null,
    host_cmd: ?[]const u8 = null,
    test_base_url: ?[]const u8 = null,
    /// ZIGBROWSER_AGENT_TEST_TOOL_DEADLINE_S as given (checked by launch).
    tool_deadline: ?[]const u8 = null,
    /// Already checked by agent_net.checkTestCa (and read only under e2e).
    test_ca: ?[]const u8 = null,
};

/// hello's `e2e` object: only the seams that are set (the helper refuses a null
/// tool_deadline_s).
pub const HelloE2e = struct {
    test_base_url: ?[]const u8 = null,
    tool_deadline_s: ?i64 = null,

    pub fn jsonStringify(self: HelloE2e, jw: anytype) !void {
        try jw.beginObject();
        if (self.test_base_url) |url| {
            try jw.objectField("test_base_url");
            try jw.write(url);
        }
        if (self.tool_deadline_s) |seconds| {
            try jw.objectField("tool_deadline_s");
            try jw.write(seconds);
        }
        try jw.endObject();
    }
};

/// The seam's value: digits only, 1 to agent_protocol.tool_deadline_s; null otherwise.
fn toolDeadline(raw: []const u8) ?i64 {
    if (raw.len == 0 or raw.len > 3) return null;
    for (raw) |ch| if (!std.ascii.isDigit(ch)) return null;
    const value = std.fmt.parseInt(i64, raw, 10) catch return null;
    return if (value >= 1 and value <= protocol.tool_deadline_s) value else null;
}

pub const Launch = struct {
    argv: []const []const u8,
    env: []const []const u8,
    /// Lines for stderr: app-owned seams ignored without --e2e-protocol.
    warnings: []const []const u8,
    /// When set, the one stderr line that refuses the agent.
    refusal: ?[]const u8 = null,
    /// hello's `e2e` object; null without --e2e-protocol or seams.
    hello_e2e: ?HelloE2e = null,
};

pub fn launch(a: std.mem.Allocator, in: Inputs) !Launch {
    var warnings: std.ArrayList([]const u8) = .empty;
    var refusal: ?[]const u8 = null;
    var hello_e2e: ?HelloE2e = null;
    if (!in.e2e_protocol) {
        if (in.bwrap != null) try warnings.append(a, "zigBrowser: " ++ bwrap_env ++ " ignored without --e2e-protocol");
        if (in.host_cmd != null) try warnings.append(a, "zigBrowser: " ++ host_cmd_env ++ " ignored without --e2e-protocol");
    } else {
        var e2e: HelloE2e = .{};
        if (in.test_base_url) |url| {
            if (std.mem.eql(u8, url, test_base_url)) {
                e2e.test_base_url = url;
            } else {
                refusal = "zigBrowser: agent: test base URL must be " ++ test_base_url;
            }
        }
        if (in.tool_deadline) |raw| {
            e2e.tool_deadline_s = toolDeadline(raw);
            if (e2e.tool_deadline_s == null) refusal = tool_deadline_refusal;
        }
        if (e2e.test_base_url != null or e2e.tool_deadline_s != null) hello_e2e = e2e;
    }
    // macOS consumes or refuses every Linux-only input before dispatch: the bwrap override has no sandbox to name,
    // and the whole-host-command override would bypass `zb_agent_host launch` and its Seatbelt profile.
    const darwin = in.realization == .darwin;
    if (darwin) {
        if (in.e2e_protocol and in.bwrap != null) refusal = bwrap_refusal;
        if (in.e2e_protocol and in.host_cmd != null) refusal = host_cmd_refusal;
        if (in.realization.darwin == 0) refusal = port_refusal;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    if (in.e2e_protocol and in.host_cmd != null and !darwin) {
        try argv.append(a, in.host_cmd.?);
    } else {
        try argv.appendSlice(a, &.{ in.python, "-m", "zb_agent_host", "launch", "--home", in.home, "--python", in.python });
        switch (in.realization) {
            .linux => |dir| try argv.appendSlice(a, &.{ "--net-dir", dir }),
            .darwin => |port| try argv.appendSlice(a, &.{ "--egress-port", try std.fmt.allocPrint(a, "{d}", .{port}) }),
        }
        if (in.e2e_protocol) {
            if (!darwin) if (in.bwrap) |path| try argv.appendSlice(a, &.{ "--bwrap", path });
            if (in.test_ca) |path| try argv.appendSlice(a, &.{ "--test-ca", path });
        }
    }

    var path: std.ArrayList(u8) = .empty;
    try path.appendSlice(a, "PATH=");
    var seen: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ std.fs.path.dirname(in.python) orelse "/usr/bin", "/usr/bin", "/bin" }) |dir| try addDir(a, &path, &seen, dir);
    for (in.path_dirs) |dir| try addDir(a, &path, &seen, dir);

    var env: std.ArrayList([]const u8) = .empty;
    try env.appendSlice(a, &.{
        path.items,
        try std.fmt.allocPrint(a, "PYTHONPATH={s}/runtime/host", .{in.home}),
        "PYTHONDONTWRITEBYTECODE=1",
    });
    if (in.lang) |v| try env.append(a, try std.fmt.allocPrint(a, "LANG={s}", .{v}));
    if (in.lc_all) |v| try env.append(a, try std.fmt.allocPrint(a, "LC_ALL={s}", .{v}));
    return .{
        .argv = try argv.toOwnedSlice(a),
        .env = try env.toOwnedSlice(a),
        .warnings = try warnings.toOwnedSlice(a),
        .refusal = refusal,
        .hello_e2e = hello_e2e,
    };
}

fn addDir(a: std.mem.Allocator, path: *std.ArrayList(u8), seen: *std.ArrayList([]const u8), dir: []const u8) !void {
    for (seen.items) |known| if (std.mem.eql(u8, known, dir)) return;
    if (seen.items.len > 0) try path.append(a, ':');
    try path.appendSlice(a, dir);
    try seen.append(a, dir);
}

// --- app → helper frames (D7b) ------------------------------------------------

pub fn helloFrame(a: std.mem.Allocator, seq: u64, home: []const u8, e2e: ?HelloE2e) ![]u8 {
    const workspace = try std.fmt.allocPrint(a, "{s}/workspace", .{home});
    const scratchpad = try std.fmt.allocPrint(a, "{s}/scratchpad", .{home});
    return frame(a, .{
        .v = 1,
        .seq = seq,
        .type = "hello",
        .agent_home = home,
        .workspace = workspace,
        .scratchpad = scratchpad,
        .route = "R1",
        .e2e = e2e,
    });
}

/// `s-<win>-<k>` for the window `window-<win>`.
pub fn openSessionFrame(a: std.mem.Allocator, seq: u64, window: u32, k: u32) ![]u8 {
    const session = try std.fmt.allocPrint(a, "s-{d}-{d}", .{ window, k });
    const window_id = try std.fmt.allocPrint(a, "window-{d}", .{window});
    return frame(a, .{ .v = 1, .seq = seq, .type = "open_session", .session = session, .window_id = window_id });
}

/// Null when `text` is over 64 KiB (D7b): it is not sent.
pub fn promptFrame(a: std.mem.Allocator, seq: u64, session: []const u8, prompt_id: i64, text: []const u8) !?[]u8 {
    if (text.len > max_prompt) return null;
    return try frame(a, .{ .v = 1, .seq = seq, .type = "prompt", .session = session, .prompt_id = prompt_id, .text = text });
}

pub const SessionFrame = enum { interrupt, end_session };

pub fn sessionFrame(a: std.mem.Allocator, seq: u64, kind: SessionFrame, session: []const u8) ![]u8 {
    return frame(a, .{ .v = 1, .seq = seq, .type = @tagName(kind), .session = session });
}

pub fn shutdownFrame(a: std.mem.Allocator, seq: u64) ![]u8 {
    return frame(a, .{ .v = 1, .seq = seq, .type = "shutdown" });
}

fn frame(a: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(value, .{}, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

// --- the runtime lock (plan S3, rev 15.2) -------------------------------------

pub const RuntimeCheck = enum { ok, changed, missing };

/// `host_json`: the home's runtime/host.json (null when unreadable);
/// `runtime_json`: the installed runtime's runtime.json (null when absent, as
/// in a development checkout). The recorded lock must equal the installed one.
pub fn checkRuntime(gpa: std.mem.Allocator, host_json: ?[]const u8, runtime_json: ?[]const u8) RuntimeCheck {
    const host_text = host_json orelse return .missing;
    const Host = struct { python: []const u8, runtime_lock: ?[]const u8 = null };
    const host = std.json.parseFromSlice(Host, gpa, host_text, .{ .ignore_unknown_fields = true }) catch return .missing;
    defer host.deinit();
    const Installed = struct { lock_sha256: ?[]const u8 = null };
    var installed_lock: ?[]const u8 = null;
    var installed: ?std.json.Parsed(Installed) = null;
    defer if (installed) |p| p.deinit();
    if (runtime_json) |text| {
        installed = std.json.parseFromSlice(Installed, gpa, text, .{ .ignore_unknown_fields = true }) catch return .changed;
        installed_lock = installed.?.value.lock_sha256;
    }
    const recorded = host.value.runtime_lock;
    if (recorded == null and installed_lock == null) return .ok;
    if (recorded == null or installed_lock == null) return .changed;
    return if (std.mem.eql(u8, recorded.?, installed_lock.?)) .ok else .changed;
}

// --- supervision (D7) ---------------------------------------------------------

/// The wait before restart number `restarts` (0-based): 1, 2, 4, then 8 s.
pub fn backoffMs(restarts: u32) u32 {
    return @as(u32, 1000) << @intCast(@min(restarts, 3));
}

pub const Exit = union(enum) { exited: u8, signaled: u8 };

/// The DRAWER status reason for a helper that ended: launch's exit 3 means
/// no sandbox (bwrap missing); anything else is `exit-<n>` or `signal-<n>`.
pub fn exitReason(buf: []u8, how: Exit) []const u8 {
    return switch (how) {
        .exited => |code| if (code == 3) "sandbox" else std.fmt.bufPrint(buf, "exit-{d}", .{code}) catch "exit",
        .signaled => |sig| std.fmt.bufPrint(buf, "signal-{d}", .{sig}) catch "signal",
    };
}
