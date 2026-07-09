const std = @import("std");
const builtin = @import("builtin");

pub const IpcError = error{
    UnknownCommand,
    BadArgs,
};

const AddArgs = struct { a: i64, b: i64 };
const EchoArgs = struct { msg: []const u8 };

threadlocal var dispatch_result_cstr: ?[:0]u8 = null;
threadlocal var dispatch_err_cstr: [128]u8 = undefined;

pub fn dispatch(allocator: std.mem.Allocator, cmd: []const u8, args_json: []const u8) IpcError![]const u8 {
    if (std.mem.eql(u8, cmd, "ping")) {
        try expectNoArgs(allocator, args_json);
        return allocator.dupe(u8, "\"pong\"") catch return error.BadArgs;
    }

    if (std.mem.eql(u8, cmd, "add")) {
        const add_args = try parseAddArgs(allocator, args_json);
        const sum: i128 = @as(i128, add_args.a) + @as(i128, add_args.b);
        return std.fmt.allocPrint(allocator, "{}", .{sum}) catch return error.BadArgs;
    }

    if (std.mem.eql(u8, cmd, "echo")) {
        const msg = try parseEchoArg(allocator, args_json);
        defer allocator.free(msg);
        return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(msg, .{})}) catch return error.BadArgs;
    }

    if (std.mem.eql(u8, cmd, "os.info")) {
        try expectNoArgs(allocator, args_json);
        return osInfoJson(allocator);
    }

    return error.UnknownCommand;
}

pub export fn zb_ipc_dispatch(
    cmd: [*:0]const u8,
    args_json: [*:0]const u8,
    out_result: *?[*:0]const u8,
    out_err: *?[*:0]const u8,
) c_int {
    out_result.* = null;
    out_err.* = null;
    releaseDispatchResult();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cmd_text = std.mem.span(cmd);
    const args_text = std.mem.span(args_json);

    const result = dispatch(allocator, cmd_text, args_text) catch |err| {
        const err_name = @errorName(err);
        if (!copyToCStr(&dispatch_err_cstr, err_name)) {
            _ = copyToCStr(&dispatch_err_cstr, "BadArgs");
        }
        out_err.* = cPtrFromBuffer(&dispatch_err_cstr);
        return ipcErrorCode(err);
    };

    out_result.* = storeDispatchResult(result) catch |err| {
        _ = copyToCStr(&dispatch_err_cstr, "BadArgs");
        out_err.* = cPtrFromBuffer(&dispatch_err_cstr);
        return ipcErrorCode(err);
    };
    return 0;
}

fn expectNoArgs(allocator: std.mem.Allocator, args_json: []const u8) IpcError!void {
    const trimmed = std.mem.trim(u8, args_json, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return error.BadArgs;
    defer parsed.deinit();

    switch (parsed.value) {
        .null => return,
        .object => |obj| {
            if (obj.count() == 0) return;
            return error.BadArgs;
        },
        else => return error.BadArgs,
    }
}

fn parseAddArgs(allocator: std.mem.Allocator, args_json: []const u8) IpcError!AddArgs {
    const trimmed = std.mem.trim(u8, args_json, &std.ascii.whitespace);
    if (trimmed.len == 0) return error.BadArgs;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return error.BadArgs;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.BadArgs,
    };
    if (obj.count() != 2) return error.BadArgs;

    const a_value = obj.get("a") orelse return error.BadArgs;
    const b_value = obj.get("b") orelse return error.BadArgs;

    return .{
        .a = try valueToI64(a_value),
        .b = try valueToI64(b_value),
    };
}

fn parseEchoArg(allocator: std.mem.Allocator, args_json: []const u8) IpcError![]const u8 {
    const trimmed = std.mem.trim(u8, args_json, &std.ascii.whitespace);
    if (trimmed.len == 0) return error.BadArgs;

    const parsed = std.json.parseFromSliceLeaky(EchoArgs, allocator, trimmed, .{
        .allocate = .alloc_always,
    }) catch return error.BadArgs;
    return parsed.msg;
}

fn osInfoJson(allocator: std.mem.Allocator) IpcError![]const u8 {
    switch (comptime builtin.os.tag) {
        .windows => {
            const windows = std.os.windows;
            var version_info: windows.RTL_OSVERSIONINFOW = undefined;
            version_info.dwOSVersionInfoSize = @sizeOf(windows.RTL_OSVERSIONINFOW);

            switch (windows.ntdll.RtlGetVersion(&version_info)) {
                .SUCCESS => {},
                else => return error.BadArgs,
            }

            var release_buf: [64]u8 = undefined;
            const release = std.fmt.bufPrint(&release_buf, "{}.{}.{}", .{
                version_info.dwMajorVersion,
                version_info.dwMinorVersion,
                version_info.dwBuildNumber,
            }) catch return error.BadArgs;
            const info = .{
                .sysname = "Windows",
                .release = release,
                .machine = @tagName(builtin.cpu.arch),
            };
            return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(info, .{})}) catch return error.BadArgs;
        },
        else => {
            const uts = std.posix.uname();
            const info = .{
                .sysname = std.mem.sliceTo(&uts.sysname, 0),
                .release = std.mem.sliceTo(&uts.release, 0),
                .machine = std.mem.sliceTo(&uts.machine, 0),
            };
            return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(info, .{})}) catch return error.BadArgs;
        },
    }
}

fn valueToI64(value: std.json.Value) IpcError!i64 {
    return switch (value) {
        .integer => |v| v,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch return error.BadArgs,
        else => error.BadArgs,
    };
}

fn ipcErrorCode(err: IpcError) c_int {
    return switch (err) {
        error.UnknownCommand => 1,
        error.BadArgs => 2,
    };
}

fn copyToCStr(buf: []u8, text: []const u8) bool {
    if (text.len + 1 > buf.len) return false;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    return true;
}

fn releaseDispatchResult() void {
    if (dispatch_result_cstr) |result| {
        std.heap.page_allocator.free(result);
        dispatch_result_cstr = null;
    }
}

fn storeDispatchResult(text: []const u8) IpcError![*:0]const u8 {
    const result = std.heap.page_allocator.dupeZ(u8, text) catch return error.BadArgs;
    dispatch_result_cstr = result;
    return result.ptr;
}

fn cPtrFromBuffer(buf: []u8) [*:0]const u8 {
    return @ptrCast(buf.ptr);
}
