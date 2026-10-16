//! Chat drawer S3n2, native spawn wiring (plan rev 16.2 §3c.2, §3c.4; BlackRobin
//! 5570): the pure parts of starting netd from the browser.

const std = @import("std");
const net = @import("agent_net");

const gpa = std.testing.allocator;
const rand8 = [8]u8{ 0xde, 0xad, 0xbe, 0xef, 0x00, 0x01, 0x02, 0xff };

test "the socket directory is <XDG_RUNTIME_DIR>/zigbrowser-agent-<pid>-<16 hex>" {
    const dir = try net.sockdirPath(gpa, "/run/user/1000", 4242, rand8);
    defer gpa.free(dir);
    try std.testing.expectEqualStrings("/run/user/1000/zigbrowser-agent-4242-deadbeef000102ff", dir);
}

test "no, an empty or a relative XDG_RUNTIME_DIR refuses" {
    try std.testing.expectError(error.NoRuntimeDir, net.sockdirPath(gpa, null, 1, rand8));
    try std.testing.expectError(error.NoRuntimeDir, net.sockdirPath(gpa, "", 1, rand8));
    try std.testing.expectError(error.RelativeRuntimeDir, net.sockdirPath(gpa, "run/user/1000", 1, rand8));
}

test "the longest socket path may be 107 bytes, not 108" {
    // <runtime>/zigbrowser-agent-1-<16 hex>/bridges/port-51091.sock
    const tail = "/zigbrowser-agent-1-deadbeef000102ff/bridges/port-51091.sock".len;
    var buf: [200]u8 = undefined;
    @memset(&buf, 'r');
    buf[0] = '/';
    const fits = buf[0 .. net.sun_path_max - tail];
    const dir = try net.sockdirPath(gpa, fits, 1, rand8);
    defer gpa.free(dir);
    try std.testing.expectEqual(net.sun_path_max, dir.len + "/bridges/port-51091.sock".len);
    try std.testing.expectError(error.PathTooLong, net.sockdirPath(gpa, buf[0 .. net.sun_path_max - tail + 1], 1, rand8));
}

test "ZIGBROWSER_AGENT_NET_TEST: the decoys' value parses, in any pair order" {
    const all = try net.parseNetTest("--test-allow fake.zb.invalid=40001 --test-bridge 51091=40002 --test-bridge 31337=40003");
    try std.testing.expectEqual(@as(?u16, 40001), all.allow);
    try std.testing.expectEqual(@as(?u16, 40002), all.bridge_51091);
    try std.testing.expectEqual(@as(?u16, 40003), all.bridge_31337);
    const some = try net.parseNetTest("--test-bridge 31337=65535 --test-allow fake.zb.invalid=1");
    try std.testing.expectEqual(@as(?u16, 1), some.allow);
    try std.testing.expectEqual(@as(?u16, null), some.bridge_51091);
    try std.testing.expectEqual(@as(?u16, 65535), some.bridge_31337);
}

test "ZIGBROWSER_AGENT_NET_TEST: every other value refuses" {
    const bad = [_][]const u8{
        "", // empty
        " ", // only a separator
        "--test-allow", // a lone option
        "--test-allow fake.zb.invalid", // no =port
        "--test-allow fake.zb.invalid=", // empty port
        "--test-allow fake.zb.invalid=0", // out of range
        "--test-allow fake.zb.invalid=65536",
        "--test-allow fake.zb.invalid=+1", // a sign
        "--test-allow fake.zb.invalid=-1",
        "--test-allow fake.zb.invalid=01", // a leading zero
        "--test-allow fake.zb.invalid=1x", // not decimal
        "--test-allow evil.invalid=1", // another host
        "--test-allow api.anthropic.com=1", // never the production name
        "--test-bridge 8080=1", // another bridge
        "--test-bridge 51091=1 --test-bridge 51091=2", // a duplicate
        "--test-allow fake.zb.invalid=1 --test-allow fake.zb.invalid=2",
        "--test-nope fake.zb.invalid=1", // an unknown option
        "fake.zb.invalid=1", // a lone pair
        "--test-allow  fake.zb.invalid=1", // two separators
        " --test-allow fake.zb.invalid=1", // a leading separator
        "--test-allow fake.zb.invalid=1 ", // a trailing separator
        "--test-allow\tfake.zb.invalid=1", // a tab
        "--test-bridge 51091=1 --test-allow", // a dangling option
    };
    for (bad) |value| {
        if (net.parseNetTest(value)) |_| {
            std.debug.print("accepted: {s}\n", .{value});
            return error.TestExpectedError;
        } else |err| try std.testing.expectEqual(error.BadNetTest, err);
    }
}

