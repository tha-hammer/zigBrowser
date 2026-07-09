const std = @import("std");

pub fn sampleNormal(random: std.Random, mu: f64, sigma: f64) f64 {
    if (sigma == 0.0) return mu;
    const r1 = random.float(f64);
    const r2 = random.float(f64);
    const z0 = @sqrt(-2.0 * @log(r1)) * @cos(2.0 * std.math.pi * r2);
    return mu + sigma * z0;
}

pub fn sampleClamped(random: std.Random, mu: f64, sigma: f64, min: f64, max: f64) f64 {
    const raw = sampleNormal(random, mu, sigma);
    return @max(min, @min(max, raw));
}

pub const TypingProfile = struct {
    mu_ms: f64 = 120.0,
    sigma_ms: f64 = 40.0,
    min_ms: f64 = 80.0,
    max_ms: f64 = 200.0,
    word_pause_min_ms: f64 = 300.0,
    word_pause_max_ms: f64 = 600.0,

    pub fn default() TypingProfile {
        return .{};
    }
};

pub fn computeTypingDelays(
    allocator: std.mem.Allocator,
    random: std.Random,
    text: []const u8,
    profile: TypingProfile,
) ![]f64 {
    if (text.len == 0) return allocator.alloc(f64, 0);
    const delays = try allocator.alloc(f64, text.len);
    for (text, 0..) |char, i| {
        if (char == ' ') {
            delays[i] = sampleClamped(
                random,
                (profile.word_pause_min_ms + profile.word_pause_max_ms) / 2.0,
                (profile.word_pause_max_ms - profile.word_pause_min_ms) / 6.0,
                profile.word_pause_min_ms,
                profile.word_pause_max_ms,
            );
        } else {
            delays[i] = sampleClamped(random, profile.mu_ms, profile.sigma_ms, profile.min_ms, profile.max_ms);
        }
    }
    return delays;
}
