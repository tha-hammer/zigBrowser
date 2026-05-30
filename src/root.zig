const std = @import("std");

pub const errors = @import("errors.zig");
pub const cli = @import("cli.zig");
pub const page = @import("page.zig");
pub const script = @import("script/engine.zig");

pub const net = struct {
    pub const c = @import("net/c.zig");
    pub const curl = @import("net/curl.zig");
    pub const fetch = @import("net/fetch.zig");
    pub const store = @import("net/store.zig");
    pub const url = @import("net/url.zig");
};

pub const security = struct {
    pub const origin = @import("security/origin.zig");
};

pub const html = struct {
    pub const dom = @import("html/dom.zig");
    pub const tokenizer = @import("html/tokenizer.zig");
};

pub const css = struct {
    pub const cascade = @import("css/cascade.zig");
};

pub const layout = struct {
    pub const box = @import("layout/box.zig");
};

test "scaffold sanity" {
    try std.testing.expect(true);
}

// Track-owned test aggregators keep this file as a stable coordination seam.
test {
    _ = @import("html/test_root.zig");
}

test {
    _ = @import("render_test_root.zig");
}

test "teardown-order reserved seam executes in exact order" {
    const spy_mod = @import("spy_engine");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var spy = spy_mod.SpyScriptEngine.init(std.testing.allocator);
    defer spy.deinit();

    const spy_vtable = script.ScriptEngine.VTable{
        .stopScript = spy_mod.SpyScriptEngine.stopScript,
        .severHandles = spy_mod.SpyScriptEngine.severHandles,
        .drainFinalizers = spy_mod.SpyScriptEngine.drainFinalizers,
        .teardownIsolate = spy_mod.SpyScriptEngine.teardownIsolate,
        .runScript = spy_mod.SpyScriptEngine.runScript,
        .pumpMicrotasks = spy_mod.SpyScriptEngine.pumpMicrotasks,
    };

    const spy_engine = script.ScriptEngine{
        .ptr = @ptrCast(&spy),
        .vtable = &spy_vtable,
    };

    var test_page = page.Page.init(std.testing.allocator, spy_engine);
    defer test_page.deinit();

    var server = @import("fixture_static").Server.init(std.testing.allocator, std.testing.io) catch |err| {
        std.debug.print("failed to start static fixture: {s}\n", .{@errorName(err)});
        return err;
    };
    defer server.deinit();

    const first_url = try net.url.parse(arena, try server.url(arena, "/index.html"));
    const second_url = try net.url.parse(arena, try server.url(arena, "/next.html"));

    try test_page.navigate(std.testing.io, first_url);
    try test_page.navigate(std.testing.io, second_url);

    const expected = [_]spy_mod.Step{ .stop_script, .sever_handles, .drain_finalizers, .teardown_isolate };
    try std.testing.expectEqualSlices(spy_mod.Step, &expected, spy.calls.items[0..expected.len]);
}
