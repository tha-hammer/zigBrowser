const std = @import("std");

pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    live_allocs: usize = 0,
    total_allocs: usize = 0,
    total_frees: usize = 0,

    pub fn init(backing: std.mem.Allocator) CountingAllocator {
        return .{ .backing = backing };
    }

    pub fn create(self: *CountingAllocator, comptime T: type) !*T {
        const ptr = try self.backing.create(T);
        self.total_allocs += 1;
        self.live_allocs += 1;
        return ptr;
    }

    pub fn destroy(self: *CountingAllocator, ptr: anytype) void {
        self.backing.destroy(ptr);
        self.total_frees += 1;
        self.live_allocs -= 1;
    }

    pub fn alloc(self: *CountingAllocator, comptime T: type, len: usize) ![]T {
        const slice = try self.backing.alloc(T, len);
        self.total_allocs += 1;
        self.live_allocs += 1;
        return slice;
    }

    pub fn free(self: *CountingAllocator, slice: anytype) void {
        self.backing.free(slice);
        self.total_frees += 1;
        self.live_allocs -= 1;
    }
};

test "counting allocator tracks live allocations" {
    var counter = CountingAllocator.init(std.testing.allocator);

    const ints = try counter.alloc(u32, 4);
    try std.testing.expectEqual(@as(usize, 1), counter.live_allocs);

    counter.free(ints);
    try std.testing.expectEqual(@as(usize, 0), counter.live_allocs);
    try std.testing.expectEqual(counter.total_allocs, counter.total_frees);
}
