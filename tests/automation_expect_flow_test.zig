//! S8a red (chat-drawer plan rev 16.20.44, "S8 in detail" decision 2, phases A to C for flows):
//! an approved real run of an acting flow carries `options.expect {origin, load_serial, url}` and,
//! inside its own ticket:
//! - phase A, before the session gate, the pacing pause or any page input: the bound window's
//!   origin and load_serial are the card's, no dialog is open and it has not crashed (as for the
//!   verbs: -32013, or -32015 `crashed` / `origin_changed` / `load_serial_changed`);
//! - phase B: the flow's one navigation goes to exactly `url`, else -32015
//!   `unapproved_navigation` and nothing is navigated;
//! - phase C: the navigation committed exactly `url` (-32015 `url_changed`), and the window's new
//!   load_serial is captured; every later action step finds it unchanged (-32015
//!   `load_serial_changed`), so a superseding navigation between the approved one and the first
//!   edit, or between two edits, sends nothing further.
//! A refused run consumes no pacing. `expect` with a dry run, without a bound window, or malformed
//! is -32602 and nothing runs. (The per-event in-task guard is the later S8a slice; these checks
//! read the window registry between steps.)

const std = @import("std");
const automation = @import("automation");
const fakes = @import("automation/fake_page_port.zig");

const social_routes = automation.social_routes;
const social_flow_routes = automation.social_flow_routes;
const engine = automation.engine;
const page_port = automation.page_port;
const cookie_port = automation.cookie_port;

const testing = std.testing;
const gpa = testing.allocator;

var fake_wall_ms: i64 = 1_791_644_400_000;
fn fakeWall() i64 {
    return fake_wall_ms;
}

const flow_ok = fakes.EvalReply{ .json = "{\"ok\":true,\"value\":{\"ok\":true,\"text\":\"Ada\",\"elements\":[{\"id\":\"zb-1\",\"tag\":\"div\",\"text\":\"\",\"bbox\":{\"x\":0,\"y\":0,\"width\":80,\"height\":32}}]}}" };

/// A window registry over the shared FakePagePort: window 1 shows the fake's current URL, and its
/// load_serial counts its navigations plus any the test injects.
const Windowed = struct {
    inner: *fakes.FakePagePort,
    base_serial: u64 = 3,
    bumps: u64 = 0,
    /// Where the approved navigation lands (a redirect), instead of the URL it asked for.
    land_url: ?[]const u8 = null,
    dialog_open: bool = false,
    crashed: bool = false,
    list_calls: usize = 0,
    /// A superseding navigation commits right after the first page eval that follows the
    /// approved navigation, or right after the first eval of this op ("fill", ...).
    bump_after_first_eval_after_nav: bool = false,
    bump_after_op: ?[]const u8 = null,
    bumped: bool = false,
    /// Real clicks sent before the injected navigation.
    clicks_at_bump: usize = 0,
    /// Each registry read takes this long on `clock` (a slow read that uses up the flow budget).
    clock: ?*fakes.FakeClock = null,
    list_cost_ms: u64 = 0,
    /// A stop that arrives while a registry read runs.
    stop_during_list: ?*std.atomic.Value(bool) = null,

    fn port(self: *Windowed) page_port.PagePort {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn from(ptr: *anyopaque) *Windowed {
        return @ptrCast(@alignCast(ptr));
    }

    fn innerPort(self: *Windowed) page_port.PagePort {
        return self.inner.port();
    }

    const vtable = page_port.PagePort.VTable{
        .evalJson = evalJson,
        .navigate = navigate,
        .reload = reload,
        .url = url,
        .title = title,
        .listWindows = listWindows,
    };

    fn evalJson(ptr: *anyopaque, a: std.mem.Allocator, world: page_port.World, body: []const u8, arg: []const u8, timeout_ms: u64) page_port.PortError![]u8 {
        const self = from(ptr);
        const p = self.innerPort();
        const answer = try p.vtable.evalJson(p.ptr, a, world, body, arg, timeout_ms);
        if (!self.bumped) {
            const after_nav = self.bump_after_first_eval_after_nav and self.inner.navigate_calls.items.len > 0 and std.mem.indexOf(u8, arg, "rateLimitScan") == null;
            const after_op = if (self.bump_after_op) |op| hasOp(arg, op) else false;
            if (after_nav or after_op) {
                self.bumped = true;
                self.bumps += 1;
                self.clicks_at_bump = realClicks(self.inner);
            }
        }
        return answer;
    }
    fn navigate(ptr: *anyopaque, target: []const u8, timeout_ms: u64) page_port.PortError!void {
        const p = from(ptr).innerPort();
        return p.vtable.navigate(p.ptr, target, timeout_ms);
    }
    fn reload(ptr: *anyopaque, timeout_ms: u64) page_port.PortError!void {
        const p = from(ptr).innerPort();
        return p.vtable.reload(p.ptr, timeout_ms);
    }
    fn url(ptr: *anyopaque, a: std.mem.Allocator, timeout_ms: u64) page_port.PortError![]u8 {
        const p = from(ptr).innerPort();
        return p.vtable.url(p.ptr, a, timeout_ms);
    }
    fn title(ptr: *anyopaque, a: std.mem.Allocator, timeout_ms: u64) page_port.PortError![]u8 {
        const p = from(ptr).innerPort();
        return p.vtable.title(p.ptr, a, timeout_ms);
    }
    fn listWindows(ptr: *anyopaque, a: std.mem.Allocator, _: u64) page_port.PortError![]page_port.WindowInfo {
        const self = from(ptr);
        self.list_calls += 1;
        if (self.clock) |clock| clock.now_ms += self.list_cost_ms;
        if (self.stop_during_list) |flag| flag.store(true, .release);
        const navigated = self.inner.navigate_calls.items.len;
        const shown = if (navigated > 0) (self.land_url orelse self.inner.current_url) else self.inner.current_url;
        const list = try a.alloc(page_port.WindowInfo, 1);
        errdefer a.free(list);
        const url_copy = try a.dupe(u8, shown);
        errdefer a.free(url_copy);
        list[0] = .{
            .id = 1,
            .url = url_copy,
            .title = try a.dupe(u8, "Fixture"),
            .primary = true,
            .dialog_open = self.dialog_open,
            .terminated = if (self.crashed) .crashed else null,
            .load_serial = self.base_serial + navigated + self.bumps,
        };
        return list;
    }
};

fn hasOp(arg: []const u8, op: []const u8) bool {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"op\":\"{s}\"", .{op}) catch return false;
    return std.mem.indexOf(u8, arg, needle) != null;
}

