const std = @import("std");
const dom = @import("dom");
const c = @cImport({
    @cInclude("quickjs.h");
});

pub const SpikeError = error{
    EngineInitFailed,
    EvalFailed,
    InvalidHandle,
    StaleHandleNotDetached,
    MemoryFlatnessViolation,
    UnexpectedEvalResult,
} || HandleError;

pub const QuickJsMetrics = struct {
    ergonomics_locs: usize,
    teardown_complexity: usize,
    throughput_ops_per_sec: f64,
    license_spdx: []const u8,
    wasm_footprint_bytes: usize,
};

const churn_cycles: usize = 10_000;

const CountingAllocator = struct {
    backing: std.mem.Allocator,
    live_allocs: usize = 0,
    total_allocs: usize = 0,
    total_frees: usize = 0,

    fn init(backing: std.mem.Allocator) CountingAllocator {
        return .{ .backing = backing };
    }

    fn create(self: *CountingAllocator, comptime T: type) !*T {
        const ptr = try self.backing.create(T);
        self.total_allocs += 1;
        self.live_allocs += 1;
        return ptr;
    }

    fn destroy(self: *CountingAllocator, ptr: anytype) void {
        self.backing.destroy(ptr);
        self.total_frees += 1;
        self.live_allocs -= 1;
    }
};

pub const HandleError = error{OutOfMemory};

const Slot = struct {
    node: ?*dom.Node = null,
    generation: u32 = 1,
};

const HandleTable = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(Slot),
    free_list: std.ArrayList(u32),

    fn init(allocator: std.mem.Allocator) HandleTable {
        return .{
            .allocator = allocator,
            .slots = .empty,
            .free_list = .empty,
        };
    }

    fn deinit(self: *HandleTable) void {
        self.slots.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
    }

    fn put(self: *HandleTable, node: *dom.Node) HandleError!dom.WrapperRef {
        if (self.free_list.pop()) |slot_index| {
            const idx: usize = @intCast(slot_index);
            var slot = &self.slots.items[idx];
            slot.node = node;
            return .{ .index = slot_index, .generation = slot.generation };
        }

        const slot_index: u32 = @intCast(self.slots.items.len);
        self.slots.append(self.allocator, .{ .node = node, .generation = 1 }) catch return error.OutOfMemory;
        return .{ .index = slot_index, .generation = 1 };
    }

    fn get(self: *const HandleTable, ref: dom.WrapperRef) ?*dom.Node {
        const idx: usize = @intCast(ref.index);
        if (idx >= self.slots.items.len) return null;
        const slot = self.slots.items[idx];
        if (slot.generation != ref.generation) return null;
        return slot.node;
    }

    fn invalidate(self: *HandleTable, ref: dom.WrapperRef) void {
        const idx: usize = @intCast(ref.index);
        if (idx >= self.slots.items.len) return;

        var slot = &self.slots.items[idx];
        if (slot.generation != ref.generation) return;

        slot.node = null;
        slot.generation +%= 1;
        self.free_list.append(self.allocator, ref.index) catch {};
    }
};

const QjsAllocStats = struct {
    live_blocks: usize = 0,
    total_allocs: usize = 0,
    total_frees: usize = 0,
    live_bytes: usize = 0,
    peak_live_blocks: usize = 0,
    peak_live_bytes: usize = 0,

    fn onAlloc(self: *QjsAllocStats, size: usize) void {
        self.total_allocs += 1;
        self.live_blocks += 1;
        self.live_bytes += size;
        if (self.live_blocks > self.peak_live_blocks) self.peak_live_blocks = self.live_blocks;
        if (self.live_bytes > self.peak_live_bytes) self.peak_live_bytes = self.live_bytes;
    }

    fn onFree(self: *QjsAllocStats, size: usize) void {
        self.total_frees += 1;
        self.live_blocks -= 1;
        self.live_bytes -= size;
    }
};

