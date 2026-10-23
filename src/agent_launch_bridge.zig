//! bd zigBrowser-4pa.21, MS6.8 slice 2a (SilverRidge d751d158): a TEST-ONLY bridge over the real production launch
//! builders, so agent/host/tests/test_launch_bridge.py can hand their argv to the real Python `launch.main`. It is a
//! PREPARATORY connector proof (the Zig builder composes with the real Python consumer), not a production Darwin
//! caller: the browser's Darwin helper/login path does not call these builders until 4pa.27/MS8.
//!
//! It lives in src/ because agent_login.zig imports agent_helper.zig by path, and a file may belong to one module
//! only. Nothing in the browser imports it.
//!
//! Usage: agent_launch_bridge chat|login --python P --home H (--linux DIR | --darwin PORT)
//!          [--e2e] [--bwrap X] [--host-cmd X] [--test-ca X] [--claude-cli X] [--path-dir D]...
//! Prints one JSON object: {"argv": [...], "env": [...], "warnings": [...], "refusal": null|"..."}.
//! Exit 0 when the builder returned, 2 on a usage error, 3 on a builder error (named on stderr).

const std = @import("std");
const agent_helper = @import("agent_helper.zig");
const agent_login = @import("agent_login.zig");

const Request = struct {
    command: []const u8 = "",
    python: []const u8 = "",
    home: []const u8 = "",
    linux: ?[]const u8 = null,
    darwin: ?u16 = null,
    e2e: bool = false,
    bwrap: ?[]const u8 = null,
    host_cmd: ?[]const u8 = null,
    test_ca: ?[]const u8 = null,
    claude_cli: ?[]const u8 = null,
};

const Out = struct {
    argv: []const []const u8,
    env: []const []const u8,
    warnings: []const []const u8,
    refusal: ?[]const u8,
};

fn parse(a: std.mem.Allocator, args: []const [:0]const u8, dirs: *std.ArrayList([]const u8)) !Request {
    if (args.len < 2) return error.Usage;
    var r: Request = .{ .command = args[1] };
    if (!std.mem.eql(u8, r.command, "chat") and !std.mem.eql(u8, r.command, "login")) return error.Usage;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (std.mem.eql(u8, flag, "--e2e")) {
            r.e2e = true;
            continue;
        }
        if (i + 1 >= args.len) return error.Usage;
        i += 1;
        const v: []const u8 = args[i];
        if (std.mem.eql(u8, flag, "--python")) r.python = v
        else if (std.mem.eql(u8, flag, "--home")) r.home = v
        else if (std.mem.eql(u8, flag, "--linux")) r.linux = v
        else if (std.mem.eql(u8, flag, "--darwin")) r.darwin = std.fmt.parseInt(u16, v, 10) catch return error.Usage
        else if (std.mem.eql(u8, flag, "--bwrap")) r.bwrap = v
        else if (std.mem.eql(u8, flag, "--host-cmd")) r.host_cmd = v
        else if (std.mem.eql(u8, flag, "--test-ca")) r.test_ca = v
        else if (std.mem.eql(u8, flag, "--claude-cli")) r.claude_cli = v
        else if (std.mem.eql(u8, flag, "--path-dir")) try dirs.append(a, v)
        else return error.Usage;
    }
    if (r.python.len == 0 or r.home.len == 0 or (r.linux == null) == (r.darwin == null)) return error.Usage;
    if (std.mem.eql(u8, r.command, "login") and (r.host_cmd != null or r.test_ca != null)) return error.Usage; // chat-only seams
    return r;
}

fn build(a: std.mem.Allocator, r: Request, dirs: []const []const u8) !Out {
    if (std.mem.eql(u8, r.command, "chat")) {
        const run = try agent_helper.launch(a, .{ .python = r.python, .home = r.home, .realization = realization(r),
            .path_dirs = dirs, .e2e_protocol = r.e2e, .bwrap = r.bwrap, .host_cmd = r.host_cmd, .test_ca = r.test_ca });
        return .{ .argv = run.argv, .env = run.env, .warnings = run.warnings, .refusal = run.refusal };
    }
    const run = try agent_login.launch(a, .{ .python = r.python, .home = r.home, .realization = realization(r),
        .path_dirs = dirs, .e2e_protocol = r.e2e, .claude_cli = r.claude_cli, .bwrap = r.bwrap });
    var warnings: std.ArrayList([]const u8) = .empty;
    if (run.warning) |line| try warnings.append(a, line);
    return .{ .argv = run.argv, .env = run.env, .warnings = try warnings.toOwnedSlice(a), .refusal = run.refusal };
}

fn realization(r: Request) agent_helper.Realization {
    if (r.linux) |dir| return .{ .linux = dir };
    return .{ .darwin = r.darwin.? };
}

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var dirs: std.ArrayList([]const u8) = .empty;
    var err_buffer: [512]u8 = undefined;
    var err: std.Io.File.Writer = .init(.stderr(), init.io, &err_buffer);
    const r = parse(a, args, &dirs) catch {
        try err.interface.writeAll("agent_launch_bridge: usage: chat|login --python P --home H (--linux DIR | --darwin PORT) ...\n");
        try err.interface.flush();
        return 2;
    };
    const out = build(a, r, dirs.items) catch |e| {
        try err.interface.print("agent_launch_bridge: builder error {s}\n", .{@errorName(e)});
        try err.interface.flush();
        return 3;
    };
    const text = try std.json.Stringify.valueAlloc(a, out, .{});
    var out_buffer: [4096]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
    try w.interface.writeAll(text);
    try w.interface.writeAll("\n");
    try w.interface.flush();
    return 0;
}
