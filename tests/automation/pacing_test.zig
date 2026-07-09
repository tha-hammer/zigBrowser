const std = @import("std");
const pacing = @import("pacing");

test "rate limiter tracks remaining actions and returns delay" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const test_time = struct {
        var now_ms: i64 = 1_720_000_000_000;
        fn get() i64 {
            return now_ms;
        }
    };

    var limiter = pacing.RateLimiter.init(.{
        .min_delay_ms = 3000,
        .max_delay_ms = 8000,
        .daily_cap = 100,
    }, test_time.get);

    try std.testing.expectEqual(@as(u32, 100), limiter.remaining());

    const decision = try limiter.recordAction(random);
    try std.testing.expectEqual(@as(u32, 99), limiter.remaining());
    try std.testing.expect(decision.delay_ms >= 3000);
    try std.testing.expect(decision.delay_ms <= 8000);
    try std.testing.expect(!decision.cap_reached);
}

test "rate limiter returns error at daily cap" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const test_time = struct {
        var now_ms: i64 = 1_720_000_000_000;
        fn get() i64 {
            return now_ms;
        }
    };

    var limiter = pacing.RateLimiter.init(.{
        .min_delay_ms = 100,
        .max_delay_ms = 200,
        .daily_cap = 3,
    }, test_time.get);

    _ = try limiter.recordAction(random);
    _ = try limiter.recordAction(random);
    _ = try limiter.recordAction(random);
    try std.testing.expectEqual(@as(u32, 0), limiter.remaining());

    try std.testing.expectError(error.PlatformRateLimited, limiter.recordAction(random));
}

test "rate limiter resets at midnight" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const test_time = struct {
        var now_ms: i64 = 1_720_000_000_000;
        fn get() i64 {
            return now_ms;
        }
    };

    var limiter = pacing.RateLimiter.init(.{
        .min_delay_ms = 100,
        .max_delay_ms = 200,
        .daily_cap = 5,
    }, test_time.get);

    _ = try limiter.recordAction(random);
    _ = try limiter.recordAction(random);
    _ = try limiter.recordAction(random);
    try std.testing.expectEqual(@as(u32, 2), limiter.remaining());

    test_time.now_ms += 86_400_000;

    try std.testing.expectEqual(@as(u32, 5), limiter.remaining());
    const decision = try limiter.recordAction(random);
    try std.testing.expectEqual(@as(u32, 4), decision.remaining_actions);
}

test "updateConfig changes delay range and cap" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const test_time = struct {
        var now_ms: i64 = 1_720_000_000_000;
        fn get() i64 {
            return now_ms;
        }
    };

    var limiter = pacing.RateLimiter.init(.{
        .min_delay_ms = 3000,
        .max_delay_ms = 8000,
        .daily_cap = 100,
    }, test_time.get);

    _ = try limiter.recordAction(random);
    _ = try limiter.recordAction(random);

    limiter.updateConfig(.{
        .min_delay_ms = 1000,
        .max_delay_ms = 2000,
        .daily_cap = 50,
    });

    try std.testing.expectEqual(@as(u32, 48), limiter.remaining());

    const decision = try limiter.recordAction(random);
    try std.testing.expect(decision.delay_ms >= 1000);
    try std.testing.expect(decision.delay_ms <= 2000);
}

test "reducing cap below current count triggers rate limit" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const test_time = struct {
        var now_ms: i64 = 1_720_000_000_000;
        fn get() i64 {
            return now_ms;
        }
    };

    var limiter = pacing.RateLimiter.init(.{ .daily_cap = 10 }, test_time.get);
    for (0..8) |_| _ = try limiter.recordAction(random);

    limiter.updateConfig(.{ .daily_cap = 5 });
    try std.testing.expectError(error.PlatformRateLimited, limiter.recordAction(random));
}
