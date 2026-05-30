const std = @import("std");

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const DrawRect = struct {
    rect: Rect,
    color: u32,
};

pub const DrawText = struct {
    x: f32,
    y: f32,
    text: []const u8,
    color: u32,
};

pub const DrawImage = struct {
    rect: Rect,
    width: u32,
    height: u32,
};

pub const Command = union(enum) {
    rect: DrawRect,
    text: DrawText,
    image: DrawImage,
};

pub const DisplayList = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(Command) = .empty,

    pub fn init(allocator: std.mem.Allocator) DisplayList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DisplayList) void {
        self.commands.deinit(self.allocator);
    }
};

pub fn addBackground(list: *DisplayList, rect: Rect, color: u32) !void {
    if ((color >> 24) == 0) return;
    try list.commands.append(list.allocator, .{ .rect = .{ .rect = rect, .color = color } });
}

pub fn addText(list: *DisplayList, x: f32, y: f32, text: []const u8, color: u32) !void {
    try list.commands.append(list.allocator, .{ .text = .{
        .x = x,
        .y = y,
        .text = text,
        .color = color,
    } });
}

test "paint-snapshot display list keeps non-transparent rects only" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();

    try addBackground(&list, .{ .x = 0, .y = 0, .width = 100, .height = 30 }, 0x00000000);
    try addBackground(&list, .{ .x = 0, .y = 0, .width = 100, .height = 30 }, 0xFF102030);
    try addText(&list, 4, 18, "hello", 0xFF000000);

    try std.testing.expectEqual(@as(usize, 2), list.commands.items.len);
    try std.testing.expect(list.commands.items[0] == .rect);
    try std.testing.expect(list.commands.items[1] == .text);
}
