//! S8a red (chat-drawer plan decision 13: "If the opener leads to a new document … the engine
//! runs phase C again for it"): an approved profile-target message or DM whose Message click
//! opens the thread as a new page continues there, and only there.
//! - After the opener, the first committed new document gets phase C again: it is on the
//!   approved origin and its path is the platform's thread path (`/direct/t/` on Instagram,
//!   `/messaging/thread/` on LinkedIn), and its document token is captured; the flow then types
//!   and sends in it. Anything else is -32015 `thread_url_changed`, with nothing further sent.
//! - The allowance is one navigation, right after the opener: a second new document is
//!   `load_serial_changed` as before, and a conversation message (no opener) has none.
//! - The allowance follows only a navigation the opener itself started (automation.js's
//!   `leaving` right after the click): a navigation the opener did not start that lands before
//!   the next action is `load_serial_changed` (RoseCat 7504 #1).
//! - Every action of an approved run, on every mutation verb and every acting flow (click, fill,
//!   type, press, selectOption), names the document phase C captured (RoseCat 7504 #2); after
//!   the thread page's capture the recipient mark is still there.
//! - Every guarded action of an approved run names the document phase C captured
//!   (`guard.document`, automation.js's token), so a step whose retries cross into a new
//!   document stops there (`document_changed`) instead of acting in a page no phase checked. On
//!   the real binary that retry crossing happened (tests/e2e/automation_thread_document_test.py).

const std = @import("std");
const automation = @import("automation");
const flow_fake = @import("automation/flow_fake.zig");

const router = automation.router;
const x_routes = automation.x_routes;
const engine = automation.engine;
const page_port = automation.page_port;
const fakes = @import("automation/fake_page_port.zig");
const Harness = flow_fake.Harness;
const realClicks = flow_fake.realClicks;
const countOps = flow_fake.countOps;
const expectRefused = flow_fake.expectRefused;

const testing = std.testing;
const gpa = testing.allocator;

const ig = "https://www.instagram.com";
const li = "https://www.linkedin.com";
const dm_approved = "{\"username\":\"ada\",\"text\":\"Hi\",\"options\":{\"expect\":{\"origin\":\"" ++ ig ++ "\",\"load_serial\":3,\"url\":\"" ++ ig ++ "/ada/\"}}}";
const li_profile_approved = "{\"profileUrl\":\"" ++ li ++ "/in/carol/\",\"text\":\"Hi\",\"options\":{\"expect\":{\"origin\":\"" ++ li ++ "\",\"load_serial\":3,\"url\":\"" ++ li ++ "/in/carol/\"}}}";
const conversation = li ++ "/messaging/thread/7/";
const li_conversation_approved = "{\"conversationUrl\":\"" ++ conversation ++ "\",\"text\":\"Hi\",\"options\":{\"expect\":{\"origin\":\"" ++ li ++ "\",\"load_serial\":3,\"url\":\"" ++ conversation ++ "\",\"recipient\":\"carol\"}}}";

/// Selector fragments that only the opener's, and the message box's, commands hold.
const ig_opener = "//header//*[self::button";
const ig_box = "css=div[aria-label";
const li_opener = "Primary content";
const li_box = "msg-form__contenteditable";

fn initInstagram(h: *Harness) void {
    h.init(ig ++ "/");
}

fn initLinkedIn(h: *Harness) void {
    h.init(li ++ "/feed/");
    h.unverified_actions = true;
    h.fake.current_title = "Carol Example | LinkedIn";
}

/// `guard.document` of each real page action (click, fill, type that is not a trial), in order.
fn actionDocuments(arena: std.mem.Allocator, h: *Harness) ![]?[]const u8 {
    var out: std.ArrayListUnmanaged(?[]const u8) = .empty;
    for (h.fake.eval_calls.items) |call| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, call.arg, .{}) catch continue;
        if (parsed != .object) continue;
        const op = switch (parsed.object.get("op") orelse continue) {
            .string => |o| o,
            else => continue,
        };
        if (!inList(op, &.{ "click", "fill", "type", "press", "selectOption" })) continue;
        if (std.mem.indexOf(u8, call.arg, "\"trial\":true") != null) continue;
        const document: ?[]const u8 = blk: {
            const guard = parsed.object.get("guard") orelse break :blk null;
            if (guard != .object) break :blk null;
            const d = guard.object.get("document") orelse break :blk null;
            break :blk if (d == .string) d.string else null;
        };
        try out.append(arena, document);
    }
    return out.items;
}

fn inList(item: []const u8, list: []const []const u8) bool {
    for (list) |entry| if (std.mem.eql(u8, entry, item)) return true;
    return false;
}

