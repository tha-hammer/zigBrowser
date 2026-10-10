//! CookiePort: the seam between the cookies.* routes and the browser's cookie
//! store (WebKitCookieManager on GTK). Same threading/ownership contract as
//! PagePort: called from a non-GTK thread, blocks until done or `timeout_ms`,
//! inputs are borrowed, results are duplicated into `gpa`.
//!
//! Cookie JSON shape (one object), used in both directions:
//!   {name, value, domain, path, expires (unix seconds, -1 = session),
//!    httpOnly, secure, sameSite? ("Lax"|"Strict"|"None")}
//! Implementations must never log or report cookie values.
const std = @import("std");
const page_port = @import("page_port.zig");

pub const PortError = page_port.PortError;

pub const CookiePort = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// JSON array of cookie objects. `url` null = every cookie in the
        /// store; otherwise the cookies that would be sent to `url`.
        getAll: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, url: ?[]const u8, timeout_ms: u64) PortError![]u8,
        /// Add or replace one cookie (`cookie_json` is one object, already
        /// validated and normalized by the caller).
        set: *const fn (ptr: *anyopaque, cookie_json: []const u8, timeout_ms: u64) PortError!void,
        /// Delete cookies named `name` on `domain`; `domain` null = on every
        /// domain. Deleting nothing is not an error.
        delete: *const fn (ptr: *anyopaque, name: []const u8, domain: ?[]const u8, timeout_ms: u64) PortError!void,
    };

    pub fn getAll(self: CookiePort, gpa: std.mem.Allocator, url: ?[]const u8, timeout_ms: u64) PortError![]u8 {
        return self.vtable.getAll(self.ptr, gpa, url, timeout_ms);
    }

    pub fn set(self: CookiePort, cookie_json: []const u8, timeout_ms: u64) PortError!void {
        return self.vtable.set(self.ptr, cookie_json, timeout_ms);
    }

    pub fn delete(self: CookiePort, name: []const u8, domain: ?[]const u8, timeout_ms: u64) PortError!void {
        return self.vtable.delete(self.ptr, name, domain, timeout_ms);
    }
};
