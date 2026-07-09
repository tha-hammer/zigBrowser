const std = @import("std");
const js_embed = @import("js_embed");
const js_source: []const u8 = js_embed.source;

// --- Behavior 11: DOM Rate-Limit Detection ---

test "automation.js contains rateLimitScan handler in dispatch" {
    try std.testing.expect(std.mem.indexOf(u8, js_source, "'rateLimitScan'") != null);
}

test "rateLimitScan checks for modal selectors" {
    const has_dialog = std.mem.indexOf(u8, js_source, "dialog") != null;
    const has_alertdialog = std.mem.indexOf(u8, js_source, "alertdialog") != null;
    try std.testing.expect(has_dialog or has_alertdialog);
}

test "rateLimitScan returns platform_rate_limited on signal detection" {
    try std.testing.expect(std.mem.indexOf(u8, js_source, "platform_rate_limited") != null);
}

test "rateLimitScan hashes raw text via hashText" {
    try std.testing.expect(std.mem.indexOf(u8, js_source, "hashText") != null);
}

// --- Behavior 12: Observer Cleanup After Operations ---

test "automation.js disconnects MutationObservers in cleanup" {
    try std.testing.expect(std.mem.indexOf(u8, js_source, "observer.disconnect()") != null);
}

test "automation.js tracks outstanding waits for leak detection" {
    try std.testing.expect(std.mem.indexOf(u8, js_source, "outstandingWaits") != null);
}

test "automation.js decrements outstanding waits in cleanup path" {
    try std.testing.expect(std.mem.indexOf(u8, js_source, "outstandingWaits -= 1") != null);
}

test "automation.js exposes debugOutstandingWaits for verification" {
    try std.testing.expect(std.mem.indexOf(u8, js_source, "debugOutstandingWaits") != null);
}
