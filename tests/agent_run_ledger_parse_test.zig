//! MS6.5.1 red (plan "versioned/strict/bounded ledger schema"). Pure parse — no fs, no signals. UNREGISTERED
//! until green. The parse must reject every malformed shape so a corrupt ledger never yields entries that could
//! authorize a signal.
//!
//! The mutant this catches: a lenient parse (ignore unknown fields; skip the version, cap and duplicate checks)
//! would ACCEPT an unknown version, an extra field, an over-cap array and a duplicate basename.
const std = @import("std");
const ledger = @import("agent_run_ledger");

fn expectErr(expected: ledger.ParseError, s: []const u8) !void {
    const r = ledger.parse(std.testing.allocator, s);
    if (r) |l| {
        var m = l;
        m.deinit();
        return error.TestExpectedError;
    } else |e| {
        try std.testing.expectEqual(expected, e);
    }
}

test "valid versioned ledger parses to its entries" {
    const s =
        \\{"schema_version":1,"runs":[{"basename":"zigbrowser-agent-1-0011223344556677","dev":10,"ino":20,"uid":0,"mode":16832,"pid":100,"start_sec":5,"start_usec":7,"state":"active"}]}
    ;
    var l = try ledger.parse(std.testing.allocator, s);
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 1), l.entries().len);
    const e = l.entries()[0];
    try std.testing.expectEqualStrings("zigbrowser-agent-1-0011223344556677", e.basename);
    try std.testing.expectEqual(@as(u64, 10), e.dev);
    try std.testing.expectEqual(@as(u64, 20), e.ino);
    try std.testing.expectEqual(ledger.State.active, e.state);
}

test "an unknown schema_version is Malformed" {
    try expectErr(error.Malformed,
        \\{"schema_version":2,"runs":[]}
    );
}

test "an extra field is Malformed (strict, no unknown fields)" {
    try expectErr(error.Malformed,
        \\{"schema_version":1,"runs":[{"basename":"zigbrowser-agent-1-0011223344556677","dev":10,"ino":20,"uid":0,"mode":16832,"pid":100,"start_sec":5,"start_usec":7,"state":"active","extra":1}]}
    );
}

test "a missing field is Malformed" {
    try expectErr(error.Malformed,
        \\{"schema_version":1,"runs":[{"basename":"zigbrowser-agent-1-0011223344556677","ino":20,"uid":0,"mode":16832,"pid":100,"start_sec":5,"start_usec":7,"state":"active"}]}
    );
}

test "a mistyped field is Malformed" {
    try expectErr(error.Malformed,
        \\{"schema_version":1,"runs":[{"basename":"zigbrowser-agent-1-0011223344556677","dev":"x","ino":20,"uid":0,"mode":16832,"pid":100,"start_sec":5,"start_usec":7,"state":"active"}]}
    );
}

test "an unknown state is Malformed" {
    try expectErr(error.Malformed,
        \\{"schema_version":1,"runs":[{"basename":"zigbrowser-agent-1-0011223344556677","dev":10,"ino":20,"uid":0,"mode":16832,"pid":100,"start_sec":5,"start_usec":7,"state":"paused"}]}
    );
}

test "a name-only entry (missing the rest) is Malformed" {
    try expectErr(error.Malformed,
        \\{"schema_version":1,"runs":[{"basename":"zigbrowser-agent-1-0011223344556677"}]}
    );
}

test "a truncated/unparseable document is Malformed" {
    try expectErr(error.Malformed,
        \\{"schema_version":1,"runs":[
    );
}

test "a duplicate basename is DuplicateBasename" {
    try expectErr(error.DuplicateBasename,
        \\{"schema_version":1,"runs":[{"basename":"dup","dev":1,"ino":2,"uid":0,"mode":16832,"pid":1,"start_sec":0,"start_usec":0,"state":"active"},{"basename":"dup","dev":3,"ino":4,"uid":0,"mode":16832,"pid":2,"start_sec":0,"start_usec":0,"state":"active"}]}
    );
}

test "an over-cap array is TooManyEntries" {
    var buf: [128 * 1024]u8 = undefined;
    var len: usize = 0;
    const hdr = "{\"schema_version\":1,\"runs\":[";
    @memcpy(buf[0..hdr.len], hdr);
    len = hdr.len;
    var i: usize = 0;
    while (i <= ledger.MAX_ENTRIES) : (i += 1) { // MAX_ENTRIES + 1 distinct entries
        if (i != 0) {
            buf[len] = ',';
            len += 1;
        }
        const s = try std.fmt.bufPrint(buf[len..], "{{\"basename\":\"r{d}\",\"dev\":1,\"ino\":2,\"uid\":0,\"mode\":16832,\"pid\":1,\"start_sec\":0,\"start_usec\":0,\"state\":\"active\"}}", .{i});
        len += s.len;
    }
    const tail = "]}";
    @memcpy(buf[len..][0..tail.len], tail);
    len += tail.len;
    try expectErr(error.TooManyEntries, buf[0..len]);
}
