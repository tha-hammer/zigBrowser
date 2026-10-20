//! MS5 (macOS plan rev 12, BlueBeaver's half), the Linux-provable reds:
//! - item 3: `agent_setup.runtimeFor(os, exe)`. Linux unchanged; a macOS app bundle maps
//!   `<X>.app/Contents/MacOS/zigBrowser` to `<X>.app/Contents/Frameworks/agent-host` (nested code is
//!   signed there, JadeBeacon 6756); a macOS dev tree keeps the Linux rule.
//! - item 6: `agent_setup.platformGate(os, seatbelt_ready)`. macOS setup never runs unsandboxed: until
//!   MS6's Seatbelt backend is accepted it refuses with one fixed line; Linux runs; any other OS keeps
//!   the Linux-only refusal.
//! Unregistered until the green (run: zig test --dep agent_setup -Mroot=<this> -Magent_setup=src/agent_setup.zig).
const std = @import("std");
const agent_setup = @import("agent_setup");

const has_runtime_for = @hasDecl(agent_setup, "runtimeFor");
const has_gate = @hasDecl(agent_setup, "platformGate");

fn packageDir(os: std.Target.Os.Tag, exe: []const u8) ![]const u8 {
    if (!has_runtime_for) return error.MissingRuntimeFor;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rt = try agent_setup.runtimeFor(arena.allocator(), os, exe);
    return try std.testing.allocator.dupe(u8, rt.package_dir);
}

fn expectPackageDir(os: std.Target.Os.Tag, exe: []const u8, want: []const u8) !void {
    const got = try packageDir(os, exe);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "item 3: Linux keeps <prefix>/lib/zigbrowser/agent-host" {
    try expectPackageDir(.linux, "/usr/bin/zigBrowser", "/usr/lib/zigbrowser/agent-host");
    try expectPackageDir(.linux, "/opt/zb/bin/zigBrowser", "/opt/zb/lib/zigbrowser/agent-host");
}

test "item 3: a macOS app bundle keeps its runtime in Contents/Frameworks/agent-host" {
    try expectPackageDir(.macos, "/Applications/zigBrowser.app/Contents/MacOS/zigBrowser",
        "/Applications/zigBrowser.app/Contents/Frameworks/agent-host");
    try expectPackageDir(.macos, "/Users/u/Apps/Z B.app/Contents/MacOS/zigBrowser",
        "/Users/u/Apps/Z B.app/Contents/Frameworks/agent-host");
}

test "item 3: a macOS dev tree (not inside an .app) keeps the Linux rule" {
    try expectPackageDir(.macos, "/Users/u/zb/zig-out/bin/zigBrowser", "/Users/u/zb/zig-out/lib/zigbrowser/agent-host");
    // `Contents/MacOS` outside an `.app` is not a bundle.
    try expectPackageDir(.macos, "/tmp/Contents/MacOS/zigBrowser", "/tmp/Contents/lib/zigbrowser/agent-host");
}

test "item 3: never the Resources directory (code there fails codesign --strict)" {
    const got = try packageDir(.macos, "/Applications/zigBrowser.app/Contents/MacOS/zigBrowser");
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "/Resources/") == null);
}

test "item 6: macOS setup refuses until MS6's Seatbelt backend is accepted, and never runs unsandboxed" {
    if (!has_gate) return error.MissingPlatformGate;
    const gate = agent_setup.platformGate(.macos, false);
    try std.testing.expect(gate == .refuse);
    try std.testing.expectEqualStrings(
        "zigBrowser: agent-setup: the macOS sandbox is not ready; setup will not run unsandboxed",
        gate.refuse,
    );
    try std.testing.expect(agent_setup.platformGate(.macos, true) == .run);
}

test "item 6: Linux runs; another OS keeps the Linux-only refusal" {
    if (!has_gate) return error.MissingPlatformGate;
    try std.testing.expect(agent_setup.platformGate(.linux, false) == .run);
    try std.testing.expect(agent_setup.platformGate(.linux, true) == .run);
    const win = agent_setup.platformGate(.windows, true);
    try std.testing.expect(win == .refuse);
    try std.testing.expectEqualStrings("zigBrowser: agent-setup: the Claude Agent is Linux-only", win.refuse);
}
