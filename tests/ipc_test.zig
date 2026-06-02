const std = @import("std");
const ipc = @import("ipc");

const OsInfo = struct {
    sysname: []const u8,
    release: []const u8,
    machine: []const u8,
};

test "dispatch ping returns quoted JSON string" {
    const allocator = std.testing.allocator;
    const result = try ipc.dispatch(allocator, "ping", "{}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"pong\"", result);
}

test "dispatch add returns unquoted JSON number text" {
    const allocator = std.testing.allocator;
    const result = try ipc.dispatch(allocator, "add", "{\"a\":2,\"b\":3}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("5", result);
}

test "dispatch echo returns exact payload as JSON string" {
    const allocator = std.testing.allocator;
    const result = try ipc.dispatch(allocator, "echo", "{\"msg\":\"hi-42\"}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\"hi-42\"", result);
}

test "dispatch echo roundtrip property across 4093/4096 ceiling boundary" {
    const allocator = std.testing.allocator;

    const sizes = [_]usize{ 0, 1, 16, 1024, 4093 };
    for (sizes) |size| {
        const msg = try allocator.alloc(u8, size);
        defer allocator.free(msg);
        @memset(msg, 'a');

        const args_json = try echoArgsJson(allocator, msg);
        defer allocator.free(args_json);

        const result = try ipc.dispatch(allocator, "echo", args_json);
        defer allocator.free(result);

        const expected = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(msg, .{})});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, result);
    }
}

test "dispatch os.info returns uname-backed JSON object text" {
    const allocator = std.testing.allocator;
    const result = try ipc.dispatch(allocator, "os.info", "{}");
    defer allocator.free(result);

    var parsed = try std.json.parseFromSlice(OsInfo, allocator, result, .{});
    defer parsed.deinit();

    const uts = std.posix.uname();
    const expected_sysname = std.mem.sliceTo(&uts.sysname, 0);
    const expected_release = std.mem.sliceTo(&uts.release, 0);
    const expected_machine = std.mem.sliceTo(&uts.machine, 0);

    try std.testing.expectEqualStrings(expected_sysname, parsed.value.sysname);
    try std.testing.expectEqualStrings(expected_release, parsed.value.release);
    try std.testing.expectEqualStrings(expected_machine, parsed.value.machine);
}

test "dispatch os.info returns platform-invariant shape" {
    const allocator = std.testing.allocator;
    const result = try ipc.dispatch(allocator, "os.info", "{}");
    defer allocator.free(result);

    var parsed = try std.json.parseFromSlice(OsInfo, allocator, result, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.sysname.len > 0);
    try std.testing.expect(parsed.value.release.len > 0);
    try std.testing.expect(parsed.value.machine.len > 0);
}

test "dispatch rejects unknown command and bad args" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.UnknownCommand, ipc.dispatch(allocator, "nope", "{}"));
    try std.testing.expectError(error.BadArgs, ipc.dispatch(allocator, "add", "{}"));
    try std.testing.expectError(error.BadArgs, ipc.dispatch(allocator, "add", "{\"a\":\"2\",\"b\":3}"));
    try std.testing.expectError(error.BadArgs, ipc.dispatch(allocator, "echo", "{}"));
    try std.testing.expectError(error.BadArgs, ipc.dispatch(allocator, "echo", "{\"msg\":42}"));
}

test "dispatch accepts missing null and empty-object args for no-arg commands" {
    const allocator = std.testing.allocator;

    const ping_empty = try ipc.dispatch(allocator, "ping", "");
    defer allocator.free(ping_empty);
    try std.testing.expectEqualStrings("\"pong\"", ping_empty);

    const ping_null = try ipc.dispatch(allocator, "ping", "null");
    defer allocator.free(ping_null);
    try std.testing.expectEqualStrings("\"pong\"", ping_null);

    const os_empty_obj = try ipc.dispatch(allocator, "os.info", "{}");
    defer allocator.free(os_empty_obj);
    try std.testing.expect(os_empty_obj.len > 0);
}

test "zb_ipc_dispatch C ABI returns result and error strings" {
    var out_result: ?[*:0]const u8 = null;
    var out_err: ?[*:0]const u8 = null;

    const ok_rc = ipc.zb_ipc_dispatch("add", "{\"a\":2,\"b\":3}", &out_result, &out_err);
    try std.testing.expectEqual(@as(c_int, 0), ok_rc);
    try std.testing.expect(out_result != null);
    try std.testing.expect(out_err == null);
    try std.testing.expectEqualStrings("5", std.mem.span(out_result.?));

    out_result = null;
    out_err = null;
    const bad_rc = ipc.zb_ipc_dispatch("nope", "{}", &out_result, &out_err);
    try std.testing.expect(bad_rc != 0);
    try std.testing.expect(out_result == null);
    try std.testing.expect(out_err != null);
    try std.testing.expectEqualStrings("UnknownCommand", std.mem.span(out_err.?));
}

test "zb_ipc_dispatch enforces 4096-byte output ceiling for echo" {
    var out_result: ?[*:0]const u8 = null;
    var out_err: ?[*:0]const u8 = null;

    var ok_msg: [4093]u8 = undefined;
    @memset(ok_msg[0..], 'x');
    const ok_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"msg\":\"{s}\"}}", .{ok_msg});
    defer std.testing.allocator.free(ok_args);
    const ok_args_z = try std.testing.allocator.dupeZ(u8, ok_args);
    defer std.testing.allocator.free(ok_args_z);

    const ok_rc = ipc.zb_ipc_dispatch("echo", ok_args_z, &out_result, &out_err);
    try std.testing.expectEqual(@as(c_int, 0), ok_rc);
    try std.testing.expect(out_err == null);
    try std.testing.expect(out_result != null);
    try std.testing.expectEqual(@as(usize, 4095), std.mem.span(out_result.?).len);

    out_result = null;
    out_err = null;

    var too_big_msg: [4094]u8 = undefined;
    @memset(too_big_msg[0..], 'x');
    const too_big_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"msg\":\"{s}\"}}", .{too_big_msg});
    defer std.testing.allocator.free(too_big_args);
    const too_big_args_z = try std.testing.allocator.dupeZ(u8, too_big_args);
    defer std.testing.allocator.free(too_big_args_z);

    const bad_rc = ipc.zb_ipc_dispatch("echo", too_big_args_z, &out_result, &out_err);
    try std.testing.expect(bad_rc != 0);
    try std.testing.expect(out_result == null);
    try std.testing.expect(out_err != null);
    try std.testing.expectEqualStrings("BadArgs", std.mem.span(out_err.?));
}

fn echoArgsJson(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"msg\":{f}}}", .{std.json.fmt(msg, .{})});
}
