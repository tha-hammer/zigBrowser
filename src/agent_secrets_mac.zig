//! The macOS Keychain token store — the Zig port over the C seam in `agent_secrets_mac.m` (MS5.2).
//!
//! Thin, typed wrappers over the non-GLib C ABI so the app's macOS secrets switch can eventually call the
//! Keychain backend the way the Linux switch calls libsecret. This is GROUNDWORK: it is NOT yet wired into
//! `app.zig`'s `configureAgentSecrets` — that waits on the macOS consumer (the helper / Secrets window),
//! per the ownership split with BlueBeaver. The test below links `agent_secrets_mac.m` and exercises the
//! real round-trip against a disposable keychain (macOS only).
const std = @import("std");
const builtin = @import("builtin");

/// Mirrors ZbKeychainResult in agent_secrets_mac.h.
pub const Result = enum(c_int) { ok = 0, absent = 1, unavailable = 2 };

extern "c" fn zb_keychain_store(keychain_path: ?[*:0]const u8, unlock_password: ?[*:0]const u8, service: [*:0]const u8, account: [*:0]const u8, token: [*:0]const u8, out_err: ?*?[*:0]u8) c_int;
extern "c" fn zb_keychain_lookup(keychain_path: ?[*:0]const u8, unlock_password: ?[*:0]const u8, service: [*:0]const u8, account: [*:0]const u8, out_token: ?*?[*:0]u8, out_err: ?*?[*:0]u8) c_int;
extern "c" fn zb_keychain_clear(keychain_path: ?[*:0]const u8, unlock_password: ?[*:0]const u8, service: [*:0]const u8, account: [*:0]const u8, out_err: ?*?[*:0]u8) c_int;
extern "c" fn zb_keychain_free(token: ?[*:0]u8) void;
extern "c" fn free(ptr: ?*anyopaque) void; // releases the strdup'd out_err from the C side

/// A token returned by `lookup`, owned by the C side. Release with `deinit` (the C side wipes then frees).
pub const Token = struct {
    ptr: [*:0]u8,
    pub fn slice(self: Token) [:0]const u8 {
        return std.mem.span(self.ptr);
    }
    pub fn deinit(self: Token) void {
        zb_keychain_free(self.ptr);
    }
};

/// The port does not surface the C error text yet (the consumer that needs it can be extended); it is freed
/// here so a failure path never leaks the strdup'd message.
fn dropErr(err: ?[*:0]u8) void {
    if (err) |e| free(@ptrCast(e));
}

/// `keychain_path`/`unlock_password`: null = the default (login) keychain (production); a path+password = a
/// specific keychain (tests). See agent_secrets_mac.h for the full contract.
pub fn store(keychain_path: ?[*:0]const u8, unlock_password: ?[*:0]const u8, service: [*:0]const u8, account: [*:0]const u8, token: [*:0]const u8) Result {
    var err: ?[*:0]u8 = null;
    const r: Result = @enumFromInt(zb_keychain_store(keychain_path, unlock_password, service, account, token, &err));
    dropErr(err);
    return r;
}

pub const Lookup = struct { result: Result, token: ?Token };

pub fn lookup(keychain_path: ?[*:0]const u8, unlock_password: ?[*:0]const u8, service: [*:0]const u8, account: [*:0]const u8) Lookup {
    var err: ?[*:0]u8 = null;
    var tok: ?[*:0]u8 = null;
    const r: Result = @enumFromInt(zb_keychain_lookup(keychain_path, unlock_password, service, account, &tok, &err));
    dropErr(err);
    return .{ .result = r, .token = if (tok) |t| Token{ .ptr = t } else null };
}

pub fn clear(keychain_path: ?[*:0]const u8, unlock_password: ?[*:0]const u8, service: [*:0]const u8, account: [*:0]const u8) Result {
    var err: ?[*:0]u8 = null;
    const r: Result = @enumFromInt(zb_keychain_clear(keychain_path, unlock_password, service, account, &err));
    dropErr(err);
    return r;
}

// ---- macOS-only round-trip test against a disposable keychain (links agent_secrets_mac.m) ----
// Security.framework externs for the test's throwaway keychain; opaque CF/SecKeychainRef as *anyopaque.
const SecKeychainRef = ?*anyopaque;
extern "c" fn SecKeychainCreate(path: [*:0]const u8, pwLen: u32, pw: [*]const u8, promptUser: u8, initialAccess: ?*anyopaque, out: *SecKeychainRef) c_int;
extern "c" fn SecKeychainUnlock(kc: SecKeychainRef, pwLen: u32, pw: [*]const u8, usePassword: u8) c_int;
extern "c" fn SecKeychainDelete(kc: SecKeychainRef) c_int;
extern "c" fn CFRelease(cf: ?*anyopaque) void;
extern "c" fn unlink(path: [*:0]const u8) c_int;

test "macOS keychain port: store/lookup/clear round-trip on a disposable keychain" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var buf: [160]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "/tmp/zb-ms5-zigport-{d}.keychain", .{std.c.getpid()});
    const pw = "zb-temp-pw";
    _ = unlink(path.ptr); // remove any stale file so create does not fail

    var kc: SecKeychainRef = null;
    try std.testing.expectEqual(@as(c_int, 0), SecKeychainCreate(path.ptr, @intCast(pw.len), pw.ptr, 0, null, &kc));
    defer {
        _ = SecKeychainDelete(kc);
        if (kc) |k| CFRelease(k);
        _ = unlink(path.ptr);
    }
    _ = SecKeychainUnlock(kc, @intCast(pw.len), pw.ptr, 1);

    const svc: [*:0]const u8 = "dev.zigbrowser.ClaudeAgentToken.zigtest";
    const acct: [*:0]const u8 = "default";
    const canary: [*:0]const u8 = "zb-canary-zig-9e2f";

    try std.testing.expectEqual(Result.absent, lookup(path.ptr, pw, svc, acct).result);
    try std.testing.expectEqual(Result.ok, store(path.ptr, pw, svc, acct, canary));

    const got = lookup(path.ptr, pw, svc, acct);
    try std.testing.expectEqual(Result.ok, got.result);
    try std.testing.expect(got.token != null);
    defer if (got.token) |t| t.deinit();
    try std.testing.expectEqualStrings(std.mem.span(canary), got.token.?.slice());

    try std.testing.expectEqual(Result.ok, clear(path.ptr, pw, svc, acct));
    try std.testing.expectEqual(Result.absent, lookup(path.ptr, pw, svc, acct).result);
}
