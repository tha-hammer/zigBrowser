//! N16: linkedin.* and instagram.* over the automation socket. The flows
//! live in src/linkedin.zig and src/instagram.zig; each step runs as an
//! ordinary router command through Engine.External (the shared
//! flow_runner.Runner), under one root span, one page-queue turn and one
//! flow budget, exactly like x.*.
//!
//! Order of a request (nothing below touches the page until step 4):
//! 1. Strict params: allowed keys, strings only, URLs on the platform's own
//!    https site (C43), usernames, text limits, the search URL.
//! 2. Login gate before navigation (C31): the platform's session cookie
//!    (li_at / sessionid) must be in the cookie store, else -32011
//!    logged_out. After navigating, each flow also requires the page's
//!    signed-in marker before any click or typing.
//! 3. Pacing (actions only): the server's social RateLimiter (the one
//!    social.rate_status / social.set_pacing report and change; default
//!    100 actions a day and a 3-8 s pause before each). Admission is an
//!    atomic reservation, so concurrent pages cannot overshoot the cap; at
//!    the cap: -32010 social_daily_cap. Only successes count. Reads
//!    (linkedin.extract, *.selfcheck) are not paced.
//! 4. The flow.
//!
//! Dry run (`options: {dry_run: true}`, on the acting flows that have one:
//! linkedin.connect/follow/like/comment, instagram.follow/like/comment/
//! story_view): steps 1, 2 and 4 as above, but the flow stops at its
//! committing click with a trial click instead (src/flow_steps.zig, "Dry
//! runs"), and step 3 is bypassed: no admission (not even at the cap), no
//! reservation, no pause, nothing counted or saved. The result lists the
//! runner's clean rate-limit scans and the actions left (`daily_cap`, with
//! the real call's error when there are none) in `checks`.
//!
//! Telemetry (Phase 5 EV8/EV7): one `automation.social.compound` span under
//! the root and one `automation.social.action` event per step under it.
//! URLs, usernames and texts never cross the sink: only hashes, lengths
//! and selector-table names.
const std = @import("std");
const linkedin = @import("../linkedin.zig");
const instagram = @import("../instagram.zig");
const flow = @import("../flow_steps.zig");
const engine_mod = @import("engine.zig");
const flow_runner = @import("flow_runner.zig");
const social_routes = @import("social_routes.zig");
const cookie_port = @import("cookie_port.zig");
const telemetry = @import("telemetry.zig");
const errors = @import("error.zig");

pub const Call = union(enum) {
    linkedin: linkedin.Verb,
    instagram: instagram.Verb,

    pub fn namespace(self: Call) []const u8 {
        return @tagName(self);
    }

    fn action(self: Call) []const u8 {
        return switch (self) {
            inline else => |verb| @tagName(verb),
        };
    }

    fn isAction(self: Call) bool {
        return switch (self) {
            .linkedin => |verb| linkedin.isAction(verb),
            .instagram => |verb| instagram.isAction(verb),
        };
    }

    /// The flows with a dry run (runDry).
    fn hasDryRun(self: Call) bool {
        return switch (self) {
            .linkedin => |verb| switch (verb) {
                .connect, .follow, .like, .comment => true,
                else => false,
            },
            .instagram => |verb| switch (verb) {
                .follow, .like, .comment, .story_view => true,
                else => false,
            },
        };
    }

    /// selfcheck reports on the current page: it needs no session.
    fn needsSession(self: Call) bool {
        return switch (self) {
            .linkedin => |verb| verb != .selfcheck,
            .instagram => |verb| verb != .selfcheck,
        };
    }

    fn deadlineReason(self: Call) []const u8 {
        return switch (self) {
            .linkedin => "linkedin_flow_deadline",
            .instagram => "instagram_flow_deadline",
        };
    }

    fn sessionCookie(self: Call) []const u8 {
        return switch (self) {
            .linkedin => linkedin.session_cookie,
            .instagram => instagram.session_cookie,
        };
    }

    fn site(self: Call, env: Env) flow.Site {
        var s = switch (self) {
            .linkedin => linkedin.site,
            .instagram => instagram.site,
        };
        s.fixture_origin = env.fixture_origin;
        s.unverified_actions = env.unverified_actions;
        return s;
    }
};

