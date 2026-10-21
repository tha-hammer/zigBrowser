//! S8a red (chat-drawer plan rev 16.20.43, "S8 in detail" decision 2, phase A): `options.expect`
//! on the acting verbs is checked inside the real run's own FIFO ticket, before any page input.
//!
//! Wire: `{..., "window_id": "window-<n>", "options": {"expect": {"origin": "<scheme://host[:port]>",
//! "load_serial": <u64>}}}` on dom.click, dom.fill, dom.type, dom.press, dom.selectOption,
//! page.navigate and page.reload. After the ticket, the engine reads the bound window's own
//! page.list entry:
//! - a dialog open: -32013 dialog_open;
//! - its web process ended (`crashed`): -32015 expectation_mismatch, reason `crashed`;
//! - another origin: -32015, reason `origin_changed`;
//! - another load_serial: -32015, reason `load_serial_changed`;
//! and in each case nothing reaches the page (no eval, navigate, reload or native input).
//! Refused at parse (-32602, nothing runs): `expect` without `window_id`, with `options.input`
//! native or `options.humanize`, on a verb that does not act (dom.getText, dom.hover), or
//! malformed (a missing or mistyped field, an unknown key).
//! (-32014 recovering is the queue's, before the ticket; it is covered by the recover tests.)
//!
//! Driven through `AutomationApiServer.callInProcess` (the broker's entry): the real router,
//! queue and engine, and a fake two-window PagePort.

const std = @import("std");
const automation_server = @import("automation_server");
const page_port = automation_server.automation.page_port;

const testing = std.testing;
const gpa = testing.allocator;

/// Two windows: 1 the primary fixture page, 2 a shop page. Every port reads the same list.
const World = struct {
    ports: [2]Page = .{ .{ .id = 1 }, .{ .id = 2 } },
    urls: [2][]const u8 = .{ "file:///fixture/index.html", "https://shop.example/item/7" },
    load_serials: [2]std.atomic.Value(u64) = .{ .init(3), .init(4) },
    dialog_open: [2]bool = .{ false, false },
    crashed: [2]bool = .{ false, false },
    list_calls: std.atomic.Value(u32) = .init(0),

    fn init(self: *World) void {
        for (&self.ports) |*p| p.world = self;
    }

    fn ops(self: *const World) u32 {
        var n: u32 = 0;
        for (&self.ports) |*p| n += p.ops();
        return n;
    }
};

