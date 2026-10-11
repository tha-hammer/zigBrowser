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
    /// Native input WAS dispatched to the expected document, and then the
    /// document was replaced (or was leaving) before the operation could
    /// finish (e.g. before nativeScroll's settled offsets were read). Never
    /// retried; no result from the replacement document is ever returned.
    DocumentReplaced,
    /// v3.3 setInputFiles: a path is not an absolute, readable regular
    /// file (or there are too many). Checked before anything runs.
    BadFile,
    /// v3.3 setInputFiles: the files were chosen but the page did not
    /// confirm before the deadline. They were applied once: never retried.
    FilesUnconfirmed,
    /// v3.4 screenshot: the encoded PNG is over max_screenshot_bytes;
    /// nothing is returned.
    TooLarge,
    /// v3.6: a page dialog is open on the window (it was before the call,
    /// or the call's own load raised one): the call stopped and left the
    /// dialog open. listDialogs shows it; respondDialog answers it.
    DialogOpen,
    /// v3.6 respondDialog: the window has no open dialog.
    NoDialog,
    /// v3.6 navigateWithPolicy(.dismiss): the beforeunload prompt was
    /// dismissed, so the page stayed.
    BeforeUnloadDismissed,
};

/// A viewport point in CSS px (native input, pointer cache).
pub const Point = struct { x: f64, y: f64 };

/// The page's scrollX/scrollY in CSS px (v3.3 nativeScroll).
pub const ScrollOffsets = struct { x: f64, y: f64 };

/// v3.4 screenshot: PNG bytes (owned by the `gpa` passed in) and size in
/// device pixels.
pub const Screenshot = struct { png: []u8, width: u32, height: u32 };

/// Largest encoded PNG a screenshot may return (else error.TooLarge).
pub const max_screenshot_bytes: usize = 16 * 1024 * 1024;

/// v3.5 (N23): a browser window's id, stable for the window's life and
/// never reused within a run. The first window is 1.
pub const WindowId = u32;

/// v3.5 listWindows entry; `url` and `title` are owned by the `gpa` passed
/// to listWindows (see freeWindows).
pub const WindowInfo = struct {
    id: WindowId,
    url: []u8,
    title: []u8,
    primary: bool,
    /// The window whose page opened this one (a popup), if any.
    opener: ?WindowId = null,
};

/// v3.6: the kinds of page dialog.
pub const DialogType = enum { alert, confirm, prompt, beforeunload };

/// v3.6: an open page dialog. `message` and `default_text` are owned by the
/// `gpa` passed to listDialogs (see freeDialogs).
pub const DialogInfo = struct {
    window: WindowId,
    type: DialogType,
    message: []u8,
    /// Prompts only: the text the field starts with.
    default_text: ?[]u8 = null,
};

pub fn freeDialogs(gpa: std.mem.Allocator, dialogs: []DialogInfo) void {
    for (dialogs) |d| {
        gpa.free(d.message);
        if (d.default_text) |text| gpa.free(text);
    }
    gpa.free(dialogs);
}

/// v3.6: what a navigation does when the page asks "Leave site?"
/// (beforeunload). `fail` returns DialogOpen as soon as the prompt opens and
/// leaves it open; `accept` leaves the page; `dismiss` stays
/// (BeforeUnloadDismissed).
pub const BeforeUnload = enum { fail, accept, dismiss };

