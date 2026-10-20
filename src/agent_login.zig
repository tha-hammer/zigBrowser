//! The one-shot sign-in, Zig side (chat-drawer plan D7b login frames, S6b1;
//! rev 16.18.3): the login helper's launch argv, and the C ABI that
//! agent_login.c uses for the frames (agent_protocol.zig's LoginValidator,
//! validLoginCode and encodeLogin). Nothing here sees the token: it arrives on
//! fd 4, which agent_login.c reads.
const std = @import("std");
const agent_protocol = @import("agent_protocol.zig");
const agent_auth = @import("agent_auth.zig");
const agent_helper = @import("agent_helper.zig");
const agent_setup = @import("agent_setup.zig");

pub const claude_cli_env = agent_setup.claude_cli_env;

pub const Inputs = struct {
    python: []const u8,
    home: []const u8,
    /// The login netd's socket directory (`<chat sockdir>-login`).
    login_net_dir: []const u8,
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
        .net_dir = in.login_net_dir,
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
    return .{ .argv = try argv.toOwnedSlice(a), .env = chat.env, .warning = warning };
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

test "launch: --command login, the login netd dir, and the CLI seam only with --e2e-protocol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const on = try launch(a, .{ .python = "/v/bin/python", .home = "/h", .login_net_dir = "/r/zb-1-login", .e2e_protocol = true, .claude_cli = "/t/fake" });
    try std.testing.expectEqualStrings("--e2e-claude-cli", on.argv[on.argv.len - 2]);
    try std.testing.expectEqualStrings("/t/fake", on.argv[on.argv.len - 1]);
    try std.testing.expect(on.warning == null);
    const off = try launch(a, .{ .python = "/v/bin/python", .home = "/h", .login_net_dir = "/r/zb-1-login", .e2e_protocol = false, .claude_cli = "/t/fake" });
    for (off.argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--e2e-claude-cli"));
    try std.testing.expectEqualStrings("zigBrowser: ZIGBROWSER_AGENT_CLAUDE_CLI ignored without --e2e-protocol", off.warning.?);
    try std.testing.expectEqualStrings("login", off.argv[off.argv.len - 1]);
    var net = false;
    for (off.argv, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--net-dir")) net = std.mem.eql(u8, off.argv[i + 1], "/r/zb-1-login");
    }
    try std.testing.expect(net);
    try std.testing.expectError(error.RelativeCliPath, launch(a, .{ .python = "/p", .home = "/h", .login_net_dir = "/d", .e2e_protocol = true, .claude_cli = "rel/fake" }));
}
