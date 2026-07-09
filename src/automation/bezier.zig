const std = @import("std");

pub const Point = struct { x: f64, y: f64 };

pub const CubicBezier = struct {
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,

    pub fn eval(self: CubicBezier, t: f64) Point {
        const u = 1.0 - t;
        const tt = t * t;
        const uu = u * u;
        const uuu = uu * u;
        const ttt = tt * t;
        return .{
            .x = uuu * self.p0.x + 3.0 * uu * t * self.p1.x + 3.0 * u * tt * self.p2.x + ttt * self.p3.x,
            .y = uuu * self.p0.y + 3.0 * uu * t * self.p1.y + 3.0 * u * tt * self.p2.y + ttt * self.p3.y,
        };
    }
};