fn countOps(fake: *const fakes.FakePagePort, op: []const u8) usize {
    var n: usize = 0;
    for (fake.eval_calls.items) |call| {
        if (hasOp(call.arg, op)) n += 1;
    }
    return n;
}

fn realClicks(fake: *const fakes.FakePagePort) usize {
    var n: usize = 0;
    for (fake.eval_calls.items) |call| {
        if (hasOp(call.arg, "click") and std.mem.indexOf(u8, call.arg, "\"trial\":true") == null) n += 1;
    }
    return n;
}

const SessionCookies = struct {
    fn port(self: *SessionCookies) cookie_port.CookiePort {
        return .{ .ptr = self, .vtable = &.{ .getAll = getAll, .set = set, .delete = delete } };
    }
    fn getAll(_: *anyopaque, a: std.mem.Allocator, _: ?[]const u8, _: u64) cookie_port.PortError![]u8 {
        return a.dupe(u8, "[{\"name\":\"li_at\",\"value\":\"v\",\"domain\":\"x\"},{\"name\":\"sessionid\",\"value\":\"v\",\"domain\":\"x\"}]") catch error.OutOfMemory;
    }
    fn set(_: *anyopaque, _: []const u8, _: u64) cookie_port.PortError!void {}
    fn delete(_: *anyopaque, _: []const u8, _: ?[]const u8, _: u64) cookie_port.PortError!void {}
};

const Harness = struct {
    fake: fakes.FakePagePort,
    windows: Windowed,
    clock: fakes.FakeClock,
    engine: engine.Engine,
    state: social_routes.SocialState,
    cookies: SessionCookies = .{},
    /// The bound window (`window_id`); null: none.
    window: ?page_port.WindowId = 1,
    /// The command's cancel flag (a server stop).
    cancel: std.atomic.Value(bool) = .init(false),

    fn init(self: *Harness, start_url: []const u8) void {
        self.fake = fakes.FakePagePort.init(gpa);
        self.fake.eval_replies = &.{flow_ok};
        self.fake.navigate_sets_url = true;
        self.fake.current_url = start_url;
        self.windows = .{ .inner = &self.fake };
        self.clock = fakes.FakeClock.init(gpa);
        self.engine = engine.Engine.init(self.windows.port(), self.clock.clock());
        self.state = social_routes.SocialState.init(fakeWall, self.clock.clock());
        self.cookies = .{};
        self.window = 1;
        self.cancel = .init(false);
    }

    fn deinit(self: *Harness) void {
        self.fake.deinit();
        self.clock.deinit();
    }

    fn call(self: *Harness, method: []const u8, params: []const u8) !engine.Outcome {
        const Call = struct {
            state: *social_routes.SocialState,
            env: social_flow_routes.Env,
            call: social_flow_routes.Call,
            params: []const u8,
            fn run(c: @This(), a: std.mem.Allocator, ext: *engine.External) error{OutOfMemory}!engine.Outcome {
                return social_flow_routes.handle(a, c.state, c.env, ext, c.call, c.params);
            }
        };
        const flow_call = social_flow_routes.callFromMethod(method).?;
        return self.engine.executeExternal(gpa, method, flow_call.namespace(), .{ .window = self.window, .cancel = &self.cancel }, Call{
            .state = &self.state,
            .env = .{ .cookies = self.cookies.port() },
            .call = flow_call,
            .params = params,
        }, Call.run);
    }

    fn sleeps(self: *const Harness) usize {
        return self.clock.sleeps.items.len;
    }
};

