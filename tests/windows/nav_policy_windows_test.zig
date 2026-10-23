//! ong.13 B1 (plan `2026-10-23-ong13-windows-nav-policy-tdd-plan.md` rev 3, approved 83ea7e91): the shared navigation
//! policy on Windows-shaped `file:` URLs. UNREGISTERED red: `nav_policy.decideWith`, `nav_policy.baseFromStart` and
//! the C export `zb_policy_base_from_start` do not exist yet, so this file does not compile. The green adds them and
//! registers this file as its own `zig build test` member.
//!
//! Run alone (hostless; private caches):
//!   zig test --dep nav_policy -Mroot=tests/windows/nav_policy_windows_test.zig -Mnav_policy=src/nav_policy.zig
//!
//! B1a `decideWith(…, fold_drive)`: only a leading drive designator (`/X:` then `/` or end) is case-folded, after
//!     decode and `.`/`..` normalization of both paths; every later component compares exactly. `fold_drive = false`
//!     keeps today's answers. The export folds on Windows only (its wiring is mutated in the live legs, not here).
//! B1b `baseFromStart`: the D2 base contract.
//! B1c the C ABI `zb_policy_base_from_start` (src/webkit_shim.h): size query, exact fit, one byte short, empty,
//!     invalid arguments, malformed fallback; `out` is untouched on every negative return.

const std = @import("std");
const nav = @import("nav_policy");

const base = "file:///C:/run/app/";

fn expectDecision(want: nav.Decision, candidate: []const u8, fold_drive: bool) !void {
    const got = nav.decideWith(base, candidate, .navigation_action, fold_drive);
    if (got != want) {
        std.debug.print("candidate {s} fold_drive={} -> {s}, want {s}\n", .{ candidate, fold_drive, @tagName(got), @tagName(want) });
        return error.WrongDecision;
    }
}

test "B1a: the drive letter's case alone is folded" {
    try expectDecision(.use, "file:///C:/run/app/page-b.html", true);
    try expectDecision(.use, "file:///c:/run/app/page-b.html", true);
}

test "B1a: a directory-case alias fails closed" {
    try expectDecision(.ignore, "file:///C:/run/APP/page-b.html", true);
    try expectDecision(.ignore, "file:///c:/RUN/app/page-b.html", true);
}

test "B1a: a segment boundary is respected; the base directory itself is inside" {
    try expectDecision(.ignore, "file:///C:/run/app2/x.html", true);
    try expectDecision(.ignore, "file:///c:/run/app2/x.html", true);
    try expectDecision(.use, "file:///C:/run/app", true);
    try expectDecision(.use, "file:///c:/run/app/", true);
}

test "B1a: normalization comes before the comparison" {
    try expectDecision(.use, "file:///c:/run/x/../app/p.html", true);
    try expectDecision(.use, "file:///C:/run/app/./p.html", true);
    try expectDecision(.use, "file:///c:/run/app/sub/../p.html", true);
    try expectDecision(.ignore, "file:///c:/run/app/../x/p.html", true);
}

test "B1a: outside, other drive, UNC, encoded backslash and non-file candidates stay ignored" {
    try expectDecision(.ignore, "file:///C:/run/automation/input.html", true);
    try expectDecision(.ignore, "file:///D:/run/app/p.html", true);
    try expectDecision(.ignore, "file:///d:/run/app/p.html", true);
    try expectDecision(.ignore, "file:///C:/run/app/../../../../D:/run/app/p.html", true);
    try expectDecision(.ignore, "file://server/share/run/app/p.html", true);
    try expectDecision(.ignore, "file:///C:/run/app%5C..%5Cautomation%5Cinput.html", true);
    try expectDecision(.ignore, "https://example.com/run/app/p.html", true);
}

test "B1a: without folding today's answers are kept" {
    try expectDecision(.use, "file:///C:/run/app/page-b.html", false);
    try expectDecision(.ignore, "file:///c:/run/app/page-b.html", false);
    try expectDecision(.ignore, "file:///C:/run/APP/page-b.html", false);
    try expectDecision(.use, "file:///C:/run/app/../app/page-b.html", false);
    try expectDecision(.ignore, "file:///C:/run/automation/input.html", false);
}

test "B1a: a POSIX base has no drive designator to fold" {
    const posix = "file:///home/u/app/";
    try std.testing.expectEqual(nav.Decision.use, nav.decideWith(posix, "file:///home/u/app/p.html", .navigation_action, true));
    try std.testing.expectEqual(nav.Decision.ignore, nav.decideWith(posix, "file:///HOME/u/app/p.html", .navigation_action, true));
    try std.testing.expectEqual(nav.Decision.ignore, nav.decideWith(posix, "file:///home/u/App/p.html", .navigation_action, true));
}

