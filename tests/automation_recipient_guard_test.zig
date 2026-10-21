//! S8a red (chat-drawer plan rev 16.20.52, "S8 in detail" decision 13): the recipient of an
//! approved message or DM is checked in two stages, inside each step's own automation.js task
//! (decision 14's `options.guard`).
//! - The guard gains `path` (the exact `location.pathname` a step requires) and a mark gains
//!   `path: true` (its `attribute` compared as a same-origin URL's pathname); malformed ones are
//!   BadArgs, and both reach automation.js.
//! - Stage 1, the opener: an approved `instagram.dm`'s header Message click, and an approved
//!   LinkedIn profile message's owner Message click, carry `{path: <the profile's path>, target}`.
//! - Stage 2, the thread: every later step (the input click, its clear, the typing, Send) carries
//!   the recipient mark, the thread header's profile link whose path is the approved recipient's.
//! - A LinkedIn conversationUrl approval names its recipient (`expect.recipient`); without it, or
//!   with it anywhere else, the request is -32602 and nothing runs.
//! - A run without an approval sends no guard (unchanged).

const std = @import("std");
const automation = @import("automation");
const flow_fake = @import("automation/flow_fake.zig");

const router = automation.router;
const script_command = automation.script_command;
const engine = automation.engine;
const Harness = flow_fake.Harness;
const expectRefused = flow_fake.expectRefused;

const testing = std.testing;
const gpa = testing.allocator;

const ig = "https://www.instagram.com";
const li = "https://www.linkedin.com";
const conversation = li ++ "/messaging/thread/7/";

// ---- the guard's two new checks ----

/// The guard object a parsed command sends to automation.js (owned by the returned parse).
fn wireGuard(command: *const router.ParsedCommand) !std.json.Parsed(std.json.Value) {
    const json = try script_command.buildCommandJson(gpa, command, .{ .trace_id = "t", .parent_span_id = "p", .command_id = "c" }, null);
    defer gpa.free(json);
    return std.json.parseFromSlice(std.json.Value, gpa, json, .{});
}

test "guard.path alone is a check; an empty or relative path, or a non-string, is BadArgs" {
    var command = try router.parse(gpa, "dom.click", "{\"selector\":\"css=#m\",\"options\":{\"guard\":{\"path\":\"/in/carol/\"}}}", .{});
    defer command.deinit();
    var wire = try wireGuard(&command);
    defer wire.deinit();
    try testing.expectEqualStrings("/in/carol/", wire.value.object.get("guard").?.object.get("path").?.string);
    for ([_][]const u8{ "\"\"", "\"in/carol/\"", "7", "null" }) |bad| {
        var buf: [160]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "{{\"selector\":\"css=#m\",\"options\":{{\"guard\":{{\"path\":{s},\"target\":true}}}}}}", .{bad});
        testing.expectError(error.BadArgs, router.parse(gpa, "dom.click", p, .{})) catch |e| {
            std.debug.print("path {s} was accepted\n", .{bad});
            return e;
        };
    }
}

test "a path mark compares an attribute as a URL path: it needs the attribute and a value starting with /" {
    var command = try router.parse(gpa, "dom.click", "{\"selector\":\"css=#m\",\"options\":{\"guard\":{\"marks\":[{\"selector\":\"css=header a\",\"attribute\":\"href\",\"path\":true,\"value\":\"/in/carol/\"}]}}}", .{});
    defer command.deinit();
    var wire = try wireGuard(&command);
    defer wire.deinit();
    const mark = wire.value.object.get("guard").?.object.get("marks").?.array.items[0].object;
    try testing.expect(mark.get("path").?.bool);
    try testing.expectEqualStrings("href", mark.get("attribute").?.string);
    const bad = [_][]const u8{
        "{\"selector\":\"css=header a\",\"path\":true,\"value\":\"/in/carol/\"}", // no attribute
        "{\"selector\":\"css=header a\",\"attribute\":\"href\",\"path\":true,\"value\":\"carol\"}",
        "{\"selector\":\"css=header a\",\"attribute\":\"href\",\"path\":\"yes\",\"value\":\"/in/carol/\"}",
    };
    for (bad) |mark_json| {
        var buf: [256]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "{{\"selector\":\"css=#m\",\"options\":{{\"guard\":{{\"marks\":[{s}]}}}}}}", .{mark_json});
        testing.expectError(error.BadArgs, router.parse(gpa, "dom.click", p, .{})) catch |e| {
            std.debug.print("mark {s} was accepted\n", .{mark_json});
            return e;
        };
    }
}

