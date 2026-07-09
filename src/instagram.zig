const std = @import("std");

pub const LoginState = struct {
    logged_in: bool,
    platform: []const u8,
};

pub const SocialResult = struct {
    ok: bool,
};

pub const FollowParams = struct {
    profile_url: []const u8,
};

pub const LikeParams = struct {
    post_url: []const u8,
};

pub const CommentParams = struct {
    post_url: []const u8,
    text: []const u8,
};

pub const DmParams = struct {
    username: []const u8,
    text: []const u8,
};

pub const StoryViewParams = struct {
    username: []const u8,
};

fn requireInstagramLogin(engine: anytype) !void {
    const state = engine.loginCheck();
    if (!state.logged_in) return error.SessionInvalid;
}

fn validateInstagramUrl(url: []const u8) !void {
    if (!std.mem.startsWith(u8, url, "https://www.instagram.com/")) return error.InvalidParams;
}

pub fn follow(engine: anytype, params: FollowParams) !SocialResult {
    try validateInstagramUrl(params.profile_url);
    try requireInstagramLogin(engine);
    try engine.dispatch("page.navigate", params.profile_url);
    try engine.dispatch("dom.click", "role=button[name=\"Follow\"]");
    return .{ .ok = true };
}

pub fn like(engine: anytype, params: LikeParams) !SocialResult {
    try requireInstagramLogin(engine);
    try engine.dispatch("page.navigate", params.post_url);
    try engine.dispatch("dom.click", "css=[aria-label=\"Like\"]");
    return .{ .ok = true };
}

pub fn comment(engine: anytype, params: CommentParams) !SocialResult {
    try requireInstagramLogin(engine);
    try engine.dispatch("page.navigate", params.post_url);
    try engine.dispatch("dom.fill", params.text);
    try engine.dispatch("dom.click", "role=button[name=\"Post\"]");
    return .{ .ok = true };
}

pub fn dm(engine: anytype, params: DmParams) !SocialResult {
    try requireInstagramLogin(engine);
    var buf: [256]u8 = undefined;
    const dm_url = std.fmt.bufPrint(&buf, "https://www.instagram.com/direct/t/{s}/", .{params.username}) catch return error.InvalidParams;
    try engine.dispatch("page.navigate", dm_url);
    try engine.dispatch("dom.fill", params.text);
    try engine.dispatch("dom.click", "role=button[name=\"Send\"]");
    return .{ .ok = true };
}

pub fn storyView(engine: anytype, params: StoryViewParams) !SocialResult {
    try requireInstagramLogin(engine);
    var buf: [256]u8 = undefined;
    const story_url = std.fmt.bufPrint(&buf, "https://www.instagram.com/stories/{s}/", .{params.username}) catch return error.InvalidParams;
    try engine.dispatch("page.navigate", story_url);
    return .{ .ok = true };
}

pub const InstagramVerb = enum {
    follow,
    like,
    comment,
    dm,
    story_view,
};

pub fn instagramVerb(method: []const u8) ?InstagramVerb {
    const table = [_]struct { method: []const u8, verb: InstagramVerb }{
        .{ .method = "instagram.follow", .verb = .follow },
        .{ .method = "instagram.like", .verb = .like },
        .{ .method = "instagram.comment", .verb = .comment },
        .{ .method = "instagram.dm", .verb = .dm },
        .{ .method = "instagram.story_view", .verb = .story_view },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry.method, method)) return entry.verb;
    }
    return null;
}

pub fn isInstagramMethod(method: []const u8) bool {
    return std.mem.startsWith(u8, method, "instagram.");
}