pub fn callFromMethod(method: []const u8) ?Call {
    if (linkedin.verbFromMethod(method)) |verb| return .{ .linkedin = verb };
    if (instagram.verbFromMethod(method)) |verb| return .{ .instagram = verb };
    return null;
}

/// What the server provides besides the page.
pub const Env = struct {
    /// For the session-cookie login gate (null: no cookie store, e.g. a
    /// backend without one -> -32011 unsupported).
    cookies: ?cookie_port.CookiePort,
    /// Test-only stand-in origin for both sites, from the server's
    /// configuration (never from a request). Null in production.
    fixture_origin: ?[]const u8 = null,
    /// Tests only: see flow_steps.Site.unverified_actions. The server never
    /// sets it.
    unverified_actions: bool = false,
};

/// The default hard deadline for a whole flow, like x.*. The flows that
/// type text (linkedin.connect/message/comment, instagram.comment/dm) take
/// `timeout_ms` (at most 600 s).
pub const flow_budget_ms: u64 = flow.default_flow_budget_ms;

const cookie_timeout_ms: u64 = 10_000;

pub fn handle(
    gpa: std.mem.Allocator,
    state: *social_routes.SocialState,
    env: Env,
    ext: *engine_mod.External,
    call: Call,
    params_json: []const u8,
) error{OutOfMemory}!engine_mod.Outcome {
    return handleWithBudget(gpa, state, env, ext, call, params_json, flow_budget_ms);
}

/// `handle` with an explicit flow budget (tests).
pub fn handleWithBudget(
    gpa: std.mem.Allocator,
    state: *social_routes.SocialState,
    env: Env,
    ext: *engine_mod.External,
    call: Call,
    params_json: []const u8,
    budget_ms: u64,
) error{OutOfMemory}!engine_mod.Outcome {
    const started = ext.nowMs();
    var trace = Trace.init(ext, call);
    const outcome = try execute(gpa, state, env, ext, call, params_json, started, budget_ms, &trace);
    trace.finish(&outcome, ext.nowMs() -| started);
    return outcome;
}

