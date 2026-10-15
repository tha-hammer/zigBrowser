//! The helper → app NDJSON frames (chat-drawer plan D7, D7b; S3.3): every
//! line is validated natively before anything acts on it. Exact schema per
//! type (unknown fields reject), a session the app opened, `seq` strictly
//! increasing, a tool-call id that is a UUID used once, and the size caps.
//! A rejected frame is never shown and never acted on; its content is never
//! logged, only the reason.

const std = @import("std");

pub const max_frame: usize = 256 * 1024;
pub const tool_deadline_s: i64 = 120;

pub const Reason = enum { oversize, json, envelope, seq, type, schema, session, tool_id };

pub const SelfCheck = struct { ok: bool, failures: []const []const u8 };
pub const Ready = struct { version: []const u8, route: []const u8, selfcheck: SelfCheck, tool_deadline_s: i64 };
/// No SDK session id exists yet when a session opens (RoseCat 5632): the
/// CLI's own id comes with each `result`.
pub const SessionOpened = struct { session: []const u8 };
pub const Text = struct { session: []const u8, text: []const u8 };
pub const ToolCall = struct { session: []const u8, id: []const u8, tool: []const u8, args_json: []const u8 };
pub const Result = struct { session: []const u8, sdk_session_id: []const u8, subtype: []const u8, is_error: bool, num_turns: i64, cost_usd: ?f64 };
pub const Failure = struct { session: ?[]const u8, code: []const u8, message: []const u8 };
pub const SessionEnded = struct { session: []const u8, reason: []const u8 };

pub const Frame = union(enum) {
    ready: Ready,
    session_opened: SessionOpened,
    assistant_delta: Text,
    assistant_message: Text,
    tool_call: ToolCall,
    result: Result,
    @"error": Failure,
    session_ended: SessionEnded,
};

pub const Outcome = union(enum) { ok: Frame, rejected: Reason };

const Value = std.json.Value;
const Object = std.json.ObjectMap;
const Bad = error{ Schema, Session };

const tool_prefix = "mcp__zigbrowser__";
const error_codes = [_][]const u8{ "auth", "busy", "protocol", "overflow", "sdk", "sandbox" };
const end_reasons = [_][]const u8{ "end", "interrupt", "crash", "token_removed" };
/// R3 was removed (plan rev 16 §3c.1): the token reaches the CLI only on fd 3.
const routes = [_][]const u8{"R1"};

pub const Validator = struct {
    gpa: std.mem.Allocator,
    last_seq: i64 = 0,
    /// session id -> the window it was opened for.
    sessions: std.StringHashMapUnmanaged(u32) = .empty,
    /// Every tool-call id accepted so far.
    tool_ids: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(gpa: std.mem.Allocator) Validator {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Validator) void {
        freeKeys(self.gpa, &self.sessions);
        freeKeys(self.gpa, &self.tool_ids);
    }

    /// The app opened `session` for `window` (open_session). An id is opened
    /// once: a second open of a live id is error.DuplicateSession.
    pub fn openSession(self: *Validator, session: []const u8, window: u32) !void {
        if (self.sessions.contains(session)) return error.DuplicateSession;
        const key = try self.gpa.dupe(u8, session);
        errdefer self.gpa.free(key);
        try self.sessions.put(self.gpa, key, window);
    }

    /// The session is gone (its session_ended was accepted, or the app closed
    /// it): every later frame naming it is rejected (RoseCat 5628).
    pub fn closeSession(self: *Validator, session: []const u8) void {
        if (self.sessions.fetchRemove(session)) |entry| self.gpa.free(entry.key);
    }

    /// One line from the helper's stdout. `arena` owns the frame's strings.
    /// Checks run in order (envelope, type, schema, session, seq, tool id);
    /// nothing is committed unless every check passes.
    pub fn validate(self: *Validator, arena: std.mem.Allocator, line: []const u8) Outcome {
        if (line.len > max_frame) return .{ .rejected = .oversize };
        const root = std.json.parseFromSliceLeaky(Value, arena, line, .{}) catch return .{ .rejected = .json };
        if (root != .object) return .{ .rejected = .envelope };
        const obj = root.object;
        const v = obj.get("v") orelse return .{ .rejected = .envelope };
        const seq = obj.get("seq") orelse return .{ .rejected = .envelope };
        const type_name = obj.get("type") orelse return .{ .rejected = .envelope };
        if (v != .integer or v.integer != 1 or seq != .integer or seq.integer < 1 or type_name != .string)
            return .{ .rejected = .envelope };
        const tag = std.meta.stringToEnum(std.meta.Tag(Frame), type_name.string) orelse return .{ .rejected = .type };
        const frame = parse(arena, tag, obj) catch return .{ .rejected = .schema };
        if (!self.knownSessions(frame)) return .{ .rejected = .session };
        if (seq.integer <= self.last_seq) return .{ .rejected = .seq };
        if (frame == .tool_call and self.tool_ids.contains(frame.tool_call.id)) return .{ .rejected = .tool_id };
        if (frame == .tool_call) {
            const key = self.gpa.dupe(u8, frame.tool_call.id) catch return .{ .rejected = .tool_id };
            self.tool_ids.put(self.gpa, key, {}) catch {
                self.gpa.free(key);
                return .{ .rejected = .tool_id };
            };
        }
        self.last_seq = seq.integer;
        if (frame == .session_ended) self.closeSession(frame.session_ended.session);
        return .{ .ok = frame };
    }

    fn knownSessions(self: *Validator, frame: Frame) bool {
        const session: ?[]const u8 = switch (frame) {
            .ready => null,
            .@"error" => |f| f.session,
            inline else => |f| f.session,
        };
        return if (session) |id| self.sessions.contains(id) else true;
    }
};