const Page = struct {
    id: page_port.WindowId,
    world: *World = undefined,
    evals: std.atomic.Value(u32) = .init(0),
    navigates: std.atomic.Value(u32) = .init(0),
    reloads: std.atomic.Value(u32) = .init(0),
    natives: std.atomic.Value(u32) = .init(0),
    hold: std.atomic.Value(bool) = .init(false),
    held: std.atomic.Value(bool) = .init(false),

    fn ops(self: *const Page) u32 {
        return self.evals.load(.acquire) + self.navigates.load(.acquire) + self.reloads.load(.acquire) + self.natives.load(.acquire);
    }

    fn port(self: *Page) page_port.PagePort {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn from(ptr: *anyopaque) *Page {
        return @ptrCast(@alignCast(ptr));
    }

    const vtable = page_port.PagePort.VTable{
        .evalJson = evalJson,
        .navigate = navigate,
        .reload = reload,
        .url = url,
        .title = title,
        .listWindows = listWindows,
        .forWindow = forWindow,
        .nativeClick = nativeClick,
        .nativeKey = nativeKey,
        .nativeText = nativeText,
        .nativeMove = nativeMove,
    };

    fn evalJson(ptr: *anyopaque, alloc: std.mem.Allocator, _: page_port.World, _: []const u8, arg: []const u8, _: u64) page_port.PortError![]u8 {
        const self = from(ptr);
        while (self.hold.load(.acquire)) {
            self.held.store(true, .release);
            testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        _ = self.evals.fetchAdd(1, .acq_rel);
        // Native input first locates its target; answer with a point.
        if (std.mem.indexOf(u8, arg, "\"op\":\"locate\"") != null) {
            return alloc.dupe(u8, "{\"ok\":true,\"value\":{\"x\":10,\"y\":10,\"document\":\"d1\"}}");
        }
        return alloc.dupe(u8, "{\"ok\":true,\"value\":{\"ok\":true}}");
    }
    fn navigate(ptr: *anyopaque, _: []const u8, _: u64) page_port.PortError!void {
        _ = from(ptr).navigates.fetchAdd(1, .acq_rel);
    }
    fn reload(ptr: *anyopaque, _: u64) page_port.PortError!void {
        _ = from(ptr).reloads.fetchAdd(1, .acq_rel);
    }
    fn url(ptr: *anyopaque, alloc: std.mem.Allocator, _: u64) page_port.PortError![]u8 {
        const self = from(ptr);
        return alloc.dupe(u8, self.world.urls[self.id - 1]);
    }
    fn title(_: *anyopaque, alloc: std.mem.Allocator, _: u64) page_port.PortError![]u8 {
        return alloc.dupe(u8, "Fixture");
    }
    fn listWindows(ptr: *anyopaque, alloc: std.mem.Allocator, _: u64) page_port.PortError![]page_port.WindowInfo {
        const world = from(ptr).world;
        _ = world.list_calls.fetchAdd(1, .acq_rel);
        var list: std.ArrayListUnmanaged(page_port.WindowInfo) = .empty;
        errdefer {
            for (list.items) |w| {
                alloc.free(w.url);
                alloc.free(w.title);
            }
            list.deinit(alloc);
        }
        for (0..2) |i| {
            try list.append(alloc, .{
                .id = @intCast(i + 1),
                .url = try alloc.dupe(u8, world.urls[i]),
                .title = try alloc.dupe(u8, "Fixture"),
                .primary = i == 0,
                .opener = if (i == 0) null else 1,
                .terminated = if (world.crashed[i]) .crashed else null,
                .dialog_open = world.dialog_open[i],
                .load_serial = world.load_serials[i].load(.acquire),
            });
        }
        return list.toOwnedSlice(alloc);
    }
    fn forWindow(ptr: *anyopaque, id: page_port.WindowId) page_port.PortError!page_port.PagePort {
        const world = from(ptr).world;
        if (id < 1 or id > world.ports.len) return error.NoPage;
        return world.ports[id - 1].port();
    }
    fn nativeClick(ptr: *anyopaque, _: f64, _: f64, _: ?[]const u8, _: u64) page_port.PortError!void {
        _ = from(ptr).natives.fetchAdd(1, .acq_rel);
    }
    fn nativeMove(ptr: *anyopaque, _: f64, _: f64, _: ?[]const u8, _: u64) page_port.PortError!void {
        _ = from(ptr).natives.fetchAdd(1, .acq_rel);
    }
    fn nativeKey(ptr: *anyopaque, _: []const u8, _: u8, _: ?[]const u8, _: u64) page_port.PortError!void {
        _ = from(ptr).natives.fetchAdd(1, .acq_rel);
    }
    fn nativeText(ptr: *anyopaque, text: []const u8, _: ?[]const u8, _: u64, sent: *usize) page_port.PortError!void {
        _ = from(ptr).natives.fetchAdd(1, .acq_rel);
        sent.* = text.len;
    }
};

const Harness = struct {
    world: World = .{},
    server: automation_server.AutomationApiServer,

    fn start() !*Harness {
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);
        self.world = .{};
        self.world.init();
        self.server = try automation_server.AutomationApiServer.init(gpa, testing.io, .{
            .enabled = true,
            .socket_path = "",
            .token = "",
            .page_port = self.world.ports[0].port(),
            .pacing_state_path = "",
        });
        try self.server.startCore();
        return self;
    }

    fn deinit(self: *Harness) void {
        self.server.deinit();
        gpa.destroy(self);
    }

    fn call(self: *Harness, method: []const u8, params: []const u8) !Reply {
        const raw = try self.server.callInProcess(gpa, method, params);
        defer gpa.free(raw);
        return Reply.of(raw);
    }
};

const Reply = struct {
    code: ?i64 = null,
    reason_buf: [48]u8 = undefined,
    reason_len: usize = 0,

    fn reason(self: *const Reply) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }

    fn of(raw: []const u8) !Reply {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
        defer parsed.deinit();
        var out = Reply{};
        const err = parsed.value.object.get("error") orelse return out;
        out.code = err.object.get("code").?.integer;
        if (err.object.get("data")) |data| if (data == .object) if (data.object.get("reason")) |r| if (r == .string) {
            out.reason_len = @min(r.string.len, out.reason_buf.len);
            @memcpy(out.reason_buf[0..out.reason_len], r.string[0..out.reason_len]);
        };
        return out;
    }
};

