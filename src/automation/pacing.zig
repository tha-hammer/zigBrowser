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

        self.actions_today += 1;
        const range = self.config.max_delay_ms - self.config.min_delay_ms;
        const delay = self.config.min_delay_ms + @as(u32, @intFromFloat(random.float(f64) * @as(f64, @floatFromInt(range))));
        const rem = self.config.daily_cap - self.actions_today;

        return .{
            .delay_ms = delay,
            .remaining_actions = rem,
            .cap_reached = rem == 0,
        };
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
            var attrs = sink.newAttrs();
            attrs.put("trace_id", ctx.trace_id);
            attrs.put("command_id", ctx.command_id);
            attrs.put("platform.name", platform);
            attrs.putBool("pacing.cap_reached", true);
            sink.addEvent(.{ .trace_id = ctx.trace_id, .span_id = "" }, "automation.pacing.decision", attrs);
            return error.PlatformRateLimited;
        }

        self.actions_today += 1;
        const range = self.config.max_delay_ms - self.config.min_delay_ms;
        const delay = self.config.min_delay_ms + @as(u32, @intFromFloat(random.float(f64) * @as(f64, @floatFromInt(range))));
        const rem = self.config.daily_cap - self.actions_today;

        var attrs = sink.newAttrs();
        attrs.put("trace_id", ctx.trace_id);
        attrs.put("command_id", ctx.command_id);
        attrs.put("platform.name", platform);
        attrs.putBool("pacing.cap_reached", rem == 0);
        sink.addEvent(.{ .trace_id = ctx.trace_id, .span_id = "" }, "automation.pacing.decision", attrs);

        return .{
            .delay_ms = delay,
            .remaining_actions = rem,
            .cap_reached = rem == 0,
        };
    }

    pub fn updateConfig(self: *RateLimiter, config: PacingConfig) void {
        self.config = config;
    }

    fn maybeResetDay(self: *RateLimiter) void {
        const today = dayFromTimestamp(self.time_fn());
        if (today != self.current_day) {
            self.actions_today = 0;
            self.current_day = today;
        }
    }

    fn dayFromTimestamp(ms: i64) i32 {
        return @intCast(@divFloor(ms, 86_400_000));
    }
};
