//! The auth window's callback check (chat-drawer plan S6.2, A2; rev 16.17).
//! The real `claude setup-token` redirects to its manual code page
//! (https://platform.claude.com/oauth/code/callback) and reads the code at its
//! prompt as `<code>#<state>`. The auth window catches the navigation to the
//! authorize URL's `redirect_uri`, never loads that page, and hands
//! `<code>#<state>` to the login helper only when the navigation is this
//! sign-in's own callback:
//! - the scheme equals the redirect_uri's (ASCII case aside);
//! - no user info, the same host (ASCII case aside) and the same port (an
//!   absent port is the scheme's default);
//! - the same path, byte for byte (no decoding);
//! - exactly one `state`, decoded, equal to the authorize URL's one (decoded)
//!   `state`;
//! - exactly one non-empty `code`. The code is opaque, so code and state may
//!   hold any visible ASCII but '#' (D7b's `code` frame, RoseCat 5865): nothing
//!   from the page reaches the CLI's terminal as a space, a newline, a second
//!   '#', a control byte, DEL or a non-ASCII byte; `<code>#<state>` at most
//!   512 bytes.
//! A value is decoded as the code page's URLSearchParams decodes it ('+' is a
//! space, %XX a byte), except that a malformed escape refuses it.
//! A refusal is one of `Reject`, named by D7b's `AUTH blocked <reason>` word.
//!
//! `authorizeUrl` (rev 16.18.11; BlackRobin 5924) is the app's own check of the
//! login helper's `auth_url`, with the helper's exact rules: the app shows or loads
//! nothing else under the sign-in's name.
const std = @import("std");
const Uri = std.Uri;

pub const Reject = error{ Scheme, Origin, Path, State, Code };

/// The `code` frame's limit (D7b).
pub const max_code_len = 512;
/// The `auth_url` frame's limit (D7b): no decoded parameter is longer.
const max_url_len = 4096;

/// The CLI's two authorize URLs (2.1.301: CLAUDE_AI_AUTHORIZE_URL and
/// CONSOLE_AUTHORIZE_URL), host and path byte for byte.
const authorize_targets = [_][2][]const u8{
    .{ "claude.com", "/cai/oauth/authorize" },
    .{ "platform.claude.com", "/oauth/authorize" },
};
/// Its exact parameter names, each exactly once, and no other.
const authorize_params = [_][]const u8{
    "code", "client_id", "response_type", "redirect_uri", "scope", "code_challenge", "code_challenge_method", "state",
};
/// The values the capture fixes (RoseCat 5967), compared decoded.
const authorize_fixed = [_][2][]const u8{
    .{ "code", "true" },
    .{ "response_type", "code" },
    .{ "redirect_uri", "https://platform.claude.com/oauth/code/callback" },
    .{ "scope", "user:inference" },
    .{ "code_challenge_method", "S256" },
};

/// True only for one of the CLI's own authorize URLs (rev 16.18.11): the login
/// helper's rules (login.authorize_url), checked again by the app before the
/// link is shown or loaded. tests/fixtures/agent/authorize_url_cases.json holds
/// every case, shared with the helper's tests.
pub fn authorizeUrl(url: []const u8) bool {
    if (url.len > max_url_len) return false;
    // Visible ASCII only: no NUL, control byte, space, DEL or non-ASCII byte (rev 16.18.12).
    for (url) |c| if (c < 0x21 or c > 0x7e) return false;
    const uri = Uri.parse(url) catch return false;
    if (!std.mem.eql(u8, uri.scheme, "https")) return false;
    if (uri.user != null or uri.password != null or uri.port != null or uri.fragment != null) return false;
    const host = text(uri.host orelse return false);
    const path = text(uri.path);
    const target = for (authorize_targets) |t| {
        if (std.mem.eql(u8, host, t[0]) and std.mem.eql(u8, path, t[1])) break true;
    } else false;
    if (!target) return false;

    // No name the CLI never sends, and each written plainly: names are compared as
    // written, so `st%61te` is not `state` (rev 16.18.12). Each of the eight exactly
    // once: every one is read below through `param`, which refuses a missing or
    // repeated name.
    var pieces = std.mem.splitScalar(u8, text(uri.query orelse return false), '&');
    while (pieces.next()) |piece| {
        const name = piece[0 .. std.mem.indexOfScalar(u8, piece, '=') orelse piece.len];
        for (authorize_params) |p| {
            if (std.mem.eql(u8, name, p)) break;
        } else return false;
    }

    var buf: [max_url_len]u8 = undefined;
    for (authorize_fixed) |f| {
        const value = param(uri.query, f[0], &buf) orelse return false;
        if (!std.mem.eql(u8, value, f[1])) return false;
    }
    if (!uuid(param(uri.query, "client_id", &buf) orelse return false)) return false;
    if (!s256Challenge(param(uri.query, "code_challenge", &buf) orelse return false)) return false;
    const state = param(uri.query, "state", &buf) orelse return false;
    return state.len > 0;
}

