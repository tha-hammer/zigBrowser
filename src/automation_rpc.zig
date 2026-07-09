const std = @import("std");

const testing = std.testing;

pub const RouterResult = union(enum) {
    success_json: []const u8,
    method_not_found,
    invalid_params,
};

pub const Router = struct {
    context: *anyopaque,
    dispatchFn: *const fn (*anyopaque, []const u8, ?std.json.Value) RouterResult,

    fn dispatch(self: Router, method: []const u8, params: ?std.json.Value) RouterResult {
        return self.dispatchFn(self.context, method, params);
    }
};

pub const ConnectionConfig = struct {
    token: []const u8,
    max_line_bytes: usize = 64 * 1024,
};

pub const Connection = struct {
    token: []const u8,
    max_line_bytes: usize,
    authenticated: bool = false,

    pub fn init(config: ConnectionConfig) Connection {
        return .{
            .token = config.token,
            .max_line_bytes = config.max_line_bytes,
        };
    }

    pub fn handleLine(
        self: *Connection,
        allocator: std.mem.Allocator,
        line: []const u8,
        router: Router,
    ) !?[]u8 {
        if (line.len > self.max_line_bytes) {
            return try jsonRpcError(allocator, .null, -32700, "Parse error");
        }

        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
            return try jsonRpcError(allocator, .null, -32700, "Parse error");
        };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |obj| obj,
            else => return try jsonRpcError(allocator, .null, -32600, "Invalid Request"),
        };

        const id = parseId(obj) catch return try jsonRpcError(allocator, .null, -32600, "Invalid Request");

        const jsonrpc = switch (obj.get("jsonrpc") orelse return try jsonRpcError(allocator, id.responseId(), -32600, "Invalid Request")) {
            .string => |value| value,
            else => return try jsonRpcError(allocator, id.responseId(), -32600, "Invalid Request"),
        };
        if (!std.mem.eql(u8, jsonrpc, "2.0")) {
            return try jsonRpcError(allocator, id.responseId(), -32600, "Invalid Request");
        }

        const method = switch (obj.get("method") orelse return try jsonRpcError(allocator, id.responseId(), -32600, "Invalid Request")) {
            .string => |value| value,
            else => return try jsonRpcError(allocator, id.responseId(), -32600, "Invalid Request"),
        };
        if (method.len == 0) {
            return try jsonRpcError(allocator, id.responseId(), -32600, "Invalid Request");
        }

        const params = if (obj.get("params")) |params_value| params: {
            switch (params_value) {
                .object => {},
                else => return try jsonRpcError(allocator, id.responseId(), -32602, "Invalid params"),
            }
            break :params params_value;
        } else null;

        if (!self.authenticated) {
            if (!self.acceptsAuth(obj)) {
                return try jsonRpcError(allocator, id.responseId(), -32000, "Authentication failed");
            }
            self.authenticated = true;
        }

        const result = router.dispatch(method, params);
        if (id.isNotification()) return null;

        return switch (result) {
            .success_json => |json| try jsonRpcResult(allocator, id.responseId(), json),
            .method_not_found => try jsonRpcError(allocator, id.responseId(), -32601, "Method not found"),
            .invalid_params => try jsonRpcError(allocator, id.responseId(), -32602, "Invalid params"),
        };
    }

    fn acceptsAuth(self: Connection, obj: std.json.ObjectMap) bool {
        const auth = obj.get("auth") orelse return false;
        return switch (auth) {
            .string => |value| std.mem.eql(u8, value, self.token),
            else => false,
        };
    }
};

pub const JsonRpcId = union(enum) {
    absent,
    null,
    integer: i64,
    number_string: []const u8,
    string: []const u8,

    fn responseId(self: JsonRpcId) JsonRpcId {
        return switch (self) {
            .absent => .null,
            else => self,
        };
    }

    fn isNotification(self: JsonRpcId) bool {
        return self == .absent;
    }
};

fn parseId(obj: std.json.ObjectMap) !JsonRpcId {
    const id_value = obj.get("id") orelse return .absent;
    return switch (id_value) {
        .null => .null,
        .integer => |value| .{ .integer = value },
        .number_string => |value| .{ .number_string = value },
        .string => |value| .{ .string = value },
        else => error.InvalidId,
    };
}

