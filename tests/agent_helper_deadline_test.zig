//! S7b (chat-drawer plan section 7 and S7b, rev 16.20.34): the tool deadline seam's app side.
//! `ZIGBROWSER_AGENT_TEST_TOOL_DEADLINE_S`, read only with --e2e-protocol, is exactly an
//! integer from 1 to 120 (options.TOOL_DEADLINE_S, agent_protocol.tool_deadline_s); it goes
//! to the helper as hello.e2e.tool_deadline_s. Any other value refuses the agent with one
//! stderr line, as a wrong test base URL does. Without --e2e-protocol it is dropped. hello's
//! e2e object names only the seams that are set: the helper refuses a null tool_deadline_s.
//! The new input is reached through @hasField, so this file compiles before the green and fails.
const std = @import("std");
const helper = @import("agent_helper");

const has = @hasField(helper.Inputs, "tool_deadline") and @hasField(helper.HelloE2e, "tool_deadline_s");
const refusal = "zigBrowser: agent: test tool deadline must be an integer from 1 to 120";

fn base(e2e: bool) helper.Inputs {
    return .{ .python = "/rt/venv/bin/python", .home = "/d/agent-home", .net_dir = "/run/user/1000/zigbrowser-agent-7-00", .e2e_protocol = e2e };
}

fn launchWith(a: std.mem.Allocator, e2e: bool, deadline: ?[]const u8, base_url: ?[]const u8) !helper.Launch {
    var in = base(e2e);
    @field(in, "tool_deadline") = deadline;
    in.test_base_url = base_url;
    return helper.launch(a, in);
}

fn e2eObject(a: std.mem.Allocator, run: helper.Launch) ![]const u8 {
    const line = try helper.helloFrame(a, 1, "/d/agent-home", run.hello_e2e);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
    return std.json.Stringify.valueAlloc(a, parsed.value.object.get("e2e").?, .{});
}

test "an integer from 1 to 120 goes to the helper as hello.e2e.tool_deadline_s" {
    if (!has) return error.TestNoDeadlineSeam;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "1", "7", "120" }) |value| {
        const run = try launchWith(a, true, value, null);
        try std.testing.expect(run.refusal == null);
        const want = try std.fmt.allocPrint(a, "{{\"tool_deadline_s\":{s}}}", .{value});
        try std.testing.expectEqualStrings(want, try e2eObject(a, run));
    }
    const both = try launchWith(a, true, "7", "https://fake.zb.invalid");
    try std.testing.expectEqualStrings("{\"test_base_url\":\"https://fake.zb.invalid\",\"tool_deadline_s\":7}", try e2eObject(a, both));
}

test "any other value refuses the agent with one line" {
    if (!has) return error.TestNoDeadlineSeam;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "0", "121", "-3", "", "abc", "7.5", " 7", "7 ", "+7", "007x", "99999999999999999999" }) |value| {
        const run = try launchWith(arena.allocator(), true, value, null);
        try std.testing.expectEqualStrings(refusal, run.refusal orelse "none");
    }
}

test "without --e2e-protocol it is dropped, and without seams hello's e2e is null" {
    if (!has) return error.TestNoDeadlineSeam;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dropped = try launchWith(a, false, "7", null);
    try std.testing.expect(dropped.refusal == null and dropped.hello_e2e == null);
    const only_url = try launchWith(a, true, null, "https://fake.zb.invalid");
    try std.testing.expectEqualStrings("{\"test_base_url\":\"https://fake.zb.invalid\"}", try e2eObject(a, only_url));
    const none = try launchWith(a, true, null, null);
    try std.testing.expectEqualStrings("null", try e2eObject(a, none));
}
