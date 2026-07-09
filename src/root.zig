const std = @import("std");
const cli = @import("cli.zig");
const automation_rpc = @import("automation_rpc.zig");
const automation_transport = @import("automation_transport.zig");
const ipc = @import("ipc.zig");
const nav_policy = @import("nav_policy.zig");
const uri = @import("uri.zig");
const webkit = @import("webkit.zig");

test "module reachability" {
    _ = cli;
    _ = automation_rpc;
    _ = automation_transport;
    _ = ipc;
    _ = nav_policy;
    _ = uri;
    _ = webkit;
}

test "--version line reports backend runtime versions" {
    var buf: [160]u8 = undefined;
    const line = webkit.versionLine(&buf);
    try std.testing.expect(isVersionLine(line));
}

fn isVersionLine(line: []const u8) bool {
    const prefix = "zigBrowser — ";
    if (!std.mem.startsWith(u8, line, prefix)) return false;

    const rest = line[prefix.len..];
    if (std.mem.startsWith(u8, rest, "WebKitGTK ")) {
        return isGtkVersion(rest["WebKitGTK ".len ..]);
    }
    if (std.mem.startsWith(u8, rest, "WebView2 ")) {
        return rest.len > "WebView2 ".len;
    }
    if (std.mem.startsWith(u8, rest, "WKWebView ")) {
        return rest.len > "WKWebView ".len;
    }
    return false;
}

fn isGtkVersion(rest: []const u8) bool {
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
