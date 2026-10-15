//! Chat drawer S3b (plan D7, D7b, S3.2, S3.6; rev 16 §3c.2, §3c.4): the pure
//! parts of starting the helper from the browser: the launch argv and its
//! built environment, the e2e seams, the app's frames, the runtime-lock check
//! and the restart backoff.

const std = @import("std");
const helper = @import("agent_helper");

fn base() helper.Inputs {
    return .{
        .python = "/rt/venv/bin/python",
        .home = "/d/agent-home",
        .net_dir = "/run/user/1000/zigbrowser-agent-7-00",
        .path_dirs = &.{ "/usr/bin", "/home/u/.bun/bin", "/rt/venv/bin" },
        .lang = "C.UTF-8",
        .e2e_protocol = false,
    };
}

fn expectStrings(want: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "the launch argv names the home, the python and netd's directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run = try helper.launch(arena.allocator(), base());
    try expectStrings(&.{
        "/rt/venv/bin/python", "-m",                  "zb_agent_host", "launch",
        "--home",              "/d/agent-home",       "--python",      "/rt/venv/bin/python",
        "--net-dir",           "/run/user/1000/zigbrowser-agent-7-00",
    }, run.argv);
    try std.testing.expect(run.refusal == null);
    try std.testing.expectEqual(@as(usize, 0), run.warnings.len);
    try std.testing.expect(run.hello_e2e == null);
}

test "the launch environment is built: PATH, locale and the read-only package, nothing inherited" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var in = base();
    in.lc_all = "C";
    const run = try helper.launch(arena.allocator(), in);
    try expectStrings(&.{
        "PATH=/rt/venv/bin:/usr/bin:/bin:/home/u/.bun/bin",
        "PYTHONPATH=/d/agent-home/runtime/host",
        "PYTHONDONTWRITEBYTECODE=1",
        "LANG=C.UTF-8",
        "LC_ALL=C",
    }, run.env);
}

test "without --e2e-protocol the app-owned seams are refused with one line each, and the rest is inert" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var in = base();
    in.bwrap = "/tmp/marker-bwrap";
    in.host_cmd = "/tmp/marker-host";
    in.test_base_url = "https://203.0.113.9";
    in.test_ca = "/tmp/ca.pem";
    const run = try helper.launch(arena.allocator(), in);
    try expectStrings(&.{
        "zigBrowser: ZIGBROWSER_AGENT_BWRAP ignored without --e2e-protocol",
        "zigBrowser: ZIGBROWSER_AGENT_HOST_CMD ignored without --e2e-protocol",
    }, run.warnings);
    try std.testing.expectEqualStrings("/rt/venv/bin/python", run.argv[0]);
    for (run.argv) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, arg, "marker") == null);
        try std.testing.expect(!std.mem.eql(u8, arg, "--test-ca"));
    }
    try std.testing.expect(run.hello_e2e == null);
    try std.testing.expect(run.refusal == null);
}

test "with --e2e-protocol the seams reach launch as arguments and hello as its e2e object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var in = base();
    in.e2e_protocol = true;
    in.bwrap = "/opt/oracle-bwrap";
    in.test_ca = "/tmp/ca.pem";
    in.test_base_url = "https://fake.zb.invalid";
    const run = try helper.launch(arena.allocator(), in);
    try expectStrings(&.{ "--bwrap", "/opt/oracle-bwrap", "--test-ca", "/tmp/ca.pem" }, run.argv[run.argv.len - 4 ..]);
    try std.testing.expectEqualStrings("https://fake.zb.invalid", run.hello_e2e.?.test_base_url.?);
    for (run.env) |entry| try std.testing.expect(std.mem.indexOf(u8, entry, "fake.zb.invalid") == null);
}

test "with --e2e-protocol the helper command seam replaces the whole argv, with the same environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var in = base();
    in.e2e_protocol = true;
    in.host_cmd = "/repo/tests/fixtures/agent/fake_host.py";
    const run = try helper.launch(arena.allocator(), in);
    try expectStrings(&.{"/repo/tests/fixtures/agent/fake_host.py"}, run.argv);
    try std.testing.expectEqualStrings("PYTHONPATH=/d/agent-home/runtime/host", run.env[1]);
}

test "rev 16: the only test base URL is the fake's allowlisted name, through netd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "http://127.0.0.1:8080", "https://api.anthropic.com", "https://fake.zb.invalid/", "" }) |url| {
        var in = base();
        in.e2e_protocol = true;
        in.test_base_url = url;
        const run = try helper.launch(arena.allocator(), in);
        try std.testing.expectEqualStrings("zigBrowser: agent: test base URL must be https://fake.zb.invalid", run.refusal.?);
    }
}

