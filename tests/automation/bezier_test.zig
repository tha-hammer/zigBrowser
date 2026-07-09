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
