//! N11: x.post / x.schedule_post / x.login_check over the automation socket.
//! The flows live in src/x.zig; each step runs as an ordinary router command
//! through Engine.External.runCommand, so it gets retries, actionability
//! checks and telemetry under the x.* command's single root span.
const std = @import("std");
const x = @import("../x.zig");
const pacing = @import("pacing.zig");
const engine_mod = @import("engine.zig");
const script_command = @import("script_command.zig");

pub const Verb = x.Verb;

pub fn verbFromMethod(method: []const u8) ?Verb {
    return x.verbFromMethod(method);
}

/// One hard deadline for a whole x.* flow. src/x.zig clamps every step's
/// timeout to what is left (waitFor also leaves room for its 1 s native
/// grace), and no step starts once it is spent, so a flow holds the page
/// queue for at most this long (plus the last native call's own rounding).
pub const flow_budget_ms: u64 = 120_000;

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

/// Runner for src/x.zig (see the runner contract there): one command per
/// call, keeping the last result (borrowed by the flow until the next call)
/// and the failure of the latest step. Every failure it hands out carries
/// the x.* command's trace_id/command_id.
pub const Runner = struct {
    gpa: std.mem.Allocator,
    ext: *engine_mod.External,
    deadline_ms: u64,
    last_result: ?engine_mod.Outcome = null,
    failure: ?engine_mod.Outcome = null,

    pub fn run(self: *Runner, method: []const u8, params_json: []const u8) error{OutOfMemory}!?[]const u8 {
        if (self.remainingMs() == 0) {
            self.setFailure(try engine_mod.automationFailure(self.gpa, .action_timeout, "x_flow_deadline", self.ext.ids()));
            return null;
        }
        const outcome = try self.ext.runCommand(self.gpa, method, params_json);
        switch (outcome) {
            .result => |json| {
                // A step that succeeded supersedes any earlier failure.
                self.clearFailure();
                self.dropResult();
                self.last_result = outcome;
                return json;
            },
            .failure => {
                self.setFailure(outcome);
                return null;
            },
        }
    }

    pub fn nowMs(self: *const Runner) u64 {
        return self.ext.nowMs();
    }

    pub fn remainingMs(self: *const Runner) u64 {
        return self.deadline_ms -| self.ext.nowMs();
    }

    pub fn pause(self: *Runner, ms: u64) bool {
        if (self.ext.pause(ms)) return true;
        const cancelled = engine_mod.automationFailure(self.gpa, .cancelled, null, self.ext.ids()) catch {
            self.clearFailure();
            return false;
        };
        self.setFailure(cancelled);
        return false;
    }

    /// The latest step succeeded but its answer was unusable.
    pub fn malformed(self: *Runner) error{OutOfMemory}!void {
        self.setFailure(try internalFailure(self.gpa, self.ext.ids()));
    }

    pub fn notFound(self: *Runner, reason: []const u8) error{OutOfMemory}!void {
        self.setFailure(try engine_mod.automationFailure(self.gpa, .element_not_found, reason, self.ext.ids()));
    }

    fn setFailure(self: *Runner, outcome: engine_mod.Outcome) void {
        self.clearFailure();
        self.failure = outcome;
    }

    fn clearFailure(self: *Runner) void {
        if (self.failure) |*old| old.deinit(self.gpa);
        self.failure = null;
    }

    fn dropResult(self: *Runner) void {
        if (self.last_result) |*old| old.deinit(self.gpa);
        self.last_result = null;
    }

    fn deinit(self: *Runner) void {
        self.dropResult();
        if (self.failure) |*f| f.deinit(self.gpa);
    }

    /// Hands the recorded failure to the caller. src/x.zig records one for
    /// every null it returns; if a flow ever stops without one, that is an
    /// internal error (still with ids), never a stale or missing failure.
    pub fn takeFailure(self: *Runner) error{OutOfMemory}!engine_mod.Outcome {
        const f = self.failure orelse return internalFailure(self.gpa, self.ext.ids());
        self.failure = null;
        return f;
    }
};

/// -32603 "Unexpected page answer" with `data.{trace_id, command_id}`.
fn internalFailure(gpa: std.mem.Allocator, ids: script_command.Ids) error{OutOfMemory}!engine_mod.Outcome {
    const Data = struct { trace_id: []const u8, command_id: []const u8 };
    return .{ .failure = .{
        .code = engine_mod.internal_error_code,
        .message = "Unexpected page answer",
        .data_json = try std.json.Stringify.valueAlloc(gpa, Data{ .trace_id = ids.trace_id, .command_id = ids.command_id }, .{}),
    } };
}

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

    var runner = Runner{ .gpa = gpa, .ext = ext, .deadline_ms = ext.nowMs() +| flow_budget_ms };
    defer runner.deinit();

    const flow_result: x.Error!?[]u8 = switch (verb) {
        .login_check => x.loginCheck(gpa, &runner),
        .post, .schedule_post => blk: {
            const text = stringField(params, "text") orelse return invalidParams();
            // `compose_url` is a deliberate public override of the page the
            // flow opens (fixtures, x.com mirrors). It grants nothing new: the
            // same client may already page.navigate anywhere. Default: x.com.
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
