//! MS7.4 (macOS plan line 2158; RoseCat 8058 on 0281321): the AppKit drawer's bubble text, all in the portable
//! src/agent_drawer.zig so src/agent_drawer_mac.m only moves bytes. The GTK bubble shows breakRuns(text) and copies
//! the selection's ORIGINAL bytes through originalOffset (character offsets). AppKit differs in three ways this seam
//! settles:
//! - NSString offsets (selectedRange) are UTF-16 code units, not characters: an astral character (U+10000 and up)
//!   is 2 units;
//! - an exact-length -[NSString initWithBytes:length:encoding:NSUTF8StringEncoding] returns nil for invalid UTF-8,
//!   so the shown bytes must always be valid UTF-8;
//! - an embedded NUL must neither cut the text nor reach the view.
//! The policy (appkitShown): the GTK shown form (break points in long unbroken runs), with every invalid UTF-8
//! sequence and every NUL shown as U+FFFD (one replacement per maximal invalid subpart, as std.unicode does). Copy
//! (appkitOriginalOffset): a UTF-16 offset in the shown text maps to a byte offset in the ORIGINAL, so a selection
//! copies the original's exact bytes (invalid ones and NULs included) and never a break point or a replacement
//! character. bubbleLayoutContiguous(len) (RoseCat 8075: an explicit amendment of the GTK label/text-view split for
//! AppKit): every AppKit bubble is one read-only NSTextView subclass, so Ctrl+C reaches the bubble's own copy: (a
//! selectable NSTextField would copy through the window's shared field editor); label_text_max stays the
//! responsiveness boundary: a bubble up to it lays out contiguously, past it non-contiguously (a 200 KiB reply).
//! Rows: the policy on fixed examples (ASCII, astral, invalid, NUL, a long run); properties over seeded random byte
//! strings (valid UTF-8, no NUL, equal to breakRuns for valid NUL-free input, offset 0 -> 0 and the end -> the
//! original's end, monotone, a whole selection copies the whole original); 200 KiB unbroken and 200 KiB of words
//! (whole copy exact, every shown line of an unbroken run at most break_every characters, non-contiguous layout); and the
//! C exports equal the Zig results.
//! RED until the green adds them; build step `test-agent-drawer-appkit-text`, not in `test`.
const std = @import("std");
const drawer = @import("agent_drawer");

const gpa = std.testing.allocator;
const replacement = "\u{FFFD}";

fn utf16Len(s: []const u8) !usize {
    var n: usize = 0;
    var it = (try std.unicode.Utf8View.init(s)).iterator();
    while (it.nextCodepoint()) |cp| n += if (cp >= 0x10000) 2 else 1;
    return n;
}

fn shown(text: []const u8) ![]u8 {
    return drawer.appkitShown(gpa, text);
}

/// The original bytes a selection of shown UTF-16 units [from, to) copies.
fn copied(text: []const u8, from: usize, to: usize) []const u8 {
    return text[drawer.appkitOriginalOffset(text, from)..drawer.appkitOriginalOffset(text, to)];
}

test "valid NUL-free text shows exactly as on GTK (breakRuns)" {
    for ([_][]const u8{ "", "hello world", "a\u{1F600}b", "tab\there\nline" }) |t| {
        const a = try shown(t);
        defer gpa.free(a);
        const b = try drawer.breakRuns(gpa, t);
        defer gpa.free(b);
        try std.testing.expectEqualStrings(b, a);
    }
}

test "astral characters count two UTF-16 units and copy their four bytes" {
    const t = "a\u{1F600}b"; // 'a', 4 bytes, 'b'
    try std.testing.expectEqual(@as(usize, 0), drawer.appkitOriginalOffset(t, 0));
    try std.testing.expectEqual(@as(usize, 1), drawer.appkitOriginalOffset(t, 1));
    try std.testing.expectEqual(@as(usize, 5), drawer.appkitOriginalOffset(t, 3));
    try std.testing.expectEqual(@as(usize, 6), drawer.appkitOriginalOffset(t, 4));
    try std.testing.expectEqualStrings("\u{1F600}", copied(t, 1, 3));
}

test "invalid UTF-8 and NUL show as U+FFFD and copy their original bytes" {
    const t = "a\xFFb\x00c\xE2\x82d"; // a, a stray byte, b, NUL, c, a truncated 3-byte sequence, d
    const s = try shown(t);
    defer gpa.free(s);
    try std.testing.expectEqualStrings("a" ++ replacement ++ "b" ++ replacement ++ "c" ++ replacement ++ "d", s);
    try std.testing.expect(std.unicode.utf8ValidateSlice(s));
    try std.testing.expect(std.mem.indexOfScalar(u8, s, 0) == null);
    try std.testing.expectEqualStrings("\xFF", copied(t, 1, 2));
    try std.testing.expectEqualStrings("\x00", copied(t, 3, 4));
    try std.testing.expectEqualStrings("\xE2\x82", copied(t, 5, 6));
    try std.testing.expectEqualStrings(t, copied(t, 0, try utf16Len(s)));
}