const feed = "https://www.linkedin.com/feed/";
const post = "https://www.linkedin.com/feed/update/1/";

fn likeParams(buf: []u8, origin: []const u8, serial: u64, approved_url: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"postUrl\":\"" ++ post ++ "\",\"options\":{{\"expect\":{{\"origin\":\"{s}\",\"load_serial\":{d},\"url\":\"{s}\"}}}}}}", .{ origin, serial, approved_url });
}

fn expectRefused(outcome: engine.Outcome, code: i64, reason: []const u8) !void {
    if (outcome != .failure) {
        std.debug.print("expected {d} {s}, got a result {s}\n", .{ code, reason, outcome.result });
        return error.TestExpectedEqual;
    }
    try testing.expectEqual(code, outcome.failure.code);
    if (reason.len > 0) {
        var buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "\"reason\":\"{s}\"", .{reason});
        testing.expect(std.mem.indexOf(u8, outcome.failure.data_json orelse "", needle) != null) catch |e| {
            std.debug.print("data {s}, wanted reason {s}\n", .{ outcome.failure.data_json orelse "(none)", reason });
            return e;
        };
    }
}

test "flow phases: a matching approval runs the flow once, reading the window before and after its navigation" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, post));
    defer outcome.deinit(gpa);
    if (outcome != .result) {
        std.debug.print("failure {d} {s}\n", .{ outcome.failure.code, outcome.failure.data_json orelse "" });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    try testing.expectEqual(@as(usize, 1), h.fake.navigate_calls.items.len);
    try testing.expectEqual(@as(usize, 1), realClicks(&h.fake));
    try testing.expectEqual(before - 1, h.state.remaining());
    // Phase A, phase C, and before the action.
    try testing.expect(h.windows.list_calls >= 3);
}

const PhaseA = enum { origin, load_serial, dialog, crashed };

fn phaseA(change: PhaseA, code: i64, reason: []const u8) !void {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    switch (change) {
        .origin => h.fake.current_url = "https://www.instagram.com/",
        .load_serial => h.windows.bumps = 1,
        .dialog => h.windows.dialog_open = true,
        .crashed => h.windows.crashed = true,
    }
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, post));
    defer outcome.deinit(gpa);
    try expectRefused(outcome, code, reason);
    // Before the gate's pacing pause and any page input.
    try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    try testing.expectEqual(@as(usize, 0), h.sleeps());
    try testing.expectEqual(before, h.state.remaining());
}

test "flow phase A: another origin, serial, a dialog or a crash refuses before any page input or pacing" {
    try phaseA(.origin, -32015, "origin_changed");
    try phaseA(.load_serial, -32015, "load_serial_changed");
    try phaseA(.dialog, -32013, "");
    try phaseA(.crashed, -32015, "crashed");
}

test "flow phase B: a navigation to anything but the approved URL is refused before it starts" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, "https://www.linkedin.com/feed/update/9/"));
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32015, "unapproved_navigation");
    try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    try testing.expectEqual(@as(usize, 0), realClicks(&h.fake));
    try testing.expectEqual(before, h.state.remaining());
}

test "flow phase C: a navigation that commits another URL is refused before the first action" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    h.windows.land_url = "https://www.linkedin.com/feed/update/2/";
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, post));
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32015, "url_changed");
    try testing.expectEqual(@as(usize, 1), h.fake.navigate_calls.items.len);
    try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    try testing.expectEqual(before, h.state.remaining());
}

test "flow phase C: a superseding navigation between the approved one and the first edit sends nothing" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    h.windows.bump_after_first_eval_after_nav = true;
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, post));
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32015, "load_serial_changed");
    try testing.expect(h.windows.bumped);
    try testing.expectEqual(@as(usize, 0), realClicks(&h.fake));
    try testing.expectEqual(before, h.state.remaining());
}