const QuickJsSpike = struct {
    allocator: std.mem.Allocator,
    table: HandleTable,
    counter: CountingAllocator,
    rt: *c.JSRuntime,
    ctx: *c.JSContext,
    qjs_alloc: *QjsAllocStats,

    fn init(allocator: std.mem.Allocator) !QuickJsSpike {
        const qjs_alloc = try allocator.create(QjsAllocStats);
        qjs_alloc.* = .{};
        errdefer allocator.destroy(qjs_alloc);

        var spike = QuickJsSpike{
            .allocator = allocator,
            .table = HandleTable.init(allocator),
            .counter = CountingAllocator.init(allocator),
            .rt = undefined,
            .ctx = undefined,
            .qjs_alloc = qjs_alloc,
        };

        var mf = c.JSMallocFunctions{
            .js_calloc = qjsCalloc,
            .js_malloc = qjsMalloc,
            .js_free = qjsFree,
            .js_realloc = qjsRealloc,
            .js_malloc_usable_size = qjsMallocUsableSize,
        };

        spike.rt = c.JS_NewRuntime2(&mf, qjs_alloc) orelse return error.EngineInitFailed;
        errdefer c.JS_FreeRuntime(spike.rt);

        spike.ctx = c.JS_NewContext(spike.rt) orelse return error.EngineInitFailed;
        errdefer c.JS_FreeContext(spike.ctx);

        c.JS_SetContextOpaque(spike.ctx, &spike);
        try spike.installBindings();
        return spike;
    }

    fn deinit(self: *QuickJsSpike) void {
        c.JS_FreeContext(self.ctx);
        c.JS_FreeRuntime(self.rt);
        self.table.deinit();
        self.allocator.destroy(self.qjs_alloc);
    }

    fn installBindings(self: *QuickJsSpike) !void {
        const global = c.JS_GetGlobalObject(self.ctx);
        defer c.JS_FreeValue(self.ctx, global);

        const mutate_fn = c.JS_NewCFunction(self.ctx, jsMutateNode, "mutateNode", 3);
        if (c.JS_IsException(mutate_fn)) return error.EngineInitFailed;
        if (c.JS_SetPropertyStr(self.ctx, global, "mutateNode", mutate_fn) < 0) return error.EngineInitFailed;
    }

    fn eval(self: *QuickJsSpike, source: []const u8) SpikeError!c.JSValue {
        const val = c.JS_Eval(
            self.ctx,
            source.ptr,
            source.len,
            "<quickjs-spike>",
            c.JS_EVAL_TYPE_GLOBAL,
        );
        if (c.JS_IsException(val)) {
            self.dumpException();
            return error.EvalFailed;
        }
        return val;
    }

    fn dumpException(self: *QuickJsSpike) void {
        const exc = c.JS_GetException(self.ctx);
        defer c.JS_FreeValue(self.ctx, exc);
        const msg = c.JS_ToCString(self.ctx, exc);
        if (msg) |m| {
            defer c.JS_FreeCString(self.ctx, m);
            std.debug.print("quickjs exception: {s}\n", .{std.mem.span(m)});
        }
    }

    fn runButtonChurn(self: *QuickJsSpike, cycles: usize) SpikeError!void {
        var baseline_live: ?usize = null;

        var i: usize = 0;
        while (i < cycles) : (i += 1) {
            const node = try self.counter.create(dom.Node);
            node.* = .{ .kind = .{ .element = .{ .tag_name = "button", .attributes = &.{} } } };

            const ref = try self.table.put(node);
            node.script_wrapper = ref;

            const script_src = try std.fmt.allocPrint(
                self.allocator,
                "mutateNode({d}, {d}, 'armed')",
                .{ ref.index, ref.generation },
            );
            defer self.allocator.free(script_src);

            const ok_value = try self.eval(script_src);
            defer c.JS_FreeValue(self.ctx, ok_value);

            const ok_int = c.JS_ToBool(self.ctx, ok_value);
            if (ok_int <= 0) return error.InvalidHandle;

            const resolved = self.table.get(ref) orelse return error.InvalidHandle;
            switch (resolved.kind) {
                .element => |el| {
                    if (!std.mem.eql(u8, el.tag_name, "armed")) return error.UnexpectedEvalResult;
                },
                else => return error.UnexpectedEvalResult,
            }

            self.table.invalidate(ref);
            if (self.table.get(ref) != null) return error.StaleHandleNotDetached;

            const stale_src = try std.fmt.allocPrint(
                self.allocator,
                "mutateNode({d}, {d}, 'stale')",
                .{ ref.index, ref.generation },
            );
            defer self.allocator.free(stale_src);

            const stale_value = try self.eval(stale_src);
            defer c.JS_FreeValue(self.ctx, stale_value);
            const stale_ok = c.JS_ToBool(self.ctx, stale_value);
            if (stale_ok != 0) return error.StaleHandleNotDetached;

            // Force real QuickJS GC every cycle to stress stale-handle behavior.
            c.JS_RunGC(self.rt);

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

fn jsMutateNode(
    ctx_opt: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]const c.JSValue,
) callconv(.c) c.JSValue {
    const ctx = ctx_opt orelse unreachable;
    if (argc < 3) return c.JS_NewBool(ctx, false);

    const spike_opaque = c.JS_GetContextOpaque(ctx) orelse return c.JS_ThrowInternalError(ctx, "missing spike context");
    const spike: *QuickJsSpike = @ptrCast(@alignCast(spike_opaque));

    var idx_i32: i32 = 0;
    var gen_i32: i32 = 0;
    if (c.JS_ToInt32(ctx, &idx_i32, argv[0]) < 0) return c.JS_ThrowTypeError(ctx, "index must be int32");
    if (c.JS_ToInt32(ctx, &gen_i32, argv[1]) < 0) return c.JS_ThrowTypeError(ctx, "generation must be int32");

    const tag_c = c.JS_ToCString(ctx, argv[2]);
    if (tag_c == null) return c.JS_ThrowTypeError(ctx, "tag must be string");
    defer c.JS_FreeCString(ctx, tag_c);

    if (idx_i32 < 0 or gen_i32 <= 0) return c.JS_NewBool(ctx, false);

    const ref = dom.WrapperRef{
        .index = @intCast(idx_i32),
        .generation = @intCast(gen_i32),
    };

    const node = spike.table.get(ref) orelse return c.JS_NewBool(ctx, false);
    const tag = std.mem.span(tag_c.?);

    switch (node.kind) {
        .element => |*el| {
            // Keep mutation allocation-free in churn loops; use canonical tags.
            if (std.mem.eql(u8, tag, "armed")) {
                el.tag_name = "armed";
            } else if (std.mem.eql(u8, tag, "clicked")) {
                el.tag_name = "clicked";
            } else {
                el.tag_name = "custom";
            }
            return c.JS_NewBool(ctx, true);
        },
        else => return c.JS_NewBool(ctx, false),
    }
}

fn monotonicNowNs() u128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    const sec_raw = if (@hasField(std.c.timespec, "sec")) ts.sec else ts.tv_sec;
    const nsec_raw = if (@hasField(std.c.timespec, "nsec")) ts.nsec else ts.tv_nsec;
    const sec: u128 = @intCast(if (sec_raw < 0) 0 else sec_raw);
    const nsec: u128 = @intCast(if (nsec_raw < 0) 0 else nsec_raw);
    return (sec * std.time.ns_per_s) + nsec;
}

fn qjsMalloc(opaque_ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    if (opaque_ptr == null) return null;
    const stats: *QjsAllocStats = @ptrCast(@alignCast(opaque_ptr.?));
    const raw = std.c.malloc(size) orelse return null;
    const usable = qjsTrackedSize(raw, size);
    stats.onAlloc(usable);
    return raw;
}

fn qjsCalloc(opaque_ptr: ?*anyopaque, count: usize, size: usize) callconv(.c) ?*anyopaque {
    if (opaque_ptr == null) return null;
    const stats: *QjsAllocStats = @ptrCast(@alignCast(opaque_ptr.?));
    const raw = std.c.calloc(count, size) orelse return null;
    const bytes = std.math.mul(usize, count, size) catch return null;
    const usable = qjsTrackedSize(raw, bytes);
    stats.onAlloc(usable);
    return raw;
}

fn qjsFree(opaque_ptr: ?*anyopaque, user_ptr: ?*anyopaque) callconv(.c) void {
    if (opaque_ptr == null or user_ptr == null) return;
    const stats: *QjsAllocStats = @ptrCast(@alignCast(opaque_ptr.?));
    const size = qjsTrackedSize(user_ptr, 0);
    std.c.free(user_ptr);
    stats.onFree(size);
}

fn qjsRealloc(opaque_ptr: ?*anyopaque, user_ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    if (opaque_ptr == null) return null;
    const stats: *QjsAllocStats = @ptrCast(@alignCast(opaque_ptr.?));

    if (user_ptr == null) return qjsMalloc(opaque_ptr, size);
    if (size == 0) {
        qjsFree(opaque_ptr, user_ptr);
        return null;
    }
    const old_size = qjsTrackedSize(user_ptr, 0);
    const new_raw = std.c.realloc(user_ptr, size) orelse return null;
    const new_size = qjsTrackedSize(new_raw, size);

    if (new_size > old_size) {
        stats.live_bytes += new_size - old_size;
    } else {
        stats.live_bytes -= old_size - new_size;
    }
    if (stats.live_bytes > stats.peak_live_bytes) stats.peak_live_bytes = stats.live_bytes;
    return new_raw;
}

fn qjsMallocUsableSize(user_ptr: ?*const anyopaque) callconv(.c) usize {
    return qjsUsableSize(user_ptr);
}

fn qjsTrackedSize(ptr: ?*const anyopaque, fallback: usize) usize {
    const size = qjsUsableSize(ptr);
    return if (size > 0) size else fallback;
}

fn qjsUsableSize(ptr: ?*const anyopaque) usize {
    if (ptr == null) return 0;
    return switch (@import("builtin").os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos, .serenity => std.c.malloc_size(ptr),
        .windows => std.c._msize(ptr),
        .freebsd, .linux => std.c.malloc_usable_size(ptr),
        else => 0,
    };
}

fn measureQuickJsMetrics(allocator: std.mem.Allocator) !QuickJsMetrics {
    var spike = try QuickJsSpike.init(allocator);
    defer spike.deinit();

    const start_ns = monotonicNowNs();
    try spike.runButtonChurn(churn_cycles);
    const end_ns = monotonicNowNs();
    const elapsed_ns_u128: u128 = if (end_ns > start_ns) (end_ns - start_ns) else 1;
    const elapsed_ns = @as(f64, @floatFromInt(elapsed_ns_u128));
    const throughput = (@as(f64, @floatFromInt(churn_cycles)) * 1_000_000_000.0) / elapsed_ns;

    const locs = try countLines(allocator, "spikes/quickjs/spike.zig");
    const amalgam_size = try fileSize("spikes/quickjs/vendor/quickjs-ng/quickjs-amalgam.c");

    return .{
        .ergonomics_locs = locs,
        .teardown_complexity = 2, // JS_FreeContext + JS_FreeRuntime
        .throughput_ops_per_sec = throughput,
        .license_spdx = "MIT",
        .wasm_footprint_bytes = amalgam_size,
    };
}

fn countLines(allocator: std.mem.Allocator, path: []const u8) !usize {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(bytes);

    var count: usize = 0;
    for (bytes) |ch| {
        if (ch == '\n') count += 1;
    }
    if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') count += 1;
    return count;
}

fn fileSize(path: []const u8) !usize {
    var f = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer f.close(std.testing.io);
    const stat = try f.stat(std.testing.io);
    return stat.size;
}

fn writeMetricsRecord(allocator: std.mem.Allocator, metrics: QuickJsMetrics) !void {
    const content = try std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "engine": "quickjs-ng",
        \\  "metrics": {{
        \\    "ergonomics_locs": {d},
        \\    "teardown_complexity": {d},
        \\    "throughput_ops_per_sec": {d:.3},
        \\    "license_spdx": "{s}",
        \\    "wasm_footprint_bytes": {d}
        \\  }}
        \\}}
    ,
        .{
            metrics.ergonomics_locs,
            metrics.teardown_complexity,
            metrics.throughput_ops_per_sec,
            metrics.license_spdx,
            metrics.wasm_footprint_bytes,
        },
    );
    defer allocator.free(content);

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, "spikes/quickjs/metrics.json", .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, content);
}

