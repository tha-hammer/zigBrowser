//! The auth window's callback check (chat-drawer plan S6.2, A2; rev 16.17 as
//! proposed in mail 5858). The real `claude setup-token` (2.1.301, captured
//! in tests/fixtures/agent/setup_token_transcript.json) redirects to the manual
//! code page https://platform.claude.com/oauth/code/callback and reads the
//! code at its prompt as `<code>#<state>`. The auth window catches that
//! navigation, never loads the page, and hands `<code>#<state>` to the login
//! helper, but only when:
//! - the scheme equals the redirect_uri's (ASCII case aside);
//! - there is no user info, the host equals the redirect_uri's (ASCII case
//!   aside) and so does the port (an absent port is the scheme's default);
//! - the path equals the redirect_uri's byte for byte (no decoding);
//! - exactly one `state` parameter, decoded, equals the authorize URL's one
//!   `state` (also decoded).
//! A value is decoded as the code page's URLSearchParams decodes it ('+' is a
//! space, %XX a byte), except that a malformed escape refuses it.
//! That much is `checkCallback`, the plan's invariant. `callbackCode` also
//! needs exactly one non-empty `code`. The code is opaque (the capture masks
//! it), so code and state may hold any visible ASCII but '#' (D7b's `code`
//! frame, RoseCat 5865): nothing the page sends reaches the CLI's terminal as a
//! space, a newline, a second '#', a control byte, DEL or a non-ASCII byte. The
//! result is at most 512 bytes. A refusal is a reason (D7b's
//! `AUTH blocked <reason>` word).
//! The oracle below is a separate reference parse with std.Uri.
const std = @import("std");
const auth = @import("agent_auth");

const redirect = "https://platform.claude.com/oauth/code/callback";
const state = "Zb3_state-0123456789abcdefghijklmnopqrstuvw";
const authorize = "https://claude.com/cai/oauth/authorize?code=true&client_id=00000000-0000-4000-8000-00000000fa6e" ++
    "&response_type=code&redirect_uri=" ++ redirect ++ "&scope=user:inference&code_challenge=" ++
    "chal_0123456789abcdefghijklmnopqrstuvwxyzABC&code_challenge_method=S256&state=" ++ state;

/// `checkCallback`, or error.TestNoCheckCallback before it exists (so this file
/// compiles, and fails by behavior, before src/agent_auth.zig has it).
fn check(a: []const u8, n: []const u8) !bool {
    if (!@hasDecl(auth, "checkCallback")) return error.TestNoCheckCallback;
    return auth.checkCallback(a, n);
}

fn code(a: []const u8, n: []const u8, buf: []u8) ![]const u8 {
    if (!@hasDecl(auth, "callbackCode")) return error.TestNoCallbackCode;
    return auth.callbackCode(a, n, buf);
}

fn word(err: anyerror) ![]const u8 {
    if (!@hasDecl(auth, "rejectWord")) return error.TestNoRejectWord;
    return auth.rejectWord(@errorCast(err));
}

fn expectCode(n: []const u8, want: []const u8) !void {
    var buf: [512]u8 = undefined;
    try std.testing.expect(try check(authorize, n));
    try std.testing.expectEqualStrings(want, try code(authorize, n, &buf));
}

/// The reason, through both entry points: checkCallback is false for every
/// reason but `code`.
fn expectReject(n: []const u8, want: anyerror) !void {
    var buf: [512]u8 = undefined;
    const got = code(authorize, n, &buf);
    std.testing.expectError(want, got) catch |e| {
        std.debug.print("nav: {s}\n", .{n});
        return e;
    };
    try std.testing.expectEqual(want == error.Code, try check(authorize, n));
}