fn execute(
    gpa: std.mem.Allocator,
    state: *social_routes.SocialState,
    env: Env,
    ext: *engine_mod.External,
    call: Call,
    params_json: []const u8,
    started: u64,
    default_budget_ms: u64,
    trace: *Trace,
) error{OutOfMemory}!engine_mod.Outcome {
    const ids = ext.ids();
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, params_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalidParams(),
    };
    defer parsed.deinit();
    const params = switch (parsed.value) {
        .object => |object| object,
        else => return invalidParams(),
    };
    var keys = params.iterator();
    while (keys.next()) |entry| {
        if (!inList(allowedParams(call), entry.key_ptr.*)) return invalidParams();
        // Every allowed param is a string, except the flow's timeout_ms and
        // options (checked by flowOptions).
        if (std.mem.eql(u8, entry.key_ptr.*, "timeout_ms") or std.mem.eql(u8, entry.key_ptr.*, "options")) continue;
        if (entry.value_ptr.* != .string) return invalidParams();
    }
    const p = Params{ .object = params };
    const s = call.site(env);
    // One absolute deadline from the request start for everything below
    // (cookie gate, pacing pause, every flow step): timeout_ms (at most
    // 600 s), else the default.
    const explicit_ms = flow.flowTimeoutParam(params.get("timeout_ms")) catch return invalidParams();
    const deadline_ms = started +| flow.flowBudgetMs(default_budget_ms, explicit_ms, null);
    const options = flowOptions(params.get("options")) catch return invalidParams();
    const dry_run = options.dry_run;
    trace.dry_run = dry_run;
    // S8: an approval binds a real run of an acting flow to one window; a dry run has no card.
    if (dry_run and !call.hasDryRun()) return invalidParams();
    if (options.expect != null and (dry_run or !call.isAction() or ext.options.window == null)) return invalidParams();
    // S8 decision 13: a conversation message names no one, so its approval names the recipient;
    // no other approval may.
    if (options.expect) |expect| {
        const conversation_message = call == .linkedin and call.linkedin == .message and p.get("conversationUrl") != null;
        if ((expect.recipient != null) != conversation_message) return invalidParams();
    }

    // 1. Everything that needs no page, before the gate and pacing.
    validate(gpa, call, s, p) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidParams => return invalidParams(),
    };
    trace.describe(call, s, p);

    // S8 phase A ("S8 in detail" decision 2): the window as the approval card showed it, inside
    // this ticket and before the gate, the pacing pause or any page input.
    if (options.expect) |expect| {
        var found: ?engine_mod.Outcome = switch (try ext.boundWindow(gpa, deadline_ms -| ext.nowMs())) {
            .refused => |refused| refused,
            .window => |window| blk: {
                defer window.deinit(gpa);
                break :blk try engine_mod.windowRefusal(gpa, window, .{ .origin = expect.origin, .load_serial = expect.load_serial }, ids);
            },
        };
        // As for the verbs (RoseCat db43ca1): a stop, then a check that used up the budget, then
        // what the check found.
        if (ext.cancelled() or ext.nowMs() >= deadline_ms) {
            if (found) |*f| f.deinit(gpa);
            if (ext.cancelled()) return engine_mod.automationFailure(gpa, .cancelled, null, ids);
            return engine_mod.automationFailure(gpa, .action_timeout, "expect_used_deadline", ids);
        }
        if (found) |f| return f;
    }

    // 2. Login gate before navigation.
    if (call.needsSession()) {
        if (try sessionGate(gpa, env, ext, call, s, deadline_ms)) |failure| return failure;
        trace.login_verified = true;
    }

    var runner = flow_runner.Runner{
        .gpa = gpa,
        .ext = ext,
        .deadline_ms = deadline_ms,
        .deadline_reason = call.deadlineReason(),
        .observer = trace.observer(),
        .platform = call.namespace(),
        .approval = if (options.expect) |expect| .{ .url = expect.url, .recipient = expect.recipient } else null,
    };
    defer runner.deinit();

    // 3. Pacing for actions: reserve, pause, then commit (success) or
    //    release (any other way out).
    var reservation: ?social_routes.SocialState.Reservation = null;
    defer if (reservation) |*r| r.release();
    if (dry_run) {
        // No admission: nothing is reserved, paused, counted or saved, and
        // the cap does not refuse it (the result reports what is left).
        trace.remaining_actions = state.remaining();
    } else if (call.isAction()) {
        trace.remaining_actions = state.remaining();
        reservation = state.reserve() orelse return engine_mod.automationFailure(gpa, .platform_rate_limited, "social_daily_cap", ids);
        var csprng: std.Random.DefaultCsprng = undefined;
        const random = state.delayRandom(&csprng) orelse return .{ .failure = .{ .code = engine_mod.internal_error_code, .message = "No entropy for pacing" } };
        const delay_ms = state.actionDelayMs(random);
        if (delay_ms >= runner.remainingMs()) return engine_mod.automationFailure(gpa, .action_timeout, call.deadlineReason(), ids);
        if (!runner.pause(delay_ms)) return runner.takeFailure();
    }

    // 4. The flow.
    const flow_result = if (dry_run) runDry(gpa, &runner, call, s, p) else run(gpa, &runner, call, s, p);
    const result = flow_result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidParams => return invalidParams(),
        error.LoggedOut => return engine_mod.automationFailure(gpa, .session_invalid, "logged_out", ids),
    };
    const json = result orelse return takeFailure(gpa, &runner, trace);
    // N20: a limit dialog or toast after the last click is not a success.
    if (!(try runner.finish())) {
        gpa.free(json);
        return takeFailure(gpa, &runner, trace);
    }
    if (dry_run) {
        defer gpa.free(json);
        return .{ .result = try flow_runner.withRouteChecks(gpa, json, runner.clean_scans, .{ .remaining = trace.remaining_actions.?, .cap_reason = "social_daily_cap" }) };
    }
    if (reservation) |*r| r.commit();
    return .{ .result = json };
}

/// The runner's failure; when it is a step's own failure, its data names
/// that step (`step`, the telemetry name: e.g. "navigate",
/// "waitFor_signed_in", "waitFor_story_media").
fn takeFailure(gpa: std.mem.Allocator, runner: *flow_runner.Runner, trace: *const Trace) error{OutOfMemory}!engine_mod.Outcome {
    const failed = runner.failed_step;
    const outcome = try runner.takeFailure();
    if (failed == null or failed != trace.error_step_index) return outcome;
    return flow_runner.withFailedStep(gpa, outcome, trace.error_step_buf[0..trace.error_step_len]);
}

