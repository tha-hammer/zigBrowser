const std = @import("std");

const testing = std.testing;

pub const Platform = enum {
    linux,
    macos,
    windows,
};

pub const AutomationConfig = struct {
    enabled: bool = false,
    socket_path: []const u8 = "",
    token: []const u8 = "",
};

/// The automation socket's path (WS2.0): `<base>\zigbrowser\zigbrowser-automation-<hex>.sock` on
/// Windows (an owner-only directory of its own), `<base>/zigbrowser-automation-<hex>.sock` elsewhere.
/// A path the bind could not hold (UnixAddress.max_len) is error.SocketPathTooLong, never cut.
pub fn planSocketPath(
    allocator: std.mem.Allocator,
    platform: Platform,
    base_dir: []const u8,
    nonce: u64,
) ![]u8 {
    const path = try switch (platform) {
        .windows => std.fmt.allocPrint(
            allocator,
            "{s}\\zigbrowser\\zigbrowser-automation-{x}.sock",
            .{ base_dir, nonce },
        ),
        .linux, .macos => std.fmt.allocPrint(
            allocator,
            "{s}/zigbrowser-automation-{x}.sock",
            .{ base_dir, nonce },
        ),
    };
    if (path.len >= std.Io.net.UnixAddress.max_len) {
        allocator.free(path);
        return error.SocketPathTooLong;
    }
    return path;
}

/// The socket's base directory (WS2.0): Windows, %LOCALAPPDATA% and nothing else (no /tmp or
/// XDG_RUNTIME_DIR fallback: missing or empty is error.NoLocalAppData); Linux and macOS,
/// XDG_RUNTIME_DIR, else /tmp.
pub fn socketBaseDir(platform: Platform, xdg_runtime_dir: ?[]const u8, local_app_data: ?[]const u8) error{NoLocalAppData}![]const u8 {
    return switch (platform) {
        .windows => if (local_app_data) |v| (if (v.len > 0) v else error.NoLocalAppData) else error.NoLocalAppData,
        .linux, .macos => xdg_runtime_dir orelse "/tmp",
    };
}

pub fn runOpenWithAutomationLifecycle(
    server: anytype,
    runner: anytype,
    config: AutomationConfig,
) !u8 {
    if (!config.enabled) return runner.run(server);

    try server.start(config);
    defer server.stop();
    return runner.run(server);
}

test "P2.1 socket path planning is randomized and platform-shaped" {
    const linux_a = try planSocketPath(testing.allocator, .linux, "/tmp/zigbrowser-test", 0x1111);
    defer testing.allocator.free(linux_a);
    const linux_b = try planSocketPath(testing.allocator, .linux, "/tmp/zigbrowser-test", 0x2222);
    defer testing.allocator.free(linux_b);
    const windows = try planSocketPath(testing.allocator, .windows, "C:\\Users\\maceo\\AppData\\Local", 0x3333);
    defer testing.allocator.free(windows);

    try testing.expect(!std.mem.eql(u8, linux_a, linux_b));
    try testing.expect(std.mem.startsWith(u8, linux_a, "/tmp/zigbrowser-test/zigbrowser-automation-"));
    try testing.expect(std.mem.endsWith(u8, linux_a, ".sock"));
    try testing.expect(std.mem.startsWith(u8, windows, "C:\\Users\\maceo\\AppData\\Local\\zigbrowser\\zigbrowser-automation-"));
    try testing.expect(windows.len < std.Io.net.UnixAddress.max_len);
}

test "P2.1 automation lifecycle starts one server around fake app runner and stops after return" {
    var fake_server = FakeAutomationServer{};
    var fake_runner = FakeAppRunner{};
    const config = AutomationConfig{
        .enabled = true,
        .socket_path = "/tmp/zigbrowser-test.sock",
        .token = "test-token",
    };

    const code = try runOpenWithAutomationLifecycle(&fake_server, &fake_runner, config);

    try testing.expectEqual(@as(u8, 7), code);
    try testing.expectEqual(@as(usize, 1), fake_server.start_count);
    try testing.expectEqual(@as(usize, 1), fake_server.stop_count);
    try testing.expect(fake_runner.observed_server_started);
    try testing.expect(fake_runner.observed_server_not_stopped_during_run);
}

test "P2.1 automation lifecycle does not start server when disabled" {
    var fake_server = FakeAutomationServer{};
    var fake_runner = FakeAppRunner{};
    const config = AutomationConfig{
        .enabled = false,
        .socket_path = "",
        .token = "",
    };

    const code = try runOpenWithAutomationLifecycle(&fake_server, &fake_runner, config);

    try testing.expectEqual(@as(u8, 7), code);
    try testing.expectEqual(@as(usize, 0), fake_server.start_count);
    try testing.expectEqual(@as(usize, 0), fake_server.stop_count);
}

const FakeAutomationServer = struct {
    start_count: usize = 0,
    stop_count: usize = 0,
    started: bool = false,

    fn start(self: *FakeAutomationServer, config: AutomationConfig) !void {
        try testing.expect(config.enabled);
        try testing.expect(config.socket_path.len > 0);
        try testing.expect(config.token.len > 0);
        self.start_count += 1;
        self.started = true;
    }

    fn stop(self: *FakeAutomationServer) void {
        self.stop_count += 1;
        self.started = false;
    }
};

const FakeAppRunner = struct {
    observed_server_started: bool = false,
    observed_server_not_stopped_during_run: bool = false,

    fn run(self: *FakeAppRunner, server: *FakeAutomationServer) !u8 {
        self.observed_server_started = server.started;
        self.observed_server_not_stopped_during_run = server.stop_count == 0;
        return 7;
    }
};
