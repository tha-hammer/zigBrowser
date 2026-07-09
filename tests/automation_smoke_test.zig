const std = @import("std");
const automation = @import("automation");

const expected_phase1_command_verbs = [_][]const u8{
    "dom.query",
    "dom.click",
    "dom.fill",
    "dom.type",
    "dom.getText",
    "dom.getAttribute",
    "dom.waitFor",
    "page.navigate",
    "page.reload",
    "page.url",
    "page.title",
    "page.evaluate",
    "page.screenshot",
};

test "automation facade exposes the Phase 1 command verb list" {
    try std.testing.expectEqual(
        expected_phase1_command_verbs.len,
        automation.phase1_command_verbs.len,
    );

    for (expected_phase1_command_verbs, automation.phase1_command_verbs) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}