test "B1a: decide is decideWith without folding" {
    for ([_][]const u8{ "file:///c:/run/app/page-b.html", "file:///C:/run/app/page-b.html", "file:///C:/run/x.html" }) |c| {
        try std.testing.expectEqual(nav.decideWith(base, c, .navigation_action, false), nav.decide(base, c, .navigation_action));
    }
}

fn expectBase(want: []const u8, start: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const got = nav.baseFromStart(start, &buf) orelse {
        std.debug.print("start {s} -> null, want {s}\n", .{ start, want });
        return error.NoBase;
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("start {s} -> {s}, want {s}\n", .{ start, got, want });
        return error.WrongBase;
    }
}

test "B1b: a local file: start gives its directory with a trailing slash" {
    try expectBase("file:///C:/run/app/", "file:///C:/run/app/test.html");
    try expectBase("file:///C:/run/app/", "file:///C:/run/app/test.html?x=1");
    try expectBase("file:///C:/run/app/", "file:///C:/run/app/test.html#f");
    try expectBase("file:///C:/run/app/", "file:///C:/run/app/test.html?x=1#f");
    try expectBase("file:///C:/run/app/", "file:///C:/run/app/");
    try expectBase("file:///C:/run/app/", "file:///C:/run/app/../app/test.html");
    try expectBase("file:///C:/run/app/", "file://localhost/C:/run/app/t.html");
    try expectBase("file:///home/u/app/", "file:///home/u/app/t.html");
}

test "B1b: bytes outside the unreserved set are percent-encoded in the base" {
    try expectBase("file:///C:/run/my%20app/", "file:///C:/run/my%20app/t.html");
    try expectBase("file:///C:/run/a%25b/", "file:///C:/run/a%25b/t.html");
    try expectBase("file:///C:/run/caf%C3%A9/", "file:///C:/run/caf%C3%A9/t.html");
}

test "B1b: a non-file start keeps GTK's last-slash prefix; a malformed file start is unchanged" {
    try expectBase("https://h/a/", "https://h/a/b?q");
    try expectBase("https://h/a/b?q=/", "https://h/a/b?q=/x");
    try expectBase("about:blank", "about:blank");
    try expectBase("file://server/share/x.html", "file://server/share/x.html");
    try expectBase("file:relative.html", "file:relative.html");
}

const BASE_INVALID: c_int = -1;
const BASE_SHORT: c_int = -3;

test "B1c: the export's size query and an exact fit" {
    const start = "file:///C:/run/app/test.html";
    const want = "file:///C:/run/app/";
    const len = nav.zb_policy_base_from_start(start, null, 0);
    try std.testing.expectEqual(@as(c_int, want.len), len);
    var buf: [want.len + 1]u8 = undefined;
    try std.testing.expectEqual(len, nav.zb_policy_base_from_start(start, &buf, buf.len));
    try std.testing.expectEqualStrings(want, buf[0..want.len]);
    try std.testing.expectEqual(@as(u8, 0), buf[want.len]);
}

test "B1c: one byte short and zero capacity write nothing" {
    const start = "file:///C:/run/app/test.html";
    const want_len = "file:///C:/run/app/".len;
    var buf: [want_len]u8 = undefined;
    @memset(&buf, 0xA5);
    try std.testing.expectEqual(BASE_SHORT, nav.zb_policy_base_from_start(start, &buf, buf.len));
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0xA5), b);
    try std.testing.expectEqual(BASE_SHORT, nav.zb_policy_base_from_start(start, &buf, 0));
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0xA5), b);
}

test "B1c: an empty start is the empty base" {
    try std.testing.expectEqual(@as(c_int, 0), nav.zb_policy_base_from_start("", null, 0));
    var buf = [_]u8{0xA5};
    try std.testing.expectEqual(@as(c_int, 0), nav.zb_policy_base_from_start("", &buf, 1));
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
}

test "B1c: invalid arguments are refused and write nothing" {
    var buf = [_]u8{0xA5} ** 8;
    try std.testing.expectEqual(BASE_INVALID, nav.zb_policy_base_from_start(null, &buf, buf.len));
    try std.testing.expectEqual(BASE_INVALID, nav.zb_policy_base_from_start("file:///C:/a/b.html", null, 5));
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0xA5), b);
}

test "B1c: a malformed file start comes back unchanged through the export" {
    const start = "file://server/share/x.html";
    var buf: [start.len + 1]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, start.len), nav.zb_policy_base_from_start(start, &buf, buf.len));
    try std.testing.expectEqualStrings(start, buf[0..start.len]);
}