fn runOk(h: *Harness, method: []const u8, params: []const u8) !void {
    var outcome = try h.call(method, params);
    defer outcome.deinit(gpa);
    if (outcome != .result) {
        std.debug.print("{s}: failure {d} {s}\n", .{ method, outcome.failure.code, outcome.failure.data_json orelse "" });
        return error.TestUnexpectedResult;
    }
}

test "an Instagram thread that opens as a new page on the thread path: phase C again, then typed and sent there" {
    var h: Harness = undefined;
    initInstagram(&h);
    defer h.deinit();
    h.windows.click_navigates = .{ .match = ig_opener, .url = ig ++ "/direct/t/42/" };
    try runOk(&h, "instagram.dm", dm_approved);
    try testing.expectEqual(@as(usize, 1), h.fake.navigate_calls.items.len);
    // The opener, the message box, Send; and the text typed once.
    try testing.expectEqual(@as(usize, 3), realClicks(&h.fake));
    try testing.expectEqual(@as(usize, 1), countOps(&h.fake, "type"));
    // Every step after the opener ran in the thread's own document (phase C captured doc-1).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const docs = try actionDocuments(arena.allocator(), &h);
    for (docs[1..]) |d| try testing.expectEqualStrings("doc-1", d orelse return error.TestExpectedDocument);
}

test "a LinkedIn profile message's thread that opens as a new page on /messaging/thread/ continues there" {
    var h: Harness = undefined;
    initLinkedIn(&h);
    defer h.deinit();
    h.windows.click_navigates = .{ .match = li_opener, .url = li ++ "/messaging/thread/9/" };
    try runOk(&h, "linkedin.message", li_profile_approved);
    try testing.expectEqual(@as(usize, 1), countOps(&h.fake, "type"));
    try testing.expectEqual(@as(usize, 3), realClicks(&h.fake));
}

test "a new page after the opener that is not the platform's thread on the approved origin: thread_url_changed, nothing further" {
    const rows = [_]struct { what: []const u8, url: []const u8 }{
        .{ .what = "another profile", .url = ig ++ "/mallory/" },
        .{ .what = "another origin's thread path", .url = "https://elsewhere.example/direct/t/42/" },
        .{ .what = "the other platform's thread path", .url = ig ++ "/messaging/thread/42/" },
        .{ .what = "a path that only starts like the thread's", .url = ig ++ "/direct/tx/42/" },
    };
    for (rows) |row| {
        var h: Harness = undefined;
        initInstagram(&h);
        defer h.deinit();
        h.windows.click_navigates = .{ .match = ig_opener, .url = row.url };
        var outcome = try h.call("instagram.dm", dm_approved);
        defer outcome.deinit(gpa);
        expectRefused(outcome, -32015, "thread_url_changed") catch |e| {
            std.debug.print("{s}\n", .{row.what});
            return e;
        };
        // Only the opener; no box click, no typing, no Send.
        try testing.expectEqual(@as(usize, 1), realClicks(&h.fake));
        try testing.expectEqual(@as(usize, 0), countOps(&h.fake, "type"));
    }
}

test "the allowance is one navigation: a second new page after the thread's is load_serial_changed" {
    var h: Harness = undefined;
    initInstagram(&h);
    defer h.deinit();
    h.windows.click_navigates = .{ .match = ig_opener, .url = ig ++ "/direct/t/42/" };
    h.windows.click_navigates_then = .{ .match = ig_box, .url = ig ++ "/direct/t/43/" };
    var outcome = try h.call("instagram.dm", dm_approved);
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32015, "load_serial_changed");
    try testing.expectEqual(@as(usize, 0), countOps(&h.fake, "type"));
}

test "a conversation message has no opener, so no allowance: a new page after its first action is load_serial_changed" {
    var h: Harness = undefined;
    h.init(li ++ "/feed/");
    defer h.deinit();
    h.windows.click_navigates = .{ .match = li_box, .url = li ++ "/messaging/thread/8/" };
    var outcome = try h.call("linkedin.message", li_conversation_approved);
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32015, "load_serial_changed");
    try testing.expectEqual(@as(usize, 0), countOps(&h.fake, "type"));
}

