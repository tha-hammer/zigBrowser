//! 4pa.62 (Linux shared-parser half) + V03-F14: the parsers both PagePort adapters use for the shim's C ABI answers
//! (window list, dialog list, recovery list, ZB_AUTO_* codes) live in ONE module, src/automation_port_parse.zig, and
//! run here on every Linux gate. Before this, the GTK port held tested copies and the macOS port held untested copies.
//!
//! The samples are the shapes the two shims emit: the macOS shim's NSJSONSerialization output (src/wkwebview_shim.m
//! zb_automation_list_windows / _list_dialogs / _recover: `\/` escapes, `crashed` present only after a crash, keys in
//! any order) and the GTK shim's (`"crashed":null`). The codes come from the real src/webkit_shim.h.
//! The macOS runtime proof of these paths still needs a released Mac run; this proves the shared parse logic only.
const std = @import("std");
const parse = @import("automation_port_parse");
const page_port = parse.page_port;
const c = @cImport({
    @cInclude("webkit_shim.h");
});

const gpa = std.testing.allocator;

test "macOS window list: two windows with stable ids, opener, health and the crash reason" {
    const windows = try parse.parseWindows(gpa,
        \\[{"incident":0,"loading":false,"primary":true,"process_group":1,"url":"https:\/\/a.example\/","load_serial":3,"dialog_open":false,"opener":0,"unresponsive_ms":0,"responsive":true,"title":"A","id":3},
        \\ {"id":7,"url":"https:\/\/b.example\/p?q=1","title":"B \u00e9","primary":false,"opener":3,"dialog_open":true,"responsive":false,"unresponsive_ms":4200,"loading":true,"process_group":1,"load_serial":9,"incident":2,"crashed":"crashed"}]
    );
    defer page_port.freeWindows(gpa, windows);
    try std.testing.expectEqual(@as(usize, 2), windows.len);
    try std.testing.expectEqual(@as(page_port.WindowId, 3), windows[0].id);
    try std.testing.expectEqual(@as(page_port.WindowId, 7), windows[1].id);
    try std.testing.expectEqualStrings("https://a.example/", windows[0].url);
    try std.testing.expectEqualStrings("https://b.example/p?q=1", windows[1].url);
    try std.testing.expectEqualStrings("B \xc3\xa9", windows[1].title);
    try std.testing.expect(windows[0].primary and !windows[1].primary);
    try std.testing.expect(windows[0].opener == null);
    try std.testing.expectEqual(@as(?page_port.WindowId, 3), windows[1].opener);
    try std.testing.expect(windows[0].terminated == null);
    try std.testing.expectEqual(page_port.Termination.crashed, windows[1].terminated.?);
    try std.testing.expect(windows[0].web_process_responsive and !windows[1].web_process_responsive);
    try std.testing.expectEqual(@as(u64, 4200), windows[1].unresponsive_ms);
    try std.testing.expect(windows[1].loading and windows[1].dialog_open);
    try std.testing.expectEqual(@as(u64, 9), windows[1].load_serial);
    try std.testing.expectEqual(@as(u32, 2), windows[1].incident);
    try std.testing.expectEqual(@as(u32, 1), windows[1].process_group);
}

