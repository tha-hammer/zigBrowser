//! The one-shot sign-in, Zig side (chat-drawer plan D7b login frames, S6b1;
//! rev 16.18.3): the login helper's launch argv, and the C ABI that
//! agent_login.c uses for the frames (agent_protocol.zig's LoginValidator,
//! validLoginCode and encodeLogin). Nothing here sees the token: it arrives on
//! fd 4, which agent_login.c reads.
const std = @import("std");
const agent_protocol = @import("agent_protocol.zig");
const agent_auth = @import("agent_auth.zig");
const agent_auth_seam = @import("agent_auth_seam.zig");
const agent_helper = @import("agent_helper.zig");
const agent_setup = @import("agent_setup.zig");

pub const claude_cli_env = agent_setup.claude_cli_env;

pub const Inputs = struct {
    python: []const u8,
    home: []const u8,
    /// The login netd's realization: its socket directory (`<chat sockdir>-login`) on Linux, its egress port on macOS.
    realization: agent_helper.Realization,
    path_dirs: []const []const u8 = &.{},
    lang: ?[]const u8 = null,
    lc_all: ?[]const u8 = null,
    e2e_protocol: bool,
    /// ZIGBROWSER_AGENT_CLAUDE_CLI's value (null: unset).
    claude_cli: ?[]const u8 = null,
    bwrap: ?[]const u8 = null,
};

pub const Launch = struct {
    argv: []const []const u8,
    env: []const []const u8,
    /// One stderr line when a seam was ignored or refused.
    warning: ?[]const u8 = null,
    /// When set, the one stderr line that refuses the sign-in (the chat launch's refusal: a macOS bwrap override or
    /// a zero port); nothing is dispatched.
    refusal: ?[]const u8 = null,
};

pub const Error = error{ RelativeCliPath, OutOfMemory };

/// `launch --command login`, built like the chat helper's launch (the same
/// environment), with the login netd's directory. The fake setup-token CLI is
/// passed only as `--e2e-claude-cli <path>`, and only with --e2e-protocol
/// (S6.1); never in an environment.
pub fn launch(a: std.mem.Allocator, in: Inputs) Error!Launch {
    const chat = try agent_helper.launch(a, .{
        .python = in.python,
        .home = in.home,
        .realization = in.realization,
        .path_dirs = in.path_dirs,
        .lang = in.lang,
        .lc_all = in.lc_all,
        .e2e_protocol = in.e2e_protocol,
        .bwrap = in.bwrap,
    });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, chat.argv);
    try argv.appendSlice(a, &.{ "--command", "login" });
    var warning: ?[]const u8 = null;
    if (in.claude_cli) |cli| {
        if (!in.e2e_protocol) {
            warning = "zigBrowser: " ++ claude_cli_env ++ " ignored without --e2e-protocol";
        } else {
            if (!std.fs.path.isAbsolute(cli)) return error.RelativeCliPath;
            try argv.appendSlice(a, &.{ "--e2e-claude-cli", cli });
        }
    }
    return .{ .argv = try argv.toOwnedSlice(a), .env = chat.env, .warning = warning, .refusal = chat.refusal };
}

/// `<chat sockdir>-login`; it fits sun_path whenever the chat one does with
/// room for "-login" (the login netd binds no bridges/ socket, so its longest
/// path is egress/proxy.sock).
pub fn loginNetDir(a: std.mem.Allocator, chat_sockdir: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}-login", .{chat_sockdir});
}

// --- the C ABI (agent_login.c) ----------------------------------------------

/// The frame kinds agent_login.c acts on.
pub const ZB_LOGIN_AUTH_URL: c_int = 1;
pub const ZB_LOGIN_NEED_CODE: c_int = 2;
pub const ZB_LOGIN_DONE: c_int = 3;
pub const ZB_LOGIN_ERROR: c_int = 4;

/// A validator for one sign-in, or null when out of memory.
export fn zb_login_validator_new() ?*agent_protocol.LoginValidator {
    const v = std.heap.c_allocator.create(agent_protocol.LoginValidator) catch return null;
    v.* = .{};
    return v;
}

