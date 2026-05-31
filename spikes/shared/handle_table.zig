const std = @import("std");
const dom = @import("dom");

pub const HandleError = error{OutOfMemory};

const Slot = struct {
    node: ?*dom.Node = null,
    generation: u32 = 1,
};

pub const HandleTable = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(Slot),
    free_list: std.ArrayList(u32),

    pub fn init(allocator: std.mem.Allocator) HandleTable {
        return .{
            .allocator = allocator,
            .slots = .empty,
            .free_list = .empty,
        };
    }

    pub fn deinit(self: *HandleTable) void {
        self.slots.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
    }

    pub fn put(self: *HandleTable, node: *dom.Node) HandleError!dom.WrapperRef {
        if (self.free_list.pop()) |slot_index| {
            const idx: usize = @intCast(slot_index);
            var slot = &self.slots.items[idx];
            slot.node = node;
            return .{
                .index = slot_index,
                .generation = slot.generation,
            };
        }

        const slot_index: u32 = @intCast(self.slots.items.len);
        try self.slots.append(self.allocator, .{
            .node = node,
            .generation = 1,
        });
        return .{
            .index = slot_index,
            .generation = 1,
        };
    }

    pub fn get(self: *const HandleTable, ref: dom.WrapperRef) ?*dom.Node {
        const idx: usize = @intCast(ref.index);
        if (idx >= self.slots.items.len) return null;

        const slot = self.slots.items[idx];
        if (slot.generation != ref.generation) return null;
        return slot.node;
    }

    pub fn invalidate(self: *HandleTable, ref: dom.WrapperRef) void {
        const idx: usize = @intCast(ref.index);
        if (idx >= self.slots.items.len) return;

        var slot = &self.slots.items[idx];
        if (slot.generation != ref.generation) return;

        slot.node = null;
        slot.generation +%= 1;
        self.free_list.append(self.allocator, ref.index) catch {};
    }
};

test "handle table put/get/invalidate enforces generation checks" {
    var table = HandleTable.init(std.testing.allocator);
    defer table.deinit();

    var node = dom.Node{
        .kind = .{ .element = .{ .tag_name = "button", .attributes = &.{} } },
    };

    const ref = try table.put(&node);
    try std.testing.expect(table.get(ref) == &node);

    table.invalidate(ref);
    try std.testing.expect(table.get(ref) == null);
}

test "handle table reuses invalidated slot with bumped generation" {
    var table = HandleTable.init(std.testing.allocator);
    defer table.deinit();

    var node_a = dom.Node{
        .kind = .{ .element = .{ .tag_name = "a", .attributes = &.{} } },
    };
    var node_b = dom.Node{
        .kind = .{ .element = .{ .tag_name = "b", .attributes = &.{} } },
    };

    const first = try table.put(&node_a);
    table.invalidate(first);
    const second = try table.put(&node_b);

    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(second.generation != first.generation);
    try std.testing.expect(table.get(first) == null);
    try std.testing.expect(table.get(second) == &node_b);
}
