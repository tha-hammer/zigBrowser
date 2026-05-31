const std = @import("std");

const decision_doc_path = "Plans/JS_ENGINE_STRATEGY.md";

test "engine decision record cites all five §C2.9 metrics per spike" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        decision_doc_path,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(bytes);

    try assertMetricsForSection(bytes, "### v2a Spike Metrics - QuickJS-ng", "### v2a Spike Metrics - XS");
    try assertMetricsForSection(bytes, "### v2a Spike Metrics - XS", "### v2a Spike Metrics - WASM");
    try assertMetricsForSection(bytes, "### v2a Spike Metrics - WASM", null);
}

fn assertMetricsForSection(doc: []const u8, section_heading: []const u8, next_heading: ?[]const u8) !void {
    const section_start = std.mem.indexOf(u8, doc, section_heading) orelse return error.TestUnexpectedResult;
    const section_end = if (next_heading) |next| blk: {
        break :blk std.mem.indexOfPos(u8, doc, section_start + section_heading.len, next) orelse doc.len;
    } else doc.len;
    const section = doc[section_start..section_end];

    const required_metrics = [_][]const u8{
        "ergonomics_locs",
        "teardown_complexity",
        "throughput_ops_per_sec",
        "license_spdx",
        "wasm_footprint_bytes",
    };

    for (required_metrics) |metric| {
        try std.testing.expect(std.mem.indexOf(u8, section, metric) != null);
    }
}
