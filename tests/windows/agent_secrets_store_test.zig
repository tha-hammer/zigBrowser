//! WS6 (b) RED — UNREGISTERED (run with
//!   `zig test --dep agent_secrets_store -Mroot=<this> -Magent_secrets_store=src/agent_secrets_store.zig`).
//!
//! The portable TokenStore interface (one save/read/remove abstraction over the Linux file/libsecret and
//! Windows CredMan/DPAPI backends) and the WS6.3 safety refusal (a credential test refuses to run if a
//! non-test `zigBrowser/*` target exists; the only target it may touch is a disposable
//! `zigBrowser-test-<random>`). Save validates the ONE shape (agent_secrets_shape) FIRST, so no backend ever
//! stores a malformed token. Red now: src/agent_secrets_store.zig does not exist. Green creates it.
const std = @import("std");
const store = @import("agent_secrets_store");

const canary = "sk-ant-oat01-ZBCANARY-0123456789abcdef";

/// An in-memory fake backend: records exactly what the interface hands it, so the test proves the shape
/// gate runs BEFORE the backend (a malformed token must never reach save_calls).
const FakeStore = struct {
    saved: ?[]const u8 = null,
    save_calls: usize = 0,
    /// When set, read() reports this many bytes WITHOUT writing them — simulates a misbehaving backend that
    /// over-reports the length, so TokenStore.read must fail closed with no slice trap.
    read_len_override: ?usize = null,

    fn save(ptr: *anyopaque, token: []const u8) store.StoreError!void {
        const self: *FakeStore = @ptrCast(@alignCast(ptr));
        self.save_calls += 1;
        self.saved = token;
    }
    fn read(ptr: *anyopaque, buf: []u8) store.StoreError!usize {
        const self: *FakeStore = @ptrCast(@alignCast(ptr));
        if (self.read_len_override) |n| return n; // over-report, write nothing
        const s = self.saved orelse return error.NotFound;
        @memcpy(buf[0..s.len], s);
        return s.len;
    }
    fn remove(ptr: *anyopaque) store.StoreError!void {
        const self: *FakeStore = @ptrCast(@alignCast(ptr));
        self.saved = null;
    }
    fn iface(self: *FakeStore) store.TokenStore {
        return .{ .ptr = self, .vtable = &.{ .save = save, .read = read, .remove = remove } };
    }
};

test "TokenStore.save validates the shape FIRST: a malformed token never reaches the backend" {
    var fake = FakeStore{};
    const ts = fake.iface();
    try std.testing.expectError(error.BadShape, ts.save("sk-ant-api03-" ++ "a" ** 40)); // an API key
    try std.testing.expectError(error.BadShape, ts.save(store.shape.token_prefix ++ "a" ** 21)); // one short
    try std.testing.expectEqual(@as(usize, 0), fake.save_calls); // the backend was NEVER called (skip-check mutant)
    try std.testing.expect(fake.saved == null);
}

test "TokenStore round-trips a valid token: save -> read -> remove" {
    var fake = FakeStore{};
    const ts = fake.iface();
    try ts.save(canary);
    try std.testing.expectEqual(@as(usize, 1), fake.save_calls);
    var buf: [600]u8 = undefined;
    const n = try ts.read(&buf);
    try std.testing.expectEqualStrings(canary, buf[0..n]);
    try ts.remove();
    try std.testing.expectError(error.NotFound, ts.read(&buf));
}

