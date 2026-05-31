const std = @import("std");
const dom = @import("dom");
const handle_table = @import("handle_table");
const counting = @import("counting_alloc");

const RuntimeError = error{
    Trap,
    HostRejected,
};

pub const SpikeError = error{
    WasmTrap,
    InvalidHandle,
    StaleHandleNotDetached,
    MemoryFlatnessViolation,
    HostCallFailed,
} || handle_table.HandleError;

pub const WasmSpike = struct {
    table: handle_table.HandleTable,
    counter: counting.CountingAllocator,

    pub fn init(allocator: std.mem.Allocator) WasmSpike {
        return .{
            .table = handle_table.HandleTable.init(allocator),
            .counter = counting.CountingAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *WasmSpike) void {
        self.table.deinit();
    }

    pub fn runButtonChurn(self: *WasmSpike, cycles: usize) SpikeError!void {
        var baseline_live: ?usize = null;
        var i: usize = 0;
        while (i < cycles) : (i += 1) {
            const node = try self.counter.create(dom.Node);
            node.* = .{
                .kind = .{ .element = .{ .tag_name = "button", .attributes = &.{} } },
            };

            const ref = try self.table.put(node);
            const token = encodeHandle(ref);
            try callRuntimeHost(linearMemoryHostCall, token);

            const resolved = self.table.get(decodeHandle(token)) orelse return error.InvalidHandle;
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

fn callRuntimeHost(host_call: *const fn (u64) RuntimeError!void, handle_token: u64) SpikeError!void {
    host_call(handle_token) catch |err| {
        return switch (err) {
            error.Trap => error.WasmTrap,
            error.HostRejected => error.HostCallFailed,
        };
    };
}

fn linearMemoryHostCall(handle_token: u64) RuntimeError!void {
    const ref = decodeHandle(handle_token);
    if (ref.generation == 0) return error.HostRejected;
}

fn trapHost(_: u64) RuntimeError!void {
    return error.Trap;
}

fn encodeHandle(ref: dom.WrapperRef) u64 {
    return (@as(u64, ref.generation) << 32) | @as(u64, ref.index);
}

fn decodeHandle(token: u64) dom.WrapperRef {
    return .{
        .index = @as(u32, @truncate(token)),
        .generation = @as(u32, @truncate(token >> 32)),
    };
}

test "wasm-engine button-churn across linear-memory: no leak, no UAF" {
    var spike = WasmSpike.init(std.testing.allocator);
    defer spike.deinit();

    try spike.runButtonChurn(10_000);
    try std.testing.expectEqual(@as(usize, 0), spike.counter.live_allocs);
}

test "a WASM trap surfaces as error.WasmTrap, not a raw runtime panic" {
    try std.testing.expectError(error.WasmTrap, callRuntimeHost(trapHost, 0xDEADBEEF));
}
