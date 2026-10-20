//! macOS plan rev 16 item 1: on macOS the runtime is always `<exe dir>/../Frameworks/agent-host`, a dev or staging
//! tree included (zig-out/bin -> zig-out/Frameworks), mirroring the shim (@executable_path/../Frameworks) and the
//! zig-out tree the census scans. Linux is unchanged. Unregistered until the green (run: zig test --dep agent_setup
//! -Mroot=tests/agent_setup_ms5_devtree_test.zig -Magent_setup=src/agent_setup.zig).
const std = @import("std");
const agent_setup = @import("agent_setup");

fn expectRuntime(os: std.Target.Os.Tag, exe: []const u8, package_dir: []const u8, python: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rt = try agent_setup.runtimeFor(arena.allocator(), os, exe);
    try std.testing.expectEqualStrings(package_dir, rt.package_dir);
    try std.testing.expectEqualStrings(python, rt.python);
}

const fw = "Python.framework/Versions/3.12/bin/python3.12";

test "a macOS dev or staging tree keeps its runtime in <prefix>/Frameworks/agent-host, like the bundle" {
    try expectRuntime(.macos, "/Users/u/zb/zig-out/bin/zigBrowser", "/Users/u/zb/zig-out/Frameworks/agent-host",
        "/Users/u/zb/zig-out/Frameworks/agent-host/" ++ fw);
    try expectRuntime(.macos, "/tmp/stage/bin/zigBrowser", "/tmp/stage/Frameworks/agent-host",
        "/tmp/stage/Frameworks/agent-host/" ++ fw);
}

test "an app bundle is the same rule: Contents/MacOS -> Contents/Frameworks/agent-host" {
    try expectRuntime(.macos, "/Applications/zigBrowser.app/Contents/MacOS/zigBrowser",
        "/Applications/zigBrowser.app/Contents/Frameworks/agent-host",
        "/Applications/zigBrowser.app/Contents/Frameworks/agent-host/" ++ fw);
}

test "Linux keeps <prefix>/lib/zigbrowser/agent-host and its venv" {
    try expectRuntime(.linux, "/usr/bin/zigBrowser", "/usr/lib/zigbrowser/agent-host", "/usr/lib/zigbrowser/agent-host/venv/bin/python");
}