test "a callback to the redirect_uri with the state and a code gives code#state" {
    try expectCode(redirect ++ "?code=fakecode-0123&state=" ++ state, "fakecode-0123#" ++ state);
    // The order of parameters, other parameters and a fragment do not matter.
    try expectCode(redirect ++ "?state=" ++ state ++ "&code=c0de", "c0de#" ++ state);
    try expectCode(redirect ++ "?code=c0de&x=1&state=" ++ state ++ "#frag", "c0de#" ++ state);
    // The default port written out, and case in the scheme and host.
    try expectCode("https://platform.claude.com:443/oauth/code/callback?code=c&state=" ++ state, "c#" ++ state);
    try expectCode("HTTPS://Platform.Claude.COM/oauth/code/callback?code=c&state=" ++ state, "c#" ++ state);
    // Visible punctuation in an opaque code (RoseCat 5865).
    try expectCode(redirect ++ "?code=a%2Bb&state=" ++ state, "a+b#" ++ state);
    try expectCode(redirect ++ "?code=x%2Fy%3D%3D&state=" ++ state, "x/y==#" ++ state);
    try expectCode(redirect ++ "?code=!$%27()*,;:@%5B%5D%7B%7D%7C%5C%5E%60%22%3C%3E%3F&state=" ++ state, "!$'()*,;:@[]{}|\\^`\"<>?#" ++ state);
    // A percent-encoded state that decodes to the same bytes.
    try expectCode(redirect ++ "?code=c&state=%5Ab3_state-0123456789abcdefghijklmnopqrstuvw", "c#" ++ state);
}

test "A2: wrong or missing state is refused (state)" {
    try expectReject(redirect ++ "?code=c&state=" ++ "A" ** 43, error.State);
    try expectReject(redirect ++ "?code=c", error.State);
    try expectReject(redirect ++ "?code=c&state=", error.State);
    try expectReject(redirect ++ "?code=c&state=" ++ state ++ "&state=" ++ state, error.State);
    try expectReject(redirect ++ "?code=c&state=" ++ state ++ "x", error.State);
    try expectReject(redirect ++ "?code=c&state=" ++ state[0 .. state.len - 1], error.State);
    try expectReject(redirect ++ "?code=c&STATE=" ++ state, error.State);
    try expectReject(redirect ++ "?code=c&state=%zz", error.State);
}

test "A2: another port, a host lookalike or user info is refused (origin)" {
    try expectReject("https://platform.claude.com:8443/oauth/code/callback?code=c&state=" ++ state, error.Origin);
    try expectReject("https://platform.claude.com:80/oauth/code/callback?code=c&state=" ++ state, error.Origin);
    for ([_][]const u8{
        "https://platform.claude.com.evil.test/oauth/code/callback",
        "https://evilplatform.claude.com/oauth/code/callback",
        "https://platform-claude.com/oauth/code/callback",
        "https://claude.com/oauth/code/callback",
        "https://platform.claude.com./oauth/code/callback",
        "https://platform.claude.com@evil.test/oauth/code/callback",
        "https://evil@platform.claude.com/oauth/code/callback",
        "https://u:p@platform.claude.com/oauth/code/callback",
    }) |base| {
        var buf: [256]u8 = undefined;
        try expectReject(try std.fmt.bufPrint(&buf, "{s}?code=c&state={s}", .{ base, state }), error.Origin);
    }
    try expectReject("not a url", error.Origin);
}

test "A2: http instead of https is refused (scheme)" {
    try expectReject("http://platform.claude.com/oauth/code/callback?code=c&state=" ++ state, error.Scheme);
    try expectReject("wss://platform.claude.com/oauth/code/callback?code=c&state=" ++ state, error.Scheme);
}

test "another path on the redirect_uri's origin is refused (path)" {
    for ([_][]const u8{
        "/oauth/code/callback/",
        "/oauth/code/Callback",
        "/oauth/code/%63allback",
        "/oauth/code",
        "/oauth/code/callback/x",
        "//oauth/code/callback",
    }) |path| {
        var buf: [256]u8 = undefined;
        try expectReject(try std.fmt.bufPrint(&buf, "https://platform.claude.com{s}?code=c&state={s}", .{ path, state }), error.Path);
    }
}

