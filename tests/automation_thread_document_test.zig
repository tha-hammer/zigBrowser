//! S8a red (chat-drawer plan decision 13: "If the opener leads to a new document … the engine
//! runs phase C again for it"): an approved profile-target message or DM whose Message click
//! opens the thread as a new page continues there, and only there.
//! - After the opener, the first committed new document gets phase C again: it is on the
//!   approved origin and its path is the platform's thread path (`/direct/t/` on Instagram,
//!   `/messaging/thread/` on LinkedIn), and its document token is captured; the flow then types
//!   and sends in it. Anything else is -32015 `thread_url_changed`, with nothing further sent.
//! - The allowance is one navigation, right after the opener: a second new document is
//!   `load_serial_changed` as before, and a conversation message (no opener) has none.
//! - Every guarded action of an approved run names the document phase C captured
//!   (`guard.document`, automation.js's token), so a step whose retries cross into a new
//!   document stops there (`document_changed`) instead of acting in a page no phase checked. On
//!   the real binary that retry crossing happened (tests/e2e/automation_thread_document_test.py).

const std = @import("std");
const automation = @import("automation");
const flow_fake = @import("automation/flow_fake.zig");

const router = automation.router;
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
        if (!std.mem.eql(u8, op, "click") and !std.mem.eql(u8, op, "fill") and !std.mem.eql(u8, op, "type")) continue;
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
