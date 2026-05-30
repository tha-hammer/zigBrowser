const std = @import("std");
const css = @import("../css/cascade.zig");

pub const FloatBox = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    side: css.FloatVal,
};

pub fn availableLineWidth(container_width: f32, line_y: f32, floats: []const FloatBox) f32 {
    var left_inset: f32 = 0;
    var right_inset: f32 = 0;

    for (floats) |f| {
        if (!overlapsY(line_y, f)) continue;
        switch (f.side) {
            .left => left_inset = @max(left_inset, f.x + f.width),
            .right => right_inset = @max(right_inset, container_width - f.x),
            .none => {},
        }
    }

    const width = container_width - left_inset - right_inset;
    return if (width > 0) width else 0;
}

pub fn clearOffset(clear: css.ClearVal, current_y: f32, floats: []const FloatBox) f32 {
    var y = current_y;
    for (floats) |f| {
        const conflicts = switch (clear) {
            .none => false,
            .left => f.side == .left,
            .right => f.side == .right,
            .both => f.side == .left or f.side == .right,
        };
        if (!conflicts) continue;
        y = @max(y, f.y + f.height);
    }
    return y;
}

fn overlapsY(line_y: f32, f: FloatBox) bool {
    return line_y >= f.y and line_y < (f.y + f.height);
}

test "float-flow reduces line width around right float" {
    const floats = [_]FloatBox{
        .{ .x = 350, .y = 0, .width = 150, .height = 120, .side = .right },
    };
    const width = availableLineWidth(500, 20, floats[0..]);
    try std.testing.expectApproxEqAbs(@as(f32, 350), width, 0.001);
}

test "float-flow clear both pushes below stacked floats" {
    const floats = [_]FloatBox{
        .{ .x = 0, .y = 0, .width = 120, .height = 80, .side = .left },
        .{ .x = 360, .y = 20, .width = 140, .height = 130, .side = .right },
    };
    const offset = clearOffset(.both, 10, floats[0..]);
    try std.testing.expectApproxEqAbs(@as(f32, 150), offset, 0.001);
}

test "float-flow stacked left+right floats squeeze available width" {
    const floats = [_]FloatBox{
        .{ .x = 0, .y = 0, .width = 100, .height = 60, .side = .left },
        .{ .x = 420, .y = 0, .width = 80, .height = 60, .side = .right },
    };
    const width = availableLineWidth(500, 30, floats[0..]);
    try std.testing.expectApproxEqAbs(@as(f32, 320), width, 0.001);
}
