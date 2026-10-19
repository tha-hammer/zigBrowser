//! S5c-1 (chat-drawer plan S5.6, rev 16.20; the user's decision 1, 2026-10-19): a
//! bubble's long unbroken runs get break points, so GTK can wrap them, and Copy maps
//! a selection of the shown text back to the original bytes.
//! The rule: a run is a maximal sequence of characters that are not ASCII
//! whitespace. A run of more than `break_run_min` characters gets U+200B after
//! every `break_every` characters of it, never at its end. Any other text is shown
//! as it is.
const std = @import("std");
const drawer = @import("agent_drawer");

const zwsp = "\u{200B}";
const gpa = std.testing.allocator;

fn shown(text: []const u8) ![]u8 {
    return drawer.breakRuns(gpa, text);
}

test "text with no run over the limit is shown unchanged" {
    const cases = [_][]const u8{
        "",
        "Hello from the agent",
        "word " ** 1000,
        "a" ** drawer.break_run_min,
        ("b" ** drawer.break_run_min) ++ " " ++ ("c" ** drawer.break_run_min),
        "line one\nline two\ttabbed",
    };
    for (cases) |text| {
        const out = try shown(text);
        defer gpa.free(out);
        try std.testing.expectEqualStrings(text, out);
    }
}

test "a run one over the limit gets a break point after every break_every characters" {
    const text = "y" ** (drawer.break_run_min + 1);
    const out = try shown(text);
    defer gpa.free(out);
    const per = drawer.break_every;
    const breaks = (text.len - 1) / per;
    try std.testing.expectEqual(text.len + breaks * zwsp.len, out.len);
    var i: usize = 0;
    var seen: usize = 0;
    while (i < out.len) {
        if (std.mem.startsWith(u8, out[i..], zwsp)) {
            try std.testing.expectEqual(per * (seen + 1), i - seen * zwsp.len);
            seen += 1;
            i += zwsp.len;
        } else i += 1;
    }
    try std.testing.expectEqual(breaks, seen);
    try std.testing.expect(!std.mem.endsWith(u8, out, zwsp));
}

test "characters are counted, not bytes, and a break never splits a character" {
    const text = "\u{754C}" ** 300; // 300 characters, 900 bytes
    const out = try shown(text);
    defer gpa.free(out);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expectEqual(text.len + ((300 - 1) / drawer.break_every) * zwsp.len, out.len);
}

test "only the long run is broken; the words around it are untouched" {
    const run = "Q" ** 200;
    const text = "before words " ++ run ++ " after words";
    const out = try shown(text);
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "before words Q"));
    try std.testing.expect(std.mem.endsWith(u8, out, "Q after words"));
}

/// Shown character offset -> original byte offset, at every offset of `text`'s
/// shown form: monotonic, every original character boundary is reached, and a
/// selection of the shown text maps to exactly the original bytes it covers.
fn checkMapping(text: []const u8) !void {
    const out = try shown(text);
    defer gpa.free(out);
    const chars = try std.unicode.utf8CountCodepoints(out);
    var prev: usize = 0;
    var c: usize = 0;
    while (c <= chars) : (c += 1) {
        const at = drawer.originalOffset(text, c);
        try std.testing.expect(at >= prev and at <= text.len);
        try std.testing.expect(at == text.len or (text[at] & 0xC0) != 0x80);
        prev = at;
    }
    // Each shown character maps to the same character of the original; an added
    // break point maps to where the next character starts, and only added ones exist.
    var view = try std.unicode.Utf8View.init(out);
    var it = view.iterator();
    var at: usize = 0;
    var added: usize = 0;
    while (it.nextCodepointSlice()) |slice| : (at += 1) {
        const o = drawer.originalOffset(text, at);
        if (o < text.len and std.mem.startsWith(u8, text[o..], slice)) continue;
        try std.testing.expectEqualStrings(zwsp, slice);
        try std.testing.expectEqual(o, drawer.originalOffset(text, at + 1));
        added += 1;
    }
    try std.testing.expectEqual(out.len - text.len, added * zwsp.len);
    try std.testing.expectEqual(@as(usize, 0), drawer.originalOffset(text, 0));
    try std.testing.expectEqual(text.len, drawer.originalOffset(text, chars));
    // The whole shown text copies as the whole original, U+200B the original had included.
    const whole = text[drawer.originalOffset(text, 0)..drawer.originalOffset(text, chars)];
    try std.testing.expectEqualStrings(text, whole);
}

test "Copy maps every shown offset back to the original" {
    try checkMapping("");
    try checkMapping("plain words only");
    try checkMapping("y" ** 1000);
    try checkMapping("\u{754C}" ** 400 ++ " tail");
    try checkMapping("x" ** 129 ++ zwsp ++ "z" ** 300); // the original's own U+200B is kept
}

test "property: for any text, every shown character maps back to the original" {
    var prng = std.Random.DefaultPrng.init(0x5c1);
    const r = prng.random();
    const alphabet = [_][]const u8{ "a", "b", " ", "\n", "\u{754C}", "\u{1F600}", zwsp, "\t" };
    var round: usize = 0;
    while (round < 300) : (round += 1) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const n = r.uintLessThan(usize, 600);
        var i: usize = 0;
        // Long runs are likely: most picks are one of the two letters.
        while (i < n) : (i += 1) {
            const pick = if (r.uintLessThan(u8, 10) < 8) alphabet[r.uintLessThan(usize, 2)] else alphabet[r.uintLessThan(usize, alphabet.len)];
            try buf.appendSlice(gpa, pick);
        }
        try checkMapping(buf.items);
        const out = try shown(buf.items);
        defer gpa.free(out);
        try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    }
}
