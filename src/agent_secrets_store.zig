//! WS6: the portable TokenStore interface and the WS6.3 test-safety logic. One save/read/remove
//! abstraction over the Linux (file / libsecret) and Windows (Credential Manager / DPAPI-file) backends,
//! with the ONE token shape (agent_secrets_shape) enforced on Save so no backend stores a malformed token.
//! Platform-free (no std.os.*); the concrete backends live elsewhere (agent_secrets.zig, agent_secrets_win.cpp).
const std = @import("std");
pub const shape = @import("agent_secrets_shape.zig");

/// The real Windows Credential Manager target for the agent token.
pub const prod_target = "zigBrowser/ClaudeAgentToken/default";
/// A disposable per-test target: `zigBrowser-test-<random>` (WS6.3). The ONLY target a credential test
/// may create/read/delete.
pub const test_target_prefix = "zigBrowser-test-";
/// The production target family: any `zigBrowser/*` credential (never a test target).
pub const prod_target_prefix = "zigBrowser/";

pub const StoreError = error{
    /// The token is not the setup-token shape (checked before any backend call, and on read-back).
    BadShape,
    /// The backend (Credential Manager / Secret Service / file) is unavailable.
    Unavailable,
    /// No token is stored under the target.
    NotFound,
    /// The backend reported more bytes than the caller's buffer holds: fail closed, never slice past the end.
    Oversized,
};

/// The disposable test nonce is lowercase hex, at least this many chars (>= 32 bits), so the bare prefix and
/// short/near-miss targets are rejected.
pub const min_test_nonce_len = 8;

/// A disposable test target iff it is EXACTLY `zigBrowser-test-<nonce>` where <nonce> is >= 8 lowercase-hex
/// characters. The bare prefix, a too-short nonce, or any non-hex byte is NOT a test target (WS6.3, RoseCat).
pub fn isTestTarget(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, test_target_prefix)) return false;
    const nonce = name[test_target_prefix.len..];
    if (nonce.len < min_test_nonce_len) return false;
    for (nonce) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// A credential target is SAFE for a test to create/read/delete iff it is a disposable test target AND not a
/// production `zigBrowser/*` credential — the only target a credential test may ever touch (WS6.3).
pub fn validTestTarget(name: []const u8) bool {
    return isTestTarget(name) and !isProductionTarget(name);
}

/// A production credential iff it is in the `zigBrowser/*` family. A `zigBrowser-test-*` target starts
/// with `zigBrowser-`, not `zigBrowser/`, so it is never production.
pub fn isProductionTarget(name: []const u8) bool {
    return std.mem.startsWith(u8, name, prod_target_prefix);
}

pub const RunSafety = enum { ok, refuse_bad_target, refuse_production_target };

/// WS6.3: a credential test may run only when BOTH halves hold (RoseCat) — (1) the PROPOSED target is a
/// strict disposable `zigBrowser-test-<hex>` (never a production target), and (2) NO existing target is a
/// non-test `zigBrowser/*` credential. Dropping either half would let a test touch a real user token.
pub fn runSafety(proposed: []const u8, existing_targets: []const []const u8) RunSafety {
    if (!validTestTarget(proposed)) return .refuse_bad_target;
    for (existing_targets) |t| {
        if (isProductionTarget(t)) return .refuse_production_target;
    }
    return .ok;
}

/// The portable token store. Save enforces the shape FIRST (one rule for every backend); read/remove pass
/// through. The concrete backend is supplied by `ptr`/`vtable`.
pub const TokenStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        save: *const fn (*anyopaque, token: []const u8) StoreError!void,
        read: *const fn (*anyopaque, buf: []u8) StoreError!usize,
        remove: *const fn (*anyopaque) StoreError!void,
    };

    /// Validate the ONE shape before handing the token to the backend, so a malformed token is never
    /// stored (WS6.1). This is the single enforcement point — no backend repeats it.
    pub fn save(self: TokenStore, token: []const u8) StoreError!void {
        if (!shape.validToken(token)) return error.BadShape;
        return self.vtable.save(self.ptr, token);
    }

    /// Read the stored token into `buf`; returns its length. The backend's value is validated against the ONE
    /// shape centrally (RoseCat WS6), so a planted/corrupt backend value (e.g. an API key seeded straight into
    /// Credential Manager) is rejected here with error.BadShape — the Windows store preserves the shipped
    /// load contract (agent_secrets.loadFile refuses a bad-shape file) without the backend repeating the rule.
    pub fn read(self: TokenStore, buf: []u8) StoreError!usize {
        const n = self.vtable.read(self.ptr, buf) catch |e| {
            std.crypto.secureZero(u8, buf); // never leave backend bytes in the caller's buffer on error
            return e;
        };
        if (n > buf.len) {
            // A misbehaving backend reported more than the buffer holds: fail closed, with NO `buf[0..n]`
            // slice trap, and wipe whatever it wrote.
            std.crypto.secureZero(u8, buf);
            return error.Oversized;
        }
        if (!shape.validToken(buf[0..n])) {
            // A planted/corrupt backend value: zero the reported bytes so it never lingers, then refuse.
            std.crypto.secureZero(u8, buf[0..n]);
            return error.BadShape;
        }
        return n;
    }

    /// Remove the stored token (idempotent at the backend's discretion).
    pub fn remove(self: TokenStore) StoreError!void {
        return self.vtable.remove(self.ptr);
    }
};
