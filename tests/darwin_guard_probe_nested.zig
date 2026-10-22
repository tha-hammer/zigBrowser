//! bd zigBrowser-4pa.63: the same probe one container down (a method, like the ledger's `Ledger.deinit`), so a
//! guard that analyses only top-level declarations fails the selftest too.
const builtin = @import("builtin");

pub const Inner = struct {
    pub fn darwinOnly() u8 {
        const a: [if (builtin.os.tag == .macos) 1 else 2]u8 = .{ 1, 2 };
        return a[0];
    }
};
