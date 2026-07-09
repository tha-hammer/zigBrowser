const std = @import("std");

pub const SessionConfig = struct {
    warmup_ms: u64 = 30_000,
    break_interval_ms: u64 = 600_000,
    break_duration_min_ms: u64 = 300_000,
    break_duration_max_ms: u64 = 900_000,
    session_duration_mean_ms: u64 = 3_600_000,
    session_duration_sigma_ms: u64 = 600_000,
};

pub const SessionSimulator = struct {
    config: SessionConfig,
    start_ms: i64,
    last_break_ms: i64,
    last_activity_ms: i64,
    break_count: u32,
    time_fn: *const fn () i64,

    pub fn init(config: SessionConfig, time_fn: *const fn () i64) SessionSimulator {
        const now = time_fn();
        return .{
            .config = config,
            .start_ms = now,
            .last_break_ms = now,
            .last_activity_ms = now,
            .break_count = 0,
            .time_fn = time_fn,
        };
    }

    pub fn isInWarmup(self: *SessionSimulator) bool {
        if (self.config.warmup_ms == 0) return false;
        const elapsed: u64 = @intCast(self.time_fn() - self.start_ms);
        return elapsed < self.config.warmup_ms;
    }

    pub fn shouldBreak(self: *SessionSimulator) bool {
        const since_break: u64 = @intCast(self.time_fn() - self.last_break_ms);
        return since_break >= self.config.break_interval_ms;
    }

    pub fn takeBreak(self: *SessionSimulator, random: std.Random) u64 {
        const range = self.config.break_duration_max_ms - self.config.break_duration_min_ms;
        const duration = self.config.break_duration_min_ms + @as(u64, @intFromFloat(random.float(f64) * @as(f64, @floatFromInt(range))));
        self.last_break_ms = self.time_fn() + @as(i64, @intCast(duration));
        self.break_count += 1;
        return duration;
    }

    pub fn recordActivity(self: *SessionSimulator) void {
        self.last_activity_ms = self.time_fn();
    }

    pub fn elapsedMs(self: *SessionSimulator) u64 {
        return @intCast(self.time_fn() - self.start_ms);
    }
};