test "a missing, empty, doubled or unsafe code is refused (code), the state passing" {
    for ([_][]const u8{
        "?state=" ++ state,
        "?code=&state=" ++ state,
        "?code=a&code=b&state=" ++ state,
        "?code=a%23b&state=" ++ state, // a '#' would split the CLI's code#state
        "?code=a%0Ab&state=" ++ state, // a newline would end the CLI's line
        "?code=a%03b&state=" ++ state, // Ctrl-C at the CLI's terminal
        "?code=a%0Db&state=" ++ state, // a carriage return ends it too
        "?code=a%1Bb&state=" ++ state, // ESC
        "?code=a%7Fb&state=" ++ state, // DEL
        "?code=a%00b&state=" ++ state,
        "?code=a%C3%A9&state=" ++ state, // not ASCII
        "?code=a%20b&state=" ++ state,
        "?code=a+b&state=" ++ state, // '+' is a space, as the code page reads it
        "?code=a%&state=" ++ state,
        "?code=%zz&state=" ++ state,
    }) |query| {
        var buf: [512]u8 = undefined;
        try expectReject(try std.fmt.bufPrint(&buf, "{s}{s}", .{ redirect, query }), error.Code);
    }
    // At most 512 bytes in all: a code of 512 - 1 - 43 passes, one more is refused.
    var nav: [900]u8 = undefined;
    const ok_len = 512 - 1 - state.len;
    try expectCode(try std.fmt.bufPrint(&nav, "{s}?code={s}&state={s}", .{ redirect, "c" ** ok_len, state }), "c" ** ok_len ++ "#" ++ state);
    try expectReject(try std.fmt.bufPrint(&nav, "{s}?code={s}&state={s}", .{ redirect, "c" ** (ok_len + 1), state }), error.Code);
}

test "an authorize URL without one redirect_uri and one state accepts nothing" {
    const nav = redirect ++ "?code=c&state=" ++ state;
    for ([_][]const u8{
        "https://claude.com/cai/oauth/authorize?redirect_uri=" ++ redirect,
        "https://claude.com/cai/oauth/authorize?state=" ++ state,
        "https://claude.com/cai/oauth/authorize?redirect_uri=" ++ redirect ++ "&state=",
        "https://claude.com/cai/oauth/authorize?redirect_uri=" ++ redirect ++ "&state=" ++ state ++ "&state=" ++ state,
        "https://claude.com/cai/oauth/authorize?redirect_uri=" ++ redirect ++ "&redirect_uri=" ++ redirect ++ "&state=" ++ state,
        "nonsense",
    }) |a| {
        var buf: [512]u8 = undefined;
        try std.testing.expect(!try check(a, nav));
        if (code(a, nav, &buf)) |got| {
            std.debug.print("authorize {s} gave {s}\n", .{ a, got });
            return error.TestUnexpectedCode;
        } else |_| {}
    }
}

test "a percent-encoded redirect_uri in the authorize URL is decoded" {
    const a = "https://claude.com/cai/oauth/authorize?redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=" ++ state;
    var buf: [512]u8 = undefined;
    const nav = redirect ++ "?code=c&state=" ++ state;
    try std.testing.expect(try check(a, nav));
    try std.testing.expectEqualStrings("c#" ++ state, try code(a, nav, &buf));
}

test "each reason has its D7b word" {
    try std.testing.expectEqualStrings("scheme", try word(error.Scheme));
    try std.testing.expectEqualStrings("origin", try word(error.Origin));
    try std.testing.expectEqualStrings("path", try word(error.Path));
    try std.testing.expectEqualStrings("state", try word(error.State));
    try std.testing.expectEqualStrings("code", try word(error.Code));
}

// ---- The oracle: a reference parse with std.Uri ----------------------------

fn raw(c: std.Uri.Component) []const u8 {
    return switch (c) {
        .raw, .percent_encoded => |s| s,
    };
}