test "GTK window list: crashed null, every termination reason, and defaults for absent health fields" {
    const windows = try parse.parseWindows(gpa,
        \\[{"id":1,"url":"https://a.example/","title":"A","primary":true,"opener":0,"crashed":null},
        \\ {"id":2,"url":"https://b.example/","title":"B","primary":false,"opener":1,"crashed":"crashed"},
        \\ {"id":3,"url":"","title":"","primary":false,"opener":1,"crashed":"memory_limit"},
        \\ {"id":4,"url":"","title":"","primary":false,"opener":0,"crashed":"terminated_by_api"}]
    );
    defer page_port.freeWindows(gpa, windows);
    try std.testing.expectEqual(@as(usize, 4), windows.len);
    try std.testing.expect(windows[0].terminated == null);
    try std.testing.expect(windows[0].opener == null);
    try std.testing.expectEqual(page_port.Termination.crashed, windows[1].terminated.?);
    try std.testing.expectEqual(@as(?page_port.WindowId, 1), windows[1].opener);
    try std.testing.expectEqual(page_port.Termination.memory_limit, windows[2].terminated.?);
    try std.testing.expectEqual(page_port.Termination.terminated_by_api, windows[3].terminated.?);
    try std.testing.expect(windows[0].web_process_responsive);
    try std.testing.expectEqual(@as(u64, 0), windows[0].unresponsive_ms);
    try std.testing.expectEqual(@as(u64, 0), windows[0].load_serial);
}

