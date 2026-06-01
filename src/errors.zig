pub const BrowserError = error{
    Usage,
    InvalidUri,
    UnsupportedScheme,
    DisplayUnavailable,
    GtkInitFailed,
    LoadFailed,
    SnapshotFailed,
    WriteFailed,
    Timeout,
    RuntimeMissing,
    WebViewInitFailed,
    Cancelled,
};

pub const LoadFailure = struct {
    domain: i32,
    code: i32,
    message: []const u8,
};

pub fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.Usage => 1,
        error.InvalidUri, error.UnsupportedScheme => 2,
        error.DisplayUnavailable => 3,
        error.GtkInitFailed => 4,
        error.LoadFailed => 5,
        error.SnapshotFailed => 6,
        error.WriteFailed => 7,
        error.Timeout => 8,
        error.RuntimeMissing => 9,
        error.WebViewInitFailed => 10,
        error.Cancelled => 130,
        else => 1,
    };
}