test "TokenStore.read rejects a planted invalid backend value and ZEROES the reported bytes" {
    // A value seeded straight into the backend (bypassing save) that is NOT the setup-token shape must be
    // rejected on read AND wiped from the caller's buffer — no planted bytes linger.
    const planted = "sk-ant-api03-" ++ "a" ** 40; // an API key planted directly into the backend
    var fake = FakeStore{};
    fake.saved = planted;
    const ts = fake.iface();
    var buf: [600]u8 = [_]u8{0xAA} ** 600; // sentinel prefill
    try std.testing.expectError(error.BadShape, ts.read(&buf));
    // the planted bytes are gone: buf[0..planted.len] is zeroed (not the API key, not the sentinel)
    for (buf[0..planted.len]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try std.testing.expect(std.mem.indexOf(u8, &buf, "sk-ant-api03") == null);
    // a valid value still reads back
    fake.saved = canary;
    var buf2: [600]u8 = undefined;
    const n = try ts.read(&buf2);
    try std.testing.expectEqualStrings(canary, buf2[0..n]);
}

test "TokenStore.read fails closed on an oversized backend length: no slice trap, buffer zeroed" {
    var fake = FakeStore{};
    const ts = fake.iface();
    var buf: [64]u8 = [_]u8{0xBB} ** 64; // sentinel
    fake.read_len_override = buf.len + 1; // the backend over-reports; read must not slice buf[0..n]
    try std.testing.expectError(error.Oversized, ts.read(&buf));
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0), b); // whole buffer wiped
}

test "WS6.3 disposable target grammar: prefix + >=8 hex; the bare prefix and near misses are rejected" {
    try std.testing.expect(store.isTestTarget("zigBrowser-test-deadbeef"));
    try std.testing.expect(store.isTestTarget("zigBrowser-test-0123456789abcdef"));
    try std.testing.expect(store.validTestTarget("zigBrowser-test-deadbeef"));
    for ([_][]const u8{
        "zigBrowser-test-",            // the bare prefix (no nonce)
        "zigBrowser-test",             // no trailing dash
        "zigBrowser-test-dead",        // nonce too short (< 8)
        "zigBrowser-test-deadbeeg",    // 'g' is not hex
        "zigBrowser-test-DEADBEEF",    // uppercase is not the lowercase-hex grammar
        "zigBrowser-test-dead beef",   // space
        "zigBrowser/ClaudeAgentToken/default", // the production target
        "zigBrowser-testdeadbeef",     // missing the dash before the nonce
    }) |bad| {
        try std.testing.expect(!store.isTestTarget(bad));
        try std.testing.expect(!store.validTestTarget(bad));
    }
}

test "WS6.3 safety: both halves required — strict disposable proposed AND no production target present" {
    const good = "zigBrowser-test-deadbeef";
    // ok: the proposed target is a strict disposable, and no production target exists.
    try std.testing.expectEqual(store.RunSafety.ok, store.runSafety(good, &.{good}));
    try std.testing.expectEqual(store.RunSafety.ok, store.runSafety(good, &.{}));
    // HALF 1 (grammar): a non-disposable proposed target is refused even with a clean environment — dropping
    // the grammar check would let this forbidden test run.
    try std.testing.expectEqual(store.RunSafety.refuse_bad_target,
        store.runSafety("zigBrowser/ClaudeAgentToken/default", &.{}));
    try std.testing.expectEqual(store.RunSafety.refuse_bad_target, store.runSafety("zigBrowser-test-", &.{})); // bare prefix
    try std.testing.expectEqual(store.RunSafety.refuse_bad_target, store.runSafety("zigBrowser-test-xyz", &.{})); // non-hex
    // HALF 2 (environment): a strict disposable proposed target is still refused when ANY production target
    // exists — dropping the existing-target scan would let this forbidden test run.
    try std.testing.expectEqual(store.RunSafety.refuse_production_target,
        store.runSafety(good, &.{"zigBrowser/ClaudeAgentToken/default"}));
    try std.testing.expectEqual(store.RunSafety.refuse_production_target,
        store.runSafety(good, &.{ good, "zigBrowser/ClaudeAgentToken/default" }));
}

test "target classification: disposable test target vs production target" {
    try std.testing.expect(store.isTestTarget("zigBrowser-test-deadbeef"));
    try std.testing.expect(!store.isTestTarget("zigBrowser/ClaudeAgentToken/default"));
    try std.testing.expect(store.isProductionTarget("zigBrowser/ClaudeAgentToken/default"));
    // the disposable test target must NEVER be seen as production (that would make runSafety refuse tests)
    try std.testing.expect(!store.isProductionTarget("zigBrowser-test-deadbeef"));
}