/// S8: an approval's expectation of a flow's window (strings borrowed from the request).
const FlowExpect = struct {
    origin: []const u8,
    load_serial: u64,
    url: []const u8,
    /// S8 decision 13: the LinkedIn slug a conversation message's approval names.
    recipient: ?[]const u8 = null,
};

const FlowOptions = struct { dry_run: bool = false, expect: ?FlowExpect = null };

/// `options` of a flow request: absent -> nothing; an object of `dry_run: bool` and (S8)
/// `expect: {origin: non-empty string, load_serial: integer >= 0, url: non-empty string}`, no
/// other key, else InvalidParams. Only the acting flows take `options` (allowedParams).
fn flowOptions(value: ?std.json.Value) error{InvalidParams}!FlowOptions {
    const options = switch (value orelse return .{}) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    var out = FlowOptions{};
    var keys = options.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "dry_run")) {
            out.dry_run = switch (entry.value_ptr.*) {
                .bool => |b| b,
                else => return error.InvalidParams,
            };
        } else if (std.mem.eql(u8, key, "expect")) {
            out.expect = try flowExpect(entry.value_ptr.*);
        } else return error.InvalidParams;
    }
    return out;
}

fn flowExpect(value: std.json.Value) error{InvalidParams}!FlowExpect {
    const object = switch (value) {
        .object => |o| o,
        else => return error.InvalidParams,
    };
    var keys = object.iterator();
    while (keys.next()) |entry| {
        if (!inList(&.{ "origin", "load_serial", "url", "recipient" }, entry.key_ptr.*)) return error.InvalidParams;
    }
    const text = struct {
        fn of(o: std.json.ObjectMap, key: []const u8) error{InvalidParams}![]const u8 {
            return switch (o.get(key) orelse return error.InvalidParams) {
                .string => |t| if (t.len > 0) t else error.InvalidParams,
                else => error.InvalidParams,
            };
        }
    };
    const load_serial: u64 = switch (object.get("load_serial") orelse return error.InvalidParams) {
        .integer => |n| std.math.cast(u64, n) orelse return error.InvalidParams,
        else => return error.InvalidParams,
    };
    const recipient: ?[]const u8 = if (object.get("recipient") != null) try text.of(object, "recipient") else null;
    if (recipient) |r| if (!isRecipientSlug(r)) return error.InvalidParams;
    return .{ .origin = try text.of(object, "origin"), .load_serial = load_serial, .url = try text.of(object, "url"), .recipient = recipient };
}

/// A LinkedIn profile slug: 1 to 100 of A-Z, a-z, 0-9, `_`, `.`, `%`, `-`.
fn isRecipientSlug(slug: []const u8) bool {
    if (slug.len == 0 or slug.len > 100) return false;
    for (slug) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '%' or c == '-')) return false;
    return true;
}

/// The platform's session cookie must be in the store (never reads or
/// reports its value). Returns the failure, or null to go on.
fn sessionGate(gpa: std.mem.Allocator, env: Env, ext: *engine_mod.External, call: Call, s: flow.Site, deadline_ms: u64) error{OutOfMemory}!?engine_mod.Outcome {
    const ids = ext.ids();
    const store = env.cookies orelse return try engine_mod.automationFailure(gpa, .session_invalid, "unsupported", ids);
    const timeout_ms = @min(cookie_timeout_ms, deadline_ms -| ext.nowMs());
    if (timeout_ms == 0) return try engine_mod.automationFailure(gpa, .action_timeout, call.deadlineReason(), ids);
    const url = try std.fmt.allocPrint(gpa, "{s}/", .{s.base()});
    defer gpa.free(url);
    const text_json = store.getAll(gpa, url, timeout_ms) catch |err| return try engine_mod.automationFailure(gpa, switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => .action_timeout,
        error.Cancelled => .cancelled,
        else => .session_invalid,
    }, if (err == error.Timeout and timeout_ms < cookie_timeout_ms)
        // Cut short by the flow budget, not by the cookie store.
        call.deadlineReason()
    else
        "session_cookie_unreadable", ids);
    defer gpa.free(text_json);
    const Cookie = struct { name: []const u8 = "", value: []const u8 = "" };
    const cookies = std.json.parseFromSlice([]const Cookie, gpa, text_json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try engine_mod.automationFailure(gpa, .session_invalid, "session_cookie_unreadable", ids),
    };
    defer cookies.deinit();
    for (cookies.value) |cookie| {
        if (std.mem.eql(u8, cookie.name, call.sessionCookie()) and cookie.value.len > 0) return null;
    }
    return try engine_mod.automationFailure(gpa, .session_invalid, "logged_out", ids);
}

