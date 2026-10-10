//! N12 parser fixture for tools/check_cross_symbols.py: an object that needs
//! one core shim symbol and one symbol no shim defines. `zig build
//! cross-check` compiles it for Windows (COFF) and macOS (Mach-O) and
//! requires the checker to report exactly zb_cross_fixture_probe missing,
//! proving it detects a missing symbol in both formats.
extern fn zb_app_run(uri: [*:0]const u8, print_title: c_int, e2e_protocol: c_int) c_int;
extern fn zb_cross_fixture_probe() void;

export fn zb_cross_fixture_entry() c_int {
    zb_cross_fixture_probe();
    return zb_app_run("about:blank", 0, 0);
}