test "guard.path and a mark's path reach automation.js" {
    var command = try router.parse(gpa, "dom.click", "{\"selector\":\"css=#m\",\"options\":{\"guard\":{\"path\":\"/ada/\",\"marks\":[{\"selector\":\"css=header a\",\"attribute\":\"href\",\"path\":true,\"value\":\"/ada/\"}],\"target\":true}}}", .{});
    defer command.deinit();
    var parsed = try wireGuard(&command);
    defer parsed.deinit();
    const guard = parsed.value.object.get("guard").?.object;
    try testing.expectEqualStrings("/ada/", guard.get("path").?.string);
    try testing.expect(guard.get("marks").?.array.items[0].object.get("path").?.bool);
}

// ---- what each approved step sends ----

/// One page action the flow sent (a click, fill or type that is not a trial), with its guard.
const Action = struct { op: []const u8, guard: ?std.json.ObjectMap };

fn actions(arena: std.mem.Allocator, h: *Harness) ![]Action {
    var out: std.ArrayListUnmanaged(Action) = .empty;
    for (h.fake.eval_calls.items) |call| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, call.arg, .{}) catch continue;
        if (parsed != .object) continue;
        const op = switch (parsed.object.get("op") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, op, "click") and !std.mem.eql(u8, op, "fill") and !std.mem.eql(u8, op, "type")) continue;
        if (parsed.object.get("options")) |options| if (options == .object) if (options.object.get("trial")) |t| if (t == .bool and t.bool) continue;
        const guard: ?std.json.ObjectMap = if (parsed.object.get("guard")) |g| (if (g == .object) g.object else null) else null;
        try out.append(arena, .{ .op = op, .guard = guard });
    }
    return out.items;
}

fn expectOpener(action: Action, path: []const u8) !void {
    const guard = action.guard orelse return error.TestExpectedGuard;
    try testing.expectEqualStrings(path, (guard.get("path") orelse return error.TestExpectedPath).string);
    try testing.expect(guard.get("target").?.bool);
    // Stage 1 also binds the profile's owner (one mark; tests/automation_recipient_owner_test.zig
    // pins which, RoseCat 8b05366).
    try testing.expectEqual(@as(usize, 1), (guard.get("marks") orelse return error.TestExpectedOwnerMark).array.items.len);
}

fn expectRecipient(action: Action, path: []const u8) !void {
    const guard = action.guard orelse return error.TestExpectedGuard;
    try testing.expect(guard.get("path") == null);
    try testing.expect(guard.get("target").?.bool);
    const marks = (guard.get("marks") orelse return error.TestExpectedMarks).array.items;
    try testing.expectEqual(@as(usize, 1), marks.len);
    const mark = marks[0].object;
    try testing.expectEqualStrings("href", mark.get("attribute").?.string);
    try testing.expect(mark.get("path").?.bool);
    try testing.expectEqualStrings(path, mark.get("value").?.string);
    try testing.expect(std.mem.indexOf(u8, mark.get("selector").?.string, "header") != null);
}

fn runOk(h: *Harness, method: []const u8, params: []const u8) !void {
    var outcome = try h.call(method, params);
    defer outcome.deinit(gpa);
    if (outcome != .result) {
        std.debug.print("{s}: failure {d} {s}\n", .{ method, outcome.failure.code, outcome.failure.data_json orelse "" });
        return error.TestUnexpectedResult;
    }
}

const dm_approved = "{\"username\":\"ada\",\"text\":\"Hi\",\"options\":{\"expect\":{\"origin\":\"" ++ ig ++ "\",\"load_serial\":3,\"url\":\"" ++ ig ++ "/ada/\"}}}";

test "an approved instagram.dm: the Message click needs the profile's path; input, typing and Send need the thread's recipient" {
    var h: Harness = undefined;
    h.init(ig ++ "/");
    defer h.deinit();
    try runOk(&h, "instagram.dm", dm_approved);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const sent = try actions(arena.allocator(), &h);
    try testing.expectEqual(@as(usize, 4), sent.len);
    try expectOpener(sent[0], "/ada/");
    for (sent[1..]) |action| try expectRecipient(action, "/ada/");
}

test "an approved LinkedIn profile message: the owner's Message click needs /in/<slug>/; every later step the thread's recipient" {
    var h: Harness = undefined;
    h.init(li ++ "/feed/");
    defer h.deinit();
    h.unverified_actions = true;
    h.fake.current_title = "Carol Example | LinkedIn";
    try runOk(&h, "linkedin.message", "{\"profileUrl\":\"" ++ li ++ "/in/carol/\",\"text\":\"Hi\",\"options\":{\"expect\":{\"origin\":\"" ++ li ++ "\",\"load_serial\":3,\"url\":\"" ++ li ++ "/in/carol/\"}}}");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const sent = try actions(arena.allocator(), &h);
    // The Message click, then the input's click, clear and typing, and Send.
    try testing.expectEqual(@as(usize, 5), sent.len);
    try expectOpener(sent[0], "/in/carol/");
    for (sent[1..]) |action| try expectRecipient(action, "/in/carol/");
}

