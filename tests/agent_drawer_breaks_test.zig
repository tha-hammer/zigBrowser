//! S5c-1 (chat-drawer plan S5.6, rev 16.20.2; the user's decision 1, 2026-10-19): a
//! bubble's long unbroken runs get break points, so GTK can wrap them, and Copy maps
//! a selection of the shown text back to the original bytes.
//! The rule: a run is a maximal sequence of code points that are not ASCII
//! whitespace (SP, HT, LF, VT, FF, CR). A run of more than 128 code points gets a
//! line feed after every 64th of them, never at its end (rev 16.20.9: a line feed,
//! not U+200B). Any other text is shown as it is.
//! The oracle below is written independently of the production code (RoseCat 6015):
//! it works on a code-point array and pins the literal 128 and 64.
const std = @import("std");
const drawer = @import("agent_drawer");

const zwsp = "\u{200B}"; // a character of the source text, never added
const brk = "\n"; // the added break point
const gpa = std.testing.allocator;
const RUN_MIN = 128; // literal: the plan's numbers, not the production exports
const EVERY = 64;

/// The independent oracle: the shown text, and for every shown code-point offset
/// (0..=count) the original byte offset Copy must use.
const Oracle = struct {
    shown: []u8,
    map: []usize,

    fn deinit(self: Oracle) void {
        gpa.free(self.shown);
        gpa.free(self.map);
    }
};

fn isWs(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == 0x0b or cp == 0x0c or cp == '\r';
}

fn oracle(text: []const u8) !Oracle {
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(gpa);
    var starts: std.ArrayList(usize) = .empty; // byte offset of each code point
    defer starts.deinit(gpa);
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    var at: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        try cps.append(gpa, try std.unicode.utf8Decode(slice));
        try starts.append(gpa, at);
        at += slice.len;
    }
    // Each code point's run length (0 for whitespace) and its 1-based index in its run.
    const n = cps.items.len;
    const run_len = try gpa.alloc(usize, n);
    defer gpa.free(run_len);
    const run_pos = try gpa.alloc(usize, n);
    defer gpa.free(run_pos);
    var i: usize = 0;
    while (i < n) {
        if (isWs(cps.items[i])) {
            run_len[i] = 0;
            run_pos[i] = 0;
            i += 1;
            continue;
        }
        var j = i;
        while (j < n and !isWs(cps.items[j])) j += 1;
        for (i..j) |k| {
            run_len[k] = j - i;
            run_pos[k] = k - i + 1;
        }
        i = j;
    }
    var shown: std.ArrayList(u8) = .empty;
    errdefer shown.deinit(gpa);
    var map: std.ArrayList(usize) = .empty;
    errdefer map.deinit(gpa);
    var buf: [4]u8 = undefined;
    for (0..n) |k| {
        try map.append(gpa, starts.items[k]);
        const len = try std.unicode.utf8Encode(cps.items[k], &buf);
        try shown.appendSlice(gpa, buf[0..len]);
        if (run_len[k] > RUN_MIN and run_pos[k] % EVERY == 0 and run_pos[k] < run_len[k]) {
            try map.append(gpa, starts.items[k] + len); // an added break maps after its character
            try shown.appendSlice(gpa, brk);
        }
    }
    try map.append(gpa, text.len);
    return .{ .shown = try shown.toOwnedSlice(gpa), .map = try map.toOwnedSlice(gpa) };
}

/// breakRuns and every originalOffset agree with the oracle.
fn agree(text: []const u8) !void {
    const want = try oracle(text);
    defer want.deinit();
    const got = try drawer.breakRuns(gpa, text);
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u8, want.shown, got);
    for (want.map, 0..) |offset, c| {
        try std.testing.expectEqual(offset, drawer.originalOffset(text, c));
    }
    try std.testing.expectEqual(text.len, drawer.originalOffset(text, want.map.len + 5));
}

