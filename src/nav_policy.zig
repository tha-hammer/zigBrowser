const std = @import("std");

pub const Decision = enum {
    use,
    ignore,
    open_in_subwindow,
};

pub const DecisionType = enum {
    navigation_action,
    new_window_action,
    response,
};

comptime {
    std.debug.assert(@intFromEnum(Decision.use) == 0);
    std.debug.assert(@intFromEnum(Decision.ignore) == 1);
    std.debug.assert(@intFromEnum(Decision.open_in_subwindow) == 2);
    std.debug.assert(@intFromEnum(DecisionType.navigation_action) == 0);
    std.debug.assert(@intFromEnum(DecisionType.new_window_action) == 1);
    std.debug.assert(@intFromEnum(DecisionType.response) == 2);
}

pub fn decide(app_base: []const u8, candidate: []const u8, dtype: DecisionType) Decision {
    return switch (dtype) {
        .new_window_action => .open_in_subwindow,
        .response => .use,
        .navigation_action => blk: {
            var base_buf: [std.fs.max_path_bytes]u8 = undefined;
            const base_path = canonicalBaseDirPath(app_base, &base_buf) orelse break :blk .use;

            var candidate_buf: [std.fs.max_path_bytes]u8 = undefined;
            const candidate_path = canonicalFilePath(candidate, &candidate_buf) orelse break :blk .ignore;

            break :blk if (containsPath(base_path, candidate_path)) .use else .ignore;
        },
    };
}

pub export fn zb_policy_decide(base: [*:0]const u8, candidate: [*:0]const u8, dtype: c_int) c_int {
    const decision_type = decisionTypeFromInt(dtype) orelse return @intFromEnum(Decision.ignore);
    const decision = decide(std.mem.span(base), std.mem.span(candidate), decision_type);
    return @intFromEnum(decision);
}

fn decisionTypeFromInt(dtype: c_int) ?DecisionType {
    return switch (dtype) {
        @intFromEnum(DecisionType.navigation_action) => .navigation_action,
        @intFromEnum(DecisionType.new_window_action) => .new_window_action,
        @intFromEnum(DecisionType.response) => .response,
        else => null,
    };
}

fn canonicalBaseDirPath(uri_text: []const u8, out_buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var decode_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = fileUriPath(uri_text, decode_buf[0..]) orelse return null;

    var normalized_buf: [std.fs.max_path_bytes]u8 = undefined;
    const normalized = normalizeAbsolutePosix(path, &normalized_buf) orelse return null;

    return ensureTrailingSlash(normalized, out_buf);
}

fn canonicalFilePath(uri_text: []const u8, out_buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var decode_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = fileUriPath(uri_text, decode_buf[0..]) orelse return null;
    return normalizeAbsolutePosix(path, out_buf);
}

fn fileUriPath(uri_text: []const u8, decode_buf: []u8) ?[]const u8 {
    const parsed = std.Uri.parse(uri_text) catch return null;
    if (!std.ascii.eqlIgnoreCase(parsed.scheme, "file")) return null;
    if (parsed.host) |host| {
        var host_buf: [256]u8 = undefined;
        const raw_host = host.toRaw(host_buf[0..]) catch return null;
        if (raw_host.len != 0 and !std.ascii.eqlIgnoreCase(raw_host, "localhost")) return null;
    }

    const path = parsed.path.toRaw(decode_buf) catch return null;
    if (path.len == 0 or path[0] != '/') return null;
    return path;
}

fn containsPath(base_dir_path: []const u8, candidate_path: []const u8) bool {
    if (std.mem.eql(u8, base_dir_path, "/")) return true;
    if (std.mem.eql(u8, candidate_path, base_dir_path[0 .. base_dir_path.len - 1])) return true;
    return std.mem.startsWith(u8, candidate_path, base_dir_path);
}

fn ensureTrailingSlash(path: []const u8, out_buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (std.mem.eql(u8, path, "/")) {
        out_buf[0] = '/';
        return out_buf[0..1];
    }

    if (path[path.len - 1] == '/') {
        if (path.len > out_buf.len) return null;
        @memcpy(out_buf[0..path.len], path);
        return out_buf[0..path.len];
    }

    if (path.len + 1 > out_buf.len) return null;
    @memcpy(out_buf[0..path.len], path);
    out_buf[path.len] = '/';
    return out_buf[0 .. path.len + 1];
}

fn normalizeAbsolutePosix(path: []const u8, out_buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (path.len == 0 or path[0] != '/') return null;

    out_buf[0] = '/';
    var out_len: usize = 1;

    var i: usize = 1;
    while (i <= path.len) {
        const seg_start = i;
        while (i < path.len and path[i] != '/') : (i += 1) {}
        const seg = path[seg_start..i];

        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) {
            // Skip empty and current-directory segments.
        } else if (std.mem.eql(u8, seg, "..")) {
            if (out_len > 1) {
                out_len -= 1;
                while (out_len > 0 and out_buf[out_len - 1] != '/') : (out_len -= 1) {}
            }
        } else {
            if (out_len > 1 and out_buf[out_len - 1] != '/') {
                if (out_len >= out_buf.len) return null;
                out_buf[out_len] = '/';
                out_len += 1;
            }
            if (out_len + seg.len > out_buf.len) return null;
            @memcpy(out_buf[out_len .. out_len + seg.len], seg);
            out_len += seg.len;
        }
        i += 1;
    }

    if (out_len == 0) return null;
    return out_buf[0..out_len];
}
