//! The one-shot login helper's frames (chat-drawer plan D7b, rev 16.18; S6a).
//! login → app on stdout, each line validated natively before anything acts
//! on it:
//! - `auth_url` {url}: https, at most 4 KiB, once, and first;
//! - `need_code` {}: after `auth_url`, any number of times (once per prompt);
//! - `done` {}: after `auth_url`; the token is already on fd 4;
//! - `error` {code, message}: code one of cli, timeout, cancelled, shape,
//!   protocol, exchange (rev 16.18.9); message at most 1 KiB.
//! The envelope is {"v":1,"seq":n,"type":...} with `seq` strictly increasing;
//! unknown fields reject; a frame is at most 8 KiB; after `done` or `error`
//! every frame is out of order.
//! app → login on stdin: `start` {}, `code` {code}, `cancel` {}. A code is
//! `<code>#<state>`: 3 to 512 characters of visible ASCII (0x21-0x7e) with
//! exactly one '#', both parts non-empty; the encoder refuses anything else.
const std = @import("std");
const proto = @import("agent_protocol");

const has = @hasDecl(proto, "LoginValidator");

const url = "https://claude.com/cai/oauth/authorize?code=true&state=s";

/// Feeds `lines` to one validator; the outcome of the last one.
fn last(arena: std.mem.Allocator, lines: []const []const u8) !proto.LoginOutcome {
    var v: proto.LoginValidator = .{};
    var out: proto.LoginOutcome = undefined;
    for (lines) |l| out = v.validate(arena, l);
    return out;
}

fn expectOk(lines: []const []const u8, tag: std.meta.Tag(proto.LoginFrame)) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try last(arena.allocator(), lines);
    if (out != .ok) {
        std.debug.print("rejected ({s}): {s}\n", .{ @tagName(out.rejected), lines[lines.len - 1] });
        return error.TestRejected;
    }
    try std.testing.expectEqual(tag, std.meta.activeTag(out.ok));
}

fn expectRejected(lines: []const []const u8, reason: proto.LoginReason) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try last(arena.allocator(), lines);
    if (out != .rejected) {
        std.debug.print("accepted: {s}\n", .{lines[lines.len - 1]});
        return error.TestAccepted;
    }
    try std.testing.expectEqual(reason, out.rejected);
}

const auth = "{\"v\":1,\"seq\":1,\"type\":\"auth_url\",\"url\":\"" ++ url ++ "\"}";

test "a whole sign-in: auth_url, need_code (twice), done" {
    if (!has) return error.TestNoLoginValidator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var v: proto.LoginValidator = .{};
    const a = v.validate(arena.allocator(), auth);
    try std.testing.expect(a == .ok and a.ok == .auth_url);
    try std.testing.expectEqualStrings(url, a.ok.auth_url.url);
    try std.testing.expect(v.validate(arena.allocator(), "{\"v\":1,\"seq\":2,\"type\":\"need_code\"}").ok == .need_code);
    try std.testing.expect(v.validate(arena.allocator(), "{\"v\":1,\"seq\":3,\"type\":\"need_code\"}").ok == .need_code);
    try std.testing.expect(v.validate(arena.allocator(), "{\"v\":1,\"seq\":7,\"type\":\"done\"}").ok == .done);
}

