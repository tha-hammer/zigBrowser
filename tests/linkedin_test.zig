const std = @import("std");
const linkedin = @import("linkedin");

const CommandRecord = struct {
    method: []const u8,
    params_json: []const u8,
};

const MockEngine = struct {
    logged_in: bool = true,
    platform: []const u8 = "linkedin",
    cmds: [32]CommandRecord = undefined,
    cmd_count: usize = 0,
    fail_on_method: ?[]const u8 = null,

    pub fn loginCheck(self: *const MockEngine) linkedin.LoginState {
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

// --- Behavior 2.1: linkedin.visit ---

test "visit navigates to profile URL" {
    var engine = MockEngine{};
    const result = try linkedin.visit(&engine, .{
        .profile_url = "https://www.linkedin.com/in/john-doe/",
    });
    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("page.navigate", engine.lastCommand().method);
    try std.testing.expect(std.mem.indexOf(u8, engine.lastCommand().params_json, "john-doe") != null);
}

test "visit fails if not logged in" {
    var engine = MockEngine{ .logged_in = false };
    const result = linkedin.visit(&engine, .{
        .profile_url = "https://www.linkedin.com/in/john-doe/",
    });
    try std.testing.expectError(error.SessionInvalid, result);
}

test "visit rejects non-linkedin URL" {
    var engine = MockEngine{};
    const result = linkedin.visit(&engine, .{
        .profile_url = "https://www.instagram.com/john/",
    });
    try std.testing.expectError(error.InvalidParams, result);
}

// --- Behavior 2.2: linkedin.connect ---

test "connect without note sends connection request" {
    var engine = MockEngine{};
    const result = try linkedin.connect(&engine, .{
        .profile_url = "https://www.linkedin.com/in/jane/",
        .note = null,
    });
    try std.testing.expect(result.ok);
    const cmds = engine.commandLog();
    try std.testing.expectEqualStrings("page.navigate", cmds[0].method);
    try std.testing.expectEqualStrings("dom.click", cmds[1].method);
    try std.testing.expect(std.mem.indexOf(u8, cmds[1].params_json, "Connect") != null);
}

test "connect with note fills note field" {
    var engine = MockEngine{};
    const result = try linkedin.connect(&engine, .{
        .profile_url = "https://www.linkedin.com/in/jane/",
        .note = "Hi Jane!",
    });
    try std.testing.expect(result.ok);
    const cmds = engine.commandLog();
    try std.testing.expect(cmds.len >= 5);
    try std.testing.expectEqualStrings("dom.fill", cmds[3].method);
    try std.testing.expect(std.mem.indexOf(u8, cmds[3].params_json, "Hi Jane!") != null);
}

test "connect fails if not logged in" {
    var engine = MockEngine{ .logged_in = false };
    const result = linkedin.connect(&engine, .{
        .profile_url = "https://www.linkedin.com/in/jane/",
        .note = null,
    });
    try std.testing.expectError(error.SessionInvalid, result);
}

// --- Behavior 2.3: linkedin.message ---

test "message sends text to conversation" {
    var engine = MockEngine{};
    const result = try linkedin.message(&engine, .{
        .conversation_url = "https://www.linkedin.com/messaging/thread/123/",
        .text = "Hello!",
    });
    try std.testing.expect(result.ok);
    const cmds = engine.commandLog();
    try std.testing.expectEqualStrings("page.navigate", cmds[0].method);
    try std.testing.expectEqualStrings("dom.fill", cmds[1].method);
    try std.testing.expect(std.mem.indexOf(u8, cmds[1].params_json, "Hello!") != null);
    try std.testing.expectEqualStrings("dom.click", cmds[2].method);
}

// --- Behavior 2.4: linkedin.like ---

test "like clicks like button on post" {
    var engine = MockEngine{};
    const result = try linkedin.like(&engine, .{
        .post_url = "https://www.linkedin.com/feed/update/urn:li:activity:123/",
    });
    try std.testing.expect(result.ok);
    const cmds = engine.commandLog();
    try std.testing.expectEqualStrings("page.navigate", cmds[0].method);
    try std.testing.expectEqualStrings("dom.click", cmds[1].method);
    try std.testing.expect(std.mem.indexOf(u8, cmds[1].params_json, "Like") != null);
}

// --- Behavior 2.5: linkedin.comment ---

test "comment posts text on linkedin post" {
    var engine = MockEngine{};
    const result = try linkedin.comment(&engine, .{
        .post_url = "https://www.linkedin.com/feed/update/urn:li:activity:456/",
        .text = "Great post!",
    });
    try std.testing.expect(result.ok);
    const cmds = engine.commandLog();
    try std.testing.expect(cmds.len >= 3);
}

// --- Behavior 2.6: linkedin.follow ---

test "follow clicks follow button on profile" {
    var engine = MockEngine{};
    const result = try linkedin.follow(&engine, .{
        .profile_url = "https://www.linkedin.com/in/leader/",
    });
    try std.testing.expect(result.ok);
    const cmds = engine.commandLog();
    try std.testing.expectEqualStrings("page.navigate", cmds[0].method);
    try std.testing.expectEqualStrings("dom.click", cmds[1].method);
    try std.testing.expect(std.mem.indexOf(u8, cmds[1].params_json, "Follow") != null);
}

// --- Behavior 2.7: linkedin.search ---

test "search executes linkedin search" {
    var engine = MockEngine{};
    const result = try linkedin.search(&engine, .{
        .query = "software engineer",
        .search_type = "people",
    });
    try std.testing.expect(result.ok);
    const cmds = engine.commandLog();
    try std.testing.expectEqualStrings("page.navigate", cmds[0].method);
    try std.testing.expect(std.mem.indexOf(u8, cmds[0].params_json, "linkedin.com/search") != null);
}

// --- Behavior 2.8: linkedin.visit rejects non-linkedin URL ---
// (covered in 2.1 test above)

// --- Behavior 2.9: linkedin verb dispatch ---

test "linkedinVerb routes linkedin.visit" {
    const verb = linkedin.linkedinVerb("linkedin.visit");
    try std.testing.expect(verb != null);
    try std.testing.expectEqual(linkedin.LinkedInVerb.visit, verb.?);
}

test "linkedinVerb routes linkedin.connect" {
    const verb = linkedin.linkedinVerb("linkedin.connect");
    try std.testing.expect(verb != null);
    try std.testing.expectEqual(linkedin.LinkedInVerb.connect, verb.?);
}

test "linkedinVerb rejects unknown method" {
    const verb = linkedin.linkedinVerb("linkedin.unknown");
    try std.testing.expect(verb == null);
}

test "isLinkedInMethod identifies linkedin namespace" {
    try std.testing.expect(linkedin.isLinkedInMethod("linkedin.visit"));
    try std.testing.expect(linkedin.isLinkedInMethod("linkedin.connect"));
    try std.testing.expect(!linkedin.isLinkedInMethod("social.login_check"));
    try std.testing.expect(!linkedin.isLinkedInMethod("dom.click"));
}
