const std = @import("std");
const session = @import("session");

test "session starts in warmup period" {
    const test_time = struct {
        var now_ms: i64 = 1_720_000_000_000;
        fn get() i64 {
            return now_ms;
        }
    };

    var sim = session.SessionSimulator.init(.{
        .warmup_ms = 30_000,
        .break_interval_ms = 600_000,
        .break_duration_min_ms = 300_000,
        .break_duration_max_ms = 900_000,
        .session_duration_mean_ms = 3_600_000,
        .session_duration_sigma_ms = 600_000,
    }, test_time.get);

    try std.testing.expect(sim.isInWarmup());

    test_time.now_ms += 30_000;
    try std.testing.expect(!sim.isInWarmup());
}

test "session with zero warmup is never in warmup" {
    const test_time = struct {
        var now_ms: i64 = 1_720_000_000_000;
        fn get() i64 {
            return now_ms;
        }
    };

    var sim = session.SessionSimulator.init(.{
        .warmup_ms = 0,
    }, test_time.get);

    try std.testing.expect(!sim.isInWarmup());
}

test "session requests break after sustained activity" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const test_time = struct {
        var now_ms: i64 = 1_720_000_000_000;
        fn get() i64 {
            return now_ms;
        }
    };

    var sim = session.SessionSimulator.init(.{
        .warmup_ms = 0,
        .break_interval_ms = 600_000,
        .break_duration_min_ms = 300_000,
        .break_duration_max_ms = 900_000,
    }, test_time.get);

    try std.testing.expect(!sim.shouldBreak());

    test_time.now_ms += 900_000;
    sim.recordActivity();

    try std.testing.expect(sim.shouldBreak());

    const break_duration = sim.takeBreak(random);
    try std.testing.expect(break_duration >= 300_000);
    try std.testing.expect(break_duration <= 900_000);

    test_time.now_ms += @intCast(break_duration);
    try std.testing.expect(!sim.shouldBreak());
}