test "error frames: each code, at any point" {
    if (!has) return error.TestNoLoginValidator;
    for ([_][]const u8{ "cli", "timeout", "cancelled", "shape", "protocol", "exchange" }) |code| {
        var buf: [128]u8 = undefined;
        const e = try std.fmt.bufPrint(&buf, "{{\"v\":1,\"seq\":2,\"type\":\"error\",\"code\":\"{s}\",\"message\":\"m\"}}", .{code});
        try expectOk(&.{e}, .@"error");
        try expectOk(&.{ auth, e }, .@"error");
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var v: proto.LoginValidator = .{};
    const out = v.validate(arena.allocator(), "{\"v\":1,\"seq\":1,\"type\":\"error\",\"code\":\"timeout\",\"message\":\"sign-in timed out\"}");
    try std.testing.expectEqualStrings("timeout", out.ok.@"error".code);
    try std.testing.expectEqualStrings("sign-in timed out", out.ok.@"error".message);
}

test "the envelope and the schema are exact" {
    if (!has) return error.TestNoLoginValidator;
    try expectRejected(&.{"not json"}, .json);
    try expectRejected(&.{"[1]"}, .envelope);
    try expectRejected(&.{"{\"v\":2,\"seq\":1,\"type\":\"auth_url\",\"url\":\"" ++ url ++ "\"}"}, .envelope);
    try expectRejected(&.{"{\"v\":1,\"seq\":0,\"type\":\"auth_url\",\"url\":\"" ++ url ++ "\"}"}, .envelope);
    try expectRejected(&.{"{\"v\":1,\"type\":\"auth_url\",\"url\":\"" ++ url ++ "\"}"}, .envelope);
    try expectRejected(&.{"{\"v\":1,\"seq\":1,\"type\":\"ready\"}"}, .type);
    try expectRejected(&.{"{\"v\":1,\"seq\":1,\"type\":\"token\",\"token\":\"x\"}"}, .type);
    try expectRejected(&.{"{\"v\":1,\"seq\":1,\"type\":\"auth_url\",\"url\":\"" ++ url ++ "\",\"x\":1}"}, .schema);
    try expectRejected(&.{"{\"v\":1,\"seq\":1,\"type\":\"auth_url\"}"}, .schema);
    try expectRejected(&.{"{\"v\":1,\"seq\":1,\"type\":\"auth_url\",\"url\":7}"}, .schema);
    try expectRejected(&.{"{\"v\":1,\"seq\":1,\"type\":\"auth_url\",\"url\":\"http://claude.com/cai/oauth/authorize\"}"}, .schema);
    try expectRejected(&.{"{\"v\":1,\"seq\":1,\"type\":\"auth_url\",\"url\":\"javascript:alert(1)\"}"}, .schema);
    try expectRejected(&.{ auth, "{\"v\":1,\"seq\":2,\"type\":\"need_code\",\"x\":1}" }, .schema);
    try expectRejected(&.{ auth, "{\"v\":1,\"seq\":2,\"type\":\"done\",\"token\":\"sk-ant-oat01-x\"}" }, .schema);
    try expectRejected(&.{"{\"v\":1,\"seq\":1,\"type\":\"error\",\"code\":\"auth\",\"message\":\"m\"}"}, .schema);
    try expectRejected(&.{"{\"v\":1,\"seq\":1,\"type\":\"error\",\"code\":\"cli\"}"}, .schema);
    try expectRejected(&.{"{\"v\":1,\"seq\":1,\"type\":\"error\",\"code\":\"cli\",\"message\":\"m\",\"session\":null}"}, .schema);
}

test "sizes: url at most 4 KiB, message at most 1 KiB, a frame at most 8 KiB" {
    if (!has) return error.TestNoLoginValidator;
    const head = "{\"v\":1,\"seq\":1,\"type\":\"auth_url\",\"url\":\"https://claude.com/";
    var buf: [9000]u8 = undefined;
    const fits = try std.fmt.bufPrint(&buf, "{s}{s}\"}}", .{ head, "a" ** (4096 - "https://claude.com/".len) });
    try expectOk(&.{fits}, .auth_url);
    const long = try std.fmt.bufPrint(&buf, "{s}{s}\"}}", .{ head, "a" ** (4097 - "https://claude.com/".len) });
    try expectRejected(&.{long}, .schema);
    const msg = try std.fmt.bufPrint(&buf, "{{\"v\":1,\"seq\":1,\"type\":\"error\",\"code\":\"cli\",\"message\":\"{s}\"}}", .{"m" ** 1024});
    try expectOk(&.{msg}, .@"error");
    const msg2 = try std.fmt.bufPrint(&buf, "{{\"v\":1,\"seq\":1,\"type\":\"error\",\"code\":\"cli\",\"message\":\"{s}\"}}", .{"m" ** 1025});
    try expectRejected(&.{msg2}, .schema);
    const big = try std.fmt.bufPrint(&buf, "{{\"v\":1,\"seq\":1,\"type\":\"need_code\"}}{s}", .{" " ** 8192});
    try expectRejected(&.{big}, .oversize);
}

test "order: auth_url once and first; nothing after done or error; seq increases" {
    if (!has) return error.TestNoLoginValidator;
    const need = "{\"v\":1,\"seq\":2,\"type\":\"need_code\"}";
    const done = "{\"v\":1,\"seq\":3,\"type\":\"done\"}";
    try expectRejected(&.{"{\"v\":1,\"seq\":1,\"type\":\"need_code\"}"}, .order);
    try expectRejected(&.{"{\"v\":1,\"seq\":1,\"type\":\"done\"}"}, .order);
    try expectRejected(&.{ auth, "{\"v\":1,\"seq\":2,\"type\":\"auth_url\",\"url\":\"" ++ url ++ "\"}" }, .order);
    try expectRejected(&.{ auth, need, done, "{\"v\":1,\"seq\":4,\"type\":\"need_code\"}" }, .order);
    try expectRejected(&.{ auth, done, "{\"v\":1,\"seq\":4,\"type\":\"error\",\"code\":\"cli\",\"message\":\"m\"}" }, .order);
    try expectRejected(&.{ "{\"v\":1,\"seq\":1,\"type\":\"error\",\"code\":\"cli\",\"message\":\"m\"}", "{\"v\":1,\"seq\":2,\"type\":\"auth_url\",\"url\":\"" ++ url ++ "\"}" }, .order);
    try expectRejected(&.{ auth, "{\"v\":1,\"seq\":1,\"type\":\"need_code\"}" }, .seq);
    // A rejected frame commits nothing: the same seq is still free afterwards.
    try expectOk(&.{ auth, "{\"v\":1,\"seq\":2,\"type\":\"need_code\",\"x\":1}", need }, .need_code);
    try expectOk(&.{ auth, "{\"v\":1,\"seq\":2,\"type\":\"auth_url\",\"url\":\"" ++ url ++ "\"}", need }, .need_code);
}

/// The grammar, written out: 3 to 512 of 0x21-0x7e, exactly one '#', both
/// parts non-empty.
fn referenceCode(code: []const u8) bool {
    if (code.len < 3 or code.len > 512) return false;
    var hashes: usize = 0;
    var at: usize = 0;
    for (code, 0..) |c, i| {
        if (c < 0x21 or c > 0x7e) return false;
        if (c == '#') {
            hashes += 1;
            at = i;
        }
    }
    return hashes == 1 and at > 0 and at < code.len - 1;
}

test "validLoginCode: <code>#<state>, visible ASCII, one '#' (table)" {
    if (!has) return error.TestNoLoginValidator;
    for ([_][]const u8{ "a#b", "fakecode-0123#Zb3_state", "a+b#s", "!$'()*,;:@[]{}|\\^`\"<>?#s", "c" ** 510 ++ "#s" }) |good|
        try std.testing.expect(proto.validLoginCode(good));
    for ([_][]const u8{ "", "ab", "#ab", "ab#", "a#b#c", "a b#s", "a#s\n", "a\r#s", "a\x03#s", "a\x1b#s", "a\x7f#s", "a\x00#s", "\xc3\xa9#s", "c" ** 511 ++ "#s" }) |bad| {
        if (proto.validLoginCode(bad)) {
            std.debug.print("accepted: {any}\n", .{bad});
            return error.TestAccepted;
        }
    }
}

test "property (oracle): validLoginCode matches the grammar over 10k strings" {
    if (!has) return error.TestNoLoginValidator;
    var prng = std.Random.DefaultPrng.init(0x10_9C0DE);
    const random = prng.random();
    const odd = [_]u8{ ' ', '\t', '\n', '\r', 0x03, 0x1b, 0x7f, 0x00, 0x80, 0xff, '#' };
    var buf: [600]u8 = undefined;
    var accepted: usize = 0;
    for (0..10_000) |_| {
        const len: usize = switch (random.uintLessThan(u8, 3)) {
            0 => random.uintAtMost(usize, 6),
            1 => random.intRangeAtMost(usize, 509, 515),
            else => random.uintAtMost(usize, 80),
        };
        const s = buf[0..len];
        for (s) |*c| c.* = random.intRangeAtMost(u8, 0x21, 0x7e);
        // Mostly no '#' from the range; place one in most strings.
        for (s) |*c| if (c.* == '#') {
            c.* = 'h';
        };
        if (len > 0 and random.uintLessThan(u8, 5) != 0) s[random.uintLessThan(usize, len)] = '#';
        if (len > 0 and random.uintLessThan(u8, 4) == 0) s[random.uintLessThan(usize, len)] = odd[random.uintLessThan(usize, odd.len)];
        try std.testing.expectEqual(referenceCode(s), proto.validLoginCode(s));
        if (referenceCode(s)) accepted += 1;
    }
    try std.testing.expect(accepted > 1000 and accepted < 9000);
}

test "encodeLogin: start, code and cancel frames; a code outside the grammar is refused" {
    if (!has) return error.TestNoLoginValidator;
    const gpa = std.testing.allocator;
    const start = try proto.encodeLogin(gpa, 1, .start);
    defer gpa.free(start);
    try std.testing.expectEqualStrings("{\"v\":1,\"seq\":1,\"type\":\"start\"}", start);
    const cancel = try proto.encodeLogin(gpa, 3, .cancel);
    defer gpa.free(cancel);
    try std.testing.expectEqualStrings("{\"v\":1,\"seq\":3,\"type\":\"cancel\"}", cancel);
    // A code with JSON's own specials survives the round trip.
    const raw = "a\"b\\c/d#Zb3_state";
    const code = try proto.encodeLogin(gpa, 2, .{ .code = raw });
    defer gpa.free(code);
    const parsed = try std.json.parseFromSlice(struct { v: i64, seq: i64, type: []const u8, code: []const u8 }, gpa, code, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("code", parsed.value.type);
    try std.testing.expectEqualStrings(raw, parsed.value.code);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.seq);
    try std.testing.expect(code.len <= 4096);
    try std.testing.expectError(error.BadCode, proto.encodeLogin(gpa, 2, .{ .code = "a b#s" }));
    try std.testing.expectError(error.BadCode, proto.encodeLogin(gpa, 2, .{ .code = "a#s\n" }));
    try std.testing.expectError(error.BadCode, proto.encodeLogin(gpa, 2, .{ .code = "nohash" }));
}
