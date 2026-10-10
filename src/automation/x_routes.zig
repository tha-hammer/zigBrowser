//! N11: x.post / x.schedule_post / x.login_check (and N13 x.selfcheck) over
//! the automation socket.
//! The flows live in src/x.zig; each step runs as an ordinary router command
//! through Engine.External.runCommand, so it gets retries, actionability
//! checks and telemetry under the x.* command's single root span.
const std = @import("std");
const x = @import("../x.zig");
const pacing = @import("pacing.zig");
const engine_mod = @import("engine.zig");
const flow_runner = @import("flow_runner.zig");
const flow = @import("../flow_steps.zig");

pub const Verb = x.Verb;

pub fn verbFromMethod(method: []const u8) ?Verb {
    return x.verbFromMethod(method);
}

/// One hard deadline for a whole x.* flow. src/x.zig clamps every step's
/// timeout to what is left (waitFor also leaves room for its 1 s native
/// grace), and no step starts once it is spent, so a flow holds the page
/// queue for at most this long (plus the last native call's own rounding).
/// This is the default; x.post / x.schedule_post may set `timeout_ms` (at
/// most 600 s), and a humanized flow is sized from its typing schedule
/// (flow_steps.flowBudgetMs).
pub const flow_budget_ms: u64 = flow.default_flow_budget_ms;

/// X actions (posts and scheduled posts) allowed per UTC day.
pub const default_daily_cap: u32 = 50;

/// Per-server X pacing. Delays are 0: the flows already move at UI speed;
/// the cap is what protects the account.
pub const XState = struct {
    lock: std.atomic.Mutex = .unlocked,
    limiter: pacing.RateLimiter,
    /// N21: told after a counted post (persisted by the server).
    on_change: ?pacing.ChangeHook = null,

    pub fn init(wall_ms: *const fn () i64) XState {
        return .{ .limiter = pacing.RateLimiter.init(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = default_daily_cap }, wall_ms) };
    }

    pub fn remaining(self: *XState) u32 {
        self.acquire();
        defer self.lock.unlock();
        return self.limiter.remaining();
    }

    /// Counts one successful post or scheduled post.
    pub fn consume(self: *XState) void {
        {
            self.acquire();
            defer self.lock.unlock();
            var prng = std.Random.DefaultPrng.init(0);
            _ = self.limiter.recordAction(prng.random()) catch {};
        }
        if (self.on_change) |hook| hook.changed(hook.ctx);
    }

    /// N21: state loaded at startup (see RateLimiter.restore).
    pub fn restore(self: *XState, saved: pacing.Persisted, day: i32) void {
        self.acquire();
        defer self.lock.unlock();
        self.limiter.restore(saved, day);
    }

    pub fn persisted(self: *XState) @typeInfo(@TypeOf(pacing.RateLimiter.persisted)).@"fn".return_type.? {
        self.acquire();
        defer self.lock.unlock();
        return self.limiter.persisted();
    }

    fn acquire(self: *XState) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }
};

pub const Runner = flow_runner.Runner;


pub fn handle(
    gpa: std.mem.Allocator,
    state: *XState,
    ext: *engine_mod.External,
    verb: Verb,
    params_json: []const u8,
) error{OutOfMemory}!engine_mod.Outcome {
    return handleWithBudget(gpa, state, ext, verb, params_json, flow_budget_ms);
}

/// `handle` with an explicit flow budget (tests reach the budget edges
/// without a page call that outlives its own timeout).
pub fn handleWithBudget(
    gpa: std.mem.Allocator,
    state: *XState,
    ext: *engine_mod.External,
    verb: Verb,
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
    const allowed: []const []const u8 = switch (verb) {
        .post => &.{ "text", "compose_url", "options", "timeout_ms" },
        .schedule_post => &.{ "text", "date", "time", "compose_url", "options", "timeout_ms" },
        .login_check, .selfcheck => &.{},
    };
    var keys = params.iterator();
    while (keys.next()) |entry| {
        if (!inList(allowed, entry.key_ptr.*)) return invalidParams();
    }

    // The flow budget: the request's timeout_ms (at most 600 s); else, for
    // a humanized flow, the default plus its typing's worst case; else the
    // default.
    const explicit_ms = flow.flowTimeoutParam(params.get("timeout_ms")) catch return invalidParams();
    var humanized_text: ?[]const u8 = null;
    if (verb == .post or verb == .schedule_post) {
        if (inputOptions(params)) |input| {
            if (input.humanize) humanized_text = stringField(params, "text");
        }
    }
    const flow_ms = flow.flowBudgetMs(budget_ms, explicit_ms, humanized_text);
    var runner = Runner{ .gpa = gpa, .ext = ext, .deadline_ms = ext.nowMs() +| flow_ms, .deadline_reason = "x_flow_deadline", .platform = "x" };
    defer runner.deinit();

    const flow_result: x.Error!?[]u8 = switch (verb) {
        .login_check => x.loginCheck(gpa, &runner),
        .selfcheck => x.selfCheck(gpa, &runner),
        .post, .schedule_post => blk: {
            const text = stringField(params, "text") orelse return invalidParams();
            // `compose_url` is a deliberate public override of the page the
            // flow opens (fixtures, x.com mirrors). It grants nothing new: the
            // same client may already page.navigate anywhere. Default: x.com.
            const compose_url = if (params.get("compose_url")) |_| (stringField(params, "compose_url") orelse return invalidParams()) else x.compose_url;
            const input = inputOptions(params) orelse return invalidParams();
            if (state.remaining() == 0) return engine_mod.automationFailure(gpa, .platform_rate_limited, "x_daily_cap", ids);
            break :blk if (verb == .post)
                x.post(gpa, &runner, .{ .text = text, .compose_url = compose_url, .input = input })
            else
                x.schedulePost(gpa, &runner, .{
                    .text = text,
                    .date = stringField(params, "date") orelse return invalidParams(),
                    .time = stringField(params, "time") orelse return invalidParams(),
                    .compose_url = compose_url,
                    .input = input,
                });
        },
    };
    const result = flow_result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidParams => return invalidParams(),
        error.LoggedOut => return engine_mod.automationFailure(gpa, .session_invalid, "logged_out", ids),
    };
    const json = result orelse return runner.takeFailure();
    // N20: a limit dialog or toast after the last click is not a success.
    if (!(try runner.finish())) {
        gpa.free(json);
        return runner.takeFailure();
    }
    // Only posts and scheduled posts are paced; checks are read-only.
    if (verb == .post or verb == .schedule_post) state.consume();
    return .{ .result = json };
}

/// `options: {input?: "synthetic"|"native", humanize?: bool}` (the N7/N8
/// rules: humanize needs native input); null when malformed.
fn inputOptions(params: std.json.ObjectMap) ?x.Input {
    const options = switch (params.get("options") orelse return .{}) {
        .object => |o| o,
        else => return null,
    };
    var input = x.Input{};
    var keys = options.iterator();
    while (keys.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "input")) {
            const mode = switch (entry.value_ptr.*) {
                .string => |s| s,
                else => return null,
            };
            if (std.mem.eql(u8, mode, "native")) input.native = true else if (!std.mem.eql(u8, mode, "synthetic")) return null;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "humanize")) {
            input.humanize = switch (entry.value_ptr.*) {
                .bool => |b| b,
                else => return null,
            };
        } else return null;
    }
    if (input.humanize and !input.native) return null;
    return input;
}

fn invalidParams() engine_mod.Outcome {
    return .{ .failure = .{ .code = -32602, .message = "Invalid params" } };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

fn inList(list: []const []const u8, item: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, item)) return true;
    }
    return false;
}
