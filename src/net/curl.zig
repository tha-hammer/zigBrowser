const std = @import("std");
const errors = @import("../errors.zig");
const c = @import("c.zig").c;

pub const NetError = errors.NetError;

pub const CurlHandle = struct {
    handle: ?*c.CURL,

    pub fn init() NetError!CurlHandle {
        const handle = c.curl_easy_init() orelse return error.TlsError;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *CurlHandle) void {
        if (self.handle) |h| {
            c.curl_easy_cleanup(h);
            self.handle = null;
        }
    }
};

test "libcurl links: version non-empty" {
    const version_ptr = c.curl_version();
    try std.testing.expect(version_ptr != null);
    const version = std.mem.span(version_ptr);
    try std.testing.expect(version.len > 0);
}

test "CurlHandle.init returns non-null handle" {
    var handle = try CurlHandle.init();
    defer handle.deinit();
    try std.testing.expect(handle.handle != null);
}