/// A lowercase UUID, 8-4-4-4-12 hex digits.
fn uuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        const dash = i == 8 or i == 13 or i == 18 or i == 23;
        if (dash != (c == '-')) return false;
        if (!dash and !std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

/// The base64url of a SHA-256, unpadded: 43 characters of [A-Za-z0-9_-].
fn s256Challenge(s: []const u8) bool {
    if (s.len != 43) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}

pub fn rejectWord(err: Reject) []const u8 {
    return switch (err) {
        error.Scheme => "scheme",
        error.Origin => "origin",
        error.Path => "path",
        error.State => "state",
        error.Code => "code",
    };
}

/// The plan's invariant: the navigation is this sign-in's callback (scheme,
/// host, port and path of the redirect_uri, and its state), whatever its code.
pub fn checkCallback(authorize_url: []const u8, nav_url: []const u8) bool {
    var buf: [max_code_len]u8 = undefined;
    _ = callbackCode(authorize_url, nav_url, &buf) catch |err| return err == error.Code;
    return true;
}

/// `<code>#<state>` in `out` for this sign-in's callback, or the reason it is
/// refused. An authorize URL without one redirect_uri and one non-empty state
/// accepts nothing (`Origin`).
pub fn callbackCode(authorize_url: []const u8, nav_url: []const u8, out: []u8) Reject![]const u8 {
    const authorize = Uri.parse(authorize_url) catch return error.Origin;
    var redirect_buf: [max_url_len]u8 = undefined;
    var state_buf: [max_url_len]u8 = undefined;
    const redirect_text = param(authorize.query, "redirect_uri", &redirect_buf) orelse return error.Origin;
    const state = param(authorize.query, "state", &state_buf) orelse return error.Origin;
    if (state.len == 0) return error.Origin;
    const redirect = Uri.parse(redirect_text) catch return error.Origin;
    const redirect_host = text(redirect.host orelse return error.Origin);

    const nav = Uri.parse(nav_url) catch return error.Origin;
    if (!std.ascii.eqlIgnoreCase(nav.scheme, redirect.scheme)) return error.Scheme;
    if (nav.user != null or nav.password != null) return error.Origin;
    const nav_host = text(nav.host orelse return error.Origin);
    if (!std.ascii.eqlIgnoreCase(nav_host, redirect_host)) return error.Origin;
    if (port(nav) != port(redirect)) return error.Origin;
    if (!std.mem.eql(u8, text(nav.path), text(redirect.path))) return error.Path;

    var nav_state_buf: [max_url_len]u8 = undefined;
    const nav_state = param(nav.query, "state", &nav_state_buf) orelse return error.State;
    if (!std.mem.eql(u8, nav_state, state)) return error.State;

    var code_buf: [max_url_len]u8 = undefined;
    const code = param(nav.query, "code", &code_buf) orelse return error.Code;
    if (code.len == 0 or !visible(code) or !visible(state)) return error.Code;
    if (code.len + 1 + state.len > @min(out.len, max_code_len)) return error.Code;
    return std.fmt.bufPrint(out, "{s}#{s}", .{ code, state }) catch unreachable;
}

fn text(component: Uri.Component) []const u8 {
    return switch (component) {
        .raw, .percent_encoded => |s| s,
    };
}

fn port(uri: Uri) u16 {
    if (uri.port) |p| return p;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return 443;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return 80;
    return 0;
}

/// The one value of `name` in `query`, decoded into `out`; null when
/// it is absent, given twice, malformed or longer than `out`. Names are
/// compared as written.
fn param(query: ?Uri.Component, name: []const u8, out: []u8) ?[]const u8 {
    var value: ?[]const u8 = null;
    var pieces = std.mem.splitScalar(u8, text(query orelse return null), '&');
    while (pieces.next()) |piece| {
        const eq = std.mem.indexOfScalar(u8, piece, '=');
        if (!std.mem.eql(u8, piece[0 .. eq orelse piece.len], name)) continue;
        if (value != null) return null;
        value = if (eq) |i| piece[i + 1 ..] else "";
    }
    return percentDecode(value orelse return null, out);
}

/// URLSearchParams decoding, but strict: a malformed escape gives null.
fn percentDecode(in: []const u8, out: []u8) ?[]const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < in.len) : (len += 1) {
        if (len == out.len) return null;
        if (in[i] != '%') {
            out[len] = if (in[i] == '+') ' ' else in[i];
            i += 1;
            continue;
        }
        if (in.len - i < 3) return null;
        out[len] = std.fmt.parseInt(u8, in[i + 1 .. i + 3], 16) catch return null;
        i += 3;
    }
    return out[0..len];
}

/// Visible ASCII but '#', the CLI's separator.
fn visible(s: []const u8) bool {
    for (s) |c| if (c < 0x21 or c > 0x7e or c == '#') return false;
    return true;
}
