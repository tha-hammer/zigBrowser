const std = @import("std");
const css = @import("../css/cascade.zig");
const dom = @import("../html/dom.zig");
const box_mod = @import("box.zig");

pub const BlockInput = struct {
    container_x: f32 = 0,
    container_y: f32 = 0,
    container_width: f32,
    content_height: f32,
    style: css.ComputedStyle,
    auto_margin_left: bool = false,
    auto_margin_right: bool = false,
};

pub const BlockGeometry = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    margin_left: f32,
    margin_right: f32,
};

pub fn collapseAdjacentMargins(previous_bottom: f32, next_top: f32) f32 {
    if (previous_bottom >= 0 and next_top >= 0) return @max(previous_bottom, next_top);
    if (previous_bottom <= 0 and next_top <= 0) return @min(previous_bottom, next_top);
    return previous_bottom + next_top;
}

pub fn resolvePercentWidth(percent: f32, containing_width: f32) f32 {
    return percent * containing_width;
}

pub fn layoutBlockGeometry(input: BlockInput) BlockGeometry {
    const s = input.style;
    const base_left_margin = s.margin[3];
    const base_right_margin = s.margin[1];
    const side_non_content = s.padding[1] + s.padding[3] + s.border[1] + s.border[3];

    var width = s.width orelse (input.container_width - side_non_content - base_left_margin - base_right_margin);
    if (width < 0) width = 0;

    var margin_left = base_left_margin;
    var margin_right = base_right_margin;

    if (input.auto_margin_left or input.auto_margin_right) {
        const remaining = input.container_width - side_non_content - width - base_left_margin - base_right_margin;
        const free_space = if (remaining > 0) remaining else 0;
        if (input.auto_margin_left and input.auto_margin_right) {
            margin_left += free_space / 2.0;
            margin_right += free_space / 2.0;
        } else if (input.auto_margin_left) {
            margin_left += free_space;
        } else if (input.auto_margin_right) {
            margin_right += free_space;
        }
    }

    const height = s.height orelse input.content_height;

    return .{
        .x = input.container_x + margin_left + s.border[3] + s.padding[3],
        .y = input.container_y + s.margin[0] + s.border[0] + s.padding[0],
        .width = width,
        .height = height,
        .margin_left = margin_left,
        .margin_right = margin_right,
    };
}

pub fn attachSource(layout_box: *box_mod.Box, source: *const dom.Node) void {
    layout_box.source = source;
}

test "layout-block-geometry handles auto margins and explicit width" {
    const style = css.ComputedStyle{
        .width = 200,
        .margin = .{ 0, 0, 0, 0 },
    };

    const geom = layoutBlockGeometry(.{
        .container_width = 500,
        .content_height = 60,
        .style = style,
        .auto_margin_left = true,
        .auto_margin_right = true,
    });

    try std.testing.expectApproxEqAbs(@as(f32, 150), geom.margin_left, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 150), geom.margin_right, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 150), geom.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), geom.width, 0.001);
}

test "layout-block-geometry collapse + percent helper coverage" {
    try std.testing.expectApproxEqAbs(@as(f32, 12), collapseAdjacentMargins(12, 8), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -10), collapseAdjacentMargins(-4, -10), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), collapseAdjacentMargins(10, -8), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 240), resolvePercentWidth(0.6, 400), 0.001);
}

test "layout-block-geometry assigns read-only Box.source pointer" {
    var node = dom.Node{
        .kind = .{ .element = .{ .tag_name = "p", .attributes = &.{} } },
    };
    var bx = box_mod.Box{
        .x = 0,
        .y = 0,
        .width = 1,
        .height = 1,
        .content = .{ .line = &.{} },
        .source = null,
    };

    attachSource(&bx, &node);
    try std.testing.expect(bx.source != null);
}
