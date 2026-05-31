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

test "dispatch rejects unknown command and bad args" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.UnknownCommand, ipc.dispatch(allocator, "nope", "{}"));
    try std.testing.expectError(error.BadArgs, ipc.dispatch(allocator, "add", "{}"));
    try std.testing.expectError(error.BadArgs, ipc.dispatch(allocator, "add", "{\"a\":\"2\",\"b\":3}"));
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
