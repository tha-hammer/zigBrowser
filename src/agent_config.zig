//! Startup switch for the Claude Agent drawer: whether every browsing
//! window gets the floating "S" icon (src/agent_drawer.c).
//! Pure: cli.zig parses the flag; webkit.zig reads the environment and
//! applies the result.
//!
//! The default stays `off` until slice S5 of the chat-drawer plan
//! (thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md,
//! D2): with it off, every window's widget tree is exactly
//! GtkWindow -> WebKitWebView, as before the drawer existed.

const std = @import("std");
const env_switch = @import("env_switch.zig");

pub const AgentDrawer = enum { on, off };

/// The built-in choice when neither the flag nor the variable is given.
pub const default_agent_drawer: AgentDrawer = .off;

/// The environment variable read when no `--agent-drawer` flag is given.
pub const env_name = "ZIGBROWSER_AGENT_DRAWER";

const flag_or_env = env_switch.Switch(AgentDrawer, default_agent_drawer);

/// Command-line or environment value -> AgentDrawer (exactly `on`, `off`).
pub const parse = flag_or_env.parse;

/// The value plus, when the variable was consulted and is not `on` or
/// `off`, that text (the default is used, and startup says so).
pub const Resolved = flag_or_env.Resolved;

/// The effective setting: the flag, else the variable, else the default.
pub const resolve = flag_or_env.resolve;

/// --agent-secret-store <secret-service|file> (chat-drawer plan D11, S4): where
/// the Secrets window keeps the token. The Secret Service is the default; the
/// 0600 file agent-home/secrets/claude-token only when chosen here (or by an
/// explicit click in the window). Values match agent_secrets.h's store ints.
pub const SecretStore = enum(c_int) { secret_service = 0, file = 1 };

pub fn parseSecretStore(text: []const u8) ?SecretStore {
    if (std.mem.eql(u8, text, "secret-service")) return .secret_service;
    if (std.mem.eql(u8, text, "file")) return .file;
    return null;
}

test "--agent-secret-store parses exactly secret-service and file" {
    try std.testing.expectEqual(SecretStore.secret_service, parseSecretStore("secret-service").?);
    try std.testing.expectEqual(SecretStore.file, parseSecretStore("file").?);
    for ([_][]const u8{ "", "keyring", "File", "secret_service", "secret-service ", "files" }) |text| {
        try std.testing.expect(parseSecretStore(text) == null);
    }
}

test "only on and off parse" {
    try std.testing.expectEqual(AgentDrawer.on, parse("on").?);
    try std.testing.expectEqual(AgentDrawer.off, parse("off").?);
    for ([_][]const u8{ "", "0", "1", "true", "OFF", "On", " on" }) |text| {
        try std.testing.expect(parse(text) == null);
    }
}

test "the built-in default keeps the drawer off" {
    try std.testing.expectEqual(AgentDrawer.off, default_agent_drawer);
    try std.testing.expectEqual(Resolved{ .value = .off }, resolve(null, null));
}

test "the flag wins over the variable, which wins over the default" {
    try std.testing.expectEqual(Resolved{ .value = .on }, resolve(null, "on"));
    try std.testing.expectEqual(Resolved{ .value = .off }, resolve(null, "off"));
    try std.testing.expectEqual(Resolved{ .value = .off }, resolve(.off, "on"));
    try std.testing.expectEqual(Resolved{ .value = .on }, resolve(.on, "off"));
    try std.testing.expectEqual(Resolved{ .value = .on }, resolve(.on, null));
}

test "a variable that is not on or off keeps the default and is reported; a flag makes it irrelevant" {
    const bad = resolve(null, "yes");
    try std.testing.expectEqual(AgentDrawer.off, bad.value);
    try std.testing.expectEqualStrings("yes", bad.bad_env.?);
    try std.testing.expectEqualStrings("", resolve(null, "").bad_env.?);
    try std.testing.expectEqual(Resolved{ .value = .on }, resolve(.on, "bogus"));
}

/// The reference the property test compares against: "flag ?? parse(env)
/// ?? off", written as a table lookup rather than as `resolve`'s branches.
fn referenceResolve(flag: ?AgentDrawer, env: ?[]const u8) Resolved {
    const parsed: ?AgentDrawer = if (env) |text|
        (if (std.mem.eql(u8, text, "on")) .on else if (std.mem.eql(u8, text, "off")) .off else null)
    else
        null;
    const value = flag orelse parsed orelse AgentDrawer.off;
    const bad = flag == null and env != null and parsed == null;
    return .{ .value = value, .bad_env = if (bad) env else null };
}

test "property (oracle): resolve equals flag ?? parse(env) ?? off for every flag and env up to 16 bytes" {
    var prng = std.Random.DefaultPrng.init(0x5A_D7A3);
    const random = prng.random();
    const alphabet = "onfON \x00\t-1";
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        const flag: ?AgentDrawer = switch (random.uintLessThan(u8, 3)) {
            0 => null,
            1 => .on,
            else => .off,
        };
        const env: ?[]const u8 = switch (random.uintLessThan(u8, 4)) {
            0 => null,
            1 => if (random.boolean()) "on" else "off",
            else => blk: {
                const len = random.uintAtMost(usize, buf.len);
                for (buf[0..len]) |*ch| ch.* = alphabet[random.uintLessThan(usize, alphabet.len)];
                break :blk buf[0..len];
            },
        };
        const got = resolve(flag, env);
        const want = referenceResolve(flag, env);
        try std.testing.expectEqual(want.value, got.value);
        try std.testing.expectEqual(want.bad_env == null, got.bad_env == null);
        if (want.bad_env) |text| try std.testing.expectEqualStrings(text, got.bad_env.?);
    }
}