test "ZIGBROWSER_AGENT_NET_TEST: --test-ready-delay ms=1-4000, at most once, last in netd's argv (RoseCat 5830)" {
    const held = try net.parseNetTest("--test-ready-delay ms=2500 --test-allow fake.zb.invalid=40001");
    try std.testing.expectEqual(@as(?u16, 2500), held.ready_delay_ms);
    try std.testing.expectEqual(@as(?u16, 40001), held.allow);
    try std.testing.expectEqual(@as(?u16, 4000), (try net.parseNetTest("--test-ready-delay ms=4000")).ready_delay_ms);
    for ([_][]const u8{
        "--test-ready-delay ms=0",
        "--test-ready-delay ms=4001",
        "--test-ready-delay ms=01",
        "--test-ready-delay ms=",
        "--test-ready-delay 2500",
        "--test-ready-delay s=2500",
        "--test-ready-delay ms=1 --test-ready-delay ms=2",
    }) |value| {
        if (net.parseNetTest(value)) |_| {
            std.debug.print("accepted: {s}\n", .{value});
            return error.TestExpectedError;
        } else |err| try std.testing.expectEqual(error.BadNetTest, err);
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const argv = try net.netdArgv(arena.allocator(), "/v/bin/python", "/pkg", "/d", "/usr/bin/bwrap", null, try net.parseNetTest("--test-ready-delay ms=2500 --test-bridge 31337=40003"));
    try expectArgv(&.{ "/v/bin/python", "-I", "-S", "/pkg/zb_agent_host/netd.py", "--sockdir", "/d", "--bwrap", "/usr/bin/bwrap", "--test-bridge", "31337=40003", "--test-ready-delay", "2500" }, argv);
}

test "netd's argv: exact, with the seam's pairs only when given" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // netd runs as a script (standard library only): -I needs no PYTHONPATH and -S no site.
    const plain = try net.netdArgv(a, "/v/bin/python", "/pkg", "/run/user/1/zigbrowser-agent-1-deadbeef000102ff", "/usr/bin/bwrap", null, null);
    const want_plain = [_][]const u8{ "/v/bin/python", "-I", "-S", "/pkg/zb_agent_host/netd.py", "--sockdir", "/run/user/1/zigbrowser-agent-1-deadbeef000102ff", "--bwrap", "/usr/bin/bwrap" };
    try expectArgv(&want_plain, plain);

    const seam = try net.parseNetTest("--test-bridge 31337=40003 --test-allow fake.zb.invalid=40001");
    const with = try net.netdArgv(a, "/v/bin/python", "/pkg", "/d", "/usr/bin/bwrap", null, seam);
    // A fixed order (allow, then 51091, then 31337), whatever the seam's order.
    const want_with = [_][]const u8{ "/v/bin/python", "-I", "-S", "/pkg/zb_agent_host/netd.py", "--sockdir", "/d", "--bwrap", "/usr/bin/bwrap", "--test-allow", "fake.zb.invalid=40001", "--test-bridge", "31337=40003" };
    try expectArgv(&want_with, with);
}

test "netd's environment is built, never inherited: no ZIGBROWSER_* name reaches it" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const bare = try net.netdEnv(arena.allocator(), null, null);
    try expectArgv(&.{ "PATH=/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE=1" }, bare);
    const lang = try net.netdEnv(arena.allocator(), "C.UTF-8", "en_US.UTF-8");
    try expectArgv(&.{ "PATH=/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE=1", "LANG=C.UTF-8", "LC_ALL=en_US.UTF-8" }, lang);
}

test "ZIGBROWSER_AGENT_NET_TEST_CA: an absolute path to a regular file, not a link" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ca.pem", .data = "-----BEGIN CERTIFICATE-----\n" });
    try tmp.dir.createDir(io, "sub", .default_dir);
    try tmp.dir.symLink(io, "ca.pem", "link.pem", .{});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try net.checkTestCa(try std.fs.path.join(a, &.{ root, "ca.pem" }));
    for ([_][]const u8{ "link.pem", "sub", "missing.pem" }) |name| {
        try std.testing.expectError(error.BadNetTestCa, net.checkTestCa(try std.fs.path.join(a, &.{ root, name })));
    }
    try std.testing.expectError(error.BadNetTestCa, net.checkTestCa("ca.pem"));
    try std.testing.expectError(error.BadNetTestCa, net.checkTestCa(""));
}

fn expectArgv(want: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}