test "a copy across a break point gives the original run, never the break" {
    const run = "x" ** 200; // one unbroken run: a break after 64, 128 and 192 characters
    const s = try shown(run);
    defer gpa.free(s);
    try std.testing.expectEqual(@as(usize, 203), s.len);
    try std.testing.expectEqualStrings(run[60..70], copied(run, 60, 71)); // 10 x's and the break between
    try std.testing.expectEqualStrings(run, copied(run, 0, try utf16Len(s)));
}

test "seeded random bytes: shown is valid UTF-8 without NUL; offsets are monotone and span the original" {
    var prng = std.Random.DefaultPrng.init(0x5eed_a991e);
    const r = prng.random();
    var buf: [600]u8 = undefined;
    for (0..400) |_| {
        const len = r.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = switch (r.uintLessThan(u8, 4)) {
            0 => r.int(u8), // anything, invalid sequences and NULs included
            1 => ' ',
            else => 'a' + r.uintLessThan(u8, 26),
        };
        const t = buf[0..len];
        const s = try shown(t);
        defer gpa.free(s);
        try std.testing.expect(std.unicode.utf8ValidateSlice(s));
        try std.testing.expect(std.mem.indexOfScalar(u8, s, 0) == null);
        if (std.unicode.utf8ValidateSlice(t) and std.mem.indexOfScalar(u8, t, 0) == null) {
            const b = try drawer.breakRuns(gpa, t);
            defer gpa.free(b);
            try std.testing.expectEqualStrings(b, s);
        }
        const units = try utf16Len(s);
        try std.testing.expectEqual(@as(usize, 0), drawer.appkitOriginalOffset(t, 0));
        try std.testing.expectEqual(t.len, drawer.appkitOriginalOffset(t, units));
        try std.testing.expectEqual(t.len, drawer.appkitOriginalOffset(t, units + 7)); // past the end
        var last: usize = 0;
        for (0..units + 1) |u| {
            const o = drawer.appkitOriginalOffset(t, u);
            try std.testing.expect(o >= last and o <= t.len);
            last = o;
        }
    }
}

test "200 KiB unbroken and 200 KiB of words: whole copy exact, short lines, non-contiguous layout" {
    const big = 200 * 1024;
    const unbroken = try gpa.alloc(u8, big);
    defer gpa.free(unbroken);
    @memset(unbroken, 'q');
    const words = try gpa.alloc(u8, big);
    defer gpa.free(words);
    for (words, 0..) |*b, i| b.* = if (i % 8 == 7) ' ' else 'w';
    for ([_][]const u8{ unbroken, words }) |t| {
        const s = try shown(t);
        defer gpa.free(s);
        try std.testing.expectEqualStrings(t, copied(t, 0, try utf16Len(s)));
        var lines = std.mem.splitScalar(u8, s, '\n');
        while (lines.next()) |line| try std.testing.expect(line.len <= drawer.break_every or std.mem.indexOfScalar(u8, line, ' ') != null);
        try std.testing.expect(!drawer.bubbleLayoutContiguous(t.len));
    }
    try std.testing.expect(drawer.bubbleLayoutContiguous(drawer.label_text_max));
    try std.testing.expect(!drawer.bubbleLayoutContiguous(drawer.label_text_max + 1));
}

test "the C exports return exactly the Zig results" {
    for ([_][]const u8{ "", "a\u{1F600}b", "a\xFFb\x00c", "x" ** 200 }) |t| {
        const s = try shown(t);
        defer gpa.free(s);
        var out_len: usize = 0;
        const c = drawer.zb_drawer_appkit_shown(t.ptr, t.len, &out_len) orelse return error.OutOfMemory;
        defer std.c.free(c);
        try std.testing.expectEqualStrings(s, c[0..out_len]);
        try std.testing.expectEqual(@as(u8, 0), c[out_len]); // NUL-terminated for the caller
        for (0..(try utf16Len(s)) + 2) |u| {
            try std.testing.expectEqual(drawer.appkitOriginalOffset(t, u), drawer.zb_drawer_appkit_original_offset(t.ptr, t.len, u));
        }
    }
    for ([_]usize{ 0, drawer.label_text_max, drawer.label_text_max + 1 }) |n| {
        try std.testing.expectEqual(@as(c_int, @intFromBool(drawer.bubbleLayoutContiguous(n))), drawer.zb_drawer_bubble_layout_contiguous(n));
    }
}
