const std = @import("std");
const gaussian = @import("gaussian");

test "box-muller standard normal has mean≈0 and stddev≈1 over 10000 samples" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var sum: f64 = 0;
    var sum_sq: f64 = 0;
    const n: usize = 10000;
    for (0..n) |_| {
        const sample = gaussian.sampleNormal(random, 0.0, 1.0);
        sum += sample;
        sum_sq += sample * sample;
    }
    const mean = sum / @as(f64, @floatFromInt(n));
    const variance = sum_sq / @as(f64, @floatFromInt(n)) - mean * mean;
    const stddev = @sqrt(variance);

    try std.testing.expect(@abs(mean) < 0.05);
    try std.testing.expect(@abs(stddev - 1.0) < 0.05);
}

test "clamped gaussian never exceeds [min, max] over 10000 samples" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    for (0..10000) |_| {
        const sample = gaussian.sampleClamped(random, 120.0, 40.0, 80.0, 200.0);
        try std.testing.expect(sample >= 80.0);
        try std.testing.expect(sample <= 200.0);
    }
}

test "clamped gaussian with min=max returns constant" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    for (0..100) |_| {
        const sample = gaussian.sampleClamped(random, 0.0, 100.0, 50.0, 50.0);
        try std.testing.expectEqual(@as(f64, 50.0), sample);
    }
}

test "typing delays: per-char in [80,200], word boundary in [300,600]" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const profile = gaussian.TypingProfile{
        .mu_ms = 120.0,
        .sigma_ms = 40.0,
        .min_ms = 80.0,
        .max_ms = 200.0,
        .word_pause_min_ms = 300.0,
        .word_pause_max_ms = 600.0,
    };

    const delays = try gaussian.computeTypingDelays(allocator, random, "hello world", profile);
    defer allocator.free(delays);

    try std.testing.expectEqual(@as(usize, 11), delays.len);

    for (delays, 0..) |delay, i| {
        if ("hello world"[i] == ' ') {
            try std.testing.expect(delay >= 300.0);
            try std.testing.expect(delay <= 600.0);
        } else {
            try std.testing.expect(delay >= 80.0);
            try std.testing.expect(delay <= 200.0);
        }
    }
}

test "typing delays: empty string returns empty slice" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const profile = gaussian.TypingProfile.default();
    const delays = try gaussian.computeTypingDelays(allocator, random, "", profile);
    defer allocator.free(delays);
    try std.testing.expectEqual(@as(usize, 0), delays.len);
}
