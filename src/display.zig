const std = @import("std");

pub const PIXEL_FORMAT = "ARGB8888";

pub const DisplayError = error{
    DimensionMismatch,
    BackendFailure,
};

pub const Display = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        present: *const fn (*anyopaque, pixels: []const u32, width: u32, height: u32) DisplayError!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn present(self: Display, pixels: []const u32, width: u32, height: u32) DisplayError!void {
        return self.vtable.present(self.ptr, pixels, width, height);
    }

    pub fn deinit(self: Display) void {
        self.vtable.deinit(self.ptr);
    }
};

pub const NullDisplay = struct {
    allocator: std.mem.Allocator,
    last_pixels: ?[]u32 = null,
    last_width: u32 = 0,
    last_height: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) NullDisplay {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinitOwned(self: *NullDisplay) void {
        if (self.last_pixels) |pixels| {
            self.allocator.free(pixels);
            self.last_pixels = null;
        }
    }

    pub fn display(self: *NullDisplay) Display {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn lastFrame(self: *const NullDisplay) ?[]const u32 {
        return self.last_pixels;
    }

    pub fn lastDimensions(self: *const NullDisplay) struct { width: u32, height: u32 } {
        return .{
            .width = self.last_width,
            .height = self.last_height,
        };
    }

    fn present(ptr: *anyopaque, pixels: []const u32, width: u32, height: u32) DisplayError!void {
        const self: *NullDisplay = @ptrCast(@alignCast(ptr));

        const expected_len = std.math.mul(usize, width, height) catch return error.DimensionMismatch;
        if (pixels.len != expected_len) return error.DimensionMismatch;

        if (self.last_pixels) |previous| {
            self.allocator.free(previous);
            self.last_pixels = null;
        }

        const copied = self.allocator.alloc(u32, pixels.len) catch return error.BackendFailure;
        @memcpy(copied, pixels);

        self.last_pixels = copied;
        self.last_width = width;
        self.last_height = height;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *NullDisplay = @ptrCast(@alignCast(ptr));
        self.deinitOwned();
    }

    const vtable = Display.VTable{
        .present = present,
        .deinit = deinit,
    };
};

test "0b.1 NullDisplay.present captures pixels exactly" {
    var backend = NullDisplay.init(std.testing.allocator);
    defer backend.deinitOwned();

    var frame = [_]u32{
        0xFF111111, 0xFF222222,
        0xFF333333, 0xFF444444,
    };

    const display = backend.display();
    try display.present(&frame, 2, 2);

    const captured = backend.lastFrame() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 4), captured.len);
    try std.testing.expectEqualSlices(u32, &frame, captured);

    frame[0] = 0xFFFFFFFF;
    try std.testing.expectEqual(@as(u32, 0xFF111111), captured[0]);
}

test "0b.1 NullDisplay.present rejects DimensionMismatch" {
    var backend = NullDisplay.init(std.testing.allocator);
    defer backend.deinitOwned();

    const frame = [_]u32{ 0xFF000000, 0xFF111111, 0xFF222222 };
    try std.testing.expectError(error.DimensionMismatch, backend.display().present(&frame, 2, 2));
    try std.testing.expect(backend.lastFrame() == null);
}

test "0b.1 Display.deinit delegates to backend vtable" {
    var backend = NullDisplay.init(std.testing.allocator);

    const frame = [_]u32{0xFFAAAAAA};
    try backend.display().present(&frame, 1, 1);
    try std.testing.expect(backend.lastFrame() != null);

    backend.display().deinit();
    try std.testing.expect(backend.lastFrame() == null);
}
