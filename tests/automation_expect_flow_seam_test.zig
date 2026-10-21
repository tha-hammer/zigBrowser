//! S8a red (RoseCat 7098 #4): phase B through `flow_runner.Runner` itself. Before phase C,
//! nothing but the one approved navigation runs: an action, a reload, another navigation, or a
//! second try after the approved one failed is -32015 `unapproved_navigation`, and nothing is
//! sent; after phase C, another navigation or a reload is refused the same way. (The site flows
//! always navigate first, so a scripted step list drives the runner.) On HEAD it does not compile:
//! `Runner.approval` is the seam this slice adds.

const std = @import("std");
const automation = @import("automation");
const flow_fake = @import("automation/flow_fake.zig");

const engine = automation.engine;
const Harness = flow_fake.Harness;
const feed = flow_fake.feed;
const post = flow_fake.post;
const expectRefused = flow_fake.expectRefused;
const realClicks = flow_fake.realClicks;

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
            // Every step is tried, a failed one included (a later step must still be refused);
            // the answer is the last failure.
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
const click_like = Step{ .method = "dom.click", .params = "{\"selector\":\"css=#like\"}" };

test "flow phase B: before phase C nothing but the one approved navigation runs (RoseCat 7098 #4)" {
    const cases = [_]struct { what: []const u8, steps: []const Step, navigates: usize, reloads: usize = 0, fail_navigate: bool = false }{
        .{ .what = "an action first", .steps = &.{click_like}, .navigates = 0 },
        .{ .what = "a reload first", .steps = &.{.{ .method = "page.reload", .params = "{}" }}, .navigates = 0 },
        .{ .what = "another navigation first", .steps = &.{.{ .method = "page.navigate", .params = "{\"url\":\"https://www.linkedin.com/feed/update/9/\"}" }}, .navigates = 0 },
        .{ .what = "a second try after the approved one failed", .steps = &.{ navigate_post, navigate_post }, .navigates = 1, .fail_navigate = true },
        .{ .what = "a second navigation after phase C", .steps = &.{ navigate_post, navigate_post }, .navigates = 1 },
        .{ .what = "a reload after phase C", .steps = &.{ navigate_post, .{ .method = "page.reload", .params = "{}" } }, .navigates = 1 },
    };
    for (cases) |case| {
        var h: Harness = undefined;
        h.init(feed);
        defer h.deinit();
        if (case.fail_navigate) h.fake.navigate_result = error.NavigationFailed;
        var outcome = try runSteps(&h, case.steps);
        defer outcome.deinit(gpa);
        expectRefused(outcome, -32015, "unapproved_navigation") catch |e| {
            std.debug.print("{s}\n", .{case.what});
            return e;
        };
        try testing.expectEqual(case.navigates, h.fake.navigate_calls.items.len);
        try testing.expectEqual(case.reloads, h.fake.reload_calls);
        try testing.expectEqual(@as(usize, 0), realClicks(&h.fake));
    }
}