fn jsonRpcResult(allocator: std.mem.Allocator, id: JsonRpcId, result_json: []const u8) ![]u8 {
    const id_json = try idJson(allocator, id);
    defer allocator.free(id_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"result\":{s},\"id\":{s}}}\n",
        .{ result_json, id_json },
    );
}

fn jsonRpcError(
    allocator: std.mem.Allocator,
    id: JsonRpcId,
    code: i64,
    message: []const u8,
) ![]u8 {
    const id_json = try idJson(allocator, id);
    defer allocator.free(id_json);
    const message_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(message, .{})});
    defer allocator.free(message_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":{},\"message\":{s}}},\"id\":{s}}}\n",
        .{ code, message_json, id_json },
    );
}

fn idJson(allocator: std.mem.Allocator, id: JsonRpcId) ![]u8 {
    return switch (id) {
        .absent, .null => allocator.dupe(u8, "null"),
        .integer => |value| std.fmt.allocPrint(allocator, "{}", .{value}),
        .number_string => |value| allocator.dupe(u8, value),
        .string => |value| std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})}),
    };
}

test "P2.2 JSON-RPC parser returns parse error -32700 for malformed JSON" {
    var router = FakeRouter.init(.success);
    var conn = Connection.init(.{
        .token = "secret-token",
        .max_line_bytes = 4096,
    });

    const response = try conn.handleLine(testing.allocator, "{\"jsonrpc\":\"2.0\",", router.router());
    defer testing.allocator.free(response.?);

    try testing.expectEqual(@as(usize, 0), router.dispatch_count);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Parse error\"},\"id\":null}\n",
        response.?,
    );
}

test "P2.2 JSON-RPC parser returns invalid request -32600 for non-object, batch, bad jsonrpc, and missing method" {
    const cases = [_][]const u8{
        "42",
        "[]",
        "{\"jsonrpc\":\"1.0\",\"method\":\"ping\",\"id\":\"bad-version\",\"auth\":\"secret-token\"}",
        "{\"jsonrpc\":\"2.0\",\"params\":{},\"id\":\"missing-method\",\"auth\":\"secret-token\"}",
    };

    for (cases) |line| {
        var router = FakeRouter.init(.success);
        var conn = Connection.init(.{
            .token = "secret-token",
            .max_line_bytes = 4096,
        });

        const response = try conn.handleLine(testing.allocator, line, router.router());
        defer testing.allocator.free(response.?);

        try testing.expectEqual(@as(usize, 0), router.dispatch_count);
        try expectJsonRpcErrorCode(response.?, -32600);
    }
}

test "P2.2 JSON-RPC parser returns invalid params -32602 for wrong params shape before router dispatch" {
    var router = FakeRouter.init(.success);
    var conn = Connection.init(.{
        .token = "secret-token",
        .max_line_bytes = 4096,
    });

    const response = try conn.handleLine(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"dom.click\",\"params\":[\"#submit\"],\"id\":7,\"auth\":\"secret-token\"}",
        router.router(),
    );
    defer testing.allocator.free(response.?);

    try testing.expectEqual(@as(usize, 0), router.dispatch_count);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"Invalid params\"},\"id\":7}\n",
        response.?,
    );
}

test "P2.2 JSON-RPC parser maps router method not found to -32601" {
    var router = FakeRouter.init(.method_not_found);
    var conn = Connection.init(.{
        .token = "secret-token",
        .max_line_bytes = 4096,
    });

    const response = try conn.handleLine(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"not.real\",\"params\":{},\"id\":\"abc\",\"auth\":\"secret-token\"}",
        router.router(),
    );
    defer testing.allocator.free(response.?);

    try testing.expectEqual(@as(usize, 1), router.dispatch_count);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":\"abc\"}\n",
        response.?,
    );
}

test "P2.2 JSON-RPC auth gate rejects bad token before AutomationRouter.dispatch" {
    var router = FakeRouter.init(.success);
    var conn = Connection.init(.{
        .token = "secret-token",
        .max_line_bytes = 4096,
    });

    const response = try conn.handleLine(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"params\":{},\"id\":1,\"auth\":\"wrong-token\"}",
        router.router(),
    );
    defer testing.allocator.free(response.?);

    try testing.expectEqual(@as(usize, 0), router.dispatch_count);
    try expectJsonRpcErrorCode(response.?, -32000);
    try testing.expect(std.mem.indexOf(u8, response.?, "wrong-token") == null);
    try testing.expect(std.mem.indexOf(u8, response.?, "secret-token") == null);
}

