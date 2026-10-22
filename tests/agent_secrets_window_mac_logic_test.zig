//! MS7.5 — RED-FIRST, PORTABLE + DRIVEN: the macOS Secrets window's pure LOGIC (the controller behind the AppKit
//! shell). The window has a password field and four buttons — Save, Remove, Sign in, Cancel — each wired to the
//! Keychain seam. This test drives the controller with an injected spy backend and observes the state transitions,
//! which backend calls happen (and with what token), and that the status line NEVER contains the token. The real
//! AppKit shell (NSWindow / NSSecureTextField / NSButton) and the C entry point `zb_secrets_window_open` the drawer
//! calls are checked in the compiled two-Mac gate; this portable layer is the driven logic (RoseCat R1-R4).
//!
//! macOS stores ONLY in the Keychain (no file fallback — the Linux file-store option is not offered here). Save
//! delegates validate+store to the onboarding seam (zb_agent_onboard_token); the controller owns only the window's
//! own decisions (which status, whether to clear the field, whether a token is now held).
//!
//! RED now: `agent_secrets_window_mac` is absent (compile error). Portable — rehearsed with `zig test` in a scratch
//! copy (never in the shared worktree). UNREGISTERED (its own file; registered in build.zig at the green).
const std = @import("std");
const win = @import("agent_secrets_window_mac");

const Status = win.Status;
const Onboard = win.Onboard;
const Ctrl = win.Controller(*Spy);

/// The injected backend: records every call and returns programmed results, so each action is driven and observed.
const Spy = struct {
    // programmed results
    present_result: bool = false,
    onboard_result: Onboard = .ok,
    clear_result: bool = true,
    // observations
    present_calls: usize = 0,
    onboard_calls: usize = 0,
    clear_calls: usize = 0,
    signin_start: usize = 0,
    signin_cancel: usize = 0,
    last_token: []const u8 = "",

    pub fn present(self: *Spy) bool {
        self.present_calls += 1;
        return self.present_result;
    }
    pub fn onboard(self: *Spy, token: []const u8) Onboard {
        self.onboard_calls += 1;
        self.last_token = token;
        return self.onboard_result;
    }
    pub fn clear(self: *Spy) bool {
        self.clear_calls += 1;
        return self.clear_result;
    }
    pub fn signInStart(self: *Spy) void {
        self.signin_start += 1;
    }
    pub fn signInCancel(self: *Spy) void {
        self.signin_cancel += 1;
    }
};

test "init: no stored token -> empty; a stored token -> saved (status read from the keychain once)" {
    var absent = Spy{ .present_result = false };
    const c0 = Ctrl.init(&absent);
    try std.testing.expectEqual(Status.empty, c0.status);
    try std.testing.expect(!c0.has_token);
    try std.testing.expectEqual(@as(usize, 1), absent.present_calls);

    var has = Spy{ .present_result = true };
    const c1 = Ctrl.init(&has);
    try std.testing.expectEqual(Status.saved, c1.status);
    try std.testing.expect(c1.has_token);
}

test "Save a valid token: onboarded once with that token, status saved, token held, field cleared" {
    var spy = Spy{ .onboard_result = .ok };
    var c = Ctrl.init(&spy);
    c.onSave("sk-ant-oat01-ZBCANARYtoken0000000000");
    try std.testing.expectEqual(@as(usize, 1), spy.onboard_calls);
    try std.testing.expectEqualStrings("sk-ant-oat01-ZBCANARYtoken0000000000", spy.last_token);
    try std.testing.expectEqual(Status.saved, c.status);
    try std.testing.expect(c.has_token);
    try std.testing.expect(c.field_cleared); // only a successful save clears the field
    try std.testing.expectEqual(@as(usize, 0), spy.clear_calls); // Save never deletes
}

test "Save an invalid token: rejected, NOTHING held, field KEPT so the user can fix it" {
    var spy = Spy{ .onboard_result = .invalid };
    var c = Ctrl.init(&spy); // empty
    c.onSave("sk-ant-api03-not-a-setup-token");
    try std.testing.expectEqual(Status.rejected, c.status);
    try std.testing.expect(!c.has_token);
    try std.testing.expect(!c.field_cleared); // the field is NOT cleared on rejection
}

test "Save when the keychain is unavailable: save_failed, nothing held, field kept" {
    var spy = Spy{ .onboard_result = .unavailable };
    var c = Ctrl.init(&spy);
    c.onSave("sk-ant-oat01-ZBCANARYtoken0000000000");
    try std.testing.expectEqual(Status.save_failed, c.status);
    try std.testing.expect(!c.has_token);
    try std.testing.expect(!c.field_cleared);
}

test "Remove: clear called once; on success removed + no token; on failure remove_failed, token unchanged" {
    var ok = Spy{ .present_result = true, .clear_result = true };
    var c = Ctrl.init(&ok); // saved
    c.onRemove();
    try std.testing.expectEqual(@as(usize, 1), ok.clear_calls);
    try std.testing.expectEqual(Status.removed, c.status);
    try std.testing.expect(!c.has_token);

    var bad = Spy{ .present_result = true, .clear_result = false };
    var c2 = Ctrl.init(&bad); // saved, has_token = true
    c2.onRemove();
    try std.testing.expectEqual(Status.remove_failed, c2.status);
    try std.testing.expect(c2.has_token); // a failed delete must not pretend the token is gone
}

test "Sign in / Cancel drive the login seam and set the right status" {
    var spy = Spy{};
    var c = Ctrl.init(&spy);
    c.onSignIn();
    try std.testing.expectEqual(@as(usize, 1), spy.signin_start);
    try std.testing.expectEqual(Status.signing_in, c.status);
    c.onCancel();
    try std.testing.expectEqual(@as(usize, 1), spy.signin_cancel);
    try std.testing.expectEqual(Status.sign_in_cancelled, c.status);
}

test "the status line NEVER contains the token (no status text leaks the secret)" {
    const token = "sk-ant-oat01-ZBCANARYtoken0000000000";
    inline for (.{ Status.empty, Status.saved, Status.rejected, Status.save_failed, Status.removed, Status.remove_failed, Status.signing_in, Status.signed_in, Status.sign_in_failed, Status.sign_in_cancelled }) |s| {
        try std.testing.expect(std.mem.indexOf(u8, Ctrl.statusText(s), token) == null);
    }
    // and after actually passing a token through Save, the resulting status text still does not contain it
    var spy = Spy{ .onboard_result = .ok };
    var c = Ctrl.init(&spy);
    c.onSave(token);
    try std.testing.expect(std.mem.indexOf(u8, Ctrl.statusText(c.status), token) == null);
}

// ---- committed mutant: a controller that treats an invalid token as saved (a false "connected") is caught -------

fn mutantOnSaveMarksSaved(status: *Status, cleared: *bool) void {
    status.* = .saved; // the bug: report success regardless of the onboard result, and clear the field
    cleared.* = true;
}

test "committed mutant: 'invalid counts as saved' is caught (real maps invalid -> rejected, field kept)" {
    var spy = Spy{ .onboard_result = .invalid };
    var real = Ctrl.init(&spy);
    real.onSave("sk-ant-api03-not-a-setup-token");

    var mut_status: Status = .empty;
    var mut_cleared = false;
    mutantOnSaveMarksSaved(&mut_status, &mut_cleared);

    // the real controller and the mutant disagree exactly where it matters:
    try std.testing.expectEqual(Status.rejected, real.status);
    try std.testing.expect(!real.field_cleared);
    try std.testing.expect(real.status != mut_status); // rejected != saved
    try std.testing.expect(real.field_cleared != mut_cleared); // kept != cleared
}
