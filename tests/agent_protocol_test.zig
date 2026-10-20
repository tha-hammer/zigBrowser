//! S3.3 (chat-drawer plan; T2 frame part): the native validator of helper
//! frames, src/agent_protocol.zig.
const std = @import("std");
const p = @import("agent_protocol");

const uuid = "123e4567-e89b-42d3-a456-426614174000";

fn expectRejected(v: *p.Validator, line: []const u8, want: p.Reason) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = v.validate(arena.allocator(), line);
    if (out != .rejected) {
        std.debug.print("accepted: {s}\n", .{line});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(want, out.rejected);
}

fn expectOk(v: *p.Validator, line: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = v.validate(arena.allocator(), line);
    if (out != .ok) {
        std.debug.print("rejected ({s}): {s}\n", .{ @tagName(out.rejected), line });
        return error.TestUnexpectedResult;
    }
}

fn fresh() !p.Validator {
    var v = p.Validator.init(std.testing.allocator);
    try v.openSession("s-1-1", 1);
    try v.promptSent("s-1-1", 1); // S5d: prompt-scoped frames name the active prompt
    return v;
}

test "every valid helper frame type is accepted" {
    var v = try fresh();
    defer v.deinit();
    try expectOk(&v, "{\"v\":1,\"seq\":1,\"type\":\"ready\",\"version\":\"0.1.0\",\"route\":\"R1\",\"selfcheck\":{\"ok\":true,\"failures\":[]},\"tool_deadline_s\":120}");
    try expectOk(&v, "{\"v\":1,\"seq\":2,\"type\":\"session_opened\",\"session\":\"s-1-1\"}");
    try expectOk(&v, "{\"v\":1,\"seq\":3,\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"Hel\"}");
    try expectOk(&v, "{\"v\":1,\"seq\":4,\"type\":\"assistant_message\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"Hello\"}");
    try expectOk(&v, "{\"v\":1,\"seq\":5,\"type\":\"tool_call\",\"session\":\"s-1-1\",\"prompt_id\":1,\"id\":\"" ++ uuid ++ "\",\"tool\":\"mcp__zigbrowser__get_text\",\"args\":{\"selector\":\"h1\"}}");
    try expectOk(&v, "{\"v\":1,\"seq\":6,\"type\":\"result\",\"session\":\"s-1-1\",\"prompt_id\":1,\"sdk_session_id\":\"" ++ uuid ++ "\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"cost_usd\":null}");
    try expectOk(&v, "{\"v\":1,\"seq\":7,\"type\":\"error\",\"session\":null,\"code\":\"sdk\",\"message\":\"x\"}");
    try expectOk(&v, "{\"v\":1,\"seq\":8,\"type\":\"session_ended\",\"session\":\"s-1-1\",\"reason\":\"end\"}");
}

test "every error code of the frame table is accepted (rev 16.14 adds overloaded)" {
    var v = try fresh();
    defer v.deinit();
    const codes = [_][]const u8{ "auth", "busy", "overloaded", "protocol", "overflow", "sdk", "sandbox" };
    var buf: [160]u8 = undefined;
    for (codes, 1..) |code, seq| {
        const line = try std.fmt.bufPrint(&buf, "{{\"v\":1,\"seq\":{d},\"type\":\"error\",\"session\":null,\"code\":\"{s}\",\"message\":\"x\"}}", .{ seq, code });
        try expectOk(&v, line);
    }
}