const expect_ok = "\"options\":{\"expect\":{\"origin\":\"https://shop.example\",\"load_serial\":4}}";

/// The acting verbs, each with a matching expectation on window 2.
const acting = [_]struct { method: []const u8, args: []const u8 }{
    .{ .method = "dom.click", .args = "\"selector\":\"css=#buy\"" },
    .{ .method = "dom.fill", .args = "\"selector\":\"css=#q\",\"value\":\"v\"" },
    .{ .method = "dom.type", .args = "\"selector\":\"css=#q\",\"text\":\"hi\"" },
    .{ .method = "dom.press", .args = "\"selector\":\"css=#q\",\"key\":\"Enter\"" },
    .{ .method = "dom.selectOption", .args = "\"selector\":\"css=#s\",\"value\":\"a\"" },
    .{ .method = "page.navigate", .args = "\"url\":\"https://shop.example/next\"" },
    .{ .method = "page.reload", .args = "" },
};

fn paramsFor(buf: []u8, args: []const u8, window: []const u8, expect: []const u8) ![]const u8 {
    const sep = if (args.len > 0) "," else "";
    return std.fmt.bufPrint(buf, "{{{s}{s}\"window_id\":\"{s}\",{s}}}", .{ args, sep, window, expect });
}

test "phase A: a matching expectation acts once on its own window" {
    for (acting) |verb| {
        const h = try Harness.start();
        defer h.deinit();
        var buf: [512]u8 = undefined;
        const reply = try h.call(verb.method, try paramsFor(&buf, verb.args, "window-2", expect_ok));
        try testing.expectEqual(@as(?i64, null), reply.code);
        try testing.expect(h.world.ports[1].ops() >= 1);
        try testing.expectEqual(@as(u32, 0), h.world.ports[0].ops());
        // The check read the bound window's entry.
        try testing.expect(h.world.list_calls.load(.acquire) >= 1);
    }
}

const Change = enum { origin, load_serial, dialog, crashed };

fn mismatch(change: Change, want_code: i64, want_reason: []const u8) !void {
    for (acting) |verb| {
        const h = try Harness.start();
        defer h.deinit();
        switch (change) {
            .origin => h.world.urls[1] = "https://other.example/item/7",
            .load_serial => h.world.load_serials[1].store(5, .release),
            .dialog => h.world.dialog_open[1] = true,
            .crashed => h.world.crashed[1] = true,
        }
        var buf: [512]u8 = undefined;
        const reply = try h.call(verb.method, try paramsFor(&buf, verb.args, "window-2", expect_ok));
        testing.expectEqual(@as(?i64, want_code), reply.code) catch |e| {
            std.debug.print("{s} {s}: code {?d}, reason {s}\n", .{ verb.method, @tagName(change), reply.code, reply.reason() });
            return e;
        };
        if (want_reason.len > 0) try testing.expectEqualStrings(want_reason, reply.reason());
        try testing.expectEqual(@as(u32, 0), h.world.ops());
    }
}

test "phase A: another origin is -32015 origin_changed and nothing reaches the page" {
    try mismatch(.origin, -32015, "origin_changed");
}

test "phase A: another load_serial is -32015 load_serial_changed and nothing reaches the page" {
    try mismatch(.load_serial, -32015, "load_serial_changed");
}

test "phase A: an open dialog is -32013 and nothing reaches the page" {
    try mismatch(.dialog, -32013, "");
}

test "phase A: a crashed window is -32015 crashed and nothing reaches the page" {
    try mismatch(.crashed, -32015, "crashed");
}

