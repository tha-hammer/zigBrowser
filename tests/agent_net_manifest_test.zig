//! MS0 slice D (RoseCat 5750/5752; JadeBeacon 5753/5762, BlueBeaver 5755):
//! netd's argv names the backend's network manifest,
//! `--net-manifest <agent home>/runtime/net.json`, right after `--bwrap BWRAP`
//! and before the e2e seam's options; with no manifest path the argv is
//! byte-identical to today's (tests/agent_net_test.zig pins that).
//! netd reads and checks the file (agent/host/tests/test_netd_manifest.py).

const std = @import("std");
const net = @import("agent_net");

/// netdArgv with a manifest path, or error.TestNetdArgvTakesNoManifest
/// before it takes one (so this file compiles, and fails by behavior, today).
fn argvWith(a: std.mem.Allocator, manifest: ?[]const u8, seam: ?net.NetTest) ![]const []const u8 {
    const params = @typeInfo(@TypeOf(net.netdArgv)).@"fn".params.len;
    return if (comptime params == 7)
        net.netdArgv(a, "/v/bin/python", "/pkg", "/d", "/usr/bin/bwrap", manifest, seam)
    else
        error.TestNetdArgvTakesNoManifest;
}

fn expectArgv(want: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "netd's argv carries --net-manifest PATH right after --bwrap, before the seam's options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = try argvWith(a, "/home/u/.local/share/zigbrowser/agent-home/runtime/net.json", null);
    try expectArgv(&.{ "/v/bin/python", "-I", "-S", "/pkg/zb_agent_host/netd.py", "--sockdir", "/d", "--bwrap", "/usr/bin/bwrap", "--net-manifest", "/home/u/.local/share/zigbrowser/agent-home/runtime/net.json" }, plain);

    const seam = try net.parseNetTest("--test-bridge 31337=40003 --test-allow fake.zb.invalid=40001");
    const with = try argvWith(a, "/h/runtime/net.json", seam);
    try expectArgv(&.{ "/v/bin/python", "-I", "-S", "/pkg/zb_agent_host/netd.py", "--sockdir", "/d", "--bwrap", "/usr/bin/bwrap", "--net-manifest", "/h/runtime/net.json", "--test-allow", "fake.zb.invalid=40001", "--test-bridge", "31337=40003" }, with);
}

test "without a manifest path netd's argv is today's, byte for byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectArgv(&.{ "/v/bin/python", "-I", "-S", "/pkg/zb_agent_host/netd.py", "--sockdir", "/d", "--bwrap", "/usr/bin/bwrap" }, try argvWith(a, null, null));
}

test "the manifest path is <agent home>/runtime/net.json" {
    if (!@hasDecl(net, "netManifestPath")) return error.TestNoNetManifestPath;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/home/u/.local/share/zigbrowser/agent-home/runtime/net.json", try net.netManifestPath(a, "/home/u/.local/share/zigbrowser/agent-home"));
}