test "each kind of bad frame is rejected with its reason" {
    var v = try fresh();
    defer v.deinit();
    try expectRejected(&v, "not json", .json);
    try expectRejected(&v, "[1,2]", .envelope);
    try expectRejected(&v, "{\"v\":2,\"seq\":1,\"type\":\"ready\"}", .envelope);
    try expectRejected(&v, "{\"seq\":1,\"type\":\"ready\"}", .envelope);
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"frobnicate\"}", .type);
    // RoseCat 5632: no SDK session id exists when a session opens; the result carries the real one.
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"session_opened\",\"session\":\"s-1-1\",\"prompt_id\":1,\"sdk_session_id\":\"a\"}", .schema);
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"session_opened\",\"session\":\"s-1-1\",\"extra\":1}", .schema);
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"result\",\"session\":\"s-1-1\",\"subtype\":\"success\",\"is_error\":false,\"num_turns\":1,\"cost_usd\":null}", .schema);
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"result\",\"session\":\"s-1-1\",\"prompt_id\":1,\"sdk_session_id\":\"" ++ uuid ++ "\",\"subtype\":\"x\",\"is_error\":\"no\",\"num_turns\":1,\"cost_usd\":null}", .schema);
    // R3 was removed (plan rev 16 §3c.1): a helper reporting it is rejected.
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"ready\",\"version\":\"0\",\"route\":\"R3\",\"selfcheck\":{\"ok\":true,\"failures\":[]},\"tool_deadline_s\":120}", .schema);
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"ready\",\"version\":\"0\",\"route\":\"R2\",\"selfcheck\":{\"ok\":true,\"failures\":[]},\"tool_deadline_s\":120}", .schema);
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"ready\",\"version\":\"0\",\"route\":\"R1\",\"selfcheck\":{\"ok\":true,\"failures\":[]},\"tool_deadline_s\":119}", .schema);
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"error\",\"session\":null,\"code\":\"teapot\",\"message\":\"x\"}", .schema);
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"session_ended\",\"session\":\"s-1-1\",\"reason\":\"why\"}", .schema);
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"tool_call\",\"session\":\"s-1-1\",\"prompt_id\":1,\"id\":\"" ++ uuid ++ "\",\"tool\":\"Bash\",\"args\":{}}", .schema);
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"tool_call\",\"session\":\"s-1-1\",\"prompt_id\":1,\"id\":\"not-a-uuid\",\"tool\":\"mcp__zigbrowser__x\",\"args\":{}}", .schema);
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"tool_call\",\"session\":\"s-1-1\",\"prompt_id\":1,\"id\":\"" ++ uuid ++ "\",\"tool\":\"mcp__zigbrowser__x\",\"args\":[]}", .schema);
    // Unknown session, and a session of another (unopened) window.
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"assistant_delta\",\"session\":\"s-2-1\",\"prompt_id\":1,\"text\":\"x\"}", .session);
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"error\",\"session\":\"s-9-9\",\"prompt_id\":null,\"code\":\"sdk\",\"message\":\"x\"}", .session);
    // Size caps.
    const big = "x" ** (16 * 1024 + 1);
    try expectRejected(&v, "{\"v\":1,\"seq\":1,\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"" ++ big ++ "\"}", .schema);
    const huge = try std.testing.allocator.alloc(u8, p.max_frame + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, ' ');
    try expectRejected(&v, huge, .oversize);
}

test "seq must strictly increase, and a tool-call id is never accepted twice" {
    var v = try fresh();
    defer v.deinit();
    try expectOk(&v, "{\"v\":1,\"seq\":5,\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"a\"}");
    try expectRejected(&v, "{\"v\":1,\"seq\":5,\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"b\"}", .seq);
    try expectRejected(&v, "{\"v\":1,\"seq\":4,\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"b\"}", .seq);
    try expectOk(&v, "{\"v\":1,\"seq\":9,\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"c\"}");
    const call = "\"type\":\"tool_call\",\"session\":\"s-1-1\",\"prompt_id\":1,\"id\":\"" ++ uuid ++ "\",\"tool\":\"mcp__zigbrowser__x\",\"args\":{}}";
    try expectOk(&v, "{\"v\":1,\"seq\":10," ++ call);
    try expectRejected(&v, "{\"v\":1,\"seq\":11," ++ call, .tool_id);
}

fn validFrame(random: std.Random, buf: []u8, session: []const u8, prompt_id: i64) p.Frame {
    const words = [_][]const u8{ "hello", "x", "", "Ünïcødé", "line\nbreak", "quote\"q" };
    const text = words[random.uintLessThan(usize, words.len)];
    return switch (random.uintLessThan(u8, 5)) {
        0 => .{ .assistant_delta = .{ .session = session, .prompt_id = prompt_id, .text = text } },
        1 => .{ .assistant_message = .{ .session = session, .prompt_id = prompt_id, .text = text } },
        2 => .{ .result = .{ .session = session, .prompt_id = prompt_id, .sdk_session_id = uuid, .subtype = "success", .is_error = random.boolean(), .num_turns = random.intRangeAtMost(i64, 0, 50), .cost_usd = if (random.boolean()) null else 0.5 } },
        3 => .{ .session_ended = .{ .session = session, .reason = "end" } },
        else => blk: {
            const hex = "0123456789abcdef";
            for (buf[0..36], 0..) |*ch, i| ch.* = if (i == 8 or i == 13 or i == 18 or i == 23) '-' else hex[random.uintLessThan(usize, 16)];
            break :blk .{ .tool_call = .{ .session = session, .prompt_id = prompt_id, .id = buf[0..36], .tool = "mcp__zigbrowser__get_text", .args_json = "{\"a\":1}" } };
        },
    };
}