test "flow phase C: a navigation between two edits stops the flow before the next one" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    h.windows.bump_after_op = "fill";
    var outcome = try h.call("linkedin.comment", "{\"postUrl\":\"" ++ post ++ "\",\"text\":\"Nice\",\"options\":{\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":3,\"url\":\"" ++ post ++ "\"}}}");
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32015, "load_serial_changed");
    try testing.expect(h.windows.bumped);
    try testing.expectEqual(@as(usize, 1), countOps(&h.fake, "fill"));
    try testing.expectEqual(@as(usize, 0), countOps(&h.fake, "type"));
    // Nothing was clicked after the fill (the submit included).
    try testing.expectEqual(h.windows.clicks_at_bump, realClicks(&h.fake));
}

test "flow phases: message and DM flows take an approval too" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    const conversation = "https://www.linkedin.com/messaging/thread/7/";
    var outcome = try h.call("linkedin.message", "{\"conversationUrl\":\"" ++ conversation ++ "\",\"text\":\"Hi\",\"options\":{\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":3,\"url\":\"" ++ conversation ++ "\"}}}");
    defer outcome.deinit(gpa);
    if (outcome != .result) {
        std.debug.print("failure {d} {s}\n", .{ outcome.failure.code, outcome.failure.data_json orelse "" });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(usize, 1), h.fake.navigate_calls.items.len);
}

test "flow phases: expect with a dry run, without a window, or malformed is -32602 and nothing runs" {
    const cases = [_]struct { what: []const u8, params: []const u8, window: ?page_port.WindowId = 1 }{
        .{ .what = "dry run", .params = "{\"postUrl\":\"" ++ post ++ "\",\"options\":{\"dry_run\":true,\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":3,\"url\":\"" ++ post ++ "\"}}}" },
        .{ .what = "no window", .params = "{\"postUrl\":\"" ++ post ++ "\",\"options\":{\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":3,\"url\":\"" ++ post ++ "\"}}}", .window = null },
        .{ .what = "no url", .params = "{\"postUrl\":\"" ++ post ++ "\",\"options\":{\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":3}}}" },
        .{ .what = "url not a string", .params = "{\"postUrl\":\"" ++ post ++ "\",\"options\":{\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":3,\"url\":7}}}" },
        .{ .what = "an unknown key", .params = "{\"postUrl\":\"" ++ post ++ "\",\"options\":{\"expect\":{\"origin\":\"https://www.linkedin.com\",\"load_serial\":3,\"url\":\"" ++ post ++ "\",\"approved\":true}}}" },
    };
    for (cases) |case| {
        var h: Harness = undefined;
        h.init(feed);
        defer h.deinit();
        h.window = case.window;
        var outcome = try h.call("linkedin.like", case.params);
        defer outcome.deinit(gpa);
        testing.expect(outcome == .failure and outcome.failure.code == -32602) catch |e| {
            std.debug.print("{s}: not -32602\n", .{case.what});
            return e;
        };
        try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
        try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
        try testing.expectEqual(@as(usize, 0), h.sleeps());
    }
}

test "flow phase A: a check that used up the flow budget is its timeout, whatever it found (RoseCat db43ca1)" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    h.windows.clock = &h.clock;
    h.windows.list_cost_ms = social_flow_routes.flow_budget_ms + 1;
    h.windows.bumps = 1; // and it found another load_serial
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, post));
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32009, "expect_used_deadline");
    try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    try testing.expectEqual(@as(usize, 0), h.sleeps());
    try testing.expectEqual(before, h.state.remaining());
}

test "flow phase A: a stop comes before a check that also used up the budget and found a change (RoseCat 4d62b4e)" {
    var h: Harness = undefined;
    h.init(feed);
    defer h.deinit();
    h.windows.clock = &h.clock;
    h.windows.list_cost_ms = social_flow_routes.flow_budget_ms + 1;
    h.windows.bumps = 1;
    h.windows.stop_during_list = &h.cancel;
    const before = h.state.remaining();
    var buf: [512]u8 = undefined;
    var outcome = try h.call("linkedin.like", try likeParams(&buf, "https://www.linkedin.com", 3, post));
    defer outcome.deinit(gpa);
    try expectRefused(outcome, -32012, "");
    try testing.expectEqual(@as(usize, 0), h.fake.navigate_calls.items.len);
    try testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    try testing.expectEqual(@as(usize, 0), h.sleeps());
    try testing.expectEqual(before, h.state.remaining());
}