test "phase A is inside the ticket: a navigation while the run waits in line is seen" {
    const h = try Harness.start();
    defer h.deinit();
    const second = &h.world.ports[1];
    second.hold.store(true, .release);

    const Call = struct {
        fn run(harness: *Harness, method: []const u8, p: []const u8, out: *Reply) void {
            out.* = harness.call(method, p) catch Reply{ .code = -1 };
        }
    };
    // The first command (no expectation) holds window 2's line inside its page call.
    var first_reply: Reply = .{};
    const first = try std.Thread.spawn(.{}, Call.run, .{ h, "dom.click", "{\"selector\":\"css=#a\",\"window_id\":\"window-2\"}", &first_reply });
    while (!second.held.load(.acquire)) testing.io.sleep(.fromMilliseconds(1), .awake) catch {};

    // The approved run queues behind it, with the card's serial 4.
    var buf: [512]u8 = undefined;
    const approved = try paramsFor(&buf, "\"selector\":\"css=#buy\"", "window-2", expect_ok);
    var approved_reply: Reply = .{};
    const queued = try std.Thread.spawn(.{}, Call.run, .{ h, "dom.click", approved, &approved_reply });
    var waited: u32 = 0;
    while (h.server.queue.pendingCount("page-2") < 1 and waited < 5000) : (waited += 1) testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    try testing.expectEqual(@as(usize, 1), h.server.queue.pendingCount("page-2"));

    // A navigation commits while it waits; then the first command ends.
    h.world.load_serials[1].store(5, .release);
    second.hold.store(false, .release);
    first.join();
    queued.join();

    try testing.expectEqual(@as(?i64, null), first_reply.code);
    try testing.expectEqual(@as(?i64, -32015), approved_reply.code);
    try testing.expectEqualStrings("load_serial_changed", approved_reply.reason());
    // Only the first command's page call: the approved click sent nothing.
    try testing.expectEqual(@as(u32, 1), second.evals.load(.acquire));
}

const refused = [_]struct { what: []const u8, method: []const u8, params: []const u8 }{
    .{ .what = "no window_id", .method = "dom.click", .params = "{\"selector\":\"css=#buy\"," ++ expect_ok ++ "}" },
    .{ .what = "native input", .method = "dom.click", .params = "{\"selector\":\"css=#buy\",\"window_id\":\"window-2\",\"options\":{\"input\":\"native\",\"expect\":{\"origin\":\"https://shop.example\",\"load_serial\":4}}}" },
    .{ .what = "humanize", .method = "dom.type", .params = "{\"selector\":\"css=#q\",\"text\":\"hi\",\"window_id\":\"window-2\",\"options\":{\"input\":\"native\",\"humanize\":true,\"expect\":{\"origin\":\"https://shop.example\",\"load_serial\":4}}}" },
    .{ .what = "a verb that does not act (getText)", .method = "dom.getText", .params = "{\"selector\":\"css=#q\",\"window_id\":\"window-2\"," ++ expect_ok ++ "}" },
    .{ .what = "a verb that does not act (hover)", .method = "dom.hover", .params = "{\"selector\":\"css=#q\",\"window_id\":\"window-2\"," ++ expect_ok ++ "}" },
    .{ .what = "load_serial as a string", .method = "dom.click", .params = "{\"selector\":\"css=#buy\",\"window_id\":\"window-2\",\"options\":{\"expect\":{\"origin\":\"https://shop.example\",\"load_serial\":\"4\"}}}" },
    .{ .what = "a negative load_serial", .method = "dom.click", .params = "{\"selector\":\"css=#buy\",\"window_id\":\"window-2\",\"options\":{\"expect\":{\"origin\":\"https://shop.example\",\"load_serial\":-1}}}" },
    .{ .what = "no origin", .method = "dom.click", .params = "{\"selector\":\"css=#buy\",\"window_id\":\"window-2\",\"options\":{\"expect\":{\"load_serial\":4}}}" },
    .{ .what = "no load_serial", .method = "page.reload", .params = "{\"window_id\":\"window-2\",\"options\":{\"expect\":{\"origin\":\"https://shop.example\"}}}" },
    .{ .what = "an unknown key", .method = "dom.click", .params = "{\"selector\":\"css=#buy\",\"window_id\":\"window-2\",\"options\":{\"expect\":{\"origin\":\"https://shop.example\",\"load_serial\":4,\"approved\":true}}}" },
    .{ .what = "expect not an object", .method = "page.navigate", .params = "{\"url\":\"https://shop.example/next\",\"window_id\":\"window-2\",\"options\":{\"expect\":true}}" },
};

test "phase A: a malformed or misplaced expectation is -32602 and nothing runs" {
    for (refused) |case| {
        const h = try Harness.start();
        defer h.deinit();
        const reply = try h.call(case.method, case.params);
        testing.expectEqual(@as(?i64, -32602), reply.code) catch |e| {
            std.debug.print("{s}: code {?d}, reason {s}\n", .{ case.what, reply.code, reply.reason() });
            return e;
        };
        try testing.expectEqual(@as(u32, 0), h.world.ops());
    }
}