test "a session id is opened once, and nothing of a session is accepted after its session_ended (RoseCat 5628)" {
    var v = try fresh();
    defer v.deinit();
    try std.testing.expectError(error.DuplicateSession, v.openSession("s-1-1", 2));
    try expectOk(&v, "{\"v\":1,\"seq\":1,\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"a\"}");
    try expectOk(&v, "{\"v\":1,\"seq\":2,\"type\":\"session_ended\",\"session\":\"s-1-1\",\"reason\":\"end\"}");
    try expectRejected(&v, "{\"v\":1,\"seq\":3,\"type\":\"assistant_delta\",\"session\":\"s-1-1\",\"prompt_id\":1,\"text\":\"late\"}", .session);
    try expectRejected(&v, "{\"v\":1,\"seq\":3,\"type\":\"session_ended\",\"session\":\"s-1-1\",\"reason\":\"end\"}", .session);
    try expectRejected(&v, "{\"v\":1,\"seq\":3,\"type\":\"error\",\"session\":\"s-1-1\",\"prompt_id\":null,\"code\":\"sdk\",\"message\":\"x\"}", .session);
    // A rejected frame commits nothing: seq 3 is still free for a session-less frame.
    try expectOk(&v, "{\"v\":1,\"seq\":3,\"type\":\"error\",\"session\":null,\"code\":\"sdk\",\"message\":\"x\"}");
    // The app may close a session itself (its window went away), and may then open a new one.
    try v.openSession("s-1-2", 1);
    v.closeSession("s-1-2");
    try expectRejected(&v, "{\"v\":1,\"seq\":4,\"type\":\"assistant_delta\",\"session\":\"s-1-2\",\"prompt_id\":1,\"text\":\"a\"}", .session);
    try v.openSession("s-1-3", 1);
    try v.promptSent("s-1-3", 1);
    try expectOk(&v, "{\"v\":1,\"seq\":4,\"type\":\"assistant_delta\",\"session\":\"s-1-3\",\"prompt_id\":1,\"text\":\"a\"}");
}

/// After an accepted frame, what the app does next: a result ends the prompt, so the app
/// writes the next one (S5d); session_ended closes the session, so the app opens the next
/// one and writes its first prompt.
fn next(v: *p.Validator, frame: p.Frame, prompt: *i64) !void {
    switch (frame) {
        .result => prompt.* += 1,
        .session_ended => {
            try v.openSession("s-1-1", 1);
            prompt.* = 1;
        },
        else => return,
    }
    try v.promptSent("s-1-1", prompt.*);
}

test "property (roundtrip): validate(encode(f)) gives back f for generated valid frames" {
    var prng = std.Random.DefaultPrng.init(0xA6E7_0001);
    const random = prng.random();
    var v = try fresh();
    defer v.deinit();
    var id_buf: [36]u8 = undefined;
    var prompt: i64 = 1;
    var seq: i64 = 0;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const frame = validFrame(random, &id_buf, "s-1-1", prompt);
        seq += random.intRangeAtMost(i64, 1, 3);
        const line = try p.encode(arena.allocator(), seq, frame);
        const out = v.validate(arena.allocator(), line);
        if (out != .ok) {
            std.debug.print("rejected ({s}): {s}\n", .{ @tagName(out.rejected), line });
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqualDeep(frame, out.ok);
        try next(&v, frame, &prompt);
    }
}

test "property (invariant): random bytes and mutated valid frames are never accepted" {
    var prng = std.Random.DefaultPrng.init(0xA6E7_0002);
    const random = prng.random();
    var v = try fresh();
    defer v.deinit();
    var id_buf: [36]u8 = undefined;
    var prompt: i64 = 1;
    var seq: i64 = 1000;
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        if (random.boolean()) {
            const bytes = try a.alloc(u8, random.uintAtMost(usize, 300));
            random.bytes(bytes);
            try std.testing.expect(v.validate(a, bytes) == .rejected);
            continue;
        }
        seq += 1;
        const frame = validFrame(random, &id_buf, "s-1-1", prompt);
        const line = try p.encode(a, seq, frame);
        // The original is accepted first, so a mutation that replays its seq
        // or its tool-call id is a real replay.
        try std.testing.expect(v.validate(a, line) == .ok);
        try next(&v, frame, &prompt);
        const mutated = switch (random.uintLessThan(u8, 5)) {
            // drop a field: cut the last ",\"name\":value" before the closing brace
            0 => try std.mem.concat(a, u8, &.{ line[0..std.mem.lastIndexOfScalar(u8, line, ',').?], "}" }),
            // add a field
            1 => try std.mem.concat(a, u8, &.{ line[0 .. line.len - 1], ",\"zz\":1}" }),
            // retype the session to a number
            2 => try std.mem.replaceOwned(u8, a, line, "\"session\":\"s-1-1\"", "\"session\":7"),
            // replay an old seq
            3 => try std.fmt.allocPrint(a, "{{\"v\":1,\"seq\":{d},{s}", .{ seq - random.intRangeAtMost(i64, 0, 900), line[std.mem.indexOf(u8, line, "\"type\"").?..] }),
            // oversize: padded past the frame cap
            else => blk: {
                const padded = try a.alloc(u8, p.max_frame + 1);
                @memset(padded, ' ');
                @memcpy(padded[0..line.len], line);
                break :blk padded;
            },
        };
        if (std.mem.eql(u8, mutated, line)) continue;
        const out = v.validate(a, mutated);
        if (out == .ok) {
            std.debug.print("accepted mutated: {s}\n", .{mutated});
            return error.TestUnexpectedResult;
        }
    }
}
