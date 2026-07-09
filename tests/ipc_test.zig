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

test "zb_ipc_dispatch returns echo payloads larger than 4096 bytes" {
    var out_result: ?[*:0]const u8 = null;
    var out_err: ?[*:0]const u8 = null;

    const msg = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(msg);
    @memset(msg, 'x');

    const args = try echoArgsJson(std.testing.allocator, msg);
    defer std.testing.allocator.free(args);
    const args_z = try std.testing.allocator.dupeZ(u8, args);
    defer std.testing.allocator.free(args_z);

    const rc = ipc.zb_ipc_dispatch("echo", args_z, &out_result, &out_err);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expect(out_err == null);
    try std.testing.expect(out_result != null);

    const expected = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{std.json.fmt(msg, .{})});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, std.mem.span(out_result.?));
}

test "zb_ipc_dispatch returns a complete 128 KB result and replaces it on next dispatch" {
    var out_result: ?[*:0]const u8 = null;
    var out_err: ?[*:0]const u8 = null;

    const first_msg = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(first_msg);
    @memset(first_msg, 'a');

    const first_args = try echoArgsJson(std.testing.allocator, first_msg);
    defer std.testing.allocator.free(first_args);
    const first_args_z = try std.testing.allocator.dupeZ(u8, first_args);
    defer std.testing.allocator.free(first_args_z);

    const first_rc = ipc.zb_ipc_dispatch("echo", first_args_z, &out_result, &out_err);
    try std.testing.expectEqual(@as(c_int, 0), first_rc);
    try std.testing.expect(out_err == null);
    try std.testing.expect(out_result != null);

    const first_result = std.mem.span(out_result.?);
    try std.testing.expectEqual(first_msg.len + 2, first_result.len);
    try std.testing.expect(first_result[0] == '"');
    try std.testing.expect(first_result[first_result.len - 1] == '"');

    out_result = null;
    out_err = null;

    const second_msg = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(second_msg);
    @memset(second_msg, 'b');

    const second_args = try echoArgsJson(std.testing.allocator, second_msg);
    defer std.testing.allocator.free(second_args);
    const second_args_z = try std.testing.allocator.dupeZ(u8, second_args);
    defer std.testing.allocator.free(second_args_z);

    const second_rc = ipc.zb_ipc_dispatch("echo", second_args_z, &out_result, &out_err);
    try std.testing.expectEqual(@as(c_int, 0), second_rc);
    try std.testing.expect(out_err == null);
    try std.testing.expect(out_result != null);

    const second_result = std.mem.span(out_result.?);
    try std.testing.expectEqual(second_msg.len + 2, second_result.len);
    try std.testing.expect(second_result[0] == '"');
    try std.testing.expect(second_result[second_result.len - 1] == '"');
}

test "zb_ipc_dispatch preserves C ABI error mapping after dynamic result storage" {
    var out_result: ?[*:0]const u8 = null;
    var out_err: ?[*:0]const u8 = null;

    const unknown_rc = ipc.zb_ipc_dispatch("nope", "{}", &out_result, &out_err);
    try std.testing.expect(unknown_rc != 0);
    try std.testing.expect(out_result == null);
    try std.testing.expect(out_err != null);
    try std.testing.expectEqualStrings("UnknownCommand", std.mem.span(out_err.?));

    out_result = null;
    out_err = null;

    const bad_args_rc = ipc.zb_ipc_dispatch("echo", "{}", &out_result, &out_err);
    try std.testing.expect(bad_args_rc != 0);
    try std.testing.expect(out_result == null);
    try std.testing.expect(out_err != null);
    try std.testing.expectEqualStrings("BadArgs", std.mem.span(out_err.?));
}

fn echoArgsJson(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"msg\":{f}}}", .{std.json.fmt(msg, .{})});
}
