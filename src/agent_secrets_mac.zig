//! The macOS Keychain token store — the Zig port over the C seam in `agent_secrets_mac.m` (MS5.2).
//!
//! Thin, typed wrappers over the non-GLib C ABI so the app's macOS secrets switch can eventually call the
//! Keychain backend the way the Linux switch calls libsecret. This is GROUNDWORK: it is NOT yet wired into
//! `app.zig`'s `configureAgentSecrets` — that waits on the macOS consumer (the helper / Secrets window),
//! per the ownership split with BlueBeaver. The test below links `agent_secrets_mac.m` and exercises the
//! real round-trip against a disposable keychain (macOS only).
//!
//! Ownership (RoseCat 81e99b9): the C-side token buffer NEVER escapes this module. `lookup` copies the
//! bytes into the caller's allocator and frees the C buffer immediately, so there is no raw C pointer for a
//! caller to alias or double-free. The result is a plain allocator-owned `[]u8` under the standard Zig
//! single-owner contract — release it exactly once with `freeSecret` (which wipes then frees).
const std = @import("std");
const builtin = @import("builtin");

/// Mirrors ZbKeychainResult in agent_secrets_mac.h.
pub const Result = enum(c_int) { ok = 0, absent = 1, unavailable = 2, permission = 3 };

extern "c" fn zb_keychain_store(keychain_path: ?[*:0]const u8, unlock_password: ?[*:0]const u8, service: [*:0]const u8, account: [*:0]const u8, token: [*:0]const u8, out_err: ?*?[*:0]u8) c_int;
extern "c" fn zb_keychain_lookup(keychain_path: ?[*:0]const u8, unlock_password: ?[*:0]const u8, service: [*:0]const u8, account: [*:0]const u8, out_token: ?*?[*:0]u8, out_err: ?*?[*:0]u8) c_int;
extern "c" fn zb_keychain_clear(keychain_path: ?[*:0]const u8, unlock_password: ?[*:0]const u8, service: [*:0]const u8, account: [*:0]const u8, out_err: ?*?[*:0]u8) c_int;
extern "c" fn zb_keychain_free(token: ?[*:0]u8) void;
extern "c" fn free(ptr: ?*anyopaque) void; // releases the strdup'd out_err from the C side

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

/// The outcome of a lookup. On `.ok`, `secret` is owned by the allocator passed to `lookup`; the caller is
/// its SOLE owner and releases it exactly once with `freeSecret`. The C-side buffer does not escape.
pub const LookupResult = union(enum) {
    ok: []u8,
    absent,
    unavailable,
    permission,
};

/// Look up the token for (service, account). On `.ok` the returned slice is owned by `gpa`; free it once
/// with `freeSecret`. The C buffer is wiped+freed here, so no raw C pointer is exposed to the caller.
pub fn lookup(gpa: std.mem.Allocator, keychain_path: ?[*:0]const u8, unlock_password: ?[*:0]const u8, service: [*:0]const u8, account: [*:0]const u8) error{OutOfMemory}!LookupResult {
    var err: ?[*:0]u8 = null;
    var ctok: ?[*:0]u8 = null;
    const r: Result = @enumFromInt(zb_keychain_lookup(keychain_path, unlock_password, service, account, &ctok, &err));
    dropErr(err);
    switch (r) {
        .ok => {
            const cptr = ctok orelse return .unavailable; // OK without a buffer should not happen; treat defensively
            const span = std.mem.span(cptr);
            const buf = gpa.alloc(u8, span.len) catch {
                zb_keychain_free(cptr); // free the C copy even on OOM so it never leaks
                return error.OutOfMemory;
            };
            @memcpy(buf, span);
            zb_keychain_free(cptr); // wipe+free the C copy at once; only the caller-owned Zig copy remains
            return .{ .ok = buf };
        },
        .absent => return .absent,
        .unavailable => {
            if (ctok) |p| zb_keychain_free(p);
            return .unavailable;
        },
        .permission => {
            if (ctok) |p| zb_keychain_free(p);
            return .permission;
        },
    }
}

/// Wipe then free a secret returned by `lookup`. Single-owner contract: call exactly once; never on a copy.
pub fn freeSecret(gpa: std.mem.Allocator, secret: []u8) void {
    @memset(secret, 0);
    gpa.free(secret);
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

const TestKc = struct {
    kc: SecKeychainRef,
    path: [:0]const u8,
    fn make(buf: []u8, tag: []const u8) !TestKc {
        const path = try std.fmt.bufPrintZ(buf, "/tmp/zb-ms5-zigport-{s}-{d}.keychain", .{ tag, std.c.getpid() });
        const pw = "zb-temp-pw";
        _ = unlink(path.ptr);
        var kc: SecKeychainRef = null;
        if (SecKeychainCreate(path.ptr, @intCast(pw.len), pw.ptr, 0, null, &kc) != 0) return error.KeychainCreate;
        _ = SecKeychainUnlock(kc, @intCast(pw.len), pw.ptr, 1);
        return .{ .kc = kc, .path = path };
    }
    fn deinit(self: TestKc) void {
        _ = SecKeychainDelete(self.kc);
        if (self.kc) |k| CFRelease(k);
        _ = unlink(self.path.ptr);
    }
};
const test_pw: [*:0]const u8 = "zb-temp-pw";

test "macOS keychain port: store/lookup/clear round-trip (allocator-owned secret, freed once)" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    var buf: [160]u8 = undefined;
    const t = try TestKc.make(&buf, "roundtrip");
    defer t.deinit();

    const svc: [*:0]const u8 = "dev.zigbrowser.ClaudeAgentToken.zigtest";
    const acct: [*:0]const u8 = "default";
    const canary = "zb-canary-zig-9e2f";
    const a = std.testing.allocator; // flags a leak if the secret is not freed exactly once

    try std.testing.expect(std.meta.activeTag(try lookup(a, t.path.ptr, test_pw, svc, acct)) == .absent);
    try std.testing.expectEqual(Result.ok, store(t.path.ptr, test_pw, svc, acct, canary));

    switch (try lookup(a, t.path.ptr, test_pw, svc, acct)) {
        .ok => |secret| {
            try std.testing.expectEqualStrings(canary, secret);
            freeSecret(a, secret); // sole owner; free exactly once (testing.allocator would flag a leak)
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(Result.ok, clear(t.path.ptr, test_pw, svc, acct));
    try std.testing.expect(std.meta.activeTag(try lookup(a, t.path.ptr, test_pw, svc, acct)) == .absent);
}
