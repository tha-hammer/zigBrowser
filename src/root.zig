const std = @import("std");
const cli = @import("cli.zig");
const uri = @import("uri.zig");
const webkit = @import("webkit.zig");

test "module reachability" {
    _ = cli;
    _ = uri;
    _ = webkit;
}

test "--version line reports WebKitGTK and GTK runtime versions" {
    var buf: [160]u8 = undefined;
    const line = webkit.versionLine(&buf);
    try std.testing.expect(isVersionLine(line));
}

fn isVersionLine(line: []const u8) bool {
    const prefix = "zigBrowser — WebKitGTK ";
    if (!std.mem.startsWith(u8, line, prefix)) return false;

    const rest = line[prefix.len..];
    const sep = ", GTK ";
    const idx = std.mem.indexOf(u8, rest, sep) orelse return false;

    return isSemverTriplet(rest[0..idx]) and isSemverTriplet(rest[idx + sep.len ..]);
}

fn isSemverTriplet(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '.');
    const a = it.next() orelse return false;
    const b = it.next() orelse return false;
    const c = it.next() orelse return false;
    if (it.next() != null) return false;

    return isDigits(a) and isDigits(b) and isDigits(c);
}

fn isDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}
