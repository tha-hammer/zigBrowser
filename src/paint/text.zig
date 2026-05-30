const std = @import("std");

pub fn glyphAdvance(font_size: f32) f32 {
    return font_size * 0.6;
}

pub fn measureTextWidth(text: []const u8, font_size: f32) f32 {
    return @as(f32, @floatFromInt(text.len)) * glyphAdvance(font_size);
}

pub fn lineHeightPx(font_size: f32, line_height_multiplier: f32) f32 {
    return font_size * line_height_multiplier;
}

test "text shaping shim produces deterministic metrics" {
    try std.testing.expectApproxEqAbs(@as(f32, 9.6), glyphAdvance(16), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 48), measureTextWidth("hello", 16), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 19.2), lineHeightPx(16, 1.2), 0.0001);
}
