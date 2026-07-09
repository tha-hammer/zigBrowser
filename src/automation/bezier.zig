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

pub const MouseProfile = struct {
    overshoot_max_px: f64 = 15.0,
    dwell_min_ms: f64 = 50.0,
    dwell_max_ms: f64 = 150.0,
    fitts_a_ms: f64 = 50.0,
    fitts_b_ms: f64 = 150.0,
    target_width_px: f64 = 20.0,
    points_per_100px: usize = 10,

    pub fn default() MouseProfile {
        return .{};
    }
};

pub const MousePath = struct {
    points: []Point,
    duration_ms: f64,
    dwell_ms: f64,
};

pub fn generateMousePath(
    allocator: std.mem.Allocator,
    random: std.Random,
    start: Point,
    target: Point,
    profile: MouseProfile,
) !MousePath {
    const dx = target.x - start.x;
    const dy = target.y - start.y;
    const distance = @sqrt(dx * dx + dy * dy);

    if (distance < 1.0) {
        const points = try allocator.alloc(Point, 1);
        points[0] = start;
        const dwell = profile.dwell_min_ms + random.float(f64) * (profile.dwell_max_ms - profile.dwell_min_ms);
        return .{ .points = points, .duration_ms = 0, .dwell_ms = dwell };
    }

    const duration = profile.fitts_a_ms + profile.fitts_b_ms * @log2(distance / profile.target_width_px + 1.0);
    const dwell = profile.dwell_min_ms + random.float(f64) * (profile.dwell_max_ms - profile.dwell_min_ms);

    const n_points: usize = @max(10, @as(usize, @intFromFloat(distance / 100.0 * @as(f64, @floatFromInt(profile.points_per_100px)))));

    const perpendicular_scale = distance * 0.2 * (random.float(f64) - 0.5);
    const norm_dx = -dy / distance;
    const norm_dy = dx / distance;
    const mid_x = (start.x + target.x) / 2.0;
    const mid_y = (start.y + target.y) / 2.0;

    const curve = CubicBezier{
        .p0 = start,
        .p1 = .{ .x = mid_x + norm_dx * perpendicular_scale, .y = mid_y + norm_dy * perpendicular_scale },
        .p2 = .{ .x = target.x + norm_dx * perpendicular_scale * 0.3, .y = target.y + norm_dy * perpendicular_scale * 0.3 },
        .p3 = target,
    };

    const points = try allocator.alloc(Point, n_points);
    for (0..n_points) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_points - 1));
        points[i] = curve.eval(t);
    }

    return .{ .points = points, .duration_ms = duration, .dwell_ms = dwell };
}
