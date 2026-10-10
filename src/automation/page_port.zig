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
//!   (an idle GSource on the GTK context + GMutex/GCond) and never touch GTK objects
//!   on the calling thread.
//! - Input slices are only borrowed for the duration of the call: native code
//!   copies anything it queues, and never keeps a Zig pointer after returning
//!   (including on timeout). Results live in native memory until the calling
//!   thread duplicates them into the `gpa` passed in; the caller owns that copy.
//!   No Zig allocator is ever used on the GTK thread.
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
    /// The backend cannot do this at all (e.g. native input on a platform
    /// without a GDK shim). Never retried.
    Unsupported,
    /// Native input: the page's document is not (or no longer) the one
    /// `document` names. Before any dispatch nothing was sent; for
    /// nativeText `sent_chars` says how many code points were.
    DocumentChanged,
};

/// Native key modifier bits (PagePort.nativeKey).
pub const modifier_shift: u8 = 1 << 0;
pub const modifier_control: u8 = 1 << 1;
pub const modifier_alt: u8 = 1 << 2;
pub const modifier_meta: u8 = 1 << 3;

pub const PagePort = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Run `function_body` as the body of an async JS function in `world`
        /// (WebKitGTK: webkit_web_view_call_async_javascript_function, so
        /// `await` is allowed and a returned Promise is awaited). `arg_json`
        /// is bound to the JS variable `arg` as a string (the body calls
        /// `JSON.parse(arg)`), so command data is never spliced into source.
        /// The body always returns a string (JSON text); the port returns
        /// those bytes verbatim, allocated with `gpa`.
        evalJson: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, world: World, function_body: []const u8, arg_json: []const u8, timeout_ms: u64) PortError![]u8,
        /// Load `url` and block until the load finishes (load-changed
        /// FINISHED) or fails (load-failed -> NavigationFailed).
        navigate: *const fn (ptr: *anyopaque, url: []const u8, timeout_ms: u64) PortError!void,
        /// Reload the current page and block until the load finishes/fails.
        reload: *const fn (ptr: *anyopaque, timeout_ms: u64) PortError!void,
        /// Current committed URI ("" if none). Like every op except
        /// navigate, it first waits (within `timeout_ms`) for the primary
        /// window's first load to finish; the engine relies on this as a
        /// readiness barrier before dom.waitFor.
        url: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, timeout_ms: u64) PortError![]u8,
        /// Current document title ("" if none).
        title: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, timeout_ms: u64) PortError![]u8,

        // --- v3.1: native (trusted) input. Backends without it keep the
        // defaults, which return error.Unsupported. ---
        //
        // `document` is the token the automation.js `locate` op returned
        // for the target's document (16 lowercase hex). When non-null, the
        // backend compares it and delivers the input as ONE non-yielding
        // operation on the UI thread, atomic against timeout/abandonment:
        // on a mismatch it returns DocumentChanged and sends nothing. It is
        // null only for dom.press without a selector (a key to whatever has
        // focus). A document change caused by the input itself (link click,
        // Enter that submits) is success for click and key.

        /// Real pointer motion + left click at viewport CSS px. Returns once
        /// the page acknowledged the trusted click, or Timeout. Once input
        /// was dispatched it is never retried.
        nativeClick: *const fn (ptr: *anyopaque, x: f64, y: f64, document: ?[]const u8, timeout_ms: u64) PortError!void = unsupportedClick,
        /// One key (DOM key name, or one code point) with `modifier_*` bits.
        /// Returns after the trusted keyups are acknowledged.
        nativeKey: *const fn (ptr: *anyopaque, key: []const u8, modifiers: u8, document: ?[]const u8, timeout_ms: u64) PortError!void = unsupportedKey,
        /// Types `text` with real key events, one code point at a time.
        /// `sent_chars` is ALWAYS set, also on error: code points
        /// dispatched. An error with sent_chars > 0 is a partial side
        /// effect; never retype the prefix. As soon as a character's
        /// acknowledgement shows a new document, it stops and returns
        /// DocumentChanged (even when every requested code point was sent).
        nativeText: *const fn (ptr: *anyopaque, text: []const u8, document: ?[]const u8, timeout_ms: u64, sent_chars: *usize) PortError!void = unsupportedText,
    };

    pub fn evalJson(self: PagePort, gpa: std.mem.Allocator, world: World, function_body: []const u8, arg_json: []const u8, timeout_ms: u64) PortError![]u8 {
        return self.vtable.evalJson(self.ptr, gpa, world, function_body, arg_json, timeout_ms);
    }

    pub fn navigate(self: PagePort, url_text: []const u8, timeout_ms: u64) PortError!void {
        return self.vtable.navigate(self.ptr, url_text, timeout_ms);
    }

    pub fn reload(self: PagePort, timeout_ms: u64) PortError!void {
        return self.vtable.reload(self.ptr, timeout_ms);
    }

    pub fn url(self: PagePort, gpa: std.mem.Allocator, timeout_ms: u64) PortError![]u8 {
        return self.vtable.url(self.ptr, gpa, timeout_ms);
    }

    pub fn title(self: PagePort, gpa: std.mem.Allocator, timeout_ms: u64) PortError![]u8 {
        return self.vtable.title(self.ptr, gpa, timeout_ms);
    }

    /// False when this backend has no native input at all (the vtable kept
    /// the Unsupported defaults, or this is `no_page`).
    pub fn supportsNativeInput(self: PagePort) bool {
        return self.vtable.nativeClick != &unsupportedClick and self.vtable.nativeClick != &noPageClick;
    }

    pub fn nativeClick(self: PagePort, x: f64, y: f64, document: ?[]const u8, timeout_ms: u64) PortError!void {
        return self.vtable.nativeClick(self.ptr, x, y, document, timeout_ms);
    }

    pub fn nativeKey(self: PagePort, key: []const u8, modifiers: u8, document: ?[]const u8, timeout_ms: u64) PortError!void {
        return self.vtable.nativeKey(self.ptr, key, modifiers, document, timeout_ms);
    }

    pub fn nativeText(self: PagePort, text: []const u8, document: ?[]const u8, timeout_ms: u64, sent_chars: *usize) PortError!void {
        sent_chars.* = 0;
        return self.vtable.nativeText(self.ptr, text, document, timeout_ms, sent_chars);
    }
};

