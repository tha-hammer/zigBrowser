//! MS6.5.1 red (RoseCat 0d2e91d #2). `load` must bound the input BEFORE unbounded allocation: the read is
//! size-limited to MAX_LEDGER_BYTES, so a file over the bound is rejected as TooManyEntries, not read/parsed in
//! full. Real file via the held dir — no signals. UNREGISTERED until green.
//!
//! The mutant this catches (the plan's "parse-all-then-count"): a load that reads with no size limit turns an
//! over-bound file into a Malformed (truncated) parse, not a clean TooManyEntries.
const std = @import("std");
const ledger = @import("agent_run_ledger");

test "a file larger than MAX_LEDGER_BYTES is TooManyEntries, bounded before parsing" {
    const io = std.testing.io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();

    const big = ledger.MAX_LEDGER_BYTES + 4096;
    const buf = try std.testing.allocator.alloc(u8, big);
    defer std.testing.allocator.free(buf);
    @memset(buf, ' ');
    const head = "{\"schema_version\":2,\"runs\":[";
    @memcpy(buf[0..head.len], head); // looks like the start of a huge array so a no-limit mutant reads+parses it

    try td.dir.writeFile(io, .{ .sub_path = "huge.json", .data = buf });
    try std.testing.expectError(error.TooManyEntries, ledger.load(io, std.testing.allocator, td.dir, "huge.json"));
}

test "a valid within-bound ledger loads to its entries" {
    const io = std.testing.io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const s =
        \\{"schema_version":2,"runs":[{"basename":"zigbrowser-agent-1-0011223344556677","dev":10,"ino":20,"uid":0,"mode":16832,"pid":100,"start_kind":"linux_ticks","start_sec":5,"start_usec":0,"state":"active"}]}
    ;
    try td.dir.writeFile(io, .{ .sub_path = "ok.json", .data = s });
    var l = try ledger.load(io, std.testing.allocator, td.dir, "ok.json");
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 1), l.entries().len);
    try std.testing.expectEqualStrings("zigbrowser-agent-1-0011223344556677", l.entries()[0].basename);
}

test "a small malformed ledger loads to Malformed" {
    const io = std.testing.io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try td.dir.writeFile(io, .{ .sub_path = "bad.json", .data = "{\"schema_version\":9,\"runs\":[]}" });
    try std.testing.expectError(error.Malformed, ledger.load(io, std.testing.allocator, td.dir, "bad.json"));
}

test "a missing ledger file is Malformed (never entries)" {
    const io = std.testing.io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try std.testing.expectError(error.Malformed, ledger.load(io, std.testing.allocator, td.dir, "nope.json"));
}
