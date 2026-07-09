const std = @import("std");
const instagram = @import("instagram");

const CommandRecord = struct {
    method: []const u8,
    params_json: []const u8,
};

const MockEngine = struct {
    logged_in: bool = true,
    platform: []const u8 = "instagram",
    cmds: [32]CommandRecord = undefined,
    cmd_count: usize = 0,
    fail_on_method: ?[]const u8 = null,

    pub fn loginCheck(self: *const MockEngine) instagram.LoginState {
        return .{ .logged_in = self.logged_in, .platform = self.platform };
    }

    pub fn dispatch(self: *MockEngine, method: []const u8, params_json: []const u8) !void {
        if (self.fail_on_method) |fail_method| {
            if (std.mem.eql(u8, method, fail_method)) return error.ElementNotFound;
        }
        self.cmds[self.cmd_count] = .{ .method = method, .params_json = params_json };
        self.cmd_count += 1;
    }

    pub fn commandLog(self: *const MockEngine) []const CommandRecord {
        return self.cmds[0..self.cmd_count];
    }

    pub fn lastCommand(self: *const MockEngine) CommandRecord {
        return self.cmds[self.cmd_count - 1];
    }
};

// --- Behavior 3.1: instagram.follow ---

test "follow clicks Follow button on profile" {
    var engine = MockEngine{};
    const result = try instagram.follow(&engine, .{
        .profile_url = "https://www.instagram.com/janedoe/",
    });
    try std.testing.expect(result.ok);
    const cmds = engine.commandLog();
    try std.testing.expectEqualStrings("page.navigate", cmds[0].method);
    try std.testing.expectEqualStrings("dom.click", cmds[1].method);
    try std.testing.expect(std.mem.indexOf(u8, cmds[1].params_json, "Follow") != null);
}

test "follow fails if not logged in" {
    var engine = MockEngine{ .logged_in = false };
    const result = instagram.follow(&engine, .{
        .profile_url = "https://www.instagram.com/janedoe/",
    });
    try std.testing.expectError(error.SessionInvalid, result);
}

test "follow rejects non-instagram URL" {
    var engine = MockEngine{};
    const result = instagram.follow(&engine, .{
        .profile_url = "https://www.linkedin.com/in/jane/",
    });
    try std.testing.expectError(error.InvalidParams, result);
}

// --- Behavior 3.2: instagram.like ---

test "like clicks heart button on post" {
    var engine = MockEngine{};
    const result = try instagram.like(&engine, .{
        .post_url = "https://www.instagram.com/p/ABC123/",
    });
    try std.testing.expect(result.ok);
    const cmds = engine.commandLog();
    try std.testing.expectEqualStrings("page.navigate", cmds[0].method);
    try std.testing.expectEqualStrings("dom.click", cmds[1].method);
    try std.testing.expect(std.mem.indexOf(u8, cmds[1].params_json, "Like") != null);
}

// --- Behavior 3.3: instagram.comment ---

test "comment types and submits comment" {
    var engine = MockEngine{};
    const result = try instagram.comment(&engine, .{
        .post_url = "https://www.instagram.com/p/ABC123/",
        .text = "Nice photo!",
    });
    try std.testing.expect(result.ok);
    const cmds = engine.commandLog();
    try std.testing.expect(cmds.len >= 3);
    try std.testing.expectEqualStrings("dom.fill", cmds[1].method);
    try std.testing.expect(std.mem.indexOf(u8, cmds[1].params_json, "Nice photo!") != null);
}

// --- Behavior 3.4: instagram.dm ---

test "dm navigates to DM thread and sends message" {
    var engine = MockEngine{};
    const result = try instagram.dm(&engine, .{
        .username = "janedoe",
        .text = "Hey!",
    });
    try std.testing.expect(result.ok);
    const cmds = engine.commandLog();
    try std.testing.expectEqualStrings("page.navigate", cmds[0].method);
    try std.testing.expectEqualStrings("dom.fill", cmds[1].method);
    try std.testing.expectEqual(@as(usize, 3), cmds.len);
}

// --- Behavior 3.5: instagram.story_view ---

test "story_view navigates to stories" {
    var engine = MockEngine{};
    const result = try instagram.storyView(&engine, .{
        .username = "janedoe",
    });
    try std.testing.expect(result.ok);
    const cmds = engine.commandLog();
    try std.testing.expectEqualStrings("page.navigate", cmds[0].method);
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
}

// --- Behavior 3.6: instagram verb dispatch ---

test "instagramVerb routes instagram.follow" {
    const verb = instagram.instagramVerb("instagram.follow");
    try std.testing.expect(verb != null);
    try std.testing.expectEqual(instagram.InstagramVerb.follow, verb.?);
}

test "instagramVerb routes instagram.like" {
    const verb = instagram.instagramVerb("instagram.like");
    try std.testing.expect(verb != null);
    try std.testing.expectEqual(instagram.InstagramVerb.like, verb.?);
}

test "instagramVerb rejects unknown method" {
    const verb = instagram.instagramVerb("instagram.unknown");
    try std.testing.expect(verb == null);
}

test "isInstagramMethod identifies instagram namespace" {
    try std.testing.expect(instagram.isInstagramMethod("instagram.follow"));
    try std.testing.expect(instagram.isInstagramMethod("instagram.like"));
    try std.testing.expect(!instagram.isInstagramMethod("linkedin.connect"));
    try std.testing.expect(!instagram.isInstagramMethod("dom.click"));
}