fn allowedParams(call: Call) []const []const u8 {
    return switch (call) {
        .linkedin => |verb| switch (verb) {
            .visit, .extract => &.{"profileUrl"},
            .follow => &.{ "profileUrl", "options" },
            .connect => &.{ "profileUrl", "note", "timeout_ms", "options" },
            .message => &.{ "text", "conversationUrl", "profileUrl", "timeout_ms", "options" },
            .like => &.{ "postUrl", "options" },
            .comment => &.{ "postUrl", "text", "timeout_ms", "options" },
            .search => &.{ "query", "searchType" },
            .selfcheck => &.{},
        },
        .instagram => |verb| switch (verb) {
            .follow => &.{ "profileUrl", "options" },
            .like => &.{ "postUrl", "options" },
            .comment => &.{ "postUrl", "text", "timeout_ms", "options" },
            .dm => &.{ "username", "text", "timeout_ms", "options" },
            .story_view => &.{ "username", "options" },
            .selfcheck => &.{},
        },
    };
}

const Params = struct {
    object: std.json.ObjectMap,

    fn get(self: Params, key: []const u8) ?[]const u8 {
        return switch (self.object.get(key) orelse return null) {
            .string => |s| s,
            else => null,
        };
    }

    fn required(self: Params, key: []const u8) error{InvalidParams}![]const u8 {
        return self.get(key) orelse error.InvalidParams;
    }
};

/// Everything that does not need the page, checked before the login gate,
/// pacing or any page step.
fn validate(gpa: std.mem.Allocator, call: Call, s: flow.Site, p: Params) error{ OutOfMemory, InvalidParams }!void {
    switch (call) {
        .linkedin => |verb| switch (verb) {
            .visit, .follow, .extract => try requireSiteUrl(s, p, "profileUrl"),
            .connect => {
                try requireSiteUrl(s, p, "profileUrl");
                // Longer notes are truncated (C42); empty or invalid ones are not notes.
                if (p.get("note")) |note| try requireText(note, std.math.maxInt(usize));
            },
            .message => {
                try requireText(try p.required("text"), linkedin.max_message_chars);
                const conversation = p.get("conversationUrl");
                const profile = p.get("profileUrl");
                if ((conversation == null) == (profile == null)) return error.InvalidParams;
                if (!s.allows(conversation orelse profile.?)) return error.InvalidParams;
            },
            .like => try requireSiteUrl(s, p, "postUrl"),
            .comment => {
                try requireSiteUrl(s, p, "postUrl");
                try requireText(try p.required("text"), linkedin.max_comment_chars);
            },
            .search => {
                const built = linkedin.searchUrl(gpa, try p.required("query"), p.get("searchType") orelse "people", s.base()) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidParams,
                };
                gpa.free(built);
            },
            .selfcheck => {},
        },
        .instagram => |verb| switch (verb) {
            .follow => try requireSiteUrl(s, p, "profileUrl"),
            .like => try requireSiteUrl(s, p, "postUrl"),
            .comment => {
                try requireSiteUrl(s, p, "postUrl");
                try requireText(try p.required("text"), instagram.max_comment_chars);
            },
            .dm, .story_view => {
                if (!instagram.isUsername(try p.required("username"))) return error.InvalidParams;
                if (verb == .dm) try requireText(try p.required("text"), instagram.max_dm_chars);
            },
            .selfcheck => {},
        },
    }
}

fn requireSiteUrl(s: flow.Site, p: Params, key: []const u8) error{InvalidParams}!void {
    if (!s.allows(try p.required(key))) return error.InvalidParams;
}

fn requireText(value: []const u8, max_chars: usize) error{InvalidParams}!void {
    linkedin.validateText(value, max_chars) catch return error.InvalidParams;
}