fn freeKeys(gpa: std.mem.Allocator, map: anytype) void {
    var it = map.keyIterator();
    while (it.next()) |key| gpa.free(key.*);
    map.deinit(gpa);
}

fn parse(arena: std.mem.Allocator, tag: std.meta.Tag(Frame), obj: Object) (Bad || error{OutOfMemory})!Frame {
    return switch (tag) {
        .ready => blk: {
            try exact(obj, &.{ "version", "route", "selfcheck", "tool_deadline_s" });
            const check = obj.get("selfcheck").?;
            if (check != .object) return error.Schema;
            try exact(check.object, &.{ "ok", "failures" });
            const ok = try boolean(check.object, "ok");
            const list = check.object.get("failures").?;
            if (list != .array) return error.Schema;
            const failures = try arena.alloc([]const u8, list.array.items.len);
            for (list.array.items, failures) |item, *out| {
                if (item != .string or item.string.len > 1024) return error.Schema;
                out.* = item.string;
            }
            const deadline = try integer(obj, "tool_deadline_s");
            if (deadline != tool_deadline_s) return error.Schema;
            break :blk .{ .ready = .{ .version = try string(obj, "version", 64), .route = try oneOf(obj, "route", &routes), .selfcheck = .{ .ok = ok, .failures = failures }, .tool_deadline_s = deadline } };
        },
        .session_opened => blk: {
            try exact(obj, &.{"session"});
            break :blk .{ .session_opened = .{ .session = try string(obj, "session", 64) } };
        },
        .assistant_delta => .{ .assistant_delta = try text(obj, 16 * 1024) },
        .assistant_message => .{ .assistant_message = try text(obj, 256 * 1024) },
        .tool_call => blk: {
            try exact(obj, &.{ "session", "id", "tool", "args" });
            const id = try string(obj, "id", 36);
            if (!isUuid(id)) return error.Schema;
            const tool = try string(obj, "tool", 128);
            if (!isToolName(tool)) return error.Schema;
            const args = obj.get("args").?;
            if (args != .object) return error.Schema;
            const args_json = try std.json.Stringify.valueAlloc(arena, args, .{});
            if (args_json.len > 64 * 1024) return error.Schema;
            break :blk .{ .tool_call = .{ .session = try string(obj, "session", 64), .id = id, .tool = tool, .args_json = args_json } };
        },
        .result => blk: {
            try exact(obj, &.{ "session", "sdk_session_id", "subtype", "is_error", "num_turns", "cost_usd" });
            const turns = try integer(obj, "num_turns");
            if (turns < 0) return error.Schema;
            const cost: ?f64 = switch (obj.get("cost_usd").?) {
                .null => null,
                .float => |f| f,
                .integer => |n| @floatFromInt(n),
                else => return error.Schema,
            };
            break :blk .{ .result = .{ .session = try string(obj, "session", 64), .sdk_session_id = try string(obj, "sdk_session_id", 64), .subtype = try string(obj, "subtype", 64), .is_error = try boolean(obj, "is_error"), .num_turns = turns, .cost_usd = cost } };
        },
        .@"error" => blk: {
            try exact(obj, &.{ "session", "code", "message" });
            const session: ?[]const u8 = switch (obj.get("session").?) {
                .null => null,
                .string => |id| if (id.len <= 64) id else return error.Schema,
                else => return error.Schema,
            };
            break :blk .{ .@"error" = .{ .session = session, .code = try oneOf(obj, "code", &error_codes), .message = try string(obj, "message", 1024) } };
        },
        .session_ended => blk: {
            try exact(obj, &.{ "session", "reason" });
            break :blk .{ .session_ended = .{ .session = try string(obj, "session", 64), .reason = try oneOf(obj, "reason", &end_reasons) } };
        },
    };
}

