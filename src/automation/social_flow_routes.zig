//! N16: linkedin.* and instagram.* over the automation socket. The flows
//! live in src/linkedin.zig and src/instagram.zig; each step runs as an
//! ordinary router command through Engine.External (the shared
//! flow_runner.Runner), under one root span, one page-queue turn and one
//! flow budget, exactly like x.*.
//!
//! Pacing: actions use the server's social RateLimiter (the one
//! social.rate_status / social.set_pacing report and change, default 100
//! actions a day and a 3-8 s pause before each action). At the cap an action
//! fails with -32010 reason "social_daily_cap" without touching the page;
//! only successful actions count. Reads (linkedin.extract, *.selfcheck) are
//! not paced.
const std = @import("std");
const linkedin = @import("../linkedin.zig");
const instagram = @import("../instagram.zig");
const engine_mod = @import("engine.zig");
const flow_runner = @import("flow_runner.zig");
const social_routes = @import("social_routes.zig");
const flow = @import("../flow_steps.zig");

pub const Call = union(enum) {
    linkedin: linkedin.Verb,
    instagram: instagram.Verb,

    pub fn namespace(self: Call) []const u8 {
        return @tagName(self);
    }

    fn isAction(self: Call) bool {
        return switch (self) {
            .linkedin => |verb| linkedin.isAction(verb),
            .instagram => |verb| instagram.isAction(verb),
        };
    }

    fn deadlineReason(self: Call) []const u8 {
        return switch (self) {
            .linkedin => "linkedin_flow_deadline",
            .instagram => "instagram_flow_deadline",
        };
    }
};

pub fn callFromMethod(method: []const u8) ?Call {
    if (linkedin.verbFromMethod(method)) |verb| return .{ .linkedin = verb };
    if (instagram.verbFromMethod(method)) |verb| return .{ .instagram = verb };
    return null;
}

/// One hard deadline for a whole flow, like x.*.
pub const flow_budget_ms: u64 = 120_000;

pub fn handle(
    gpa: std.mem.Allocator,
    state: *social_routes.SocialState,
    ext: *engine_mod.External,
    call: Call,
    params_json: []const u8,
) error{OutOfMemory}!engine_mod.Outcome {
    return handleWithBudget(gpa, state, ext, call, params_json, flow_budget_ms);
}

/// `handle` with an explicit flow budget (tests).
pub fn handleWithBudget(
    gpa: std.mem.Allocator,
    state: *social_routes.SocialState,
    ext: *engine_mod.External,
    call: Call,
    params_json: []const u8,
    budget_ms: u64,
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

    // Validate everything that does not need the page before pacing.
    validate(gpa, call, p) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidParams => return invalidParams(),
    };

    var runner = flow_runner.Runner{ .gpa = gpa, .ext = ext, .deadline_ms = ext.nowMs() +| budget_ms, .deadline_reason = call.deadlineReason() };
    defer runner.deinit();

    if (call.isAction()) {
        if (state.remaining() == 0) return engine_mod.automationFailure(gpa, .platform_rate_limited, "social_daily_cap", ids);
        var prng = std.Random.DefaultPrng.init(ext.nowMs() ^ 0x9e3779b97f4a7c15);
        const delay_ms = state.actionDelayMs(prng.random());
        if (delay_ms >= runner.remainingMs()) return engine_mod.automationFailure(gpa, .action_timeout, call.deadlineReason(), ids);
        if (!runner.pause(delay_ms)) return runner.takeFailure();
    }

    const flow_result = run(gpa, &runner, call, p);
    const result = flow_result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidParams => return invalidParams(),
        error.LoggedOut => return engine_mod.automationFailure(gpa, .session_invalid, "logged_out", ids),
    };
    const json = result orelse return runner.takeFailure();
    if (call.isAction()) state.consume();
    return .{ .result = json };
}

