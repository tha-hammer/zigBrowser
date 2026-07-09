const std = @import("std");

const testing = std.testing;

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const max_single_byte_payload_len = 125;
const text_frame_fin_opcode = 0x81;

pub fn secWebSocketAccept(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ key, websocket_guid });
    defer allocator.free(combined);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(combined, &digest, .{});

    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(digest.len));
    _ = std.base64.standard.Encoder.encode(encoded, &digest);
    return encoded;
}

pub const EventNotification = struct {
    method: []const u8,
    params_json: ?[]const u8 = null,
};

pub fn eventNotificationJson(allocator: std.mem.Allocator, notification: EventNotification) ![]u8 {
    const method_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(notification.method, .{})});
    defer allocator.free(method_json);

    if (notification.params_json) |params| {
        return std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":{s},\"params\":{s}}}",
            .{ method_json, params },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":{s}}}",
        .{method_json},
    );
}

pub fn writeTextFrame(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    if (payload.len > max_single_byte_payload_len) return error.PayloadTooLarge;
    const frame = try allocator.alloc(u8, payload.len + 2);
    frame[0] = text_frame_fin_opcode;
    frame[1] = @intCast(payload.len);
    @memcpy(frame[2..], payload);
    return frame;
}

pub const DeliveryStatus = enum {
    queued,
    dropped_slow_subscriber,
};

pub const Event = struct {
    id: []const u8,
    method: []const u8,
};

pub const SubscriberQueue = struct {
    allocator: std.mem.Allocator,
    entries: []Event,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !SubscriberQueue {
        return .{
            .allocator = allocator,
            .entries = try allocator.alloc(Event, capacity),
        };
    }

    pub fn deinit(self: *SubscriberQueue) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn push(self: *SubscriberQueue, event: Event) !DeliveryStatus {
        if (self.count == self.entries.len) return .dropped_slow_subscriber;
        self.entries[self.count] = event;
        self.count += 1;
        return .queued;
    }

    pub fn pop(self: *SubscriberQueue) ?Event {
        if (self.count == 0) return null;
        const event = self.entries[0];
        std.mem.copyForwards(Event, self.entries[0 .. self.count - 1], self.entries[1..self.count]);
        self.count -= 1;
        return event;
    }

    pub fn depth(self: SubscriberQueue) usize {
        return self.count;
    }
};

test "P2.4 websocket upgrade computes RFC Sec-WebSocket-Accept" {
    const accept = try secWebSocketAccept(testing.allocator, "dGhlIHNhbXBsZSBub25jZQ==");
    defer testing.allocator.free(accept);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "P2.4 websocket text frame writes JSON-RPC notification without id" {
    const payload = try eventNotificationJson(testing.allocator, .{
        .method = "event.navigation",
        .params_json = "{\"page_id\":\"page-1\"}",
    });
    defer testing.allocator.free(payload);

    try testing.expect(std.mem.indexOf(u8, payload, "\"id\"") == null);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"event.navigation\",\"params\":{\"page_id\":\"page-1\"}}",
        payload,
    );

    const frame = try writeTextFrame(testing.allocator, payload);
    defer testing.allocator.free(frame);

    try testing.expectEqual(@as(u8, 0x81), frame[0]);
    try testing.expectEqual(@as(u8, @intCast(payload.len)), frame[1]);
    try testing.expectEqualStrings(payload, frame[2..]);
}

test "P2.4 bounded subscriber queue reports dropped slow-client events" {
    var queue = try SubscriberQueue.init(testing.allocator, 2);
    defer queue.deinit();

    try testing.expectEqual(DeliveryStatus.queued, try queue.push(.{ .id = "event-1", .method = "event.navigation" }));
    try testing.expectEqual(DeliveryStatus.queued, try queue.push(.{ .id = "event-2", .method = "event.network" }));
    try testing.expectEqual(DeliveryStatus.dropped_slow_subscriber, try queue.push(.{ .id = "event-3", .method = "event.console" }));

    try testing.expectEqual(@as(usize, 2), queue.depth());
    try testing.expectEqualStrings("event-1", queue.pop().?.id);
    try testing.expectEqualStrings("event-2", queue.pop().?.id);
    try testing.expect(queue.pop() == null);
}
