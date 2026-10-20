//! macOS plan rev 14 item 3, the interpreter (RoseCat 6797): `runtimeFor` must name the python.org universal2
//! framework's launcher inside an app bundle, with no venv, and assert BOTH fields. A macOS dev tree and Linux
//! keep `venv/bin/python`. Unregistered until the green (run: zig test --dep agent_setup
//! -Mroot=tests/agent_setup_ms5_python_test.zig -Magent_setup=src/agent_setup.zig).
const std = @import("std");
const agent_setup = @import("agent_setup");

fn expectRuntime(os: std.Target.Os.Tag, exe: []const u8, package_dir: []const u8, python: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rt = try agent_setup.runtimeFor(arena.allocator(), os, exe);
    try std.testing.expectEqualStrings(package_dir, rt.package_dir);
    try std.testing.expectEqualStrings(python, rt.python);
}

test "an app bundle runs the framework's fat launcher, never a venv" {
    try expectRuntime(.macos, "/Applications/zigBrowser.app/Contents/MacOS/zigBrowser",
        "/Applications/zigBrowser.app/Contents/Frameworks/agent-host",
        "/Applications/zigBrowser.app/Contents/Frameworks/agent-host/Python.framework/Versions/3.12/bin/python3.12");
    try expectRuntime(.macos, "/Users/u/Apps/Z B.app/Contents/MacOS/zigBrowser",
        "/Users/u/Apps/Z B.app/Contents/Frameworks/agent-host",
        "/Users/u/Apps/Z B.app/Contents/Frameworks/agent-host/Python.framework/Versions/3.12/bin/python3.12");
}

test "a macOS dev tree and Linux keep the installer's venv" {
    try expectRuntime(.macos, "/Users/u/zb/zig-out/bin/zigBrowser",
        "/Users/u/zb/zig-out/lib/zigbrowser/agent-host", "/Users/u/zb/zig-out/lib/zigbrowser/agent-host/venv/bin/python");
    try expectRuntime(.linux, "/usr/bin/zigBrowser", "/usr/lib/zigbrowser/agent-host", "/usr/lib/zigbrowser/agent-host/venv/bin/python");
}
