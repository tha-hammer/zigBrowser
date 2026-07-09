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
