const std = @import("std");
const dom = @import("dom");
const handle_table = @import("handle_table");
const counting = @import("counting_alloc");

pub const SpikeError = error{
    InvalidHandle,
    CachedPointerSurvivedPump,
    StaleHandleNotDetached,
    MemoryFlatnessViolation,
} || handle_table.HandleError;

pub const XsSpike = struct {
    table: handle_table.HandleTable,
    counter: counting.CountingAllocator,
    cached_node_ptr: ?*dom.Node = null,

    pub fn init(allocator: std.mem.Allocator) XsSpike {
        return .{
            .table = handle_table.HandleTable.init(allocator),
            .counter = counting.CountingAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *XsSpike) void {
        self.table.deinit();
    }

    pub fn cacheRawPointer(self: *XsSpike, ref: dom.WrapperRef) SpikeError!void {
        self.cached_node_ptr = self.table.get(ref) orelse return error.InvalidHandle;
    }

    pub fn pumpMicrotasks(self: *XsSpike, force_gc: bool) void {
        if (force_gc) {
            // Moving/compacting collectors invalidate raw engine pointers.
            self.cached_node_ptr = null;
        }
    }

    pub fn runButtonChurn(self: *XsSpike, cycles: usize) SpikeError!void {
        var baseline_live: ?usize = null;
        var i: usize = 0;
        while (i < cycles) : (i += 1) {
            const node = try self.counter.create(dom.Node);
            node.* = .{
                .kind = .{ .element = .{ .tag_name = "button", .attributes = &.{} } },
            };

            const ref = try self.table.put(node);
            try self.cacheRawPointer(ref);
            self.pumpMicrotasks(true);
            if (self.cached_node_ptr != null) return error.CachedPointerSurvivedPump;
            _ = self.table.get(ref) orelse return error.InvalidHandle;

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

test "xs button-churn: no leak, no UAF" {
    var spike = XsSpike.init(std.testing.allocator);
    defer spike.deinit();

    try spike.runButtonChurn(10_000);
    try std.testing.expectEqual(@as(usize, 0), spike.counter.live_allocs);
}

test "xs handles survive a GC forced during pumpMicrotasks" {
    var spike = XsSpike.init(std.testing.allocator);
    defer spike.deinit();

    const node = try spike.counter.create(dom.Node);
    defer spike.counter.destroy(node);
    node.* = .{
        .kind = .{ .element = .{ .tag_name = "div", .attributes = &.{} } },
    };

    const ref = try spike.table.put(node);
    try spike.cacheRawPointer(ref);
    try std.testing.expect(spike.cached_node_ptr != null);

    spike.pumpMicrotasks(true);
    try std.testing.expect(spike.cached_node_ptr == null);

    const resolved = spike.table.get(ref) orelse return error.InvalidHandle;
    try std.testing.expect(resolved == node);
}
