const std = @import("std");

pub const DecodeError = error{
    InvalidPng,
};

pub const ImageSize = struct {
    width: u32,
    height: u32,
};

pub fn pngIntrinsicSize(bytes: []const u8) DecodeError!ImageSize {
    const png_sig = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
    if (bytes.len < 24) return error.InvalidPng;
    if (!std.mem.eql(u8, bytes[0..8], png_sig[0..])) return error.InvalidPng;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return error.InvalidPng;

    return .{
        .width = std.mem.readInt(u32, bytes[16..20][0..4], .big),
        .height = std.mem.readInt(u32, bytes[20..24][0..4], .big),
    };
}

pub fn computeReplacedSize(intrinsic: ImageSize, attr_width: ?u32, attr_height: ?u32) ImageSize {
    if (attr_width != null and attr_height != null) {
        return .{ .width = attr_width.?, .height = attr_height.? };
    }
    if (attr_width) |w| {
        const ratio = @as(f64, @floatFromInt(intrinsic.height)) / @as(f64, @floatFromInt(intrinsic.width));
        const h_f = @as(f64, @floatFromInt(w)) * ratio;
        return .{ .width = w, .height = @intFromFloat(@round(h_f)) };
    }
    if (attr_height) |h| {
        const ratio = @as(f64, @floatFromInt(intrinsic.width)) / @as(f64, @floatFromInt(intrinsic.height));
        const w_f = @as(f64, @floatFromInt(h)) * ratio;
        return .{ .width = @intFromFloat(@round(w_f)), .height = h };
    }
    return intrinsic;
}

test "img-intrinsic-sizing reads png width/height from IHDR" {
    const png_header = [_]u8{
        137, 80, 78, 71, 13, 10, 26, 10,
        0,   0,  0,  13,
        'I', 'H', 'D', 'R',
        0,   0,  0,  200,
        0,   0,  0,  100,
    };
    const size = try pngIntrinsicSize(png_header[0..]);
    try std.testing.expectEqual(@as(u32, 200), size.width);
    try std.testing.expectEqual(@as(u32, 100), size.height);
}

test "img-intrinsic-sizing preserves aspect ratio when one dimension is provided" {
    const intrinsic = ImageSize{ .width = 200, .height = 100 };
    const from_width = computeReplacedSize(intrinsic, 120, null);
    const from_height = computeReplacedSize(intrinsic, null, 40);

    try std.testing.expectEqual(ImageSize{ .width = 120, .height = 60 }, from_width);
    try std.testing.expectEqual(ImageSize{ .width = 80, .height = 40 }, from_height);
}

test "img-intrinsic-sizing rejects malformed png payloads" {
    try std.testing.expectError(error.InvalidPng, pngIntrinsicSize("not-a-png"));
}
