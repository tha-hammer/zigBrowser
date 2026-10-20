//! The shared backend-flag decision (Windows plan WS3 coordination, rev 2.5 table proposed in
//! BlueBeaver's mail to AzureRidge; RoseCat 6389, 6405). `backend_flag.backendFlagDecision(os, flag,
//! value)` is pure and all-OS: `.apply` or `.refuse` for each (flag, value) on Linux, macOS and
//! Windows, with no C ABI, so it is tested on Linux for all three.
//!
//! The rows are literal from production, not invented:
//! - `--media-source`: exactly `on` (the default) or `off` (src/media_config.zig:17-20);
//! - `--hardware-acceleration`: exactly `never`, `always` or `webkit` (the default; there is no
//!   `auto`) (src/render_config.zig:18-20,33-35,48-50; src/cli.zig:18);
//! - `--renderer`: exactly `default`, `shm` (the Linux default) or `mesa-egl`, never `mesa_egl`
//!   (src/render_config.zig:22-26,53-59; src/cli.zig:20); Linux only: macOS and Windows have no
//!   renderer choice and refuse every value;
//! - any other flag, or any other OS: refuse.
const std = @import("std");
const bf = @import("backend_flag");

const has = @hasDecl(bf, "backendFlagDecision");

const Os = std.Target.Os.Tag;
const Row = struct { flag: []const u8, value: []const u8, linux: bool, macos: bool, windows: bool };

fn all(flag: []const u8, value: []const u8, ok: bool) Row {
    return .{ .flag = flag, .value = value, .linux = ok, .macos = ok, .windows = ok };
}

fn linuxOnly(flag: []const u8, value: []const u8) Row {
    return .{ .flag = flag, .value = value, .linux = true, .macos = false, .windows = false };
}

const table = [_]Row{
    all("media-source", "on", true),
    all("media-source", "off", true),
    all("media-source", "", false),
    all("media-source", "ON", false),
    all("media-source", "auto", false),
    all("media-source", "on ", false),
    all("media-source", "bogus", false),
    all("hardware-acceleration", "webkit", true),
    all("hardware-acceleration", "always", true),
    all("hardware-acceleration", "never", true),
    all("hardware-acceleration", "", false),
    all("hardware-acceleration", "auto", false),
    all("hardware-acceleration", "Never", false),
    all("hardware-acceleration", "bogus", false),
    linuxOnly("renderer", "default"),
    linuxOnly("renderer", "shm"),
    linuxOnly("renderer", "mesa-egl"),
    all("renderer", "mesa_egl", false),
    all("renderer", "", false),
    all("renderer", "gl", false),
    all("renderer", "angle", false),
    all("renderer", "webview2", false),
    all("renderer", "bogus", false),
    all("no-such-flag", "x", false),
    all("", "", false),
    all("media_source", "on", false),
    all("--media-source", "on", false),
    all("hardware-acceleration ", "never", false),
};

fn check(os: Os, row: Row, want: bool) !void {
    const got = bf.backendFlagDecision(os, row.flag, row.value);
    if ((got == .apply) != want) {
        std.debug.print("{s}: --{s}={s}: got {s}, want {s}\n", .{ @tagName(os), row.flag, row.value, @tagName(got), if (want) "apply" else "refuse" });
        return error.TestUnexpectedResult;
    }
}

test "every row of the table, on Linux, macOS and Windows" {
    if (!has) return error.TestNoBackendFlagDecision;
    for (table) |row| {
        try check(.linux, row, row.linux);
        try check(.macos, row, row.macos);
        try check(.windows, row, row.windows);
    }
}

test "any other OS refuses every flag" {
    if (!has) return error.TestNoBackendFlagDecision;
    for ([_]Os{ .freebsd, .ios, .wasi }) |os| {
        for (table) |row| try check(os, row, false);
    }
}

test "the Linux column is the CLI's own parsing, so the two cannot drift" {
    if (!has) return error.TestNoBackendFlagDecision;
    const render_config = bf.render_config;
    const media_config = bf.media_config;
    for (table) |row| {
        const cli_accepts = if (std.mem.eql(u8, row.flag, "hardware-acceleration"))
            render_config.parseHwPolicy(row.value) != null
        else if (std.mem.eql(u8, row.flag, "renderer"))
            render_config.parseRenderer(row.value) != null
        else if (std.mem.eql(u8, row.flag, "media-source"))
            media_config.parse(row.value) != null
        else
            false;
        try std.testing.expectEqual(cli_accepts, row.linux);
    }
}