test "a window list with an unknown crash reason, a missing field or bad JSON is EvalFailed" {
    try std.testing.expectError(error.EvalFailed, parse.parseWindows(gpa,
        \\[{"id":1,"url":"","title":"","primary":true,"opener":0,"crashed":"melted"}]
    ));
    try std.testing.expectError(error.EvalFailed, parse.parseWindows(gpa,
        \\[{"url":"","title":"","primary":true,"opener":0}]
    ));
    try std.testing.expectError(error.EvalFailed, parse.parseWindows(gpa, "[{\"id\":1,"));
    try std.testing.expectError(error.EvalFailed, parse.parseWindows(gpa, "{}"));
    const empty = try parse.parseWindows(gpa, "[]");
    defer page_port.freeWindows(gpa, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "macOS dialog list: the window id, type, message, and default_text only for a prompt" {
    const dialogs = try parse.parseDialogs(gpa,
        \\[{"window":7,"type":"prompt","message":"Name?","default_text":"anon"},{"message":"Leave?","type":"beforeunload","window":3},{"window":4,"type":"alert","message":""}]
    );
    defer page_port.freeDialogs(gpa, dialogs);
    try std.testing.expectEqual(@as(usize, 3), dialogs.len);
    try std.testing.expectEqual(@as(page_port.WindowId, 7), dialogs[0].window);
    try std.testing.expectEqual(page_port.DialogType.prompt, dialogs[0].type);
    try std.testing.expectEqualStrings("Name?", dialogs[0].message);
    try std.testing.expectEqualStrings("anon", dialogs[0].default_text.?);
    try std.testing.expectEqual(@as(page_port.WindowId, 3), dialogs[1].window);
    try std.testing.expectEqual(page_port.DialogType.beforeunload, dialogs[1].type);
    try std.testing.expect(dialogs[1].default_text == null);
    try std.testing.expectEqual(page_port.DialogType.alert, dialogs[2].type);
    try std.testing.expectEqualStrings("", dialogs[2].message);
}

test "a dialog list with an unknown type or bad JSON is EvalFailed" {
    try std.testing.expectError(error.EvalFailed, parse.parseDialogs(gpa, "[{\"window\":1,\"type\":\"toast\",\"message\":\"\"}]"));
    try std.testing.expectError(error.EvalFailed, parse.parseDialogs(gpa, "[{\"type\":\"alert\",\"message\":\"\"}]"));
    try std.testing.expectError(error.EvalFailed, parse.parseDialogs(gpa, "not json"));
}

test "recovery list: each window's id, url, ended and reloaded; a short entry is EvalFailed" {
    const recovered = try parse.parseRecovered(gpa,
        \\[{"id":1,"url":"https:\/\/a.example\/","ended":true,"reloaded":true},
        \\ {"reloaded":false,"ended":false,"url":"https://b.example/","id":3}]
    );
    defer page_port.freeRecovered(gpa, recovered);
    try std.testing.expectEqual(@as(usize, 2), recovered.len);
    try std.testing.expectEqual(@as(page_port.WindowId, 1), recovered[0].id);
    try std.testing.expectEqualStrings("https://a.example/", recovered[0].url);
    try std.testing.expect(recovered[0].ended and recovered[0].reloaded);
    try std.testing.expectEqual(@as(page_port.WindowId, 3), recovered[1].id);
    try std.testing.expect(!recovered[1].ended and !recovered[1].reloaded);
    try std.testing.expectError(error.EvalFailed, parse.parseRecovered(gpa, "[{\"id\":1}]"));
}

test "every parser frees what it built when an allocation fails" {
    const Run = struct {
        fn windows(a: std.mem.Allocator) !void {
            page_port.freeWindows(a, try parse.parseWindows(a,
                \\[{"id":1,"url":"u1","title":"t1","primary":true,"opener":0},{"id":2,"url":"u2","title":"t2","primary":false,"opener":1,"crashed":"crashed"}]
            ));
        }
        fn dialogs(a: std.mem.Allocator) !void {
            page_port.freeDialogs(a, try parse.parseDialogs(a,
                \\[{"window":1,"type":"prompt","message":"m","default_text":"d"},{"window":2,"type":"alert","message":"n"}]
            ));
        }
        fn recovered(a: std.mem.Allocator) !void {
            page_port.freeRecovered(a, try parse.parseRecovered(a,
                \\[{"id":1,"url":"u1","ended":true,"reloaded":false},{"id":2,"url":"u2","ended":false,"reloaded":true}]
            ));
        }
    };
    try std.testing.checkAllAllocationFailures(gpa, Run.windows, .{});
    try std.testing.checkAllAllocationFailures(gpa, Run.dialogs, .{});
    try std.testing.checkAllAllocationFailures(gpa, Run.recovered, .{});
}

test "every ZB_AUTO_* code of webkit_shim.h maps to its PortError; an unknown code is EvalFailed" {
    try parse.mapCode(c.ZB_AUTO_OK);
    try std.testing.expectError(error.Timeout, parse.mapCode(c.ZB_AUTO_ERR_TIMEOUT));
    try std.testing.expectError(error.NoPage, parse.mapCode(c.ZB_AUTO_ERR_NO_WINDOW));
    try std.testing.expectError(error.NavigationFailed, parse.mapCode(c.ZB_AUTO_ERR_NAV_FAILED));
    try std.testing.expectError(error.Cancelled, parse.mapCode(c.ZB_AUTO_ERR_NO_LOOP));
    try std.testing.expectError(error.Cancelled, parse.mapCode(c.ZB_AUTO_ERR_CANCELLED));
    try std.testing.expectError(error.DocumentChanged, parse.mapCode(c.ZB_AUTO_ERR_DOC_CHANGED));
    try std.testing.expectError(error.DialogOpen, parse.mapCode(c.ZB_AUTO_ERR_DIALOG_OPEN));
    try std.testing.expectError(error.NoDialog, parse.mapCode(c.ZB_AUTO_ERR_NO_DIALOG));
    try std.testing.expectError(error.BeforeUnloadDismissed, parse.mapCode(c.ZB_AUTO_ERR_DIALOG_DISMISSED));
    try std.testing.expectError(error.EvalFailed, parse.mapCode(c.ZB_AUTO_ERR_JS));
    try std.testing.expectError(error.EvalFailed, parse.mapCode(c.ZB_AUTO_ERR_INTERNAL));
    // File, screenshot-size and files-unconfirmed codes have their own map in the native-input paths.
    try std.testing.expectError(error.EvalFailed, parse.mapCode(c.ZB_AUTO_ERR_BAD_FILE));
    try std.testing.expectError(error.EvalFailed, parse.mapCode(c.ZB_AUTO_ERR_FILES_UNCONFIRMED));
    try std.testing.expectError(error.EvalFailed, parse.mapCode(c.ZB_AUTO_ERR_TOO_LARGE));
    try std.testing.expectError(error.EvalFailed, parse.mapCode(-3));
    try std.testing.expectError(error.EvalFailed, parse.mapCode(999));
}
