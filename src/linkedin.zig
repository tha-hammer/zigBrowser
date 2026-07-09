const std = @import("std");

pub const LoginState = struct {
    logged_in: bool,
    platform: []const u8,
};

pub const SocialResult = struct {
    ok: bool,
};

pub const VisitParams = struct {
    profile_url: []const u8,
};

pub const ConnectParams = struct {
    profile_url: []const u8,
    note: ?[]const u8,
};

pub const MessageParams = struct {
    conversation_url: []const u8,
    text: []const u8,
};

pub const LikeParams = struct {
    post_url: []const u8,
};

pub const CommentParams = struct {
    post_url: []const u8,
    text: []const u8,
};

pub const FollowParams = struct {
    profile_url: []const u8,
};

pub const SearchParams = struct {
    query: []const u8,
    search_type: []const u8,
};

fn requireLinkedInLogin(engine: anytype) !void {
    const state = engine.loginCheck();
    if (!state.logged_in) return error.SessionInvalid;
}

fn validateLinkedInUrl(url: []const u8) !void {
    if (!std.mem.startsWith(u8, url, "https://www.linkedin.com/")) return error.InvalidParams;
}

pub fn visit(engine: anytype, params: VisitParams) !SocialResult {
    try validateLinkedInUrl(params.profile_url);
    try requireLinkedInLogin(engine);
    try engine.dispatch("page.navigate", params.profile_url);
    return .{ .ok = true };
}

pub fn connect(engine: anytype, params: ConnectParams) !SocialResult {
    try validateLinkedInUrl(params.profile_url);
    try requireLinkedInLogin(engine);
    try engine.dispatch("page.navigate", params.profile_url);
    try engine.dispatch("dom.click", "role=button[name=\"Connect\"]");

    if (params.note) |note| {
        try engine.dispatch("dom.click", "role=button[name=\"Add a note\"]");
        const truncated = if (note.len > 300) note[0..300] else note;
        try engine.dispatch("dom.fill", truncated);
        try engine.dispatch("dom.click", "role=button[name=\"Send\"]");
    } else {
        try engine.dispatch("dom.click", "role=button[name=\"Send without a note\"]");
    }

    return .{ .ok = true };
}

pub fn message(engine: anytype, params: MessageParams) !SocialResult {
    try requireLinkedInLogin(engine);
    try engine.dispatch("page.navigate", params.conversation_url);
    try engine.dispatch("dom.fill", params.text);
    try engine.dispatch("dom.click", "role=button[name=\"Send\"]");
    return .{ .ok = true };
}

pub fn like(engine: anytype, params: LikeParams) !SocialResult {
    try requireLinkedInLogin(engine);
    try engine.dispatch("page.navigate", params.post_url);
    try engine.dispatch("dom.click", "role=button[name=\"Like\"]");
    return .{ .ok = true };
}

pub fn comment(engine: anytype, params: CommentParams) !SocialResult {
    try requireLinkedInLogin(engine);
    try engine.dispatch("page.navigate", params.post_url);
    try engine.dispatch("dom.click", "role=button[name=\"Comment\"]");
    try engine.dispatch("dom.fill", params.text);
    try engine.dispatch("dom.click", "role=button[name=\"Post\"]");
    return .{ .ok = true };
}

pub fn follow(engine: anytype, params: FollowParams) !SocialResult {
    try validateLinkedInUrl(params.profile_url);
    try requireLinkedInLogin(engine);
    try engine.dispatch("page.navigate", params.profile_url);
    try engine.dispatch("dom.click", "role=button[name=\"Follow\"]");
    return .{ .ok = true };
}

pub fn search(engine: anytype, params: SearchParams) !SocialResult {
    try requireLinkedInLogin(engine);
    const search_url = "https://www.linkedin.com/search/results/" ++ "";
    _ = params.query;
    _ = params.search_type;
    try engine.dispatch("page.navigate", search_url);
    return .{ .ok = true };
}

pub const LinkedInVerb = enum {
    visit,
    connect,
    message,
    like,
    comment,
    follow,
    search,
};

pub fn linkedinVerb(method: []const u8) ?LinkedInVerb {
    const table = [_]struct { method: []const u8, verb: LinkedInVerb }{
        .{ .method = "linkedin.visit", .verb = .visit },
        .{ .method = "linkedin.connect", .verb = .connect },
        .{ .method = "linkedin.message", .verb = .message },
        .{ .method = "linkedin.like", .verb = .like },
        .{ .method = "linkedin.comment", .verb = .comment },
        .{ .method = "linkedin.follow", .verb = .follow },
        .{ .method = "linkedin.search", .verb = .search },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry.method, method)) return entry.verb;
    }
    return null;
}

pub fn isLinkedInMethod(method: []const u8) bool {
    return std.mem.startsWith(u8, method, "linkedin.");
}