pub fn freeWindows(gpa: std.mem.Allocator, windows: []WindowInfo) void {
    for (windows) |w| {
        gpa.free(w.url);
        gpa.free(w.title);
    }
    gpa.free(windows);
}

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

        // --- v3.2 (N8 humanize) ---

        /// One real pointer-motion event to viewport CSS px, guarded by
        /// `document` like nativeClick (DocumentChanged: nothing sent). No
        /// click, no ack. Updates the window's pointer cache once dispatched.
        nativeMove: *const fn (ptr: *anyopaque, x: f64, y: f64, document: ?[]const u8, timeout_ms: u64) PortError!void = unsupportedMove,
        /// Last pointer position actually dispatched to this window (a move
        /// or a click), or null if none yet. Reads a cache only: no page
        /// call, no deadline.
        pointer: *const fn (ptr: *anyopaque) ?Point = unknownPointer,

        // --- v3.3 (N17 files, N18 scroll) ---

        /// Run `function_body` with `arg_json` in the automation world (like
        /// evalJson); the automation.js `chooseFiles` op it runs clicks the
        /// file input, and the backend answers the file chooser that click
        /// opens with `paths`. Returns the op's JSON answer verbatim: when
        /// the op refuses, nothing was clicked. Paths that are not
        /// absolute, readable regular files: error.BadFile, nothing run.
        /// Chosen but unconfirmed by the deadline: error.FilesUnconfirmed
        /// (applied once; never call again for the same command).
        setInputFiles: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, function_body: []const u8, arg_json: []const u8, paths: []const []const u8, timeout_ms: u64) PortError![]u8 = unsupportedFiles,
        /// One real smooth-scroll (wheel) event at viewport CSS px (x, y),
        /// by (delta_x, delta_y) CSS px (positive = right/down), guarded by
        /// `document` like nativeMove (DocumentChanged: nothing sent).
        /// Returns once the page acknowledged the trusted wheel and the
        /// scrolling it started went quiet, with the page's offsets at that
        /// moment. Once dispatched it is never retried: a document change
        /// after dispatch is error.DocumentReplaced (never the new
        /// document's offsets).
        nativeScroll: *const fn (ptr: *anyopaque, x: f64, y: f64, delta_x: f64, delta_y: f64, document: ?[]const u8, timeout_ms: u64) PortError!ScrollOffsets = unsupportedScroll,

        // --- v3.4 (N19) ---

        /// PNG of the visible viewport (`full_page`: the whole document),
        /// bounded by the deadline. Over max_screenshot_bytes:
        /// error.TooLarge, nothing returned.
        screenshot: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, full_page: bool, timeout_ms: u64) PortError!Screenshot = unsupportedScreenshot,

        // --- v3.5 (N23 window targeting) ---

        /// Every open window, primary first (see WindowInfo, freeWindows).
        listWindows: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, timeout_ms: u64) PortError![]WindowInfo = unsupportedList,
        /// A PagePort whose every call goes to window `id`. A pure,
        /// non-blocking handle constructor (no page work, no deadline): it
        /// may accept an id with no window; the handle's first bounded call
        /// then fails with NoPage, as do all its calls once that window
        /// closes. Calls never fall through to another window. Unsupported
        /// without window support.
        forWindow: *const fn (ptr: *anyopaque, id: WindowId) PortError!PagePort = unsupportedFor,
        /// Closes window `id`; returns once it is destroyed. NoPage if
        /// there is no such window.
        closeWindow: *const fn (ptr: *anyopaque, id: WindowId, timeout_ms: u64) PortError!void = unsupportedClose,

        // --- v3.6 page dialogs ---

        /// navigate with an explicit beforeunload policy (see
        /// BeforeUnload). A window that already shows a dialog is
        /// DialogOpen at once, and so is any other dialog that opens during
        /// the load. Null: the backend has no dialogs; `navigate` is used.
        navigateWithPolicy: ?*const fn (ptr: *anyopaque, url: []const u8, before_unload: BeforeUnload, timeout_ms: u64) PortError!void = null,
        /// Every open page dialog, the primary window's first (see
        /// DialogInfo, freeDialogs). Not tied to this handle's window.
        /// Never waits for a page load: a dialog can be what blocks it.
        listDialogs: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, timeout_ms: u64) PortError![]DialogInfo = unsupportedDialogs,
        /// Answers window `id`'s dialog: accept = OK / Leave, else Cancel /
        /// Stay; `text` answers an accepted prompt (null = its default).
        /// NoPage without that window, NoDialog when it has none.
        respondDialog: *const fn (ptr: *anyopaque, id: WindowId, accept: bool, text: ?[]const u8, timeout_ms: u64) PortError!void = unsupportedRespond,

        // --- v3.7 pointer settle ---

        /// Returns once the page has received the last nativeMove (or its
        /// document changed): a move answers when dispatched, and a backend
        /// may hold it behind earlier mouse events while page evaluations
        /// overtake it. A command that ends with a move (a native hover)
        /// calls this before answering. `document` as in nativeMove. Null:
        /// moves reach the page in order with everything else.
        settlePointer: ?*const fn (ptr: *anyopaque, document: ?[]const u8, timeout_ms: u64) PortError!void = null,
    };

    pub fn evalJson(self: PagePort, gpa: std.mem.Allocator, world: World, function_body: []const u8, arg_json: []const u8, timeout_ms: u64) PortError![]u8 {
        return self.vtable.evalJson(self.ptr, gpa, world, function_body, arg_json, timeout_ms);
    }

    pub fn navigate(self: PagePort, url_text: []const u8, timeout_ms: u64) PortError!void {
        return self.vtable.navigate(self.ptr, url_text, timeout_ms);
    }

    /// navigate with a beforeunload policy; a backend without dialogs
    /// ignores the policy (it never shows one).
    pub fn navigateWithPolicy(self: PagePort, url_text: []const u8, before_unload: BeforeUnload, timeout_ms: u64) PortError!void {
        const guarded = self.vtable.navigateWithPolicy orelse return self.vtable.navigate(self.ptr, url_text, timeout_ms);
        return guarded(self.ptr, url_text, before_unload, timeout_ms);
    }

    /// v3.7: wait until the page received the last pointer move (no-op
    /// on a backend without settlePointer).
    pub fn settlePointer(self: PagePort, document: ?[]const u8, timeout_ms: u64) PortError!void {
        const settle = self.vtable.settlePointer orelse return;
        return settle(self.ptr, document, timeout_ms);
    }

    pub fn listDialogs(self: PagePort, gpa: std.mem.Allocator, timeout_ms: u64) PortError![]DialogInfo {
        return self.vtable.listDialogs(self.ptr, gpa, timeout_ms);
    }

    pub fn respondDialog(self: PagePort, id: WindowId, accept: bool, text: ?[]const u8, timeout_ms: u64) PortError!void {
        return self.vtable.respondDialog(self.ptr, id, accept, text, timeout_ms);
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

    /// False when the backend has no pointer motion (v3.2 nativeMove left
    /// at its Unsupported default).
    pub fn supportsNativeMove(self: PagePort) bool {
        return self.supportsNativeInput() and self.vtable.nativeMove != &unsupportedMove;
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

    pub fn nativeMove(self: PagePort, x: f64, y: f64, document: ?[]const u8, timeout_ms: u64) PortError!void {
        return self.vtable.nativeMove(self.ptr, x, y, document, timeout_ms);
    }

    pub fn pointer(self: PagePort) ?Point {
        return self.vtable.pointer(self.ptr);
    }

    /// False when the backend cannot scroll with real wheel events.
    pub fn supportsNativeScroll(self: PagePort) bool {
        return self.supportsNativeInput() and self.vtable.nativeScroll != &unsupportedScroll;
    }

    pub fn setInputFiles(self: PagePort, gpa: std.mem.Allocator, function_body: []const u8, arg_json: []const u8, paths: []const []const u8, timeout_ms: u64) PortError![]u8 {
        return self.vtable.setInputFiles(self.ptr, gpa, function_body, arg_json, paths, timeout_ms);
    }

    pub fn nativeScroll(self: PagePort, x: f64, y: f64, delta_x: f64, delta_y: f64, document: ?[]const u8, timeout_ms: u64) PortError!ScrollOffsets {
        return self.vtable.nativeScroll(self.ptr, x, y, delta_x, delta_y, document, timeout_ms);
    }

    pub fn screenshot(self: PagePort, gpa: std.mem.Allocator, full_page: bool, timeout_ms: u64) PortError!Screenshot {
        return self.vtable.screenshot(self.ptr, gpa, full_page, timeout_ms);
    }

    pub fn listWindows(self: PagePort, gpa: std.mem.Allocator, timeout_ms: u64) PortError![]WindowInfo {
        return self.vtable.listWindows(self.ptr, gpa, timeout_ms);
    }

    pub fn forWindow(self: PagePort, id: WindowId) PortError!PagePort {
        return self.vtable.forWindow(self.ptr, id);
    }

    pub fn closeWindow(self: PagePort, id: WindowId, timeout_ms: u64) PortError!void {
        return self.vtable.closeWindow(self.ptr, id, timeout_ms);
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
fn unsupportedMove(_: *anyopaque, _: f64, _: f64, _: ?[]const u8, _: u64) PortError!void {
    return error.Unsupported;
}
fn unknownPointer(_: *anyopaque) ?Point {
    return null;
}
fn unsupportedFiles(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const []const u8, _: u64) PortError![]u8 {
    return error.Unsupported;
}
fn unsupportedScroll(_: *anyopaque, _: f64, _: f64, _: f64, _: f64, _: ?[]const u8, _: u64) PortError!ScrollOffsets {
    return error.Unsupported;
}
fn unsupportedScreenshot(_: *anyopaque, _: std.mem.Allocator, _: bool, _: u64) PortError!Screenshot {
    return error.Unsupported;
}
fn unsupportedList(_: *anyopaque, _: std.mem.Allocator, _: u64) PortError![]WindowInfo {
    return error.Unsupported;
}
fn unsupportedFor(_: *anyopaque, _: WindowId) PortError!PagePort {
    return error.Unsupported;
}
fn unsupportedClose(_: *anyopaque, _: WindowId, _: u64) PortError!void {
    return error.Unsupported;
}
fn unsupportedDialogs(_: *anyopaque, _: std.mem.Allocator, _: u64) PortError![]DialogInfo {
    return error.Unsupported;
}
fn unsupportedRespond(_: *anyopaque, _: WindowId, _: bool, _: ?[]const u8, _: u64) PortError!void {
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
    .nativeMove = unsupportedMove,
    .pointer = unknownPointer,
    .setInputFiles = unsupportedFiles,
    .nativeScroll = unsupportedScroll,
    .screenshot = unsupportedScreenshot,
    .listWindows = unsupportedList,
    .forWindow = unsupportedFor,
    .closeWindow = unsupportedClose,
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
