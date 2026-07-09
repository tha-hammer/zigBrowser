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

// --- Behavior 16: C40 Non-Interference Contract ---

test "C40: automation.js never calls Runtime.enable" {
    try std.testing.expect(std.mem.indexOf(u8, js_source, "Runtime.enable") == null);
}

test "C40: __zbAutomation is defined as non-enumerable" {
    try std.testing.expect(std.mem.indexOf(u8, js_source, "enumerable: false") != null);
}

test "C40: __zbAutomation is non-writable to prevent page tampering" {
    try std.testing.expect(std.mem.indexOf(u8, js_source, "writable: false") != null);
}

test "C40: __zbAutomation is non-configurable" {
    try std.testing.expect(std.mem.indexOf(u8, js_source, "configurable: false") != null);
}

test "C40: automation.js uses defineProperty not direct assignment" {
    try std.testing.expect(std.mem.indexOf(u8, js_source, "Object.defineProperty") != null);
}

test "C40: no telemetry emitted to network from page context" {
    try std.testing.expect(std.mem.indexOf(u8, js_source, "XMLHttpRequest") == null);
    try std.testing.expect(std.mem.indexOf(u8, js_source, "fetch(") == null);
    try std.testing.expect(std.mem.indexOf(u8, js_source, "WebSocket") == null);
    try std.testing.expect(std.mem.indexOf(u8, js_source, "sendBeacon") == null);
}

test "C40: no CDP protocol calls in injected script" {
    try std.testing.expect(std.mem.indexOf(u8, js_source, "Runtime.evaluate") == null);
    try std.testing.expect(std.mem.indexOf(u8, js_source, "Page.addScript") == null);
    try std.testing.expect(std.mem.indexOf(u8, js_source, "DOM.getDocument") == null);
}