export fn zb_login_validator_free(v: ?*agent_protocol.LoginValidator) void {
    if (v) |p| std.heap.c_allocator.destroy(p);
}

/// One stdout line. 0 with `kind` set and `text` holding the URL (auth_url) or
/// the error code (error), NUL-terminated; -1 when the frame is refused (then
/// nothing about it may be acted on or shown).
export fn zb_login_validate(v: *agent_protocol.LoginValidator, line: [*]const u8, len: usize, kind: *c_int, text: [*]u8, cap: usize) c_int {
    if (cap == 0) return -1;
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const out = v.validate(arena.allocator(), line[0..len]);
    const frame = switch (out) {
        .ok => |f| f,
        .rejected => return -1,
    };
    // Rev 16.18.11 (BlackRobin 5924): the app checks the authorize URL itself, with the
    // helper's exact rules, before the link is shown or loaded.
    if (frame == .auth_url and !agent_auth.authorizeUrl(frame.auth_url.url)) return -1;
    const value: []const u8 = switch (frame) {
        .auth_url => |f| f.url,
        .@"error" => |f| f.code,
        .need_code, .done => "",
    };
    if (value.len + 1 > cap) return -1;
    @memcpy(text[0..value.len], value);
    text[value.len] = 0;
    kind.* = switch (frame) {
        .auth_url => ZB_LOGIN_AUTH_URL,
        .need_code => ZB_LOGIN_NEED_CODE,
        .done => ZB_LOGIN_DONE,
        .@"error" => ZB_LOGIN_ERROR,
    };
    return 0;
}

/// 1 when `code` is a `<code>#<state>` the CLI may be typed.
export fn zb_login_code_valid(code: [*]const u8, len: usize) c_int {
    return @intFromBool(agent_protocol.validLoginCode(code[0..len]));
}

/// The app → login frame `start` (kind 0), `code` (1) or `cancel` (2), with a
/// trailing newline, NUL-terminated in `out`. 0, or -1 for a bad code or no room.
export fn zb_login_encode(kind: c_int, seq: i64, code: ?[*]const u8, code_len: usize, out: [*]u8, cap: usize) c_int {
    const frame: agent_protocol.AppLoginFrame = switch (kind) {
        0 => .start,
        1 => .{ .code = (code orelse return -1)[0..code_len] },
        2 => .cancel,
        else => return -1,
    };
    const text = agent_protocol.encodeLogin(std.heap.c_allocator, seq, frame) catch return -1;
    defer std.heap.c_allocator.free(text);
    if (text.len + 2 > cap) return -1;
    @memcpy(out[0..text.len], text);
    out[text.len] = '\n';
    out[text.len + 1] = 0;
    return 0;
}

/// S6b2 (chat-drawer plan rev 16.18.15): the ZIGBROWSER_AGENT_AUTH_TEST decision, for the auth
/// window's C body, made before the window exists. Returns 0 (unset), 1 (ignored: no
/// --e2e-protocol), 2 (refused) or 3 (ok: `port`, and `ca` NUL-terminated). For ignored and refused,
/// `line` holds the stderr line, NUL-terminated (else it is empty).
export fn zb_auth_seam(e2e: c_int, value: ?[*:0]const u8, port: *u16, ca: [*]u8, ca_cap: usize, line: [*]u8, line_cap: usize) c_int {
    if (ca_cap == 0 or line_cap == 0) return 2;
    ca[0] = 0;
    line[0] = 0;
    const seam = agent_auth_seam.authTestSeam(e2e != 0, if (value) |v| std.mem.span(v) else null);
    var buf: [256]u8 = undefined;
    if (agent_auth_seam.stderrLine(&buf, seam)) |text| {
        if (text.len + 1 <= line_cap) {
            @memcpy(line[0..text.len], text);
            line[text.len] = 0;
        }
    }
    return switch (seam) {
        .none => 0,
        .ignored => 1,
        .refused => 2,
        .ok => |ok| blk: {
            if (ok.ca.len + 1 > ca_cap) break :blk 2;
            @memcpy(ca[0..ok.ca.len], ok.ca);
            ca[ok.ca.len] = 0;
            port.* = ok.port;
            break :blk 3;
        },
    };
}