test "an approved LinkedIn conversation message checks the recipient its approval names, on every step" {
    var h: Harness = undefined;
    h.init(li ++ "/feed/");
    defer h.deinit();
    try runOk(&h, "linkedin.message", "{\"conversationUrl\":\"" ++ conversation ++ "\",\"text\":\"Hi\",\"options\":{\"expect\":{\"origin\":\"" ++ li ++ "\",\"load_serial\":3,\"url\":\"" ++ conversation ++ "\",\"recipient\":\"carol\"}}}");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const sent = try actions(arena.allocator(), &h);
    try testing.expectEqual(@as(usize, 4), sent.len);
    for (sent) |action| try expectRecipient(action, "/in/carol/");
}

test "expect.recipient: required for an approved conversation message, refused everywhere else, and well-formed" {
    const head = "\"options\":{\"expect\":{\"origin\":\"";
    const rows = [_]struct { what: []const u8, method: []const u8, start: []const u8, params: []const u8 }{
        .{ .what = "a conversation approval without recipient", .method = "linkedin.message", .start = li ++ "/feed/", .params = "{\"conversationUrl\":\"" ++ conversation ++ "\",\"text\":\"Hi\"," ++ head ++ li ++ "\",\"load_serial\":3,\"url\":\"" ++ conversation ++ "\"}}}" },
        .{ .what = "an empty recipient", .method = "linkedin.message", .start = li ++ "/feed/", .params = "{\"conversationUrl\":\"" ++ conversation ++ "\",\"text\":\"Hi\"," ++ head ++ li ++ "\",\"load_serial\":3,\"url\":\"" ++ conversation ++ "\",\"recipient\":\"\"}}}" },
        .{ .what = "a recipient with a slash", .method = "linkedin.message", .start = li ++ "/feed/", .params = "{\"conversationUrl\":\"" ++ conversation ++ "\",\"text\":\"Hi\"," ++ head ++ li ++ "\",\"load_serial\":3,\"url\":\"" ++ conversation ++ "\",\"recipient\":\"carol/x\"}}}" },
        .{ .what = "a recipient not a string", .method = "linkedin.message", .start = li ++ "/feed/", .params = "{\"conversationUrl\":\"" ++ conversation ++ "\",\"text\":\"Hi\"," ++ head ++ li ++ "\",\"load_serial\":3,\"url\":\"" ++ conversation ++ "\",\"recipient\":7}}}" },
        .{ .what = "a recipient on a profile message", .method = "linkedin.message", .start = li ++ "/feed/", .params = "{\"profileUrl\":\"" ++ li ++ "/in/carol/\",\"text\":\"Hi\"," ++ head ++ li ++ "\",\"load_serial\":3,\"url\":\"" ++ li ++ "/in/carol/\",\"recipient\":\"carol\"}}}" },
        .{ .what = "a recipient on instagram.dm", .method = "instagram.dm", .start = ig ++ "/", .params = "{\"username\":\"ada\",\"text\":\"Hi\"," ++ head ++ ig ++ "\",\"load_serial\":3,\"url\":\"" ++ ig ++ "/ada/\",\"recipient\":\"ada\"}}}" },
        .{ .what = "a recipient on linkedin.like", .method = "linkedin.like", .start = li ++ "/feed/", .params = "{\"postUrl\":\"" ++ li ++ "/feed/update/1/\"," ++ head ++ li ++ "\",\"load_serial\":3,\"url\":\"" ++ li ++ "/feed/update/1/\",\"recipient\":\"carol\"}}}" },
    };
    for (rows) |row| {
        var h: Harness = undefined;
        h.init(row.start);
        defer h.deinit();
        var outcome = try h.call(row.method, row.params);
        defer outcome.deinit(gpa);
        expectRefused(outcome, -32602, "") catch |e| {
            std.debug.print("{s}: not refused\n", .{row.what});
            return e;
        };
        try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
        try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    }
}

test "without an approval, a message or DM sends no guard" {
    const cases = [_]struct { method: []const u8, start: []const u8, params: []const u8 }{
        .{ .method = "instagram.dm", .start = ig ++ "/", .params = "{\"username\":\"ada\",\"text\":\"Hi\"}" },
        .{ .method = "linkedin.message", .start = li ++ "/feed/", .params = "{\"conversationUrl\":\"" ++ conversation ++ "\",\"text\":\"Hi\"}" },
    };
    for (cases) |case| {
        var h: Harness = undefined;
        h.init(case.start);
        defer h.deinit();
        try runOk(&h, case.method, case.params);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const sent = try actions(arena.allocator(), &h);
        try testing.expect(sent.len > 0);
        for (sent) |action| try testing.expect(action.guard == null);
    }
}
