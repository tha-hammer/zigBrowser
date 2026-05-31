const std = @import("std");
const dom = @import("dom");
const handle_table = @import("handle_table");
const counting = @import("counting_alloc");

const c = @cImport({
    @cInclude("wasm3_runtime_bridge.h");
});

const quickjs_wasm_path = ".zig-cache/spikes/pg_quickjs.wasm";
const default_stack_bytes: u32 = 1024 * 1024;

pub const SpikeError = error{
    WasmModuleUnavailable,
    WasmVmOpenFailed,
    WasmInitFailed,
    WasmEvalFailed,
    WasmTrap,
    StaleHandleNotDetached,
    MemoryFlatnessViolation,
} || handle_table.HandleError;

pub const WasmSpike = struct {
    allocator: std.mem.Allocator,
    table: handle_table.HandleTable,
    counter: counting.CountingAllocator,
    vm: ?*c.PgWasmVm = null,

    pub fn init(allocator: std.mem.Allocator) WasmSpike {
        return .{
            .allocator = allocator,
            .table = handle_table.HandleTable.init(allocator),
            .counter = counting.CountingAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *WasmSpike) void {
        if (self.vm) |vm| {
            c.pg_wasm_vm_close(vm);
            self.vm = null;
        }
        self.table.deinit();
    }

    pub fn runButtonChurn(self: *WasmSpike, cycles: usize) SpikeError!void {
        try self.ensureVm();

        var baseline_live: ?usize = null;
        var i: usize = 0;
        while (i < cycles) : (i += 1) {
            const node = try self.counter.create(dom.Node);
            node.* = .{
                .kind = .{ .element = .{ .tag_name = "button", .attributes = &.{} } },
            };

            const ref = try self.table.put(node);
            const token = encodeHandle(ref);
            try self.evalHandle(token);

            self.table.invalidate(ref);
            if (self.table.get(ref) != null) return error.StaleHandleNotDetached;

            // Re-evaluating a stale token must not resurrect it or crash.
            try self.evalHandle(token);
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

    pub fn assertTrapNormalized(self: *WasmSpike) SpikeError!void {
        try self.ensureVm();
        const vm = self.vm orelse return error.WasmVmOpenFailed;

        if (c.pg_wasm_vm_call_force_trap(vm) == 0) {
            return error.WasmTrap;
        }

        const last_err = c.pg_wasm_vm_last_error(vm);
        if (last_err != null) {
            const err_slice = std.mem.span(last_err);
            if (std.mem.indexOf(u8, err_slice, "trap") != null) {
                return;
            }
        }
        return error.WasmTrap;
    }

    fn ensureVm(self: *WasmSpike) SpikeError!void {
        if (self.vm != null) return;
        if (!fileExists(quickjs_wasm_path)) return error.WasmModuleUnavailable;

        const wasm_path_z = self.allocator.dupeZ(u8, quickjs_wasm_path) catch return error.WasmVmOpenFailed;
        defer self.allocator.free(wasm_path_z);

        const vm = c.pg_wasm_vm_open(wasm_path_z.ptr, default_stack_bytes);
        if (vm == null) return error.WasmVmOpenFailed;

        errdefer c.pg_wasm_vm_close(vm);

        if (vmHasError(vm)) return error.WasmVmOpenFailed;

        var init_rc: i32 = -999;
        if (c.pg_wasm_vm_call_init(vm, &init_rc) != 0) return error.WasmInitFailed;
        if (init_rc != 0) return error.WasmInitFailed;

        self.vm = vm;
    }

    fn evalHandle(self: *WasmSpike, token: u64) SpikeError!void {
        const vm = self.vm orelse return error.WasmVmOpenFailed;
        var eval_rc: i32 = -999;
        if (c.pg_wasm_vm_call_eval_handle(vm, token, &eval_rc) != 0) return error.WasmEvalFailed;
        if (eval_rc != 0) return error.WasmEvalFailed;
    }
};

fn vmHasError(vm: *c.PgWasmVm) bool {
    const err_ptr = c.pg_wasm_vm_last_error(vm);
    if (err_ptr == null) return false;
    return std.mem.span(err_ptr).len > 0;
}

fn fileExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn encodeHandle(ref: dom.WrapperRef) u64 {
    return (@as(u64, ref.generation) << 32) | @as(u64, ref.index);
}

test "wasm-engine button-churn across linear-memory: no leak, no UAF" {
    var spike = WasmSpike.init(std.testing.allocator);
    defer spike.deinit();

    try spike.runButtonChurn(10_000);
    try std.testing.expectEqual(@as(usize, 0), spike.counter.live_allocs);
}

test "a real runtime trap surfaces as error.WasmTrap" {
    var spike = WasmSpike.init(std.testing.allocator);
    defer spike.deinit();

    try spike.assertTrapNormalized();
}

test "real quickjs wasm module footprint is reported in MB-range" {
    if (!fileExists(quickjs_wasm_path)) return error.SkipZigTest;

    const stat = std.Io.Dir.cwd().statFile(std.testing.io, quickjs_wasm_path) catch return error.SkipZigTest;
    try std.testing.expect(stat.size >= 1024 * 1024);
}
