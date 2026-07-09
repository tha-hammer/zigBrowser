const std = @import("std");
const bezier = @import("bezier");

test "cubic bezier endpoints are exact" {
    const curve = bezier.CubicBezier{
        .p0 = .{ .x = 0, .y = 0 },
        .p1 = .{ .x = 0.25, .y = 0.75 },
        .p2 = .{ .x = 0.75, .y = 0.25 },
        .p3 = .{ .x = 1, .y = 1 },
    };

    const start = curve.eval(0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), start.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), start.y, 1e-10);

    const end = curve.eval(1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), end.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), end.y, 1e-10);
}

test "cubic bezier midpoint is on curve" {
    const curve = bezier.CubicBezier{
        .p0 = .{ .x = 0, .y = 0 },
        .p1 = .{ .x = 0, .y = 1 },
        .p2 = .{ .x = 1, .y = 0 },
        .p3 = .{ .x = 1, .y = 1 },
    };

    const mid = curve.eval(0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), mid.x, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), mid.y, 1e-10);
}

test "mouse path starts at origin and ends near target" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const path = try bezier.generateMousePath(
        allocator,
        random,
        .{ .x = 100, .y = 100 },
        .{ .x = 500, .y = 300 },
        bezier.MouseProfile.default(),
    );
    defer allocator.free(path.points);

    try std.testing.expect(path.points.len >= 10);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), path.points[0].x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), path.points[0].y, 1e-6);

    const last = path.points[path.points.len - 1];
    const dx = last.x - 500.0;
    const dy = last.y - 300.0;
    const dist = @sqrt(dx * dx + dy * dy);
    try std.testing.expect(dist < 30.0);

    try std.testing.expect(path.duration_ms > 0);
    try std.testing.expect(path.dwell_ms >= 50.0);
    try std.testing.expect(path.dwell_ms <= 150.0);
}

test "mouse path zero distance produces minimal path" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const path = try bezier.generateMousePath(
        allocator,
        random,
        .{ .x = 200, .y = 200 },
        .{ .x = 200, .y = 200 },
        bezier.MouseProfile.default(),
    );
    defer allocator.free(path.points);

    try std.testing.expect(path.points.len >= 1);
    try std.testing.expect(path.duration_ms == 0 or path.duration_ms < 50);
}
