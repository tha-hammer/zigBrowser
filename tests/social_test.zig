const std = @import("std");
const social = @import("social");

const MockPagePort = struct {
    url: []const u8 = "https://example.com/page",
    eval_logged_in: bool = false,
    eval_username: ?[]const u8 = null,

    pub fn getPageUrl(self: *const MockPagePort) []const u8 {
        return self.url;
    }

    pub fn evalLoginCheck(self: *const MockPagePort) social.LoginCheckScriptResult {
        return .{
            .logged_in = self.eval_logged_in,
            .username = self.eval_username,
        };
    }
};

test "login_check returns unknown platform for unrecognized host" {
    const mock = MockPagePort{};
    const result = social.loginCheck(&mock);
    try std.testing.expectEqualStrings("unknown", result.platform);
    try std.testing.expect(!result.logged_in);
    try std.testing.expect(result.username == null);
}

test "login_check detects linkedin from host" {
    const mock = MockPagePort{
        .url = "https://www.linkedin.com/feed/",
        .eval_logged_in = true,
        .eval_username = "john-doe",
    };
    const result = social.loginCheck(&mock);
    try std.testing.expectEqualStrings("linkedin", result.platform);
    try std.testing.expect(result.logged_in);
    try std.testing.expectEqualStrings("john-doe", result.username.?);
}

test "login_check detects instagram from host" {
    const mock = MockPagePort{
        .url = "https://www.instagram.com/explore/",
        .eval_logged_in = true,
        .eval_username = "user123",
    };
    const result = social.loginCheck(&mock);
    try std.testing.expectEqualStrings("instagram", result.platform);
    try std.testing.expect(result.logged_in);
}

test "login_check returns not logged in for login page" {
    const mock = MockPagePort{
        .url = "https://www.linkedin.com/login",
        .eval_logged_in = false,
    };
    const result = social.loginCheck(&mock);
    try std.testing.expectEqualStrings("linkedin", result.platform);
    try std.testing.expect(!result.logged_in);
    try std.testing.expect(result.username == null);
}

const MockPacingLayer = struct {
    daily_cap: u32 = 100,
    remaining: u32 = 100,
    reset_at: []const u8 = "2026-07-10T00:00:00",

    pub fn getState(self: *const MockPacingLayer) social.PacingState {
        return .{
            .remaining_actions = self.remaining,
            .reset_at = self.reset_at,
            .daily_cap = self.daily_cap,
        };
    }
};

test "rate_status returns pacing state from pacing layer" {
    const mock = MockPacingLayer{ .daily_cap = 100, .remaining = 73 };
    const result = social.rateStatus(&mock);
    try std.testing.expectEqual(@as(u32, 73), result.remaining_actions);
    try std.testing.expectEqual(@as(u32, 100), result.daily_cap);
    try std.testing.expectEqualStrings("2026-07-10T00:00:00", result.reset_at);
}

test "rate_status returns defaults when cap not reached" {
    const mock = MockPacingLayer{};
    const result = social.rateStatus(&mock);
    try std.testing.expectEqual(@as(u32, 100), result.remaining_actions);
    try std.testing.expectEqual(@as(u32, 100), result.daily_cap);
}

test "rate_status returns zero when cap reached" {
    const mock = MockPacingLayer{ .daily_cap = 100, .remaining = 0 };
    const result = social.rateStatus(&mock);
    try std.testing.expectEqual(@as(u32, 0), result.remaining_actions);
}

const MockCommandQueue = struct {
    last_pause_ms: u32 = 0,

    pub fn pauseFor(self: *MockCommandQueue, duration_ms: u32) void {
        self.last_pause_ms = duration_ms;
    }
};

test "pause blocks queue for specified duration" {
    var mock_queue = MockCommandQueue{};
    const result = social.pause(&mock_queue, .{ .duration_ms = 5000 });
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(u32, 5000), mock_queue.last_pause_ms);
}

test "pause with zero duration returns immediately" {
    var mock_queue = MockCommandQueue{};
    const result = social.pause(&mock_queue, .{ .duration_ms = 0 });
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(u32, 0), mock_queue.last_pause_ms);
}

const MockConfigurablePacing = struct {
    config: social.SetPacingParams = .{},

    pub fn configure(self: *MockConfigurablePacing, params: social.SetPacingParams) void {
        self.config = params;
    }
};

test "set_pacing updates pacing configuration" {
    var mock = MockConfigurablePacing{};
    const result = try social.setPacing(&mock, .{
        .min_delay_ms = 2000,
        .max_delay_ms = 6000,
        .daily_cap = 50,
    });
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(u32, 2000), mock.config.min_delay_ms);
    try std.testing.expectEqual(@as(u32, 6000), mock.config.max_delay_ms);
    try std.testing.expectEqual(@as(u32, 50), mock.config.daily_cap);
}

test "set_pacing rejects min greater than max" {
    var mock = MockConfigurablePacing{};
    const result = social.setPacing(&mock, .{
        .min_delay_ms = 9000,
        .max_delay_ms = 3000,
        .daily_cap = 100,
    });
    try std.testing.expectError(error.InvalidParams, result);
}

test "dispatch routes social.login_check" {
    const verb = social.socialVerb("social.login_check");
    try std.testing.expect(verb != null);
    try std.testing.expectEqual(social.SocialVerb.login_check, verb.?);
}

test "dispatch routes social.rate_status" {
    const verb = social.socialVerb("social.rate_status");
    try std.testing.expect(verb != null);
    try std.testing.expectEqual(social.SocialVerb.rate_status, verb.?);
}

test "dispatch routes social.pause" {
    const verb = social.socialVerb("social.pause");
    try std.testing.expect(verb != null);
    try std.testing.expectEqual(social.SocialVerb.pause, verb.?);
}

test "dispatch routes social.set_pacing" {
    const verb = social.socialVerb("social.set_pacing");
    try std.testing.expect(verb != null);
    try std.testing.expectEqual(social.SocialVerb.set_pacing, verb.?);
}

test "dispatch rejects unknown social method" {
    const verb = social.socialVerb("social.unknown_method");
    try std.testing.expect(verb == null);
}

test "isSocialMethod returns true for social namespace" {
    try std.testing.expect(social.isSocialMethod("social.login_check"));
    try std.testing.expect(social.isSocialMethod("social.rate_status"));
    try std.testing.expect(social.isSocialMethod("social.pause"));
    try std.testing.expect(social.isSocialMethod("social.set_pacing"));
}

test "isSocialMethod returns false for other namespaces" {
    try std.testing.expect(!social.isSocialMethod("dom.click"));
    try std.testing.expect(!social.isSocialMethod("page.navigate"));
    try std.testing.expect(!social.isSocialMethod("linkedin.connect"));
}
