//! S8a red (RoseCat 8b05366 on fe89046, plan decision 13 stage 1): an approved profile-target
//! message or DM binds the profile's OWNER, from the approval, in the opener's own in-task guard.
//! The path alone is not enough: a page at the unchanged approved path can show someone else.
//! - instagram.dm: the Message click's guard also marks the profile header's username
//!   (`css=main header h2`, normalized text) as the approved username.
//! - linkedin.message to a profileUrl: the owner Message click's guard also marks the owner
//!   area's contact-info link as a same-origin path `/in/<approved slug>/overlay/contact-info/`.
//! Both values come from the request (the approved URL / username), never from the page.

const std = @import("std");
const automation = @import("automation");
const flow_fake = @import("automation/flow_fake.zig");

const Harness = flow_fake.Harness;

const testing = std.testing;
const gpa = testing.allocator;

const ig = "https://www.instagram.com";
const li = "https://www.linkedin.com";

/// The owner marks the plan's decision 13 names (unverified live, like the thread headers').
pub const ig_owner = "css=main header h2";
pub const li_owner = "xpath=//main//section[@aria-label=\"Primary content\"]//a[contains(@href,\"/overlay/contact-info/\")]";

/// The guard of the first page action (a click, fill or type that is not a trial).
fn firstActionGuard(arena: std.mem.Allocator, h: *Harness) !std.json.ObjectMap {
    for (h.fake.eval_calls.items) |call| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, call.arg, .{}) catch continue;
        if (parsed != .object) continue;
        const op = switch (parsed.object.get("op") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, op, "click") and !std.mem.eql(u8, op, "fill") and !std.mem.eql(u8, op, "type")) continue;
        const guard = parsed.object.get("guard") orelse return error.TestExpectedGuard;
        return guard.object;
    }
    return error.TestExpectedAction;
}

fn runOk(h: *Harness, method: []const u8, params: []const u8) !void {
    var outcome = try h.call(method, params);
    defer outcome.deinit(gpa);
    if (outcome != .result) {
        std.debug.print("{s}: failure {d} {s}\n", .{ method, outcome.failure.code, outcome.failure.data_json orelse "" });
        return error.TestUnexpectedResult;
    }
}

fn expectOwnerMark(guard: std.json.ObjectMap, selector: []const u8, attribute: ?[]const u8, value: []const u8) !void {
    const marks = (guard.get("marks") orelse {
        std.debug.print("opener guard has no marks: path {s}\n", .{if (guard.get("path")) |p| p.string else "-"});
        return error.TestExpectedOwnerMark;
    }).array.items;
    try testing.expectEqual(@as(usize, 1), marks.len);
    const mark = marks[0].object;
    try testing.expectEqualStrings(selector, mark.get("selector").?.string);
    try testing.expectEqualStrings(value, mark.get("value").?.string);
    if (attribute) |a| {
        try testing.expectEqualStrings(a, mark.get("attribute").?.string);
        try testing.expect(mark.get("path").?.bool);
    } else {
        try testing.expect(mark.get("attribute") == null);
        try testing.expect(mark.get("path") == null);
    }
}

test "an approved instagram.dm's Message click binds the approved username in the profile header, with the path and target" {
    var h: Harness = undefined;
    h.init(ig ++ "/");
    defer h.deinit();
    try runOk(&h, "instagram.dm", "{\"username\":\"ada\",\"text\":\"Hi\",\"options\":{\"expect\":{\"origin\":\"" ++ ig ++ "\",\"load_serial\":3,\"url\":\"" ++ ig ++ "/ada/\"}}}");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const guard = try firstActionGuard(arena.allocator(), &h);
    try testing.expectEqualStrings("/ada/", guard.get("path").?.string);
    try testing.expect(guard.get("target").?.bool);
    try expectOwnerMark(guard, ig_owner, null, "ada");
}

test "an approved LinkedIn profile message's owner Message click binds the approved slug's contact-info link, with the path and target" {
    var h: Harness = undefined;
    h.init(li ++ "/feed/");
    defer h.deinit();
    h.unverified_actions = true;
    // The page's own title names someone else: the owner mark still comes from the approval.
    h.fake.current_title = "Mallory Other | LinkedIn";
    try runOk(&h, "linkedin.message", "{\"profileUrl\":\"" ++ li ++ "/in/carol/\",\"text\":\"Hi\",\"options\":{\"expect\":{\"origin\":\"" ++ li ++ "\",\"load_serial\":3,\"url\":\"" ++ li ++ "/in/carol/\"}}}");
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const guard = try firstActionGuard(arena.allocator(), &h);
    try testing.expectEqualStrings("/in/carol/", guard.get("path").?.string);
    try testing.expect(guard.get("target").?.bool);
    try expectOwnerMark(guard, li_owner, "href", "/in/carol/overlay/contact-info/");
}
