//! The app refuses an `auth_url` frame that its own authorize-URL check refuses (chat-drawer
//! plan rev 16.18.11; BlackRobin 5924): `zb_login_validate` (src/agent_login.zig), which
//! agent_login.c calls on every login helper frame, applies `agent_auth.authorizeUrl` to it,
//! so agent_login.c ends the sign-in `error-protocol` before the Secrets window shows the link
//! or the auth window loads it. Every case of tests/fixtures/agent/authorize_url_cases.json
//! (`app`, the app's answer), sent as the frame the helper would send.
const std = @import("std");
const agent_login = @import("agent_login");

comptime {
    _ = agent_login; // its C exports, called below as agent_login.c calls them
}

const Case = struct { name: []const u8, url: []const u8, app: bool, why: []const u8, helper: ?bool = null };
const Table = struct { about: []const u8, cases: []const Case };

const table_json = @embedFile("fixtures/agent/authorize_url_cases.json");

extern fn zb_login_validator_new() ?*anyopaque;
extern fn zb_login_validator_free(v: ?*anyopaque) void;
extern fn zb_login_validate(v: *anyopaque, line: [*]const u8, len: usize, kind: *c_int, text: [*]u8, cap: usize) c_int;

test "zb_login_validate refuses an auth_url frame that the app's check refuses" {
    const t = try std.json.parseFromSlice(Table, std.testing.allocator, table_json, .{});
    defer t.deinit();
    var wrong: usize = 0;
    var line: [8192]u8 = undefined;
    var text: [4097]u8 = undefined;
    for (t.value.cases) |c| {
        const v = zb_login_validator_new() orelse return error.OutOfMemory;
        defer zb_login_validator_free(v);
        const frame = try std.fmt.bufPrint(&line, "{{\"v\":1,\"seq\":1,\"type\":\"auth_url\",\"url\":\"{s}\"}}", .{c.url});
        var kind: c_int = -1;
        const rc = zb_login_validate(v, frame.ptr, frame.len, &kind, &text, text.len);
        const accepted = rc == 0;
        if (accepted != c.app) {
            wrong += 1;
            std.debug.print("zb_login_validate {s}: accepted {}, want {} ({s})\n", .{ c.name, accepted, c.app, c.why });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), wrong);
}

test "a NUL or control byte in the frame's url is refused (rev 16.18.12; RoseCat 6252)" {
    const t = try std.json.parseFromSlice(Table, std.testing.allocator, table_json, .{});
    defer t.deinit();
    const captured = for (t.value.cases) |c| {
        if (std.mem.eql(u8, c.name, "captured-shape")) break c.url;
    } else return error.NoCapturedShape;
    const at = std.mem.indexOf(u8, captured, "zbState-0123") orelse return error.NoState;
    var line: [8192]u8 = undefined;
    var text: [4097]u8 = undefined;
    // JSON escapes: the validator decodes them into the url's bytes.
    for ([_][]const u8{ "", "\\u0000", "\\u0001", "\\u001f", "\\u007f", "\\t", "\\n", " ", "\\u00e9", "\\u2028" }) |esc| {
        const frame = try std.fmt.bufPrint(&line, "{{\"v\":1,\"seq\":1,\"type\":\"auth_url\",\"url\":\"{s}zb{s}State{s}\"}}", .{ captured[0..at], esc, captured[at + "zbState-0123".len ..] });
        const v = zb_login_validator_new() orelse return error.OutOfMemory;
        defer zb_login_validator_free(v);
        var kind: c_int = -1;
        const accepted = zb_login_validate(v, frame.ptr, frame.len, &kind, &text, text.len) == 0;
        if (accepted != (esc.len == 0)) {
            std.debug.print("escape '{s}': accepted {}\n", .{ esc, accepted });
            return error.TestUnexpectedResult;
        }
    }
}
