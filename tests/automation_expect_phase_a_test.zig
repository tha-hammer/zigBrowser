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
const engine = automation_server.automation.engine;
const fake = @import("automation/expect_fake.zig");
const Harness = fake.Harness;
const Reply = fake.Reply;
const Page = fake.Page;
const expect_ok = fake.expect_ok;
const acting = fake.acting;
const paramsFor = fake.paramsFor;

const testing = std.testing;
const gpa = testing.allocator;

/// What one approved run of each acting verb sends to its page: exactly one operation, and
/// nothing of any other kind (RoseCat 0c1132b #3: a duplicate dispatch must fail).
const once = [_]struct { evals: u32 = 0, navigates: u32 = 0, reloads: u32 = 0 }{
    .{ .evals = 1 }, // dom.click
    .{ .evals = 1 }, // dom.fill
    .{ .evals = 1 }, // dom.type
    .{ .evals = 1 }, // dom.press
    .{ .evals = 1 }, // dom.selectOption
    .{ .navigates = 1 }, // page.navigate
    .{ .reloads = 1 }, // page.reload
};

test "phase A: a matching expectation acts exactly once on its own window" {
    for (acting, once) |verb, want| {
        const h = try Harness.start();
        defer h.deinit();
        var buf: [512]u8 = undefined;
        const reply = try h.call(verb.method, try paramsFor(&buf, verb.args, "window-2", expect_ok));
        try testing.expectEqual(@as(?i64, null), reply.code);
        const page = &h.world.ports[1];
        testing.expectEqual(want.evals, page.evals.load(.acquire)) catch |e| return report(verb.method, e);
        testing.expectEqual(want.navigates, page.navigates.load(.acquire)) catch |e| return report(verb.method, e);
        testing.expectEqual(want.reloads, page.reloads.load(.acquire)) catch |e| return report(verb.method, e);
        try testing.expectEqual(@as(u32, 0), page.natives.load(.acquire));
        try testing.expectEqual(@as(u32, 0), h.world.ports[0].ops());
        // The check read the bound window's entry.
        try testing.expect(h.world.list_calls.load(.acquire) >= 1);
    }
}

fn report(method: []const u8, err: anyerror) anyerror {
    std.debug.print("{s}: wrong operation count\n", .{method});
    return err;
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
    // Runs before h.deinit on every path, a failed wait included: the hold is cleared and each
    // thread is joined exactly once (RoseCat 7012).
    var threads = Threads{ .hold = &second.hold };
    defer threads.joinAll();

    // The first command (no expectation) holds window 2's line inside its page call.
    var first_reply: Reply = .{};
    threads.list[0] = try std.Thread.spawn(.{}, Call.run, .{ h, "dom.click", "{\"selector\":\"css=#a\",\"window_id\":\"window-2\"}", &first_reply });
    try testing.expect(waitUntil(Held{ .page = second }, wait_ms));

    // The approved run queues behind it, with the card's serial 4.
    var buf: [512]u8 = undefined;
    const approved = try paramsFor(&buf, "\"selector\":\"css=#buy\"", "window-2", expect_ok);
    var approved_reply: Reply = .{};
    threads.list[1] = try std.Thread.spawn(.{}, Call.run, .{ h, "dom.click", approved, &approved_reply });
    try testing.expect(waitUntil(Pending{ .harness = h, .page_id = "page-2" }, wait_ms));

    // A navigation commits while it waits; then the first command ends.
    h.world.load_serials[1].store(5, .release);
    threads.joinAll();

    try testing.expectEqual(@as(?i64, null), first_reply.code);
    try testing.expectEqual(@as(?i64, -32015), approved_reply.code);
    try testing.expectEqualStrings("load_serial_changed", approved_reply.reason());
    // Only the first command's page call: the approved click sent nothing.
    try testing.expectEqual(@as(u32, 1), second.evals.load(.acquire));
}

const wait_ms: u32 = 5000;

const Call = struct {
    fn run(harness: *Harness, method: []const u8, p: []const u8, out: *Reply) void {
        out.* = harness.call(method, p) catch Reply{ .code = -1 };
    }
};

/// The ticket test's threads: `joinAll` clears the hold, then joins each started thread once.
const Threads = struct {
    hold: *std.atomic.Value(bool),
    list: [2]?std.Thread = .{ null, null },

    fn joinAll(self: *Threads) void {
        self.hold.store(false, .release);
        for (&self.list) |*slot| if (slot.*) |thread| {
            thread.join();
            slot.* = null;
        };
    }
};

const Held = struct {
    page: *const Page,
    fn done(self: Held) bool {
        return self.page.held.load(.acquire);
    }
};

const Pending = struct {
    harness: *Harness,
    page_id: []const u8,
    fn done(self: Pending) bool {
        return self.harness.server.queue.pendingCount(self.page_id) == 1;
    }
};

/// Polls `condition.done()` every millisecond for at most `max_ms`.
fn waitUntil(condition: anytype, max_ms: u32) bool {
    var waited: u32 = 0;
    while (!condition.done()) : (waited += 1) {
        if (waited >= max_ms) return false;
        testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return true;
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

// Two states at once: the first in the plan's order wins (RoseCat 0c1132b SHOULD).
test "phase A: precedence is dialog, then crashed, then origin, then load_serial" {
    const cases = [_]struct { dialog: bool = false, crashed: bool = false, origin: bool = false, serial: bool = false, code: i64, reason: []const u8 }{
        .{ .dialog = true, .crashed = true, .code = -32013, .reason = "" },
        .{ .crashed = true, .origin = true, .code = -32015, .reason = "crashed" },
        .{ .origin = true, .serial = true, .code = -32015, .reason = "origin_changed" },
    };
    for (cases) |case| {
        const h = try Harness.start();
        defer h.deinit();
        h.world.dialog_open[1] = case.dialog;
        h.world.crashed[1] = case.crashed;
        if (case.origin) h.world.urls[1] = "https://other.example/item/7";
        if (case.serial) h.world.load_serials[1].store(5, .release);
        var buf: [512]u8 = undefined;
        const reply = try h.call("dom.click", try paramsFor(&buf, "\"selector\":\"css=#buy\"", "window-2", expect_ok));
        try testing.expectEqual(@as(?i64, case.code), reply.code);
        try testing.expectEqualStrings(case.reason, reply.reason());
        try testing.expectEqual(@as(u32, 0), h.world.ops());
    }
}

test "originOf: the origin a card binds" {
    const cases = [_][2][]const u8{
        .{ "https://shop.example/item/7?q=1#f", "https://shop.example" },
        .{ "HTTPS://Shop.Example/Item", "https://shop.example" },
        .{ "http://127.0.0.1:8123/x", "http://127.0.0.1:8123" },
        .{ "https://user:pw@shop.example:8443/x", "https://shop.example:8443" },
        .{ "https://shop.example", "https://shop.example" },
        .{ "https://shop.example?x", "https://shop.example" },
        .{ "http://[::1]:8080/p", "http://[::1]:8080" },
        .{ "file:///fixture/index.html", "file://" },
        .{ "about:blank", "null" },
        .{ "data:text/html,hi", "null" },
        .{ "", "null" },
        .{ "no-colon", "null" },
    };
    for (cases) |case| {
        const got = try engine.originOf(gpa, case[0]);
        defer gpa.free(got);
        testing.expectEqualStrings(case[1], got) catch |e| {
            std.debug.print("originOf({s})\n", .{case[0]});
            return e;
        };
    }
}