test "P2.2 JSON-RPC requests echo string integer and null ids unchanged and notifications produce no response" {
    const cases = [_]struct {
        id_fragment: []const u8,
        expected: []const u8,
    }{
        .{ .id_fragment = "\"req-1\"", .expected = "{\"jsonrpc\":\"2.0\",\"result\":true,\"id\":\"req-1\"}\n" },
        .{ .id_fragment = "42", .expected = "{\"jsonrpc\":\"2.0\",\"result\":true,\"id\":42}\n" },
        .{ .id_fragment = "null", .expected = "{\"jsonrpc\":\"2.0\",\"result\":true,\"id\":null}\n" },
    };

    for (cases) |case| {
        var router = FakeRouter.init(.success);
        var conn = Connection.init(.{
            .token = "secret-token",
            .max_line_bytes = 4096,
        });
        const line = try std.fmt.allocPrint(
            testing.allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"params\":{{}},\"id\":{s},\"auth\":\"secret-token\"}}",
            .{case.id_fragment},
        );
        defer testing.allocator.free(line);

        const response = try conn.handleLine(testing.allocator, line, router.router());
        defer testing.allocator.free(response.?);

        try testing.expectEqual(@as(usize, 1), router.dispatch_count);
        try testing.expectEqualStrings(case.expected, response.?);
    }

    var router = FakeRouter.init(.success);
    var conn = Connection.init(.{
        .token = "secret-token",
        .max_line_bytes = 4096,
    });

    const response = try conn.handleLine(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"params\":{},\"auth\":\"secret-token\"}",
        router.router(),
    );

    try testing.expectEqual(@as(usize, 1), router.dispatch_count);
    try testing.expect(response == null);
}

test "P2.2 JSON-RPC auth state permits later frames without raw token and oversized lines never dispatch" {
    var router = FakeRouter.init(.success);
    var conn = Connection.init(.{
        .token = "secret-token",
        .max_line_bytes = 80,
    });

    const first = try conn.handleLine(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"params\":{},\"id\":1,\"auth\":\"secret-token\"}",
        router.router(),
    );
    defer testing.allocator.free(first.?);
    try testing.expectEqual(@as(usize, 1), router.dispatch_count);

    const second = try conn.handleLine(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"params\":{},\"id\":2}",
        router.router(),
    );
    defer testing.allocator.free(second.?);
    try testing.expectEqual(@as(usize, 2), router.dispatch_count);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":true,\"id\":2}\n", second.?);

    const oversized = try std.mem.concat(testing.allocator, u8, &.{
        "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"params\":{},\"id\":3,\"padding\":\"",
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
        "\"}",
    });
    defer testing.allocator.free(oversized);

    const third = try conn.handleLine(testing.allocator, oversized, router.router());
    defer testing.allocator.free(third.?);

    try testing.expectEqual(@as(usize, 2), router.dispatch_count);
    try expectJsonRpcErrorCode(third.?, -32700);
}

fn expectJsonRpcErrorCode(response: []const u8, expected_code: i64) !void {
    const expected_fragment = try std.fmt.allocPrint(testing.allocator, "\"code\":{}", .{expected_code});
    defer testing.allocator.free(expected_fragment);
    try testing.expect(std.mem.indexOf(u8, response, expected_fragment) != null);
}

const FakeRouter = struct {
    result: FakeRouterResult,
    dispatch_count: usize = 0,

    fn init(result: FakeRouterResult) FakeRouter {
        return .{ .result = result };
    }

    fn router(self: *FakeRouter) Router {
        return .{
            .context = self,
            .dispatchFn = dispatch,
        };
    }

    fn dispatch(context: *anyopaque, method: []const u8, params: ?std.json.Value) RouterResult {
        _ = method;
        _ = params;
        const self: *FakeRouter = @ptrCast(@alignCast(context));
        self.dispatch_count += 1;
        return switch (self.result) {
            .success => .{ .success_json = "true" },
            .method_not_found => .method_not_found,
            .invalid_params => .invalid_params,
        };
    }
};

const FakeRouterResult = enum {
    success,
    method_not_found,
    invalid_params,
};