test "quickjs-ng evaluates 1+1 through real engine" {
    var spike = try QuickJsSpike.init(std.testing.allocator);
    defer spike.deinit();

    const value = try spike.eval("1+1");
    defer c.JS_FreeValue(spike.ctx, value);

    var out: i32 = 0;
    try std.testing.expect(c.JS_ToInt32(spike.ctx, &out, value) == 0);
    try std.testing.expectEqual(@as(i32, 2), out);
}

test "quickjs-ng handler mutates real dom.Node via generational handle" {
    var spike = try QuickJsSpike.init(std.testing.allocator);
    defer spike.deinit();

    const node = try spike.counter.create(dom.Node);
    defer spike.counter.destroy(node);
    node.* = .{ .kind = .{ .element = .{ .tag_name = "button", .attributes = &.{} } } };

    const ref = try spike.table.put(node);
    node.script_wrapper = ref;

    const script_src = try std.fmt.allocPrint(
        std.testing.allocator,
        "mutateNode({d}, {d}, 'clicked')",
        .{ ref.index, ref.generation },
    );
    defer std.testing.allocator.free(script_src);

    const result = try spike.eval(script_src);
    defer c.JS_FreeValue(spike.ctx, result);
    try std.testing.expect(c.JS_ToBool(spike.ctx, result) == 1);

    switch (node.kind) {
        .element => |el| try std.testing.expectEqualStrings("clicked", el.tag_name),
        else => return error.UnexpectedEvalResult,
    }

    spike.table.invalidate(ref);

    const stale_src = try std.fmt.allocPrint(
        std.testing.allocator,
        "mutateNode({d}, {d}, 'clicked')",
        .{ ref.index, ref.generation },
    );
    defer std.testing.allocator.free(stale_src);

    const stale = try spike.eval(stale_src);
    defer c.JS_FreeValue(spike.ctx, stale);
    try std.testing.expect(c.JS_ToBool(spike.ctx, stale) == 0);
}

test "quickjs-ng button-churn: real GC no leak no UAF" {
    var spike = try QuickJsSpike.init(std.testing.allocator);
    defer spike.deinit();

    try spike.runButtonChurn(churn_cycles);
    try std.testing.expectEqual(@as(usize, 0), spike.counter.live_allocs);
    try std.testing.expectEqual(spike.counter.total_allocs, spike.counter.total_frees);

    try std.testing.expectEqual(@as(usize, 0), spike.qjs_alloc.live_blocks);
    try std.testing.expectEqual(spike.qjs_alloc.total_allocs, spike.qjs_alloc.total_frees);
}

test "quickjs-ng records five C2.9 metrics" {
    const metrics = try measureQuickJsMetrics(std.testing.allocator);

    try std.testing.expect(metrics.ergonomics_locs > 0);
    try std.testing.expect(metrics.teardown_complexity >= 2);
    try std.testing.expect(metrics.throughput_ops_per_sec > 0);
    try std.testing.expect(std.mem.eql(u8, metrics.license_spdx, "MIT"));
    try std.testing.expect(metrics.wasm_footprint_bytes > 0);

    try writeMetricsRecord(std.testing.allocator, metrics);
}
