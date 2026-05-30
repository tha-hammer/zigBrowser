const std = @import("std");
const display = @import("display_list.zig");

pub const Framebuffer = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    pixels: []u32,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Framebuffer {
        const pixels = try allocator.alloc(u32, width * height);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *Framebuffer) void {
        self.allocator.free(self.pixels);
    }
};

pub fn clear(fb: *Framebuffer, color: u32) void {
    @memset(fb.pixels, color);
}

pub fn drawRect(fb: *Framebuffer, rect: display.Rect, color: u32) void {
    const start_x: usize = clampRectCoord(rect.x, fb.width);
    const start_y: usize = clampRectCoord(rect.y, fb.height);
    const end_x: usize = clampRectCoord(rect.x + rect.width, fb.width);
    const end_y: usize = clampRectCoord(rect.y + rect.height, fb.height);

    var y = start_y;
    while (y < end_y) : (y += 1) {
        var x = start_x;
        while (x < end_x) : (x += 1) {
            fb.pixels[(y * fb.width) + x] = color;
        }
    }
}

pub fn checksum(fb: *const Framebuffer) u64 {
    var sum: u64 = 0;
    for (fb.pixels) |px| sum +%= px;
    return sum;
}

fn clampRectCoord(value: f32, upper: usize) usize {
    if (value <= 0) return 0;
    const as_usize: usize = @intFromFloat(value);
    return @min(as_usize, upper);
}

test "paint-snapshot software raster checksum is stable" {
    var fb = try Framebuffer.init(std.testing.allocator, 4, 4);
    defer fb.deinit();

    clear(&fb, 0xFF000000);
    drawRect(&fb, .{ .x = 1, .y = 1, .width = 2, .height = 2 }, 0xFFFFFFFF);

    try std.testing.expectEqual(@as(u64, 68518150140), checksum(&fb));
}
