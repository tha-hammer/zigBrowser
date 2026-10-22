//! WS6.1 (a) RED — UNREGISTERED (run with `zig test`, wired into no build step).
//!
//! The token SHAPE check must live in a PORTABLE module (no std.os.linux), split out of
//! agent_secrets.zig's Linux file store, so the Windows CredMan/DPAPI store can reuse the one rule
//! without pulling the Linux syscalls. Red now: src/agent_secrets_shape.zig does not exist yet, so
//! the import fails to compile. Green creates it (and agent_secrets.zig re-exports from it).
const std = @import("std");
const shape = @import("agent_secrets_shape");

const prefix = "sk-ant-oat01-";

test "portable shape module accepts the setup-token shape and rejects near misses" {
    try std.testing.expect(shape.validToken(prefix ++ "a" ** 22)); // minimum suffix
    try std.testing.expect(shape.validToken(prefix ++ "x" ** 499)); // maximum suffix
    try std.testing.expect(!shape.validToken(prefix ++ "a" ** 21)); // one short
    try std.testing.expect(!shape.validToken(prefix ++ "x" ** 500)); // one long
    try std.testing.expect(!shape.validToken("sk-ant-api03-" ++ "a" ** 40)); // an API key
    try std.testing.expect(shape.max_token_len == 512);
}

test "the shape check is load-bearing: a skip-the-check mutant would store a malformed token" {
    const bad = "sk-ant-api03-" ++ "a" ** 40; // a well-formed API key, NOT a setup token
    const skip = struct {
        fn check(_: []const u8) bool {
            return true; // the mutant: no shape validation at all
        }
    }.check;
    try std.testing.expect(skip(bad)); // the mutant accepts the malformed token...
    try std.testing.expect(!shape.validToken(bad)); // ...while the real check rejects it (they disagree)
}
