const std = @import("std");
const pacing = @import("pacing");
const stealth = @import("stealth");

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

test "recordActionEmit emits automation.pacing.decision event with required dimensions" {
    var sink = stealth.TestTelemetrySink.init(std.testing.allocator);
    defer sink.deinit();

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

    const ctx = pacing.TraceContext{
        .trace_id = "trace-abc",
        .command_id = "cmd-123",
        .session_id = "sess-xyz",
    };

    _ = try limiter.recordActionEmit(random, &sink, ctx, "linkedin");

    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    const event = sink.events.items[0];
    try std.testing.expectEqualStrings("automation.pacing.decision", event.name);

    // Required dimensions
    try std.testing.expect(event.attrs.contains("trace_id"));
    try std.testing.expect(event.attrs.contains("command_id"));
    try std.testing.expectEqualStrings("linkedin", event.attrs.get("platform.name").?);
    try std.testing.expectEqualStrings("false", event.attrs.get("pacing.cap_reached").?);

    // C48 deny-list
    const forbidden = [_][]const u8{
        "text", "cookie", "token", "password", "secret",
        "raw_text", "message", "value", "screenshot",
    };
    for (forbidden) |key| {
        try std.testing.expect(!event.attrs.contains(key));
    }
}

test "cap-reached recordActionEmit still emits EV9 before returning error" {
    var sink = stealth.TestTelemetrySink.init(std.testing.allocator);
    defer sink.deinit();

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
        .daily_cap = 1,
    }, test_time.get);

    const ctx = pacing.TraceContext{
        .trace_id = "t",
        .command_id = "c",
        .session_id = "s",
    };

    _ = try limiter.recordActionEmit(random, &sink, ctx, "instagram");

    // Second action should emit EV9 with cap_reached=true, then error
    try std.testing.expectError(
        error.PlatformRateLimited,
        limiter.recordActionEmit(random, &sink, ctx, "instagram"),
    );

    // EV9 still emitted for the cap-reached decision
    try std.testing.expectEqual(@as(usize, 2), sink.events.items.len);
    const last_event = sink.events.items[1];
    try std.testing.expectEqualStrings("true", last_event.attrs.get("pacing.cap_reached").?);
}