fn run(gpa: std.mem.Allocator, runner: *flow_runner.Runner, call: Call, s: flow.Site, p: Params) linkedin.Error!?[]u8 {
    return switch (call) {
        .linkedin => |verb| switch (verb) {
            .visit => linkedin.visit(gpa, runner, s, try p.required("profileUrl")),
            .connect => linkedin.connect(gpa, runner, s, try p.required("profileUrl"), p.get("note")),
            .follow => linkedin.follow(gpa, runner, s, try p.required("profileUrl")),
            .message => linkedin.message(gpa, runner, s, if (p.get("conversationUrl")) |conversation| .{ .conversation_url = conversation } else .{ .profile_url = try p.required("profileUrl") }, try p.required("text")),
            .like => linkedin.like(gpa, runner, s, try p.required("postUrl")),
            .comment => linkedin.comment(gpa, runner, s, try p.required("postUrl"), try p.required("text")),
            .search => linkedin.search(gpa, runner, s, try p.required("query"), p.get("searchType") orelse "people"),
            .extract => linkedin.extract(gpa, runner, s, try p.required("profileUrl")),
            .selfcheck => linkedin.selfCheck(gpa, runner),
        },
        .instagram => |verb| switch (verb) {
            .follow => instagram.follow(gpa, runner, s, try p.required("profileUrl")),
            .like => instagram.like(gpa, runner, s, try p.required("postUrl")),
            .comment => instagram.comment(gpa, runner, s, try p.required("postUrl"), try p.required("text")),
            .dm => instagram.dm(gpa, runner, s, try p.required("username"), try p.required("text")),
            .story_view => instagram.storyView(gpa, runner, s, try p.required("username")),
            .selfcheck => instagram.selfCheck(gpa, runner),
        },
    };
}

/// The dry run of a flow that allows `options` (allowedParams).
fn runDry(gpa: std.mem.Allocator, runner: *flow_runner.Runner, call: Call, s: flow.Site, p: Params) linkedin.Error!?[]u8 {
    return switch (call) {
        .linkedin => |verb| switch (verb) {
            .connect => linkedin.dryRun(gpa, runner, s, .connect, try p.required("profileUrl")),
            .follow => linkedin.dryRun(gpa, runner, s, .follow, try p.required("profileUrl")),
            .like => linkedin.dryRun(gpa, runner, s, .like, try p.required("postUrl")),
            .comment => linkedin.dryRun(gpa, runner, s, .comment, try p.required("postUrl")),
            else => error.InvalidParams,
        },
        .instagram => |verb| switch (verb) {
            .follow => instagram.dryRun(gpa, runner, s, .follow, try p.required("profileUrl")),
            .like => instagram.dryRun(gpa, runner, s, .like, try p.required("postUrl")),
            .comment => instagram.dryRun(gpa, runner, s, .comment, try p.required("postUrl")),
            .story_view => instagram.dryRun(gpa, runner, s, .story_view, try p.required("username")),
            else => error.InvalidParams,
        },
    };
}

// ---- Telemetry (EV8 compound span, EV7 step events) ----

const Hex64 = [64]u8;

fn sha256Hex(out: *Hex64, value: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    out.* = std.fmt.bytesToHex(digest, .lower);
    return out;
}

/// A selector-table name for a selector value, if it is one, or for one
/// copy of a table XPath by its position, `xpath=(<table XPath>)[n]` (a
/// LinkedIn profile action's visible copy).
fn selectorName(call: Call, selector: []const u8) ?[]const u8 {
    if (tableName(call, selector)) |name| return name;
    const prefix = "xpath=(";
    if (!std.mem.startsWith(u8, selector, prefix) or selector.len == 0 or selector[selector.len - 1] != ']') return null;
    const open = std.mem.lastIndexOf(u8, selector, ")[") orelse return null;
    const position = selector[open + 2 .. selector.len - 1];
    if (position.len == 0) return null;
    for (position) |c| if (!std.ascii.isDigit(c)) return null;
    var buf: [1024]u8 = undefined;
    const inner = std.fmt.bufPrint(&buf, "xpath={s}", .{selector[prefix.len..open]}) catch return null;
    return tableName(call, inner);
}

fn tableName(call: Call, selector: []const u8) ?[]const u8 {
    switch (call) {
        .linkedin => inline for (@typeInfo(linkedin.selectors).@"struct".decls) |decl| {
            if (std.mem.eql(u8, @field(linkedin.selectors, decl.name), selector)) return decl.name;
        },
        .instagram => inline for (@typeInfo(instagram.selectors).@"struct".decls) |decl| {
            if (std.mem.eql(u8, @field(instagram.selectors, decl.name), selector)) return decl.name;
        },
    }
    return null;
}

