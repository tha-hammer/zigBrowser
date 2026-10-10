const std = @import("std");

pub const TraceContext = struct {
    trace_id: []const u8 = "",
    command_id: []const u8 = "",
    session_id: []const u8 = "",
};

pub const PacingConfig = struct {
    min_delay_ms: u32 = 3000,
    max_delay_ms: u32 = 8000,
    daily_cap: u32 = 100,
};

pub const PacingDecision = struct {
    delay_ms: u32,
    remaining_actions: u32,
    cap_reached: bool,
};

const ms_per_day: i64 = 86_400_000;

/// N21: one limiter's state as saved in <profile>/automation-pacing.json.
pub const Persisted = struct {
    actions_today: u32 = 0,
    daily_cap: u32,
    min_delay_ms: u32,
    max_delay_ms: u32,
};

/// N21: called after a change that must be persisted (a counted action, a
/// new pacing config), never while a pacing state lock is held.
pub const ChangeHook = struct {
    ctx: *anyopaque,
    changed: *const fn (ctx: *anyopaque) void,
};

pub const RateLimiter = struct {
    config: PacingConfig,
    actions_today: u32,
    current_day: i32,
    time_fn: *const fn () i64,

    pub fn init(config: PacingConfig, time_fn: *const fn () i64) RateLimiter {
        const now = time_fn();
        return .{
            .config = config,
            .actions_today = 0,
            .current_day = dayFromTimestamp(now),
            .time_fn = time_fn,
        };
    }

    pub fn remaining(self: *RateLimiter) u32 {
        self.maybeResetDay();
        if (self.actions_today >= self.config.daily_cap) return 0;
        return self.config.daily_cap - self.actions_today;
    }

    pub fn recordAction(self: *RateLimiter, random: std.Random) !PacingDecision {
        self.maybeResetDay();
        if (self.actions_today >= self.config.daily_cap) return error.PlatformRateLimited;
        return self.consumeAction(random);
    }

    pub fn recordActionEmit(
        self: *RateLimiter,
        random: std.Random,
        sink: anytype,
        ctx: TraceContext,
        platform: []const u8,
    ) !PacingDecision {
        self.maybeResetDay();

        if (self.actions_today >= self.config.daily_cap) {
            self.emitPacingEvent(sink, ctx, platform, true);
            return error.PlatformRateLimited;
        }

        const decision = self.consumeAction(random);
        self.emitPacingEvent(sink, ctx, platform, decision.cap_reached);
        return decision;
    }

    /// Counts one action that was admitted earlier and has now succeeded:
    /// it counts even if the cap was lowered meanwhile (or the UTC day
    /// changed: it then counts for the new day).
    pub fn countAdmitted(self: *RateLimiter) void {
        self.maybeResetDay();
        self.actions_today +|= 1;
    }

    pub fn updateConfig(self: *RateLimiter, config: PacingConfig) void {
        self.config = config;
    }

    /// The saved config always applies; the saved count only if it was
    /// saved on today's UTC day (else the day has reset it).
    pub fn restore(self: *RateLimiter, saved: Persisted, day: i32) void {
        self.maybeResetDay();
        self.config = .{ .min_delay_ms = saved.min_delay_ms, .max_delay_ms = saved.max_delay_ms, .daily_cap = saved.daily_cap };
        self.actions_today = if (day == self.current_day) saved.actions_today else 0;
    }

    /// Today's state (UTC day, after any reset) for saving.
    pub fn persisted(self: *RateLimiter) struct { part: Persisted, day: i32 } {
        self.maybeResetDay();
        return .{ .part = .{
            .actions_today = self.actions_today,
            .daily_cap = self.config.daily_cap,
            .min_delay_ms = self.config.min_delay_ms,
            .max_delay_ms = self.config.max_delay_ms,
        }, .day = self.current_day };
    }

    fn consumeAction(self: *RateLimiter, random: std.Random) PacingDecision {
        self.actions_today += 1;
        const range = self.config.max_delay_ms - self.config.min_delay_ms;
        const delay = self.config.min_delay_ms + @as(u32, @intFromFloat(random.float(f64) * @as(f64, @floatFromInt(range))));
        const rem = self.config.daily_cap - self.actions_today;
        return .{ .delay_ms = delay, .remaining_actions = rem, .cap_reached = rem == 0 };
    }

    fn emitPacingEvent(_: *RateLimiter, sink: anytype, ctx: TraceContext, platform: []const u8, cap_reached: bool) void {
        var attrs = sink.newAttrs();
        attrs.put("trace_id", ctx.trace_id);
        attrs.put("command_id", ctx.command_id);
        attrs.put("platform.name", platform);
        attrs.putBool("pacing.cap_reached", cap_reached);
        sink.addEvent(.{ .trace_id = ctx.trace_id, .span_id = "" }, "automation.pacing.decision", attrs);
    }

    fn maybeResetDay(self: *RateLimiter) void {
        const today = dayFromTimestamp(self.time_fn());
        if (today != self.current_day) {
            self.actions_today = 0;
            self.current_day = today;
        }
    }

    fn dayFromTimestamp(ms: i64) i32 {
        return @intCast(@divFloor(ms, ms_per_day));
    }
};