fn breaksIn(text: []const u8) !usize {
    const got = try drawer.breakRuns(gpa, text);
    defer gpa.free(got);
    return (got.len - text.len) / brk.len;
}

test "the production bounds are the plan's literal 128 and 64" {
    try std.testing.expectEqual(@as(usize, RUN_MIN), drawer.break_run_min);
    try std.testing.expectEqual(@as(usize, EVERY), drawer.break_every);
}

test "run lengths at the boundaries" {
    try std.testing.expectEqual(@as(usize, 0), try breaksIn("y" ** 128)); // exactly 128: unchanged
    try std.testing.expectEqual(@as(usize, 2), try breaksIn("y" ** 129)); // after the 64th and the 128th
    try std.testing.expectEqual(@as(usize, 2), try breaksIn("y" ** 192)); // an exact multiple: none at its end
    try std.testing.expectEqual(@as(usize, 3), try breaksIn("y" ** 193));
    try agree("y" ** 128);
    try agree("y" ** 129);
    try agree("y" ** 192);
    try agree("y" ** 193);
}

test "each of the six ASCII whitespace bytes ends a run; NBSP and U+200B do not" {
    const half = "a" ** 100;
    for ([_][]const u8{ " ", "\t", "\n", "\x0b", "\x0c", "\r" }) |ws| {
        const text = try std.mem.concat(gpa, u8, &.{ half, ws, half });
        defer gpa.free(text);
        try std.testing.expectEqual(@as(usize, 0), try breaksIn(text));
        try agree(text);
    }
    for ([_][]const u8{ "\u{00A0}", zwsp }) |not_ws| {
        const text = try std.mem.concat(gpa, u8, &.{ half, not_ws, half }); // one run of 201
        defer gpa.free(text);
        try std.testing.expectEqual(@as(usize, 3), try breaksIn(text));
        try agree(text);
    }
}

test "code points are counted, not bytes" {
    try std.testing.expectEqual(@as(usize, 0), try breaksIn("\u{754C}" ** 128)); // 384 bytes, 128 code points
    try agree("\u{754C}" ** 129);
    try agree("\u{1F600}" ** 300);
}

test "only the long run is broken; the words around it are untouched" {
    const text = "before words " ++ ("Q" ** 200) ++ " after words";
    try agree(text);
    const out = try drawer.breakRuns(gpa, text);
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "before words Q"));
    try std.testing.expect(std.mem.endsWith(u8, out, "Q after words"));
}

test "text with no long run is shown unchanged" {
    for ([_][]const u8{ "", "Hello from the agent", "word " ** 1000, "line one\nline two\ttabbed" }) |text| {
        const out = try drawer.breakRuns(gpa, text);
        defer gpa.free(out);
        try std.testing.expectEqualStrings(text, out);
        try agree(text);
    }
}

test "Copy's map: repeated runs, multibyte runs and the source's own U+200B" {
    try agree("y" ** 1000);
    try agree("\u{754C}" ** 400 ++ " tail");
    try agree("x" ** 130 ++ zwsp ++ "z" ** 130); // the original's own U+200B is a character of the run
    try agree(("ab" ** 100) ++ " " ++ ("ab" ** 100));
}

test "property: for any text, breakRuns and every originalOffset match the oracle" {
    var prng = std.Random.DefaultPrng.init(0x5c1);
    const r = prng.random();
    const alphabet = [_][]const u8{ "a", "b", " ", "\n", "\u{754C}", "\u{1F600}", zwsp, "\t", "\u{00A0}", "\r" };
    var round: usize = 0;
    while (round < 400) : (round += 1) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const n = r.uintLessThan(usize, 700);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            // Long runs are likely: most picks are one of the two letters.
            const pick = if (r.uintLessThan(u8, 10) < 8) alphabet[r.uintLessThan(usize, 2)] else alphabet[r.uintLessThan(usize, alphabet.len)];
            try buf.appendSlice(gpa, pick);
        }
        try agree(buf.items);
    }
}