const Trace = struct {
    ext: *engine_mod.External,
    call: Call,
    compound_id_buf: [16]u8 = undefined,
    compound_id_len: usize = 0,
    step_index: u32 = 0,
    error_step_buf: [64]u8 = undefined,
    error_step_len: usize = 0,
    error_step_index: ?u32 = null,
    login_verified: bool = false,
    dry_run: bool = false,
    remaining_actions: ?u32 = null,
    // Bounded descriptions of the request (hashes and lengths only).
    profile_hash_buf: Hex64 = undefined,
    has_profile_hash: bool = false,
    post_hash_buf: Hex64 = undefined,
    has_post_hash: bool = false,
    conversation_hash_buf: Hex64 = undefined,
    has_conversation_hash: bool = false,
    target_host: []const u8 = "",
    note_provided: bool = false,
    note_length: usize = 0,
    note_truncated: bool = false,
    query_length: ?usize = null,

    fn init(ext: *engine_mod.External, call: Call) Trace {
        var trace = Trace{ .ext = ext, .call = call };
        const id = std.hash.Wyhash.hash(0x50c1a1, ext.ids().parent_span_id);
        trace.compound_id_len = (std.fmt.bufPrint(&trace.compound_id_buf, "{x:0>16}", .{id}) catch unreachable).len;
        return trace;
    }

    fn compoundId(self: *const Trace) []const u8 {
        return self.compound_id_buf[0..self.compound_id_len];
    }

    fn describe(self: *Trace, call: Call, s: flow.Site, p: Params) void {
        self.target_host = s.host;
        if (p.get("profileUrl") orelse p.get("username")) |profile| {
            _ = sha256Hex(&self.profile_hash_buf, profile);
            self.has_profile_hash = true;
        }
        if (p.get("conversationUrl")) |conversation| {
            _ = sha256Hex(&self.conversation_hash_buf, conversation);
            self.has_conversation_hash = true;
        }
        if (p.get("postUrl")) |post| {
            _ = sha256Hex(&self.post_hash_buf, post);
            self.has_post_hash = true;
        }
        if (call == .linkedin and call.linkedin == .connect) {
            if (p.get("note")) |note| {
                self.note_provided = true;
                self.note_length = std.unicode.utf8CountCodepoints(note) catch note.len;
                self.note_truncated = linkedin.truncateNote(note).len < note.len;
            }
        }
        if (p.get("query")) |query| self.query_length = std.unicode.utf8CountCodepoints(query) catch query.len;
    }

    fn observer(self: *Trace) flow_runner.StepObserver {
        return .{ .ctx = self, .on_step = onStep };
    }

    fn onStep(ctx: *anyopaque, method: []const u8, params_json: []const u8, ok: bool, duration_ms: u64) void {
        const self: *Trace = @ptrCast(@alignCast(ctx));
        const index = self.step_index;
        self.step_index += 1;

        var selector_buf: [1024]u8 = undefined;
        const selector = selectorOf(&selector_buf, params_json);
        const short = if (std.mem.indexOfScalar(u8, method, '.')) |dot| method[dot + 1 ..] else method;
        var step_buf: [64]u8 = undefined;
        var step_name: []const u8 = short;
        if (selector) |sel| {
            if (selectorName(self.call, sel)) |name| step_name = std.fmt.bufPrint(&step_buf, "{s}_{s}", .{ short, name }) catch short;
        }
        if (!ok) {
            const n = @min(step_name.len, self.error_step_buf.len);
            @memcpy(self.error_step_buf[0..n], step_name[0..n]);
            self.error_step_len = n;
            self.error_step_index = index;
        }
        var hash_buf: Hex64 = undefined;
        var index_buf: [12]u8 = undefined;
        var duration_buf: [24]u8 = undefined;
        var entries: [9]telemetry.AttrMap.Entry = undefined;
        var count: usize = 0;
        entries[count] = .{ .key = "social.platform", .value = self.call.namespace() };
        count += 1;
        entries[count] = .{ .key = "social.action", .value = self.call.action() };
        count += 1;
        entries[count] = .{ .key = "social.step", .value = step_name };
        count += 1;
        entries[count] = .{ .key = "social.step_index", .value = std.fmt.bufPrint(&index_buf, "{d}", .{index}) catch unreachable };
        count += 1;
        entries[count] = .{ .key = "social.primitive_method", .value = method };
        count += 1;
        if (selector) |sel| {
            entries[count] = .{ .key = "social.primitive_selector_hash", .value = sha256Hex(&hash_buf, sel) };
            count += 1;
        }
        entries[count] = .{ .key = "duration_ms", .value = std.fmt.bufPrint(&duration_buf, "{d}", .{duration_ms}) catch unreachable };
        count += 1;
        entries[count] = .{ .key = "result.status", .value = if (ok) "ok" else "error" };
        count += 1;
        self.ext.childSpanUnder("automation.social.action", null, self.compoundId(), entries[0..count]);
    }

    /// The command's `selector` param, if any (a constant from a selector
    /// table; only its hash and table name are recorded).
    fn selectorOf(buf: []u8, params_json: []const u8) ?[]const u8 {
        var fba = std.heap.FixedBufferAllocator.init(buf);
        const Shape = struct { selector: ?[]const u8 = null };
        const parsed = std.json.parseFromSliceLeaky(Shape, fba.allocator(), params_json, .{ .ignore_unknown_fields = true }) catch return null;
        return parsed.selector;
    }

    fn finish(self: *Trace, outcome: *const engine_mod.Outcome, duration_ms: u64) void {
        var bufs: [6][24]u8 = undefined;
        var entries: [20]telemetry.AttrMap.Entry = undefined;
        var count: usize = 0;
        const put = struct {
            fn f(list: *[20]telemetry.AttrMap.Entry, n: *usize, key: []const u8, value: []const u8) void {
                list[n.*] = .{ .key = key, .value = value };
                n.* += 1;
            }
        }.f;
        put(&entries, &count, "social.platform", self.call.namespace());
        put(&entries, &count, "social.action", self.call.action());
        put(&entries, &count, "social.step_count", std.fmt.bufPrint(&bufs[0], "{d}", .{self.step_index}) catch unreachable);
        if (self.has_profile_hash) put(&entries, &count, "profile.id_hash", &self.profile_hash_buf);
        if (self.has_post_hash) put(&entries, &count, "post.id_hash", &self.post_hash_buf);
        if (self.has_conversation_hash) put(&entries, &count, "conversation.id_hash", &self.conversation_hash_buf);
        if (self.target_host.len > 0) put(&entries, &count, "target.host", self.target_host);
        if (self.note_provided) {
            put(&entries, &count, "note.provided", "true");
            put(&entries, &count, "note.length", std.fmt.bufPrint(&bufs[1], "{d}", .{self.note_length}) catch unreachable);
            put(&entries, &count, "note.truncated", if (self.note_truncated) "true" else "false");
        }
        if (self.query_length) |n| put(&entries, &count, "search.query_length", std.fmt.bufPrint(&bufs[2], "{d}", .{n}) catch unreachable);
        put(&entries, &count, "duration_ms", std.fmt.bufPrint(&bufs[3], "{d}", .{duration_ms}) catch unreachable);
        const status: []const u8 = switch (outcome.*) {
            .result => "ok",
            .failure => |f| if (f.code == errors.downstreamCode(.cancelled)) "cancelled" else "error",
        };
        put(&entries, &count, "result.status", status);
        switch (outcome.*) {
            .result => {},
            .failure => |f| {
                put(&entries, &count, "automation.error", if (errors.isAutomationCode(f.code)) f.message else "internal");
                if (self.error_step_index) |i| {
                    put(&entries, &count, "error.step", self.error_step_buf[0..self.error_step_len]);
                    put(&entries, &count, "error.step_index", std.fmt.bufPrint(&bufs[4], "{d}", .{i}) catch unreachable);
                }
            },
        }
        put(&entries, &count, "platform.login_verified", if (self.login_verified) "true" else "false");
        if (self.dry_run) put(&entries, &count, "social.dry_run", "true");
        if (self.remaining_actions) |n| put(&entries, &count, "pacing.remaining_actions", std.fmt.bufPrint(&bufs[5], "{d}", .{n}) catch unreachable);
        self.ext.childSpanUnder("automation.social.compound", self.compoundId(), self.ext.ids().parent_span_id, entries[0..count]);
    }
};

fn invalidParams() engine_mod.Outcome {
    return .{ .failure = .{ .code = -32602, .message = "Invalid params" } };
}

fn inList(list: []const []const u8, item: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, item)) return true;
    }
    return false;
}
