const std = @import("std");
const nav_policy = @import("nav_policy");

test "decide routes by decision type" {
    const base = "file:///app/";
    const inside = "file:///app/index.html";
    const outside = "file:///elsewhere/page.html";

    try std.testing.expectEqual(
        nav_policy.Decision.use,
        nav_policy.decide(base, inside, .navigation_action),
    );
    try std.testing.expectEqual(
        nav_policy.Decision.ignore,
        nav_policy.decide(base, outside, .navigation_action),
    );
    try std.testing.expectEqual(
        nav_policy.Decision.open_in_subwindow,
        nav_policy.decide(base, outside, .new_window_action),
    );
    try std.testing.expectEqual(
        nav_policy.Decision.use,
        nav_policy.decide(base, outside, .response),
    );
}

test "decide rejects traversal outside app base" {
    const base = "file:///app/";
    const traversal = "file:///app/../outside.html";
    const nested = "file:///app/docs/../page-b.html";

    try std.testing.expectEqual(
        nav_policy.Decision.ignore,
        nav_policy.decide(base, traversal, .navigation_action),
    );
    try std.testing.expectEqual(
        nav_policy.Decision.use,
        nav_policy.decide(base, nested, .navigation_action),
    );
}

test "decide blocks passwd traversal and handles file host containment edges" {
    try std.testing.expectEqual(
        nav_policy.Decision.ignore,
        nav_policy.decide("file:///app/", "file:///app/../etc/passwd", .navigation_action),
    );
    try std.testing.expectEqual(
        nav_policy.Decision.use,
        nav_policy.decide("file://localhost/app/", "file://localhost/app/page-b.html", .navigation_action),
    );
    try std.testing.expectEqual(
        nav_policy.Decision.use,
        nav_policy.decide("file:///app/", "file:///app", .navigation_action),
    );
}

test "decide rejects non-file candidates for navigation action" {
    const base = "file:///app/";
    try std.testing.expectEqual(
        nav_policy.Decision.ignore,
        nav_policy.decide(base, "https://example.com", .navigation_action),
    );
    try std.testing.expectEqual(
        nav_policy.Decision.ignore,
        nav_policy.decide(base, "javascript:alert(1)", .navigation_action),
    );
}

test "zb_policy_decide ABI mapping stays pinned" {
    const base = "file:///app/";
    const inside = "file:///app/page-b.html";
    const outside = "file:///outside/page.html";

    const nav_type = @intFromEnum(nav_policy.DecisionType.navigation_action);
    const new_window_type = @intFromEnum(nav_policy.DecisionType.new_window_action);
    const response_type = @intFromEnum(nav_policy.DecisionType.response);

    try std.testing.expectEqual(
        @intFromEnum(nav_policy.Decision.use),
        nav_policy.zb_policy_decide(base, inside, nav_type),
    );
    try std.testing.expectEqual(
        @intFromEnum(nav_policy.Decision.ignore),
        nav_policy.zb_policy_decide(base, outside, nav_type),
    );
    try std.testing.expectEqual(
        @intFromEnum(nav_policy.Decision.open_in_subwindow),
        nav_policy.zb_policy_decide(base, outside, new_window_type),
    );
    try std.testing.expectEqual(
        @intFromEnum(nav_policy.Decision.use),
        nav_policy.zb_policy_decide(base, outside, response_type),
    );

    // Invalid DecisionType must fail closed to ignore.
    try std.testing.expectEqual(
        @intFromEnum(nav_policy.Decision.ignore),
        nav_policy.zb_policy_decide(base, inside, 99),
    );
}
