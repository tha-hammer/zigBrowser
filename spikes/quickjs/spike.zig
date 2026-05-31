const std = @import("std");
const dom = @import("dom");
const handle_table = @import("handle_table");
const counting = @import("counting_alloc");

pub const SpikeError = error{
    InvalidHandle,
    StaleHandleNotDetached,
    MemoryFlatnessViolation,
} || handle_table.HandleError;

pub const QuickJsSpike = struct {
    allocator: std.mem.Allocator,
    table: handle_table.HandleTable,
    counter: counting.CountingAllocator,

    pub fn init(allocator: std.mem.Allocator) QuickJsSpike {
        return .{
            .allocator = allocator,
            .table = handle_table.HandleTable.init(allocator),
            .counter = counting.CountingAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *QuickJsSpike) void {
        self.table.deinit();
    }

    pub fn runButtonChurn(self: *QuickJsSpike, cycles: usize) SpikeError!void {
        var baseline_live: ?usize = null;
        var i: usize = 0;
        while (i < cycles) : (i += 1) {
            const node = try self.counter.create(dom.Node);
            node.* = .{
                .kind = .{ .element = .{ .tag_name = "button", .attributes = &.{} } },
            };

            const ref = try self.table.put(node);
            const resolved = self.table.get(ref) orelse return error.InvalidHandle;
            if (resolved != node) return error.InvalidHandle;

            self.table.invalidate(ref);
            if (self.table.get(ref) != null) return error.StaleHandleNotDetached;

            self.counter.destroy(node);
            const live_now = self.counter.live_allocs;
            if (baseline_live) |baseline| {
                if (live_now != baseline) return error.MemoryFlatnessViolation;
            } else {
                baseline_live = live_now;
            }
        }
    }
};

test "quickjs button-churn: no leak, no UAF" {
    var spike = QuickJsSpike.init(std.testing.allocator);
    defer spike.deinit();

    try spike.runButtonChurn(10_000);
    try std.testing.expectEqual(@as(usize, 0), spike.counter.live_allocs);
}
