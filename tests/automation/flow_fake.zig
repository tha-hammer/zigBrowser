//! The S8a flow-approval tests' fake (chat-drawer plan, "S8 in detail" decision 2): the shared
//! FakePagePort behind a one-window registry whose load_serial, URL, dialog, crash, read cost,
//! stop and automation.js document token a test controls, and a harness that runs a site flow
//! through `engine.executeExternal` with a bound window.

const std = @import("std");
const automation = @import("automation");
const fakes = @import("fake_page_port.zig");

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

pub const flow_ok = fakes.EvalReply{ .json = "{\"ok\":true,\"value\":{\"ok\":true,\"text\":\"Ada\",\"elements\":[{\"id\":\"zb-1\",\"tag\":\"div\",\"text\":\"\",\"bbox\":{\"x\":0,\"y\":0,\"width\":80,\"height\":32}}]}}" };

/// A window registry over the shared FakePagePort: window 1 shows the fake's current URL, and its
/// load_serial counts its navigations plus any the test injects.
pub const Windowed = struct {
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
    /// automation.js's per-document token (op documentToken, answered here, never by the inner
    /// fake): "doc-<token_bumps>"; a replaced document has a new one.
    token_bumps: u64 = 0,
    token_reads: usize = 0,
    /// The document is replaced right after the first page eval that follows the approved
    /// navigation, with the URL and load_serial left as approved.
    token_bump_after_first_eval_after_nav: bool = false,
    /// The token read with this 1-based ordinal is unreadable, as `unreadable` says (RoseCat 7107).
    token_unreadable_at: ?usize = null,
    /// A cross-document navigation a real click starts (S8 decision 13, a thread that opens as a
    /// new page): right after the first real click whose command holds `match`, the window
    /// commits a new document at `url` (a new load_serial and document token). `then` is a second
    /// such navigation, after the first real click holding its own `match`.
    click_navigates: ?ClickNav = null,
    click_navigates_then: ?ClickNav = null,
    /// The URL the last click navigation committed (shown by the registry).
    clicked_to: ?[]const u8 = null,
    unreadable: enum { script_failure, malformed, empty, missing } = .script_failure,

    pub fn port(self: *Windowed) page_port.PagePort {
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
        if (hasOp(arg, "documentToken")) {
            self.token_reads += 1;
            // Only the isolated automation world has the token; the page's own world cannot answer.
            if (world != .automation) return a.dupe(u8, "{\"ok\":false,\"error\":\"unknown_op\",\"retryable\":false}") catch error.OutOfMemory;
            if (self.token_unreadable_at) |at| if (at == self.token_reads) return a.dupe(u8, switch (self.unreadable) {
                .script_failure => "{\"ok\":false,\"error\":\"unknown_op\",\"retryable\":false}",
                .malformed => "not json",
                .empty => "{\"ok\":true,\"value\":{\"documentToken\":\"\"}}",
                .missing => "{\"ok\":true,\"value\":{}}",
            }) catch error.OutOfMemory;
            return std.fmt.allocPrint(a, "{{\"ok\":true,\"value\":{{\"documentToken\":\"doc-{d}\"}}}}", .{self.token_bumps}) catch error.OutOfMemory;
        }
        const p = self.innerPort();
        var answer = try p.vtable.evalJson(p.ptr, a, world, body, arg, timeout_ms);
        // A chunk of a guarded dom.type (S8 decision 15) succeeds as automation.js answers one:
        // its own counts and its target's and document's tokens.
        if (std.mem.indexOf(u8, arg, "\"chunk\":true") != null and std.mem.indexOf(u8, answer, "\"ok\":true") != null) {
            a.free(answer);
            answer = std.fmt.allocPrint(a, "{{\"ok\":true,\"value\":{{\"ok\":true,\"sent\":{{\"events\":0,\"chars\":0}},\"target\":\"zb-1\",\"document\":\"doc-{d}\"}}}}", .{self.token_bumps}) catch return error.OutOfMemory;
        }
        const real_click = hasOp(arg, "click") and std.mem.indexOf(u8, arg, "\"trial\":true") == null;
        if (real_click) {
            if (self.click_navigates) |nav| {
                if (std.mem.indexOf(u8, arg, nav.match) != null) {
                    self.click_navigates = null;
                    self.commitClickNav(nav.url);
                }
            } else if (self.click_navigates_then) |again| {
                if (std.mem.indexOf(u8, arg, again.match) != null) {
                    self.click_navigates_then = null;
                    self.commitClickNav(again.url);
                }
            }
        }
        if (self.token_bump_after_first_eval_after_nav and self.inner.navigate_calls.items.len > 0 and std.mem.indexOf(u8, arg, "rateLimitScan") == null) {
            self.token_bump_after_first_eval_after_nav = false;
            self.token_bumps += 1;
        }
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
    fn commitClickNav(self: *Windowed, to: []const u8) void {
        self.clicked_to = to;
        self.bumps += 1;
        self.token_bumps += 1;
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
        const shown = self.clicked_to orelse if (navigated > 0) (self.land_url orelse self.inner.current_url) else self.inner.current_url;
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

pub const ClickNav = struct { match: []const u8, url: []const u8 };

pub fn hasOp(arg: []const u8, op: []const u8) bool {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"op\":\"{s}\"", .{op}) catch return false;
    return std.mem.indexOf(u8, arg, needle) != null;
}

pub fn countOps(fake: *const fakes.FakePagePort, op: []const u8) usize {
    var n: usize = 0;
    for (fake.eval_calls.items) |call| {
        if (hasOp(call.arg, op)) n += 1;
    }
    return n;
}

pub fn realClicks(fake: *const fakes.FakePagePort) usize {
    var n: usize = 0;
    for (fake.eval_calls.items) |call| {
        if (hasOp(call.arg, "click") and std.mem.indexOf(u8, call.arg, "\"trial\":true") == null) n += 1;
    }
    return n;
}

pub const SessionCookies = struct {
    pub fn port(self: *SessionCookies) cookie_port.CookiePort {
        return .{ .ptr = self, .vtable = &.{ .getAll = getAll, .set = set, .delete = delete } };
    }
    fn getAll(_: *anyopaque, a: std.mem.Allocator, _: ?[]const u8, _: u64) cookie_port.PortError![]u8 {
        return a.dupe(u8, "[{\"name\":\"li_at\",\"value\":\"v\",\"domain\":\"x\"},{\"name\":\"sessionid\",\"value\":\"v\",\"domain\":\"x\"}]") catch error.OutOfMemory;
    }
    fn set(_: *anyopaque, _: []const u8, _: u64) cookie_port.PortError!void {}
    fn delete(_: *anyopaque, _: []const u8, _: ?[]const u8, _: u64) cookie_port.PortError!void {}
};

pub const Harness = struct {
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
    /// flow_steps.Site.unverified_actions (tests only): LinkedIn's profile Message click runs.
    unverified_actions: bool = false,

    pub fn init(self: *Harness, start_url: []const u8) void {
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
        self.unverified_actions = false;
    }

    pub fn deinit(self: *Harness) void {
        self.fake.deinit();
        self.clock.deinit();
    }

    pub fn call(self: *Harness, method: []const u8, params: []const u8) !engine.Outcome {
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
            .env = .{ .cookies = self.cookies.port(), .unverified_actions = self.unverified_actions },
            .call = flow_call,
            .params = params,
        }, Call.run);
    }

    pub fn sleeps(self: *const Harness) usize {
        return self.clock.sleeps.items.len;
    }
};

pub const feed = "https://www.linkedin.com/feed/";
pub const post = "https://www.linkedin.com/feed/update/1/";

pub fn likeParams(buf: []u8, origin: []const u8, serial: u64, approved_url: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"postUrl\":\"" ++ post ++ "\",\"options\":{{\"expect\":{{\"origin\":\"{s}\",\"load_serial\":{d},\"url\":\"{s}\"}}}}}}", .{ origin, serial, approved_url });
}

pub fn expectRefused(outcome: engine.Outcome, code: i64, reason: []const u8) !void {
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