/// URLSearchParams decoding ('+' is a space) into `out`; null on a malformed
/// escape.
fn decode(out: []u8, v: []const u8) ?[]const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < v.len) : (n += 1) {
        if (n >= out.len) return null;
        if (v[i] == '+') {
            out[n] = ' ';
            i += 1;
        } else if (v[i] == '%') {
            if (i + 3 > v.len) return null;
            out[n] = std.fmt.parseInt(u8, v[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else {
            out[n] = v[i];
            i += 1;
        }
    }
    return out[0..n];
}

/// The one value of `name` in `query`, decoded into `out`; null when it is
/// absent, repeated or malformed.
fn one(query: ?std.Uri.Component, name: []const u8, out: []u8) ?[]const u8 {
    const q = raw(query orelse return null);
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |piece| {
        const eq = std.mem.indexOfScalar(u8, piece, '=') orelse piece.len;
        if (!std.mem.eql(u8, piece[0..eq], name)) continue;
        if (found != null) return null;
        found = if (eq == piece.len) "" else piece[eq + 1 ..];
    }
    return decode(out, found orelse return null);
}

fn defaultPort(uri: std.Uri) u16 {
    if (uri.port) |p| return p;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return 80;
    return 0;
}

/// Visible ASCII but '#'.
fn visible(s: []const u8) bool {
    for (s) |c| if (c < 0x21 or c > 0x7e or c == '#') return false;
    return true;
}

const Oracle = struct {
    ok: bool,
    code: ?[]const u8 = null,
};

fn oracle(a: []const u8, n: []const u8, out: []u8) Oracle {
    const no: Oracle = .{ .ok = false };
    const ua = std.Uri.parse(a) catch return no;
    var rbuf: [1024]u8 = undefined;
    var sbuf: [1024]u8 = undefined;
    var nsbuf: [1024]u8 = undefined;
    var cbuf: [1024]u8 = undefined;
    const r = one(ua.query, "redirect_uri", &rbuf) orelse return no;
    const s = one(ua.query, "state", &sbuf) orelse return no;
    if (s.len == 0) return no;
    const ur = std.Uri.parse(r) catch return no;
    const un = std.Uri.parse(n) catch return no;
    if (!std.ascii.eqlIgnoreCase(un.scheme, ur.scheme)) return no;
    if (un.user != null or un.password != null) return no;
    const rh = raw(ur.host orelse return no);
    const nh = raw(un.host orelse return no);
    if (!std.ascii.eqlIgnoreCase(rh, nh)) return no;
    if (defaultPort(un) != defaultPort(ur)) return no;
    if (!std.mem.eql(u8, raw(un.path), raw(ur.path))) return no;
    const ns = one(un.query, "state", &nsbuf) orelse return no;
    if (!std.mem.eql(u8, ns, s)) return no;
    const c = one(un.query, "code", &cbuf) orelse return .{ .ok = true };
    if (c.len == 0 or !visible(c) or !visible(s) or c.len + 1 + s.len > 512) return .{ .ok = true };
    const got = std.fmt.bufPrint(out, "{s}#{s}", .{ c, s }) catch unreachable;
    return .{ .ok = true, .code = got };
}

fn pick(random: std.Random, items: []const []const u8) []const u8 {
    return items[random.uintLessThan(usize, items.len)];
}

test "property (oracle): checkCallback and callbackCode agree with a std.Uri reference over 10k pairs" {
    var prng = std.Random.DefaultPrng.init(0xA2_CA11);
    const random = prng.random();
    const Redirect = struct { url: []const u8, encoded: []const u8, scheme: []const u8, other: []const u8, host: []const u8, port: []const u8, path: []const u8 };
    const redirects = [_]Redirect{
        .{ .url = redirect, .encoded = "https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback", .scheme = "https", .other = "http", .host = "platform.claude.com", .port = "443", .path = "/oauth/code/callback" },
        .{ .url = "https://localhost:54545/callback", .encoded = "https%3A%2F%2Flocalhost%3A54545%2Fcallback", .scheme = "https", .other = "http", .host = "localhost", .port = "54545", .path = "/callback" },
        .{ .url = "http://127.0.0.1:8080/cb", .encoded = "http%3A%2F%2F127.0.0.1%3A8080%2Fcb", .scheme = "http", .other = "https", .host = "127.0.0.1", .port = "8080", .path = "/cb" },
    };
    const state_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.~";
    var passed: usize = 0;
    var coded: usize = 0;
    for (0..10_000) |_| {
        const rd = redirects[random.uintLessThan(usize, redirects.len)];
        var sbuf: [64]u8 = undefined;
        const s = sbuf[0..random.intRangeAtMost(usize, 1, 60)];
        for (s) |*ch| ch.* = state_chars[random.uintLessThan(usize, state_chars.len)];
        var other_buf: [64]u8 = undefined;
        const other = std.fmt.bufPrint(&other_buf, "{s}{c}", .{ s[0 .. s.len - 1], if (s[s.len - 1] == 'Q') @as(u8, 'R') else 'Q' }) catch unreachable;
        var enc_buf: [70]u8 = undefined;
        const s_enc = std.fmt.bufPrint(&enc_buf, "%{X:0>2}{s}", .{ s[0], s[1..] }) catch unreachable;

        var abuf: [512]u8 = undefined;
        const a = switch (random.uintLessThan(u8, 12)) {
            0 => std.fmt.bufPrint(&abuf, "https://claude.com/cai/oauth/authorize?redirect_uri={s}", .{rd.url}),
            1 => std.fmt.bufPrint(&abuf, "https://claude.com/cai/oauth/authorize?redirect_uri={s}&state={s}&state={s}", .{ rd.url, s, s }),
            2, 3 => std.fmt.bufPrint(&abuf, "https://claude.com/cai/oauth/authorize?code=true&redirect_uri={s}&state={s}", .{ rd.encoded, s }),
            else => std.fmt.bufPrint(&abuf, "https://claude.com/cai/oauth/authorize?code=true&response_type=code&redirect_uri={s}&scope=user:inference&state={s}", .{ rd.url, s }),
        } catch unreachable;

        var hbuf: [64]u8 = undefined;
        const upper_host = std.ascii.upperString(&hbuf, rd.host);
        var lbuf: [96]u8 = undefined;
        const host = switch (random.uintLessThan(u8, 14)) {
            0 => upper_host,
            1 => std.fmt.bufPrint(&lbuf, "{s}.evil.test", .{rd.host}) catch unreachable,
            2 => std.fmt.bufPrint(&lbuf, "evil{s}", .{rd.host}) catch unreachable,
            3 => std.fmt.bufPrint(&lbuf, "{s}.", .{rd.host}) catch unreachable,
            4 => "claude.com",
            else => rd.host,
        };
        const scheme = switch (random.uintLessThan(u8, 10)) {
            0 => rd.other,
            1 => if (std.mem.eql(u8, rd.scheme, "https")) "HTTPS" else "HTTP",
            else => rd.scheme,
        };
        const user = switch (random.uintLessThan(u8, 16)) {
            0 => "u@",
            1 => "u:p@",
            else => "",
        };
        var pbuf: [16]u8 = undefined;
        const port = switch (random.uintLessThan(u8, 8)) {
            0 => ":8443",
            1 => ":80",
            2 => ":443",
            3 => std.fmt.bufPrint(&pbuf, ":{s}", .{rd.port}) catch unreachable,
            else => if (std.mem.eql(u8, rd.port, "443") or std.mem.eql(u8, rd.port, "80")) "" else (std.fmt.bufPrint(&pbuf, ":{s}", .{rd.port}) catch unreachable),
        };
        var pathbuf: [64]u8 = undefined;
        const path = switch (random.uintLessThan(u8, 12)) {
            0 => std.fmt.bufPrint(&pathbuf, "{s}/", .{rd.path}) catch unreachable,
            1 => std.fmt.bufPrint(&pathbuf, "{s}x", .{rd.path}) catch unreachable,
            2 => std.fmt.bufPrint(&pathbuf, "%2F{s}", .{rd.path[1..]}) catch unreachable,
            3 => "/",
            else => rd.path,
        };
        var qbuf: [600]u8 = undefined;
        var qlen: usize = 0;
        const n_parts = random.uintAtMost(usize, 4);
        for (0..n_parts) |i| {
            var cb: [64]u8 = undefined;
            const c = cb[0..random.intRangeAtMost(usize, 1, 40)];
            for (c) |*ch| ch.* = state_chars[random.uintLessThan(usize, state_chars.len)];
            var part_buf: [160]u8 = undefined;
            const part = switch (random.uintLessThan(u8, 11)) {
                0, 1, 2 => std.fmt.bufPrint(&part_buf, "state={s}", .{s}),
                3 => std.fmt.bufPrint(&part_buf, "state={s}", .{other}),
                4 => std.fmt.bufPrint(&part_buf, "state=", .{}),
                5 => std.fmt.bufPrint(&part_buf, "state={s}", .{s_enc}),
                6, 7, 8 => std.fmt.bufPrint(&part_buf, "code={s}", .{c}),
                9 => std.fmt.bufPrint(&part_buf, "code={s}", .{pick(random, &.{ "", "a%23b", "a%0Ab", "a+b", "%zz", "a%41", "a%2Bb", "x%2F%3D", "%7E!", "a%7Fb", "a%C3%A9" })}),
                else => std.fmt.bufPrint(&part_buf, "x=1", .{}),
            } catch unreachable;
            if (i > 0) {
                qbuf[qlen] = '&';
                qlen += 1;
            }
            @memcpy(qbuf[qlen..][0..part.len], part);
            qlen += part.len;
        }
        // Most pairs get the passing core, so both answers are common.
        if (random.uintLessThan(u8, 2) == 0) {
            var cb: [64]u8 = undefined;
            const c = cb[0..random.intRangeAtMost(usize, 1, 40)];
            for (c) |*ch| ch.* = state_chars[random.uintLessThan(usize, state_chars.len)];
            const core = std.fmt.bufPrint(qbuf[qlen..], "{s}code={s}&state={s}", .{ if (qlen > 0) "&" else "", c, s }) catch unreachable;
            qlen += core.len;
        }
        const frag = if (random.uintLessThan(u8, 8) == 0) "#frag" else "";
        var nbuf: [1024]u8 = undefined;
        const n = std.fmt.bufPrint(&nbuf, "{s}://{s}{s}{s}{s}?{s}{s}", .{ scheme, user, host, port, path, qbuf[0..qlen], frag }) catch unreachable;

        var obuf: [600]u8 = undefined;
        const want = oracle(a, n, &obuf);
        const got = try check(a, n);
        if (got != want.ok) {
            std.debug.print("checkCallback mismatch: oracle {}\n  authorize {s}\n  nav {s}\n", .{ want.ok, a, n });
            return error.TestOracleMismatch;
        }
        var cbuf: [512]u8 = undefined;
        if (code(a, n, &cbuf)) |c| {
            if (want.code == null or !std.mem.eql(u8, want.code.?, c)) {
                std.debug.print("callbackCode gave {s}, oracle {?s}\n  authorize {s}\n  nav {s}\n", .{ c, want.code, a, n });
                return error.TestOracleMismatch;
            }
            coded += 1;
        } else |err| {
            if (err == error.TestNoCallbackCode) return err;
            if (want.code != null) {
                std.debug.print("callbackCode refused ({}), oracle {s}\n  authorize {s}\n  nav {s}\n", .{ err, want.code.?, a, n });
                return error.TestOracleMismatch;
            }
        }
        if (want.ok) passed += 1;
    }
    // Both answers are well represented.
    try std.testing.expect(passed > 300 and passed < 9000);
    try std.testing.expect(coded > 150);
}