fn allowedParams(call: Call) []const []const u8 {
    return switch (call) {
        .linkedin => |verb| switch (verb) {
            .visit, .follow, .extract => &.{"profileUrl"},
            .connect => &.{ "profileUrl", "note" },
            .message => &.{ "text", "conversationUrl", "profileUrl" },
            .like => &.{"postUrl"},
            .comment => &.{ "postUrl", "text" },
            .search => &.{ "query", "searchType", "baseUrl" },
            .selfcheck => &.{},
        },
        .instagram => |verb| switch (verb) {
            .follow => &.{"profileUrl"},
            .like => &.{"postUrl"},
            .comment => &.{ "postUrl", "text" },
            .dm => &.{ "username", "text", "baseUrl" },
            .story_view => &.{ "username", "baseUrl" },
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

/// Everything that does not need the page, checked before pacing or any
/// page step: required params, URLs, usernames, text limits, the search URL.
fn validate(gpa: std.mem.Allocator, call: Call, p: Params) error{ OutOfMemory, InvalidParams }!void {
    switch (call) {
        .linkedin => |verb| switch (verb) {
            .visit, .follow, .extract => try url(p, "profileUrl"),
            .connect => {
                try url(p, "profileUrl");
                if (p.get("note")) |note| try text(note, linkedin.max_note_chars);
            },
            .message => {
                try text(try p.required("text"), linkedin.max_message_chars);
                const conversation = p.get("conversationUrl");
                const profile = p.get("profileUrl");
                if ((conversation == null) == (profile == null)) return error.InvalidParams;
                if (!flow.isPageUrl(conversation orelse profile.?)) return error.InvalidParams;
            },
            .like => try url(p, "postUrl"),
            .comment => {
                try url(p, "postUrl");
                try text(try p.required("text"), linkedin.max_comment_chars);
            },
            .search => {
                const built = linkedin.searchUrl(gpa, try p.required("query"), p.get("searchType") orelse "people", p.get("baseUrl") orelse linkedin.base_url) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidParams,
                };
                gpa.free(built);
            },
            .selfcheck => {},
        },
        .instagram => |verb| switch (verb) {
            .follow => try url(p, "profileUrl"),
            .like => try url(p, "postUrl"),
            .comment => {
                try url(p, "postUrl");
                try text(try p.required("text"), instagram.max_comment_chars);
            },
            .dm, .story_view => {
                if (!instagram.isUsername(try p.required("username"))) return error.InvalidParams;
                if (verb == .dm) try text(try p.required("text"), instagram.max_dm_chars);
                if (p.get("baseUrl")) |base| if (!flow.isPageUrl(base)) return error.InvalidParams;
            },
            .selfcheck => {},
        },
    }
}

fn url(p: Params, key: []const u8) error{InvalidParams}!void {
    if (!flow.isPageUrl(try p.required(key))) return error.InvalidParams;
}

fn text(value: []const u8, max_chars: usize) error{InvalidParams}!void {
    linkedin.validateText(value, max_chars) catch return error.InvalidParams;
}

fn run(gpa: std.mem.Allocator, runner: *flow_runner.Runner, call: Call, p: Params) linkedin.Error!?[]u8 {
    return switch (call) {
        .linkedin => |verb| switch (verb) {
            .visit => linkedin.visit(gpa, runner, try p.required("profileUrl")),
            .connect => linkedin.connect(gpa, runner, try p.required("profileUrl"), p.get("note")),
            .follow => linkedin.follow(gpa, runner, try p.required("profileUrl")),
            .message => linkedin.message(gpa, runner, if (p.get("conversationUrl")) |conversation| .{ .conversation_url = conversation } else .{ .profile_url = try p.required("profileUrl") }, try p.required("text")),
            .like => linkedin.like(gpa, runner, try p.required("postUrl")),
            .comment => linkedin.comment(gpa, runner, try p.required("postUrl"), try p.required("text")),
            .search => linkedin.search(gpa, runner, try p.required("query"), p.get("searchType") orelse "people", p.get("baseUrl") orelse linkedin.base_url),
            .extract => linkedin.extract(gpa, runner, try p.required("profileUrl")),
            .selfcheck => linkedin.selfCheck(gpa, runner),
        },
        .instagram => |verb| switch (verb) {
            .follow => instagram.follow(gpa, runner, try p.required("profileUrl")),
            .like => instagram.like(gpa, runner, try p.required("postUrl")),
            .comment => instagram.comment(gpa, runner, try p.required("postUrl"), try p.required("text")),
            .dm => instagram.dm(gpa, runner, try p.required("username"), try p.required("text"), p.get("baseUrl") orelse instagram.base_url),
            .story_view => instagram.storyView(gpa, runner, try p.required("username"), p.get("baseUrl") orelse instagram.base_url),
            .selfcheck => instagram.selfCheck(gpa, runner),
        },
    };
}

fn invalidParams() engine_mod.Outcome {
    return .{ .failure = .{ .code = -32602, .message = "Invalid params" } };
}

fn inList(list: []const []const u8, item: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, item)) return true;
    }
    return false;
}