fn unsupportedClick(_: *anyopaque, _: f64, _: f64, _: ?[]const u8, _: u64) PortError!void {
    return error.Unsupported;
}
fn unsupportedKey(_: *anyopaque, _: []const u8, _: u8, _: ?[]const u8, _: u64) PortError!void {
    return error.Unsupported;
}
fn unsupportedText(_: *anyopaque, _: []const u8, _: ?[]const u8, _: u64, sent_chars: *usize) PortError!void {
    sent_chars.* = 0;
    return error.Unsupported;
}

/// Port for a server with no page attached (a backend without a PagePort,
/// e.g. WebView2/WKWebView today): page operations fail with
/// `error.NoPage` and native input with `error.Unsupported` (both
/// session_invalid; the latter with reason "unsupported"), so such commands
/// still run through the engine and get ids and a root span.
pub const no_page: PagePort = .{ .ptr = @constCast(&no_page_state), .vtable = &no_page_vtable };

var no_page_state: u8 = 0;

const no_page_vtable = PagePort.VTable{
    .evalJson = noPageEval,
    .navigate = noPageNavigate,
    .reload = noPageReload,
    .url = noPageRead,
    .title = noPageRead,
    .nativeClick = noPageClick,
    .nativeKey = noPageKey,
    .nativeText = noPageText,
};

fn noPageEval(_: *anyopaque, _: std.mem.Allocator, _: World, _: []const u8, _: []const u8, _: u64) PortError![]u8 {
    return error.NoPage;
}
fn noPageNavigate(_: *anyopaque, _: []const u8, _: u64) PortError!void {
    return error.NoPage;
}
fn noPageReload(_: *anyopaque, _: u64) PortError!void {
    return error.NoPage;
}
fn noPageRead(_: *anyopaque, _: std.mem.Allocator, _: u64) PortError![]u8 {
    return error.NoPage;
}
fn noPageClick(_: *anyopaque, _: f64, _: f64, _: ?[]const u8, _: u64) PortError!void {
    return error.Unsupported;
}
fn noPageKey(_: *anyopaque, _: []const u8, _: u8, _: ?[]const u8, _: u64) PortError!void {
    return error.Unsupported;
}
fn noPageText(_: *anyopaque, _: []const u8, _: ?[]const u8, _: u64, sent_chars: *usize) PortError!void {
    sent_chars.* = 0;
    return error.Unsupported;
}
