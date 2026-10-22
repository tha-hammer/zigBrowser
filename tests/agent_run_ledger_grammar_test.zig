//! MS6.5.1 red (RoseCat 0d2e91d #1). The ledger parse must validate each entry's fixed-length, single-component
//! basename grammar `zigbrowser-agent-<decimal pid>-<16 lowercase hex>`, so ONE malformed row makes the whole
//! ledger a malformed read (it never becomes an entry). Pure parse — no fs, no signals. UNREGISTERED until green.
//!
//! The mutant this catches: a parser that does not validate the basename grammar accepts a wrong-prefix/case/
//! length, slash/dot/absolute, or oversized basename and yields entries.
const std = @import("std");
const ledger = @import("agent_run_ledger");

fn one(comptime basename: []const u8) []const u8 {
    return "{\"schema_version\":1,\"runs\":[{\"basename\":\"" ++ basename ++
        "\",\"dev\":1,\"ino\":2,\"uid\":0,\"mode\":16832,\"pid\":1,\"start_sec\":0,\"start_usec\":0,\"state\":\"active\"}]}";
}

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

test "a valid grammar basename parses" {
    var l = try ledger.parse(std.testing.allocator, one("zigbrowser-agent-1-0011223344556677"));
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 1), l.entries().len);
}

test "wrong prefix is Malformed" {
    try expectErr(error.Malformed, one("notzigbrowser-agent-1-0011223344556677"));
}
test "uppercase hex is Malformed" {
    try expectErr(error.Malformed, one("zigbrowser-agent-1-00112233445566AA"));
}
test "wrong hex length (15) is Malformed" {
    try expectErr(error.Malformed, one("zigbrowser-agent-1-001122334455667"));
}
test "non-decimal pid is Malformed" {
    try expectErr(error.Malformed, one("zigbrowser-agent-0x1-0011223344556677"));
}
test "embedded slash is Malformed" {
    try expectErr(error.Malformed, one("zigbrowser-agent-1-0011223344556677/x"));
}
test "a dot basename is Malformed" {
    try expectErr(error.Malformed, one("."));
}
test "an absolute path basename is Malformed" {
    try expectErr(error.Malformed, one("/zigbrowser-agent-1-0011223344556677"));
}
test "an oversized basename is Malformed" {
    try expectErr(error.Malformed, one("zigbrowser-agent-111111111111111111111111111111-0011223344556677"));
}

test "a duplicate of a VALID basename is DuplicateBasename (not masked by grammar)" {
    const s =
        \\{"schema_version":1,"runs":[{"basename":"zigbrowser-agent-1-0011223344556677","dev":1,"ino":2,"uid":0,"mode":16832,"pid":1,"start_sec":0,"start_usec":0,"state":"active"},{"basename":"zigbrowser-agent-1-0011223344556677","dev":3,"ino":4,"uid":0,"mode":16832,"pid":2,"start_sec":0,"start_usec":0,"state":"active"}]}
    ;
    try expectErr(error.DuplicateBasename, s);
}

test "a missing top-level field is Malformed" {
    try expectErr(error.Malformed,
        \\{"schema_version":1}
    );
}
test "an extra top-level field is Malformed" {
    try expectErr(error.Malformed,
        \\{"schema_version":1,"runs":[],"junk":1}
    );
}
test "a duplicate top-level JSON key is Malformed" {
    try expectErr(error.Malformed,
        \\{"schema_version":1,"schema_version":1,"runs":[]}
    );
}