test "the app's frames are exact NDJSON lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"seq\":1,\"type\":\"hello\",\"agent_home\":\"/h\",\"workspace\":\"/h/workspace\",\"scratchpad\":\"/h/scratchpad\",\"route\":\"R1\",\"e2e\":null}\n",
        try helper.helloFrame(a, 1, "/h", null),
    );
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"seq\":2,\"type\":\"hello\",\"agent_home\":\"/h\",\"workspace\":\"/h/workspace\",\"scratchpad\":\"/h/scratchpad\",\"route\":\"R1\",\"e2e\":{\"test_base_url\":\"https://fake.zb.invalid\"}}\n",
        try helper.helloFrame(a, 2, "/h", .{ .test_base_url = "https://fake.zb.invalid" }),
    );
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"seq\":3,\"type\":\"open_session\",\"session\":\"s-4-1\",\"window_id\":\"window-4\"}\n",
        try helper.openSessionFrame(a, 3, 4, 1),
    );
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"seq\":4,\"type\":\"prompt\",\"session\":\"s-4-1\",\"text\":\"say \\\"hi\\\"\\n\"}\n",
        (try helper.promptFrame(a, 4, "s-4-1", "say \"hi\"\n")).?,
    );
    try std.testing.expectEqualStrings("{\"v\":1,\"seq\":5,\"type\":\"interrupt\",\"session\":\"s-4-1\"}\n", try helper.sessionFrame(a, 5, .interrupt, "s-4-1"));
    try std.testing.expectEqualStrings("{\"v\":1,\"seq\":6,\"type\":\"end_session\",\"session\":\"s-4-1\"}\n", try helper.sessionFrame(a, 6, .end_session, "s-4-1"));
    try std.testing.expectEqualStrings("{\"v\":1,\"seq\":7,\"type\":\"shutdown\"}\n", try helper.shutdownFrame(a, 7));
}

test "a prompt over 64 KiB is not sent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const big = try arena.allocator().alloc(u8, 64 * 1024 + 1);
    @memset(big, 'x');
    try std.testing.expect((try helper.promptFrame(arena.allocator(), 1, "s-1-1", big)) == null);
    try std.testing.expect((try helper.promptFrame(arena.allocator(), 1, "s-1-1", big[0 .. 64 * 1024])) != null);
}

test "the runtime lock recorded by --agent-setup must match the installed runtime" {
    const gpa = std.testing.allocator;
    const lock = "ab" ** 32;
    const host = "{\"python\": \"/rt/venv/bin/python\", \"runtime_lock\": \"" ++ lock ++ "\"}";
    try std.testing.expectEqual(helper.RuntimeCheck.ok, helper.checkRuntime(gpa, host, "{\"lock_sha256\": \"" ++ lock ++ "\"}"));
    try std.testing.expectEqual(helper.RuntimeCheck.changed, helper.checkRuntime(gpa, host, "{\"lock_sha256\": \"" ++ "cd" ** 32 ++ "\"}"));
    // A development checkout has no lock on either side.
    try std.testing.expectEqual(helper.RuntimeCheck.ok, helper.checkRuntime(gpa, "{\"python\": \"/p\", \"runtime_lock\": null}", null));
    try std.testing.expectEqual(helper.RuntimeCheck.changed, helper.checkRuntime(gpa, host, null));
    try std.testing.expectEqual(helper.RuntimeCheck.missing, helper.checkRuntime(gpa, null, null));
    try std.testing.expectEqual(helper.RuntimeCheck.missing, helper.checkRuntime(gpa, "not json", null));
}

test "restarts back off 1, 2, 4, then 8 s" {
    try std.testing.expectEqual(@as(u32, 1000), helper.backoffMs(0));
    try std.testing.expectEqual(@as(u32, 2000), helper.backoffMs(1));
    try std.testing.expectEqual(@as(u32, 4000), helper.backoffMs(2));
    try std.testing.expectEqual(@as(u32, 8000), helper.backoffMs(3));
    try std.testing.expectEqual(@as(u32, 8000), helper.backoffMs(40));
}

test "a helper exit maps to a status reason" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("sandbox", helper.exitReason(&buf, .{ .exited = 3 }));
    try std.testing.expectEqualStrings("exit-1", helper.exitReason(&buf, .{ .exited = 1 }));
    try std.testing.expectEqualStrings("signal-9", helper.exitReason(&buf, .{ .signaled = 9 }));
}