test "every guarded action of an approved run names the document phase C captured, and the thread's after it opens" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    {
        // In-page: phase C captured doc-0 after the approved navigation; every action names it.
        var h: Harness = undefined;
        initInstagram(&h);
        defer h.deinit();
        try runOk(&h, "instagram.dm", dm_approved);
        const docs = try actionDocuments(arena.allocator(), &h);
        try testing.expectEqual(@as(usize, 4), docs.len);
        for (docs) |d| try testing.expectEqualStrings("doc-0", d orelse return error.TestExpectedDocument);
    }
    {
        // The thread opens as a new page: the opener names doc-0, every later action the thread's doc-1.
        var h: Harness = undefined;
        initInstagram(&h);
        defer h.deinit();
        h.windows.click_navigates = .{ .match = ig_opener, .url = ig ++ "/direct/t/42/" };
        try runOk(&h, "instagram.dm", dm_approved);
        const docs = try actionDocuments(arena.allocator(), &h);
        try testing.expectEqual(@as(usize, 4), docs.len);
        try testing.expectEqualStrings("doc-0", docs[0] orelse return error.TestExpectedDocument);
        for (docs[1..]) |d| try testing.expectEqualStrings("doc-1", d orelse return error.TestExpectedDocument);
    }
}

test "guard.document is a check of its own: a non-empty string, else BadArgs" {
    var command = try router.parse(gpa, "dom.click", "{\"selector\":\"css=#m\",\"options\":{\"guard\":{\"document\":\"doc-7\"}}}", .{});
    command.deinit();
    for ([_][]const u8{ "\"\"", "7", "null" }) |bad| {
        var buf: [128]u8 = undefined;
        const params = try std.fmt.bufPrint(&buf, "{{\"selector\":\"css=#m\",\"options\":{{\"guard\":{{\"document\":{s},\"target\":true}}}}}}", .{bad});
        testing.expectError(error.BadArgs, router.parse(gpa, "dom.click", params, .{})) catch |e| {
            std.debug.print("document {s} was accepted\n", .{bad});
            return e;
        };
    }
}

test "an opener that did not start a navigation gets no allowance: a thread-path page landing before the next action is load_serial_changed (RoseCat 7504 #1)" {
    var h: Harness = undefined;
    initInstagram(&h);
    defer h.deinit();
    // The opener reports no leaving; a navigation it did not start commits right after that read.
    h.windows.click_navigates = .{ .match = ig_opener, .url = ig ++ "/direct/t/99/", .after_read = true };
    var outcome = try h.call("instagram.dm", dm_approved);
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32015, "load_serial_changed");
    try testing.expectEqual(@as(usize, 1), realClicks(&h.fake));
    try testing.expectEqual(@as(usize, 0), countOps(&h.fake, "type"));
}

test "after the thread page's capture the recipient mark is still on every later step (RoseCat 7504 #3)" {
    var h: Harness = undefined;
    initInstagram(&h);
    defer h.deinit();
    h.windows.click_navigates = .{ .match = ig_opener, .url = ig ++ "/direct/t/42/" };
    try runOk(&h, "instagram.dm", dm_approved);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var later: usize = 0;
    var seen_opener = false;
    for (h.fake.eval_calls.items) |call| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), call.arg, .{}) catch continue;
        if (parsed != .object) continue;
        const op = if (parsed.object.get("op")) |o| (if (o == .string) o.string else continue) else continue;
        if (!inList(op, &.{ "click", "fill", "type" }) or std.mem.indexOf(u8, call.arg, "\"trial\":true") != null) continue;
        if (!seen_opener) {
            seen_opener = true;
            continue;
        }
        const marks = parsed.object.get("guard").?.object.get("marks") orelse return error.TestExpectedRecipientMark;
        try testing.expectEqualStrings("/ada/", marks.array.items[0].object.get("value").?.string);
        later += 1;
    }
    try testing.expectEqual(@as(usize, 3), later);
}

test "every action of an approved flow names its document, on every mutation verb: a LinkedIn like, an X schedule (RoseCat 7504 #2)" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    {
        var h: Harness = undefined;
        h.init(li ++ "/feed/");
        defer h.deinit();
        const post = li ++ "/feed/update/1/";
        try runOk(&h, "linkedin.like", "{\"postUrl\":\"" ++ post ++ "\",\"options\":{\"expect\":{\"origin\":\"" ++ li ++ "\",\"load_serial\":3,\"url\":\"" ++ post ++ "\"}}}");
        const docs = try actionDocuments(arena.allocator(), &h);
        try testing.expect(docs.len >= 1);
        for (docs) |d| try testing.expectEqualStrings("doc-0", d orelse return error.TestExpectedDocument);
    }
    {
        var x: XHarness = undefined;
        x.init();
        defer x.deinit();
        var outcome = try x.call("x.schedule_post", "{\"text\":\"Later\",\"date\":\"2026-11-05\",\"time\":\"14:07\",\"compose_url\":\"https://x.com/compose/post\",\"options\":{\"expect\":{\"origin\":\"https://x.com\",\"load_serial\":3,\"url\":\"https://x.com/compose/post\"}}}");
        defer outcome.deinit(gpa);
        if (outcome != .result) {
            std.debug.print("x.schedule_post: failure {d} {s}\n", .{ outcome.failure.code, outcome.failure.data_json orelse "" });
            return error.TestUnexpectedResult;
        }
        var seen_select = false;
        for (x.fake.eval_calls.items) |call| {
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), call.arg, .{}) catch continue;
            if (parsed != .object) continue;
            const op = if (parsed.object.get("op")) |o| (if (o == .string) o.string else continue) else continue;
            if (!inList(op, &.{ "click", "fill", "type", "press", "selectOption" }) or std.mem.indexOf(u8, call.arg, "\"trial\":true") != null) continue;
            if (std.mem.eql(u8, op, "selectOption")) seen_select = true;
            const guard = parsed.object.get("guard") orelse {
                std.debug.print("x.schedule_post {s} has no guard\n", .{op});
                return error.TestExpectedDocument;
            };
            try testing.expectEqualStrings("doc-0", guard.object.get("document").?.string);
        }
        try testing.expect(seen_select);
    }
}

