//! N11: x.post / x.schedule_post / x.login_check over the automation socket.
//! The flows live in src/x.zig; each step runs as an ordinary router command
//! through Engine.External.runCommand, so it gets retries, actionability
//! checks and telemetry under the x.* command's single root span.
const std = @import("std");
const x = @import("../x.zig");
const pacing = @import("pacing.zig");
const engine_mod = @import("engine.zig");

pub const Verb = x.Verb;

pub fn verbFromMethod(method: []const u8) ?Verb {
    return x.verbFromMethod(method);
}

/// X actions (posts and scheduled posts) allowed per UTC day.
pub const default_daily_cap: u32 = 50;

/// Per-server X pacing. Delays are 0: the flows already move at UI speed;
/// the cap is what protects the account.
pub const XState = struct {
    lock: std.atomic.Mutex = .unlocked,
    limiter: pacing.RateLimiter,

    pub fn init(wall_ms: *const fn () i64) XState {
        return .{ .limiter = pacing.RateLimiter.init(.{ .min_delay_ms = 0, .max_delay_ms = 0, .daily_cap = default_daily_cap }, wall_ms) };
    }

    pub fn remaining(self: *XState) u32 {
        self.acquire();
        defer self.lock.unlock();
        return self.limiter.remaining();
    }

    fn consume(self: *XState) void {
        self.acquire();
        defer self.lock.unlock();
        var prng = std.Random.DefaultPrng.init(0);
        _ = self.limiter.recordAction(prng.random()) catch {};
    }

    fn acquire(self: *XState) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }
};

/// Runner for src/x.zig: one command per call, keeping the last result
/// (borrowed by the flow until the next call) and the first failure.
const Runner = struct {
    gpa: std.mem.Allocator,
    ext: *engine_mod.External,
    last_result: ?engine_mod.Outcome = null,
    failure: ?engine_mod.Outcome = null,

    pub fn run(self: *Runner, method: []const u8, params_json: []const u8) error{OutOfMemory}!?[]const u8 {
        const outcome = try self.ext.runCommand(self.gpa, method, params_json);
        switch (outcome) {
            .result => |json| {
                self.dropResult();
                self.last_result = outcome;
                return json;
            },
            .failure => {
                if (self.failure) |*old| old.deinit(self.gpa);
                self.failure = outcome;
                return null;
            },
        }
    }

    fn dropResult(self: *Runner) void {
        if (self.last_result) |*old| old.deinit(self.gpa);
        self.last_result = null;
    }

    fn deinit(self: *Runner) void {
        self.dropResult();
        if (self.failure) |*f| f.deinit(self.gpa);
    }

    /// Hands the recorded failure to the caller.
    fn takeFailure(self: *Runner) engine_mod.Outcome {
        const f = self.failure.?;
        self.failure = null;
        return f;
    }
};

pub fn handle(
    gpa: std.mem.Allocator,
    state: *XState,
    ext: *engine_mod.External,
    verb: Verb,
    params_json: []const u8,
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
        .post => &.{ "text", "compose_url" },
        .schedule_post => &.{ "text", "date", "time", "compose_url" },
        .login_check => &.{},
    };
    var keys = params.iterator();
    while (keys.next()) |entry| {
        if (!inList(allowed, entry.key_ptr.*)) return invalidParams();
    }

    var runner = Runner{ .gpa = gpa, .ext = ext };
    defer runner.deinit();

    const flow_result: x.Error!?[]u8 = switch (verb) {
        .login_check => x.loginCheck(gpa, &runner),
        .post, .schedule_post => blk: {
            const text = stringField(params, "text") orelse return invalidParams();
            const compose_url = if (params.get("compose_url")) |_| (stringField(params, "compose_url") orelse return invalidParams()) else x.compose_url;
            if (state.remaining() == 0) return engine_mod.automationFailure(gpa, .platform_rate_limited, "x_daily_cap", ids);
            break :blk if (verb == .post)
                x.post(gpa, &runner, .{ .text = text, .compose_url = compose_url })
            else
                x.schedulePost(gpa, &runner, .{
                    .text = text,
                    .date = stringField(params, "date") orelse return invalidParams(),
                    .time = stringField(params, "time") orelse return invalidParams(),
                    .compose_url = compose_url,
                });
        },
    };
    const result = flow_result catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidParams => return invalidParams(),
        error.LoggedOut => return engine_mod.automationFailure(gpa, .session_invalid, "logged_out", ids),
    };
    const json = result orelse return runner.takeFailure();
    if (verb != .login_check) state.consume();
    return .{ .result = json };
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
