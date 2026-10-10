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
};

/// One hard deadline for a whole flow, like x.*.
pub const flow_budget_ms: u64 = 120_000;

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
    // One absolute deadline for everything below: cookie gate, pacing
    // pause and every flow step.
    const deadline_ms = started +| budget_ms;
    var trace = Trace.init(ext, call);
    const outcome = try execute(gpa, state, env, ext, call, params_json, deadline_ms, &trace);
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
    deadline_ms: u64,
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
        // Every allowed param is a string.
        if (entry.value_ptr.* != .string) return invalidParams();
    }
    const p = Params{ .object = params };
    const s = call.site(env);

    // 1. Everything that needs no page, before the gate and pacing.
    validate(gpa, call, s, p) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidParams => return invalidParams(),
    };
    trace.describe(call, s, p);

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
    };
    defer runner.deinit();

    // 3. Pacing for actions: reserve, pause, then commit (success) or
    //    release (any other way out).
    var reservation: ?social_routes.SocialState.Reservation = null;
    defer if (reservation) |*r| r.release();
    if (call.isAction()) {
        trace.remaining_actions = state.remaining();
        reservation = state.reserve() orelse return engine_mod.automationFailure(gpa, .platform_rate_limited, "social_daily_cap", ids);
        var csprng: std.Random.DefaultCsprng = undefined;
        const random = state.delayRandom(&csprng) orelse return .{ .failure = .{ .code = engine_mod.internal_error_code, .message = "No entropy for pacing" } };
        const delay_ms = state.actionDelayMs(random);
        if (delay_ms >= runner.remainingMs()) return engine_mod.automationFailure(gpa, .action_timeout, call.deadlineReason(), ids);
        if (!runner.pause(delay_ms)) return runner.takeFailure();
    }

    // 4. The flow.
    const flow_result = run(gpa, &runner, call, s, p);
    const result = flow_result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidParams => return invalidParams(),
        error.LoggedOut => return engine_mod.automationFailure(gpa, .session_invalid, "logged_out", ids),
    };
    const json = result orelse return runner.takeFailure();
    if (reservation) |*r| r.commit();
    return .{ .result = json };
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
            .visit, .follow, .extract => &.{"profileUrl"},
            .connect => &.{ "profileUrl", "note" },
            .message => &.{ "text", "conversationUrl", "profileUrl" },
            .like => &.{"postUrl"},
            .comment => &.{ "postUrl", "text" },
            .search => &.{ "query", "searchType" },
            .selfcheck => &.{},
        },
        .instagram => |verb| switch (verb) {
            .follow => &.{"profileUrl"},
            .like => &.{"postUrl"},
            .comment => &.{ "postUrl", "text" },
            .dm => &.{ "username", "text" },
            .story_view => &.{"username"},
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

// ---- Telemetry (EV8 compound span, EV7 step events) ----

const Hex64 = [64]u8;

fn sha256Hex(out: *Hex64, value: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    out.* = std.fmt.bytesToHex(digest, .lower);
    return out;
}

/// A selector-table name for a selector value, if it is one.
fn selectorName(call: Call, selector: []const u8) ?[]const u8 {
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
                const in_taxonomy = f.code <= errors.downstreamCode(.element_not_found) and f.code >= errors.downstreamCode(.cancelled);
                put(&entries, &count, "automation.error", if (in_taxonomy) f.message else "internal");
                if (self.error_step_index) |i| {
                    put(&entries, &count, "error.step", self.error_step_buf[0..self.error_step_len]);
                    put(&entries, &count, "error.step_index", std.fmt.bufPrint(&bufs[4], "{d}", .{i}) catch unreachable);
                }
            },
        }
        put(&entries, &count, "platform.login_verified", if (self.login_verified) "true" else "false");
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