test "guard.document rides on every mutation verb; a selectorless press may carry it, only not target" {
    const rows = [_]struct { method: []const u8, params: []const u8 }{
        .{ .method = "dom.click", .params = "{\"selector\":\"css=#m\",\"options\":{\"guard\":{\"document\":\"d\"}}}" },
        .{ .method = "dom.fill", .params = "{\"selector\":\"css=#m\",\"value\":\"\",\"options\":{\"guard\":{\"document\":\"d\"}}}" },
        .{ .method = "dom.type", .params = "{\"selector\":\"css=#m\",\"text\":\"hi\",\"options\":{\"guard\":{\"document\":\"d\"}}}" },
        .{ .method = "dom.press", .params = "{\"selector\":\"css=#m\",\"key\":\"Enter\",\"options\":{\"guard\":{\"document\":\"d\"}}}" },
        .{ .method = "dom.press", .params = "{\"key\":\"Escape\",\"options\":{\"guard\":{\"document\":\"d\"}}}" },
        .{ .method = "dom.selectOption", .params = "{\"selector\":\"css=#s\",\"value\":\"a\",\"options\":{\"guard\":{\"document\":\"d\"}}}" },
    };
    for (rows) |row| {
        var command = router.parse(gpa, row.method, row.params, .{}) catch |e| {
            std.debug.print("{s} {s} refused\n", .{ row.method, row.params });
            return e;
        };
        command.deinit();
    }
    try testing.expectError(error.BadArgs, router.parse(gpa, "dom.press", "{\"key\":\"Escape\",\"options\":{\"guard\":{\"document\":\"d\",\"target\":true}}}", .{}));
}

var fake_wall_ms: i64 = 1_791_644_400_000;
fn fakeWall() i64 {
    return fake_wall_ms;
}

/// An X flow through `engine.executeExternal` with a bound window over flow_fake's registry (as
/// tests/automation_expect_x_flow_test.zig).
const XHarness = struct {
    fake: fakes.FakePagePort,
    windows: flow_fake.Windowed,
    clock: fakes.FakeClock,
    engine: engine.Engine,
    state: x_routes.XState,
    cancel: std.atomic.Value(bool) = .init(false),

    fn init(self: *XHarness) void {
        self.fake = fakes.FakePagePort.init(gpa);
        self.fake.eval_replies = &.{flow_fake.flow_ok};
        self.fake.navigate_sets_url = true;
        self.fake.current_url = "https://x.com/home";
        self.windows = .{ .inner = &self.fake };
        self.clock = fakes.FakeClock.init(gpa);
        self.engine = engine.Engine.init(self.windows.port(), self.clock.clock());
        self.state = x_routes.XState.init(fakeWall);
        self.cancel = .init(false);
    }

    fn deinit(self: *XHarness) void {
        self.fake.deinit();
        self.clock.deinit();
    }

    fn call(self: *XHarness, method: []const u8, params: []const u8) !engine.Outcome {
        const Call = struct {
            state: *x_routes.XState,
            verb: x_routes.Verb,
            params: []const u8,
            fn run(c: @This(), a: std.mem.Allocator, ext: *engine.External) error{OutOfMemory}!engine.Outcome {
                return x_routes.handle(a, c.state, ext, c.verb, c.params);
            }
        };
        const window: ?page_port.WindowId = 1;
        return self.engine.executeExternal(gpa, method, "x", .{ .window = window, .cancel = &self.cancel }, Call{
            .state = &self.state,
            .verb = x_routes.verbFromMethod(method).?,
            .params = params,
        }, Call.run);
    }
};
