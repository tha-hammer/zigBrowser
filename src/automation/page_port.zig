//! PagePort: the seam between the Zig automation engine and a live page.
//!
//! The engine (router mapping, retry loop, queue, telemetry) only talks to a
//! page through this vtable. Platform shims (GTK/WebKitGTK today) implement it;
//! tests use `FakePagePort` from tests/.
//!
//! Threading contract (for native implementations):
//! - Every vtable function is called from a NON-GTK thread (the automation
//!   server thread) and BLOCKS until the page work completes or `timeout_ms`
//!   elapses. Implementations marshal to the GTK main context themselves
//!   (e.g. g_main_context_invoke + GMutex/GCond) and never touch GTK objects
//!   on the calling thread.
//! - Returned slices are allocated with the `gpa` passed in and owned by the
//!   caller.
//! - If no page/view exists yet (the server starts before the window), the
//!   implementation waits for one up to `timeout_ms`, then returns
//!   `error.NoPage`.
const std = @import("std");

/// JS world a script runs in.
/// - `automation`: the isolated world where automation.js is injected at
///   document start (script world name `automation_world_name`).
/// - `page`: the page's main world (used for page.evaluate).
pub const World = enum { automation, page };

pub const automation_world_name = "zigbrowser-automation";

pub const PortError = error{
    /// No WebView/page exists (yet) and none appeared before the deadline.
    NoPage,
    /// The deadline expired before the native operation completed.
    Timeout,
    /// The navigation/reload failed (load-failed, bad URI, ...).
    NavigationFailed,
    /// The native eval call itself failed (not a JS exception: the engine
    /// wraps every body in try/catch so JS exceptions come back as JSON).
    EvalFailed,
    Cancelled,
    OutOfMemory,
};

pub const PagePort = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Run `function_body` as the body of an async JS function in `world`
        /// (WebKitGTK: webkit_web_view_call_async_javascript_function, so
        /// `await` is allowed and a returned Promise is awaited). The body
        /// always returns a string (JSON text); the port returns those bytes
        /// verbatim, allocated with `gpa`.
        evalJson: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, world: World, function_body: []const u8, timeout_ms: u64) PortError![]u8,
        /// Load `url` and block until the load finishes (load-changed
        /// FINISHED) or fails (load-failed -> NavigationFailed).
        navigate: *const fn (ptr: *anyopaque, url: []const u8, timeout_ms: u64) PortError!void,
        /// Reload the current page and block until the load finishes/fails.
        reload: *const fn (ptr: *anyopaque, timeout_ms: u64) PortError!void,
        /// Current committed URI ("" if none).
        url: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) PortError![]u8,
        /// Current document title ("" if none).
        title: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) PortError![]u8,
    };

    pub fn evalJson(self: PagePort, gpa: std.mem.Allocator, world: World, function_body: []const u8, timeout_ms: u64) PortError![]u8 {
        return self.vtable.evalJson(self.ptr, gpa, world, function_body, timeout_ms);
    }

    pub fn navigate(self: PagePort, url_text: []const u8, timeout_ms: u64) PortError!void {
        return self.vtable.navigate(self.ptr, url_text, timeout_ms);
    }

    pub fn reload(self: PagePort, timeout_ms: u64) PortError!void {
        return self.vtable.reload(self.ptr, timeout_ms);
    }

    pub fn url(self: PagePort, gpa: std.mem.Allocator) PortError![]u8 {
        return self.vtable.url(self.ptr, gpa);
    }

    pub fn title(self: PagePort, gpa: std.mem.Allocator) PortError![]u8 {
        return self.vtable.title(self.ptr, gpa);
    }
};