/// The object has exactly the envelope keys plus `names`.
fn exact(obj: Object, names: []const []const u8) Bad!void {
    const envelope = obj.contains("v") and obj.contains("seq") and obj.contains("type");
    const want = names.len + @as(usize, if (envelope) 3 else 0);
    if (obj.count() != want) return error.Schema;
    for (names) |name| if (!obj.contains(name)) return error.Schema;
}

fn string(obj: Object, name: []const u8, max: usize) Bad![]const u8 {
    const value = obj.get(name) orelse return error.Schema;
    if (value != .string or value.string.len > max) return error.Schema;
    return value.string;
}

fn boolean(obj: Object, name: []const u8) Bad!bool {
    const value = obj.get(name) orelse return error.Schema;
    return if (value == .bool) value.bool else error.Schema;
}

fn integer(obj: Object, name: []const u8) Bad!i64 {
    const value = obj.get(name) orelse return error.Schema;
    return if (value == .integer) value.integer else error.Schema;
}

fn oneOf(obj: Object, name: []const u8, allowed: []const []const u8) Bad![]const u8 {
    const value = try string(obj, name, 64);
    for (allowed) |a| if (std.mem.eql(u8, a, value)) return value;
    return error.Schema;
}

fn text(obj: Object, max: usize) Bad!Text {
    try exact(obj, &.{ "session", "text" });
    return .{ .session = try string(obj, "session", 64), .text = try string(obj, "text", max) };
}

fn isUuid(id: []const u8) bool {
    if (id.len != 36) return false;
    for (id, 0..) |ch, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash != (ch == '-')) return false;
        if (!dash and !std.ascii.isHex(ch)) return false;
    }
    return true;
}

fn isToolName(tool: []const u8) bool {
    if (!std.mem.startsWith(u8, tool, tool_prefix) or tool.len == tool_prefix.len) return false;
    for (tool[tool_prefix.len..]) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    return true;
}

/// `{"v":1,"seq":<seq>,"type":<tag>,...fields}` for a helper frame (tests,
/// and the fake helper's reference).
pub fn encode(gpa: std.mem.Allocator, seq: i64, frame: Frame) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var w: std.json.Stringify = .{ .writer = &out.writer };
    try w.beginObject();
    try w.objectField("v");
    try w.write(1);
    try w.objectField("seq");
    try w.write(seq);
    try w.objectField("type");
    try w.write(@tagName(frame));
    switch (frame) {
        .tool_call => |f| {
            try field(&w, "session", f.session);
            try field(&w, "id", f.id);
            try field(&w, "tool", f.tool);
            try w.objectField("args");
            try w.beginWriteRaw();
            try out.writer.writeAll(f.args_json);
            w.endWriteRaw();
        },
        .ready => |f| {
            try field(&w, "version", f.version);
            try field(&w, "route", f.route);
            try field(&w, "selfcheck", f.selfcheck);
            try field(&w, "tool_deadline_s", f.tool_deadline_s);
        },
        inline else => |f| inline for (std.meta.fields(@TypeOf(f))) |fd| try field(&w, fd.name, @field(f, fd.name)),
    }
    try w.endObject();
    return out.toOwnedSlice();
}

fn field(w: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try w.objectField(name);
    try w.write(value);
}
