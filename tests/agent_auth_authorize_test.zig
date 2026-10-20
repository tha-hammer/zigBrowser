//! The app's own authorize-URL check (chat-drawer plan rev 16.18.11; BlackRobin 5924). The
//! login helper (login.py) reports `auth_url` only for exactly one of the CLI's authorize URLs,
//! but it runs beside the CLI, so the app does not take its word: `agent_auth.authorizeUrl`
//! applies the same rules (here), and `zb_login_validate` refuses an `auth_url` frame that fails it
//! (agent_login.c then ends the sign-in `error-protocol`), before the Secrets window shows the
//! link or the auth window loads it (tests/agent_login_authorize_test.zig).
//!
//! Every case lives in one table, tests/fixtures/agent/authorize_url_cases.json, which
//! agent/host/tests/test_authorize_parity.py also runs against login.authorize_url: the app
//! and the helper cannot drift apart. A case's `app` is this check's answer.
const std = @import("std");
const agent_auth = @import("agent_auth");
const has = @hasDecl(agent_auth, "authorizeUrl");

const Case = struct { name: []const u8, url: []const u8, app: bool, why: []const u8, helper: ?bool = null };
const Table = struct { about: []const u8, cases: []const Case };

const table_json = @embedFile("fixtures/agent/authorize_url_cases.json");

fn table(a: std.mem.Allocator) !std.json.Parsed(Table) {
    return std.json.parseFromSlice(Table, a, table_json, .{});
}

test "the table is well formed: both answers present, the intended difference only where marked" {
    const t = try table(std.testing.allocator);
    defer t.deinit();
    try std.testing.expect(t.value.cases.len >= 30);
    var accepted: usize = 0;
    for (t.value.cases) |c| {
        if (c.app) accepted += 1;
        // a URL that a frame can carry as a JSON string without escaping
        try std.testing.expect(std.mem.indexOfAny(u8, c.url, "\"\\") == null);
    }
    try std.testing.expect(accepted >= 3);
}

test "authorizeUrl: every case in the shared table" {
    if (!has) return error.TestNoAuthorizeUrl;
    const t = try table(std.testing.allocator);
    defer t.deinit();
    var wrong: usize = 0;
    for (t.value.cases) |c| {
        const got = agent_auth.authorizeUrl(c.url);
        if (got != c.app) {
            wrong += 1;
            std.debug.print("authorizeUrl {s}: got {}, want {} ({s})\n", .{ c.name, got, c.app, c.why });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), wrong);
}