/// S6b2 (rev 16.18.16-16.18.18): the auth window's decision for one main-frame navigation.
/// Returns 0 (allow: `out` holds the `https://<host>:443` origin), 1 (capture: `out` holds
/// `<code>#<state>`) or 2 (block: `out` holds the reason word); `out` is NUL-terminated.
export fn zb_auth_decide(authorize: [*:0]const u8, nav: [*:0]const u8, captured: c_int, out: [*]u8, cap: usize) c_int {
    var buf: [agent_auth.max_code_len + 64]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf); // a captured code passes through here
    const decision = agent_auth.decideNavigation(std.mem.span(authorize), std.mem.span(nav), captured != 0, &buf);
    const kind: c_int, const text: []const u8 = switch (decision) {
        .allow => |origin| .{ 0, origin },
        .capture => |code| .{ 1, code },
        .block => |reason| .{ 2, @tagName(reason) },
    };
    if (cap == 0) return 2;
    if (text.len + 1 > cap) {
        out[0] = 0;
        return 2;
    }
    @memcpy(out[0..text.len], text);
    out[text.len] = 0;
    return kind;
}

/// The auth window's response decision (agent_auth.decideResponse, rev 16.20.33): 0 pass (WebKit's
/// default), 1 capture (`out` holds `<code>#<state>`), 2 block (`out` holds the reason word).
/// `pending` is the one pending callback's exact URI, or null.
export fn zb_auth_respond(authorize: [*:0]const u8, pending: ?[*:0]const u8, response: [*:0]const u8, main_frame: c_int, captured: c_int, out: [*]u8, cap: usize) c_int {
    var buf: [agent_auth.max_code_len + 64]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf); // a captured code passes through here
    const p: ?[]const u8 = if (pending) |v| std.mem.span(v) else null;
    const decision = agent_auth.decideResponse(std.mem.span(authorize), p, std.mem.span(response), main_frame != 0, captured != 0, &buf);
    const kind: c_int, const text: []const u8 = switch (decision) {
        .pass => .{ 0, "" },
        .capture => |code| .{ 1, code },
        .block => |reason| .{ 2, @tagName(reason) },
    };
    if (cap == 0) return if (kind == 0) 0 else 2;
    if (text.len + 1 > cap) {
        out[0] = 0;
        return 2;
    }
    @memcpy(out[0..text.len], text);
    out[text.len] = 0;
    return kind;
}

test "launch: --command login, the login netd dir, and the CLI seam only with --e2e-protocol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const on = try launch(a, .{ .python = "/v/bin/python", .home = "/h", .realization = .{ .linux = "/r/zb-1-login" }, .e2e_protocol = true, .claude_cli = "/t/fake" });
    try std.testing.expectEqualStrings("--e2e-claude-cli", on.argv[on.argv.len - 2]);
    try std.testing.expectEqualStrings("/t/fake", on.argv[on.argv.len - 1]);
    try std.testing.expect(on.warning == null);
    const off = try launch(a, .{ .python = "/v/bin/python", .home = "/h", .realization = .{ .linux = "/r/zb-1-login" }, .e2e_protocol = false, .claude_cli = "/t/fake" });
    for (off.argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--e2e-claude-cli"));
    try std.testing.expectEqualStrings("zigBrowser: ZIGBROWSER_AGENT_CLAUDE_CLI ignored without --e2e-protocol", off.warning.?);
    try std.testing.expectEqualStrings("login", off.argv[off.argv.len - 1]);
    var net = false;
    for (off.argv, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--net-dir")) net = std.mem.eql(u8, off.argv[i + 1], "/r/zb-1-login");
    }
    try std.testing.expect(net);
    try std.testing.expectError(error.RelativeCliPath, launch(a, .{ .python = "/p", .home = "/h", .realization = .{ .linux = "/d" }, .e2e_protocol = true, .claude_cli = "rel/fake" }));
}
