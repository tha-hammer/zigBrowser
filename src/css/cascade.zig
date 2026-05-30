pub const Display = enum { block, @"inline", inline_block, none };
pub const TextAlign = enum { left, right, center, justify };
pub const FloatVal = enum { none, left, right };
pub const ClearVal = enum { none, left, right, both };

pub const ComputedStyle = struct {
    display: Display = .@"inline",
    color: u32 = 0xFF000000,
    background_color: u32 = 0x00000000,
    font_size: f32 = 16.0,
    font_weight: u16 = 400,
    line_height: f32 = 1.2,
    text_align: TextAlign = .left,
    margin: [4]f32 = .{ 0, 0, 0, 0 },
    padding: [4]f32 = .{ 0, 0, 0, 0 },
    border: [4]f32 = .{ 0, 0, 0, 0 },
    width: ?f32 = null,
    height: ?f32 = null,
    float: FloatVal = .none,
    clear: ClearVal = .none,
};
