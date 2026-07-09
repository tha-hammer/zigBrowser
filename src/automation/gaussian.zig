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
