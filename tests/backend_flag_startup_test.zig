//! The startup's flag step (Windows plan WS3 coordination, "Order (binding)" step 1, part 2; bead
//! zigBrowser-j76; option (a), RoseCat 6473, JadeBeacon 6472). `backend_flag.startup(sink, hw,
//! renderer, media)` is the one order every backend's startup follows:
//! 1. each flag PRESENT on the command line (cli.zig already refused any value its parser
//!    refuses, with usage) goes to `sink.decide`, in a fixed order; the app's sink is
//!    webkit.applyBackendFlag(builtin.os.tag, ...), which refuses an unsupported value with
//!    error.UnsupportedFlag before any C call, and the app prints `refusalMessage`;
//! 2. a refusal stops there: nothing is applied;
//! 3. then `sink.applyResolved` runs exactly once, with the resolved effective configuration
//!    (render_config.resolve) and the media flag, defaults included: on Linux that is
//!    webkit.applyRender and webkit.applyMediaSource, the one native apply.
//! An ABSENT flag never reaches `decide` (it is not a decision), but its default is still
//! applied by step 3 (RoseCat 6451, 6454). Outside the gate until the green registers it.
const std = @import("std");
const bf = @import("backend_flag");
const render_config = bf.render_config;
const media_config = bf.media_config;

const has = @hasDecl(bf, "startup") and @hasDecl(bf, "presentFlags") and @hasDecl(bf, "refusalMessage");

/// Records every call, in order, as text.
const Recorder = struct {
    log: std.ArrayList(u8) = .empty,
    refuse: ?[]const u8 = null, // a flag name this sink refuses, as an unsupporting backend does

    fn line(self: *Recorder, comptime fmt: []const u8, args: anytype) void {
        self.log.print(std.testing.allocator, fmt ++ "\n", args) catch @panic("oom");
    }

    pub fn decide(self: *Recorder, flag: []const u8, value: []const u8) error{UnsupportedFlag}!void {
        self.line("decide {s}={s}", .{ flag, value });
        if (self.refuse) |r| if (std.mem.eql(u8, r, flag)) return error.UnsupportedFlag;
    }

    pub fn applyResolved(self: *Recorder, cfg: render_config.RenderConfig, media: ?media_config.MediaSource) void {
        self.line("apply hardware-acceleration={s} renderer={s} media-source={s}", .{
            @tagName(cfg.hw_policy), render_config.rendererName(cfg.renderer), if (media) |m| @tagName(m) else "(default)",
        });
    }
};

fn run(rec: *Recorder, hw: ?render_config.HwPolicy, renderer: ?render_config.Renderer, media: ?media_config.MediaSource) !void {
    if (!has) return error.TestNoStartupStep;
    try bf.startup(rec, hw, renderer, media);
}

test "absent flags: no decision at all, and the defaults are still applied, once" {
    var rec: Recorder = .{};
    defer rec.log.deinit(std.testing.allocator);
    try run(&rec, null, null, null);
    try std.testing.expectEqualStrings("apply hardware-acceleration=webkit renderer=shm media-source=(default)\n", rec.log.items);
}

test "present flags: each decided, in a fixed order, before the one apply" {
    var rec: Recorder = .{};
    defer rec.log.deinit(std.testing.allocator);
    try run(&rec, .never, .mesa_egl, .off);
    try std.testing.expectEqualStrings(
        "decide hardware-acceleration=never\n" ++
            "decide renderer=mesa-egl\n" ++
            "decide media-source=off\n" ++
            "apply hardware-acceleration=never renderer=mesa-egl media-source=off\n",
        rec.log.items,
    );
}

test "only the present ones are decided; the absent ones keep their defaults in the apply" {
    var rec: Recorder = .{};
    defer rec.log.deinit(std.testing.allocator);
    try run(&rec, null, null, .off);
    try std.testing.expectEqualStrings("decide media-source=off\napply hardware-acceleration=webkit renderer=shm media-source=off\n", rec.log.items);
}

test "a refusal stops the startup: no later decision, nothing applied" {
    var rec: Recorder = .{ .refuse = "renderer" };
    defer rec.log.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedFlag, run(&rec, .always, .shm, .on));
    try std.testing.expectEqualStrings("decide hardware-acceleration=always\ndecide renderer=shm\n", rec.log.items);
}

test "every present value is production's own spelling, which its parser reads back" {
    if (!has) return error.TestNoStartupStep;
    var buf: [3]bf.Present = undefined;
    try std.testing.expectEqual(@as(usize, 0), bf.presentFlags(null, null, null, &buf).len);
    for ([_]render_config.HwPolicy{ .never, .always, .webkit }) |hw| {
        const got = bf.presentFlags(hw, null, null, &buf);
        try std.testing.expectEqual(@as(usize, 1), got.len);
        try std.testing.expectEqualStrings("hardware-acceleration", got[0].flag);
        try std.testing.expectEqual(hw, render_config.parseHwPolicy(got[0].value).?);
    }
    for ([_]render_config.Renderer{ .default, .shm, .mesa_egl }) |r| {
        const got = bf.presentFlags(null, r, null, &buf);
        try std.testing.expectEqualStrings("renderer", got[0].flag);
        try std.testing.expectEqual(r, render_config.parseRenderer(got[0].value).?);
    }
    for ([_]media_config.MediaSource{ .on, .off }) |m| {
        const got = bf.presentFlags(null, null, m, &buf);
        try std.testing.expectEqualStrings("media-source", got[0].flag);
        try std.testing.expectEqual(m, media_config.parse(got[0].value).?);
    }
}

test "the refusal message, exactly, per OS" {
    if (!has) return error.TestNoStartupStep;
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("zigBrowser: --renderer=shm is not supported on Windows", try bf.refusalMessage(&buf, .windows, "renderer", "shm"));
    try std.testing.expectEqualStrings("zigBrowser: --renderer=mesa-egl is not supported on macOS", try bf.refusalMessage(&buf, .macos, "renderer", "mesa-egl"));
    try std.testing.expectEqualStrings("zigBrowser: --media-source=off is not supported on Linux", try bf.refusalMessage(&buf, .linux, "media-source", "off"));
}

test "the resolved defaults are the ones the plan names: webkit, shm, media on" {
    try std.testing.expectEqual(render_config.HwPolicy.webkit, render_config.resolve(null, null).hw_policy);
    try std.testing.expectEqual(render_config.Renderer.shm, render_config.resolve(null, null).renderer);
    try std.testing.expectEqual(media_config.MediaSource.on, media_config.resolve(null, null).value);
}
