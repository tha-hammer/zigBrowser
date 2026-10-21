//! S8a red (RoseCat 7155 on 2c95253): before phase C, a read is not "nothing". While an approved
//! run has not committed its approved navigation, every step but that one `page.navigate` is
//! -32015 `unapproved_navigation` and reaches nothing: a dom.query, dom.getText, dom.waitFor,
//! page.url or page.title included. After phase C, reads go on as before (only actions are
//! guarded), and after a failed approved navigation nothing runs at all.

const std = @import("std");
const automation = @import("automation");
const flow_fake = @import("automation/flow_fake.zig");

const engine = automation.engine;
const Harness = flow_fake.Harness;
const feed = flow_fake.feed;
const post = flow_fake.post;
const expectRefused = flow_fake.expectRefused;

const testing = std.testing;
const gpa = testing.allocator;

const Step = struct { method: []const u8, params: []const u8 };

fn runSteps(h: *Harness, steps: []const Step) !engine.Outcome {
    const Body = struct {
        steps: []const Step,
        fn run(b: @This(), a: std.mem.Allocator, ext: *engine.External) error{OutOfMemory}!engine.Outcome {
            var runner = automation.flow_runner.Runner{
                .gpa = a,
                .ext = ext,
                .deadline_ms = ext.nowMs() + 60_000,
                .deadline_reason = "test_flow_deadline",
                .approval = .{ .url = post },
            };
            defer runner.deinit();
            var failed = false;
            for (b.steps) |step| {
                if ((try runner.run(step.method, step.params)) == null) failed = true;
            }
            return if (failed) runner.takeFailure() else .{ .result = try a.dupe(u8, "{\"ok\":true}") };
        }
    };
    return h.engine.executeExternal(gpa, "test.flow", "test", .{ .window = h.window }, Body{ .steps = steps }, Body.run);
}

const navigate_post = Step{ .method = "page.navigate", .params = "{\"url\":\"" ++ post ++ "\",\"timeout_ms\":5000}" };

const reads = [_]Step{
    .{ .method = "dom.query", .params = "{\"selector\":\"css=#like\"}" },
    .{ .method = "dom.getText", .params = "{\"selector\":\"css=#like\"}" },
    .{ .method = "dom.waitFor", .params = "{\"selector\":\"css=#like\",\"state\":\"attached\",\"timeout_ms\":2000}" },
    .{ .method = "page.url", .params = "{}" },
    .{ .method = "page.title", .params = "{}" },
};

test "flow phase B: a read before the approved navigation is refused and reaches nothing" {
    for (reads) |read| {
        var h: Harness = undefined;
        h.init(feed);
        defer h.deinit();
        var outcome = try runSteps(&h, &.{read});
        defer outcome.deinit(gpa);
        expectRefused(outcome, -32015, "unapproved_navigation") catch |e| {
            std.debug.print("{s} first\n", .{read.method});
            return e;
        };
        try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
        try testing.expectEqual(@as(usize, 0), h.fake.url_calls);
        try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    }
}

test "flow phase B: after a failed approved navigation, a read is refused too" {
    for (reads) |read| {
        var h: Harness = undefined;
        h.init(feed);
        defer h.deinit();
        h.fake.navigate_result = error.NavigationFailed;
        var outcome = try runSteps(&h, &.{ navigate_post, read });
        defer outcome.deinit(gpa);
        expectRefused(outcome, -32015, "unapproved_navigation") catch |e| {
            std.debug.print("{s} after a failed navigation\n", .{read.method});
            return e;
        };
        try testing.expectEqual(@as(usize, 1), h.fake.navigate_calls.items.len);
        try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    }
}

test "flow phase C: after the approved navigation committed, reads run as before" {
    for (reads) |read| {
        var h: Harness = undefined;
        h.init(feed);
        defer h.deinit();
        var outcome = try runSteps(&h, &.{ navigate_post, read });
        defer outcome.deinit(gpa);
        if (outcome != .result) {
            std.debug.print("{s} after phase C: {d} {s}\n", .{ read.method, outcome.failure.code, outcome.failure.data_json orelse "" });
            return error.TestUnexpectedResult;
        }
    }
}
