const std = @import("std");
const testing = std.testing;
const dashboard_embed = @import("dashboard_embed");

test "dashboard HTML content is non-empty" {
    const html = dashboard_embed.html;
    try testing.expect(html.len > 0);
}

test "dashboard HTML starts with doctype" {
    const html = dashboard_embed.html;
    try testing.expect(std.mem.startsWith(u8, html, "<!DOCTYPE html>"));
}

test "dashboard HTML contains zbHost IPC bridge" {
    const html = dashboard_embed.html;
    try testing.expect(std.mem.indexOf(u8, html, "zbHost") != null);
}

test "dashboard HTML contains content security policy meta tag" {
    const html = dashboard_embed.html;
    try testing.expect(std.mem.indexOf(u8, html, "Content-Security-Policy") != null);
}

test "dashboard HTML does not contain HMAC secret references" {
    const html = dashboard_embed.html;
    try testing.expect(std.mem.indexOf(u8, html, "X-ZB-Signature") == null);
    try testing.expect(std.mem.indexOf(u8, html, "HMAC") == null);
    try testing.expect(std.mem.indexOf(u8, html, "client_shared_secret") == null);
}
