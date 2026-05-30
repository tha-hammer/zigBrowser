const std = @import("std");
const css = @import("../css/cascade.zig");

pub const LineMetrics = struct {
    width: f32,
    height: f32,
    x_offset: f32 = 0,
};

pub const InlineConfig = struct {
    max_width: f32,
    font_size: f32 = 16.0,
    line_height: f32 = 1.2,
    text_align: css.TextAlign = .left,
};

pub fn layoutTextLines(
    allocator: std.mem.Allocator,
    text: []const u8,
    config: InlineConfig,
) ![]LineMetrics {
    const glyph_width = config.font_size * 0.6;
    const space_width = glyph_width;
    const line_height_px = config.font_size * config.line_height;

    var lines = std.ArrayList(LineMetrics).empty;
    var current_width: f32 = 0;
    var saw_word = false;

    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| {
        const word_width = @as(f32, @floatFromInt(word.len)) * glyph_width;
        if (!saw_word) {
            current_width = word_width;
            saw_word = true;
            continue;
        }

        if (current_width + space_width + word_width > config.max_width and current_width > 0) {
            try lines.append(allocator, .{ .width = current_width, .height = line_height_px });
            current_width = word_width;
        } else {
            current_width += space_width + word_width;
        }
    }

    if (saw_word) {
        try lines.append(allocator, .{ .width = current_width, .height = line_height_px });
    }

    for (lines.items) |*line| {
        const slack = config.max_width - line.width;
        line.x_offset = switch (config.text_align) {
            .left, .justify => 0,
            .right => if (slack > 0) slack else 0,
            .center => if (slack > 0) slack / 2.0 else 0,
        };
    }

    return lines.toOwnedSlice(allocator);
}

test "layout-inline-wrap creates expected line count" {
    const text = "one two three four five";
    const lines = try layoutTextLines(std.testing.allocator, text, .{
        .max_width = 60,
        .font_size = 10,
        .line_height = 1.4,
    });
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectApproxEqAbs(@as(f32, 42), lines[0].width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 14), lines[0].height, 0.001);
}

test "layout-inline-wrap applies right text alignment offset" {
    const lines = try layoutTextLines(std.testing.allocator, "alpha beta", .{
        .max_width = 100,
        .font_size = 10,
        .text_align = .right,
    });
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectApproxEqAbs(@as(f32, 40), lines[0].x_offset, 0.001);
}

test "layout-inline-wrap keeps unbreakable overflow on one line" {
    const lines = try layoutTextLines(std.testing.allocator, "supercalifragilistic", .{
        .max_width = 30,
        .font_size = 10,
    });
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expect(lines[0].width > 30);
}

test "layout-inline-wrap ignores trailing whitespace-only tail" {
    const lines = try layoutTextLines(std.testing.allocator, "one two   ", .{
        .max_width = 200,
        .font_size = 10,
    });
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 1), lines.len);
}
