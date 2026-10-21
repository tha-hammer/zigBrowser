const std = @import("std");
const config_schema = @import("src/config_schema.zig");

const Backend = enum {
    gtk_backend,
    webview2_backend,
    macos_backend,
};

const WebView2Paths = struct {
    include_dir: ?[]const u8,
    winrt_include_dir: ?[]const u8,
    lib_dir: ?[]const u8,
};

const CheckWebView2SdkStep = struct {
    step: std.Build.Step,
    include_dir: ?[]const u8,
    winrt_include_dir: ?[]const u8,
    lib_dir: ?[]const u8,

    fn create(b: *std.Build, paths: WebView2Paths) *CheckWebView2SdkStep {
        const self = b.allocator.create(CheckWebView2SdkStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "check WebView2 SDK",
                .owner = b,
                .makeFn = make,
            }),
            .include_dir = paths.include_dir,
            .winrt_include_dir = paths.winrt_include_dir,
            .lib_dir = paths.lib_dir,
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const self: *CheckWebView2SdkStep = @fieldParentPtr("step", step);

        const include_dir = self.include_dir orelse {
            try fail(step, "missing WebView2 include directory; pass -Dwebview2_include=<dir> or set WEBVIEW2_INCLUDE");
            return error.MakeFailed;
        };
        const lib_dir = self.lib_dir orelse {
            try fail(step, "missing WebView2 library directory; pass -Dwebview2_lib=<dir> or set WEBVIEW2_LIB");
            return error.MakeFailed;
        };
        const winrt_include_dir = self.winrt_include_dir orelse {
            try fail(step, "missing WinRT include directory; pass -Dwinrt_include=<dir> or set WINRT_INCLUDE");
            return error.MakeFailed;
        };

        const header_path = step.owner.fmt("{s}/WebView2.h", .{include_dir});
        std.Io.Dir.cwd().access(step.owner.graph.io, header_path, .{}) catch {
            try fail(step, step.owner.fmt("missing WebView2.h at {s}", .{header_path}));
            return error.MakeFailed;
        };

        const loader_path = step.owner.fmt("{s}/WebView2LoaderStatic.lib", .{lib_dir});
        std.Io.Dir.cwd().access(step.owner.graph.io, loader_path, .{}) catch {
            try fail(step, step.owner.fmt("missing WebView2LoaderStatic.lib at {s}", .{loader_path}));
            return error.MakeFailed;
        };

        const wrl_path = step.owner.fmt("{s}/wrl.h", .{winrt_include_dir});
        std.Io.Dir.cwd().access(step.owner.graph.io, wrl_path, .{}) catch {
            try fail(step, step.owner.fmt("missing wrl.h at {s}", .{wrl_path}));
            return error.MakeFailed;
        };
    }

    fn fail(step: *std.Build.Step, message: []const u8) !void {
        try step.result_error_msgs.append(step.owner.allocator, message);
    }
};

const CheckMacosBackendStep = struct {
    step: std.Build.Step,

    fn create(b: *std.Build) *CheckMacosBackendStep {
        const self = b.allocator.create(CheckMacosBackendStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "check macOS WKWebView backend",
                .owner = b,
                .makeFn = make,
            }),
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        std.Io.Dir.cwd().access(step.owner.graph.io, "src/wkwebview_shim.m", .{}) catch {
            try step.result_error_msgs.append(
                step.owner.allocator,
                "missing wkwebview_shim.m at src/wkwebview_shim.m; macOS backend selected but the WKWebView shim has not landed",
            );
            return error.MakeFailed;
        };
    }
};

/// WS2.0: std.Io.net turns AF_UNIX on for Windows only when the target's minimum is Windows 10 1803
/// (`win10_rs4`) or later. A plain `-Dtarget=x86_64-windows-msvc` starts its range lower, so
/// `has_unix_sockets` was false and `--automation-api` exited 7 (AddressFamilyUnsupported) before it
/// wrote a token or bound a socket. A Windows target without an explicit minimum gets that floor.
fn windowsAfUnixFloor(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    if (target.result.os.tag != .windows or target.query.os_version_min != null) return target;
    var query = target.query;
    query.os_version_min = .{ .windows = .win10_rs4 };
    return b.resolveTargetQuery(query);
}

pub fn build(b: *std.Build) void {
    const target = windowsAfUnixFloor(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const backend = resolveBackend(target);
    const webview2_include = b.option(
        []const u8,
        "webview2_include",
        "Directory containing WebView2.h (or set WEBVIEW2_INCLUDE)",
    );
    const webview2_lib = b.option(
        []const u8,
        "webview2_lib",
        "Directory containing WebView2LoaderStatic.lib (or set WEBVIEW2_LIB)",
    );
    const winrt_include = b.option(
        []const u8,
        "winrt_include",
        "Directory containing wrl.h (or set WINRT_INCLUDE)",
    );
    const webview2_paths: WebView2Paths = .{
        .include_dir = webview2_include orelse b.graph.environ_map.get("WEBVIEW2_INCLUDE"),
        .winrt_include_dir = winrt_include orelse b.graph.environ_map.get("WINRT_INCLUDE"),
        .lib_dir = webview2_lib orelse b.graph.environ_map.get("WEBVIEW2_LIB"),
    };
    const site_config_path = b.option(
        []const u8,
        "site_config",
        "Path to zigBrowser JSON site config (default: zigbrowser.json)",
    ) orelse "zigbrowser.json";
    const site_config = loadSiteConfig(b, site_config_path);
    const site_options = b.addOptions();
    site_options.addOption([]const u8, "default_url", site_config.url);
    site_options.addOption([]const u8, "config_path", site_config_path);
    const site_options_module = site_options.createModule();

    const pkg_guard: *std.Build.Step = switch (backend) {
        .gtk_backend => &b.addSystemCommand(&.{
            "sh",
            "-c",
            "pkg-config --exists webkit2gtk-4.1 gtk+-3.0 || { echo 'ERROR: missing required packages: webkit2gtk-4.1 gtk+-3.0 (install libwebkit2gtk-4.1-dev libgtk-3-dev)' >&2; exit 1; }",
        }).step,
        .webview2_backend => &CheckWebView2SdkStep.create(b, webview2_paths).step,
        .macos_backend => &CheckMacosBackendStep.create(b).step,
    };

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "build_options", .module = site_options_module },
        },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureBackend(root_module, b, backend, webview2_paths);

    const exe = b.addExecutable(.{
        .name = "zigBrowser",
        .root_module = root_module,
    });
    // MS1b (option d): on macOS the ObjC shim is a separate dylib that calls back into the exe's
    // zb_ipc_dispatch / zb_policy_decide. Export the exe's symbols so the dylib's flat-namespace
    // dynamic_lookup resolves them at load. macOS-only — Linux/Windows exe exports are unchanged.
    if (backend == .macos_backend) exe.rdynamic = true;
    // WS1: the Windows browser is a GUI-subsystem PE, so launching zigBrowser.exe opens no console
    // window. The GUI subsystem would otherwise default lld's entry to WinMainCRTStartup (needs a
    // WinMain we do not define), so pin the C-runtime entry mainCRTStartup, which calls our `main`.
    // Windows-only — the Linux ELF / macOS Mach-O have no PE subsystem and are unchanged.
    if (target.result.os.tag == .windows) {
        exe.subsystem = .Windows;
        exe.entry = .{ .symbol_name = "mainCRTStartup" };
    }
    exe.step.dependOn(pkg_guard);
    b.installArtifact(exe);

    // WS3 step 2 (Windows plan, coordination rev 2.4): the seven zb_* the Windows config arm and
    // cookie port need, linked with the WebView2 shim and run on Windows
    // (tests/windows/ws3_shim_test.c). Windows-target builds only; run on the Win11 VM by
    // `bash tests/windows/build-on-windows.sh ws3-shim-test-win`.
    if (backend == .webview2_backend) {
        const ws3_shim_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        configureBackend(ws3_shim_module, b, backend, webview2_paths);
        ws3_shim_module.addCSourceFile(.{ .file = b.path("tests/windows/ws3_shim_test.c"), .flags = &.{"-std=c11"} });
        const ws3_shim_exe = b.addExecutable(.{ .name = "ws3-shim-test", .root_module = ws3_shim_module });
        ws3_shim_exe.step.dependOn(pkg_guard);
        b.step("ws3-shim-test-win", "WS3: run the WebView2 shim's config setters and cookie store on Windows")
            .dependOn(&b.addRunArtifact(ws3_shim_exe).step);
    }

    // WS2.0 (Windows plan rev 2.6): the owner-only seam's DACLs read back from Windows. Windows-target
    // builds only; run on the Win11 VM by `bash tests/windows/build-on-windows.sh owner-only-test-win`.
    if (target.result.os.tag == .windows) {
        const oo_live_module = b.createModule(.{
            .root_source_file = b.path("tests/windows/owner_only_live_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        oo_live_module.addImport("owner_only", b.createModule(.{
            .root_source_file = b.path("src/owner_only.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
        oo_live_module.linkSystemLibrary("advapi32", .{});
        oo_live_module.linkSystemLibrary("ws2_32", .{}); // the AF_UNIX socket case
        b.step("owner-only-test-win", "WS2.0: the owner-only seam's DACLs, read back on Windows")
            .dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = oo_live_module })).step);
    }

    // The Claude Agent helper runtime beside the binary (chat-drawer plan
    // D6, rev 15.2): <prefix>/lib/zigbrowser/agent-host.
    const agent_runtime = b.addSystemCommand(&.{ "sh", "tools/install_agent_runtime.sh", b.install_prefix });
    b.step("agent-runtime", "Install the Claude Agent helper runtime into the install prefix").dependOn(&agent_runtime.step);

    // MS1 (macOS launch, plan rev 6 ed13e5e): the two-host, two-arch universal gate. The
    // per-arch builds are NATIVE on each Mac over Tailscale SSH (no -Dtarget); gate.sh runs the
    // Intel (x86_64) leg always and the Apple-Silicon (arm64) leg only when ZB_MAC_ARM_HOST is
    // configured, otherwise it prints a loud "NOT RUN: arm64 host not configured" and fails
    // closed (never a silent pass). Driven from Linux; does not affect the Linux build/gate.
    const mac_gate = b.addSystemCommand(&.{ "bash", "tests/mac/gate.sh" });
    b.step("mac-gate", "Run the macOS two-host universal/arch gate over Tailscale SSH").dependOn(&mac_gate.step);

    // MS1b (plan rev 10): the signed-bundle gate — the SIGNED universal exe + shim dylib RUN the M9
    // workload + exec-arch probe on BOTH Macs (option d: the ObjC shim is a chained-fixups dylib, so
    // the signed x86_64 binary no longer crashes in [ZBAppHost init]). Driven from Linux over SSH.
    const ms1b_gate = b.addSystemCommand(&.{ "bash", "tests/mac/ms1b_signed_gate.sh" });
    b.step("ms1b-gate", "Run the macOS MS1b signed-bundle gate (the signed universal runs on both Macs)").dependOn(&ms1b_gate.step);

    // MS2a (plan): the WKWebView routed-command port runs on BOTH Macs (unsigned build) — the
    // routed commands (navigate/url/title + the dom.getText eval in the automation world) and the
    // main-thread-bridge hang guard. Driven from Linux over SSH.
    const ms2a_gate = b.addSystemCommand(&.{ "bash", "tests/mac/ms2a_gate.sh" });
    b.step("ms2a-gate", "Run the macOS MS2a routed-command gate (WKWebView port on both Macs)").dependOn(&ms2a_gate.step);

    // WS0: the Windows gate's Linux-side selftest drives tests/windows/gate.sh against fake
    // ssh/virsh/tar on PATH (fail-closed, path fence, display scrub, transport hygiene). Hermetic
    // — no Windows host, display or live socket. The [W] gate.sh --probe-only runs separately.
    const windows_gate_selftest = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/gate_selftest.py" });
    b.step("windows-gate-selftest", "Run the Windows gate's Linux-side selftest (fake ssh/virsh/tar)").dependOn(&windows_gate_selftest.step);

    // WS0 live resolver regression: the real resolve_path.sh over SSH to the Win11 VM — the seam the
    // hermetic selftest cannot cover (it fakes SSH/PInvoke, which is why the uint32 bug survived).
    // Skips cleanly (exit 0) when ZB_WIN11_HOST is unset, so it is safe in a hostless Linux gate.
    const windows_resolve_live = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/resolve_live_test.py" });
    b.step("windows-resolve-live", "Live Windows resolver regression on the VM (skips without ZB_WIN11_HOST)").dependOn(&windows_resolve_live.step);

    // WS0.6/WS0.7 two-host gate selftest: drives gate.sh --probe-only against fake ssh/virsh (VM
    // identity marker + file-server fence). Hermetic — no Windows host. The live --probe-only run
    // against both real hosts is separate (needs the slot + the .gate-identity nonce).
    const windows_twohost_selftest = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/gate_twohost_selftest.py" });
    b.step("windows-twohost-selftest", "Run the Windows two-host gate selftest (WS0.6/WS0.7, fake ssh/virsh)").dependOn(&windows_twohost_selftest.step);

    // WS1 build-driver selftest: drives build-on-windows.sh against fake git/ssh/scp/timeout — clean
    // git-archive source, injection-safe EncodedCommand, fail-closed stage/build/fetch, outer deadlines,
    // atomic validated fetch, display scrub. Hermetic — no Windows host, network or display.
    const windows_build_selftest = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/build_on_windows_selftest.py" });
    b.step("windows-build-selftest", "Run the Windows build-driver selftest (fake git/ssh/scp/timeout)").dependOn(&windows_build_selftest.step);

    // WS1.1 PE-census selftest: exercises the PE parser + import allowlist on Linux-built PE fixtures
    // (clean/vcruntime/unlisted/i386) with a mutation oracle, and pins the WebView2 SDK version. Hermetic.
    const windows_pe_census_selftest = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/pe_census_selftest.py" });
    b.step("windows-pe-census-selftest", "Run the WS1.1 PE-census selftest (Linux PE fixtures + WebView2 SDK pin)").dependOn(&windows_pe_census_selftest.step);

    // WS1.3 PNG-census selftest: the PNG non-uniform oracle on Linux-built fixtures (uniform/varied/
    // filters/truncated/absent) with a mutation oracle. Hermetic.
    const windows_png_census_selftest = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/png_census_selftest.py" });
    b.step("windows-png-census-selftest", "Run the WS1.3 PNG-census selftest (Linux PNG fixtures)").dependOn(&windows_png_census_selftest.step);
    // WS1.3/6c771ff screenshot-diagnostic source pin: each exact screenshot failure line in the shim.
    const windows_screenshot_diag_selftest = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/screenshot_diag_selftest.py" });
    b.step("windows-screenshot-diag-selftest", "Pin the exact screenshot failure diagnostics in webview2_shim.cpp").dependOn(&windows_screenshot_diag_selftest.step);

    // WS item b (live): join_argv round-trips through the real CommandLineToArgvW on the Win11 VM — the
    // independent argv oracle the Linux reference parser cannot be. Skips cleanly without ZB_WIN11_HOST.
    const windows_wincontain_argv_live = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/wincontain_argv_live_test.py" });
    b.step("windows-wincontain-argv-live", "Live Windows argv oracle on the VM (skips without ZB_WIN11_HOST)").dependOn(&windows_wincontain_argv_live.step);

    // d1d: live Windows PathResolver / containment oracle — real CreateFileW + GetFinalPathNameByHandleW on
    // the VM; proves normalize_final_path on the real \\?\ output and that resolved_within fails closed on
    // agent-created junctions (untrusted mount points). Skips cleanly without ZB_WIN11_HOST; needs no slot.
    const windows_wincontain_resolve_live = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/wincontain_resolve_live_test.py" });
    b.step("windows-wincontain-resolve-live", "Live Windows PathResolver/containment oracle on the VM (skips without ZB_WIN11_HOST)").dependOn(&windows_wincontain_resolve_live.step);

    // d1d part 2: live Windows Job Object containment — real CreateProcessW(suspended) -> assign -> resume
    // with KILL_ON_JOB_CLOSE on the VM; the child is in the job and dies when the job handle closes. Skips
    // cleanly without ZB_WIN11_HOST; needs no slot.
    const windows_wincontain_job_live = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/wincontain_job_live_test.py" });
    b.step("windows-wincontain-job-live", "Live Windows Job Object containment on the VM (skips without ZB_WIN11_HOST)").dependOn(&windows_wincontain_job_live.step);

    // Live Windows --screenshot: zb_run_screenshot must CapturePreview the page to a real, non-blank PNG on
    // the VM (it was a stub returning EXIT=6). Skips cleanly without ZB_WIN11_HOST/ZB_WIN_EXE; needs no slot.
    const windows_screenshot_live = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/screenshot_live_test.py" });
    b.step("windows-screenshot-live", "Live Windows --screenshot PNG capture on the VM (skips without ZB_WIN11_HOST)").dependOn(&windows_screenshot_live.step);

    // j76: the .windows backend-flag arm — --media-source off/on applied via the WebView2 setters,
    // observed through the page title on the VM. Skips without ZB_WIN11_HOST/ZB_WIN_EXE; needs no slot.
    const windows_config_flags_live = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/win_config_flags_test.py" });
    b.step("windows-config-flags-live", "Live Windows backend-flag arm on the VM (skips without ZB_WIN11_HOST)").dependOn(&windows_config_flags_live.step);

    // WS2.0: the PRODUCTION transport on the VM — the real browser's directory, AF_UNIX socket and token
    // are owner-only (protected DACLs read back), no TCP listener, and zbother can neither connect nor
    // read the token. Skips cleanly without ZB_WIN11_HOST/ZB_WIN_EXE; needs no slot.
    const windows_transport_live = b.addSystemCommand(&.{ "python3", "-I", "tests/e2e/win_transport_test.py" });
    b.step("windows-transport-live", "Live Windows WS2.0 transport: owner-only socket, token and directory on the VM (skips without ZB_WIN11_HOST)").dependOn(&windows_transport_live.step);

    // j76 / WS3.2: a refused backend flag reaches the user's stderr on the Windows GUI exe (exactly the
    // refusal line, exit 1, open and --screenshot), and `--renderer=shm` stays a parse error. Skips without
    // ZB_WIN11_HOST/ZB_WIN_EXE; needs no slot.
    const windows_refusal_live = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/refusal_stderr_live_test.py" });
    b.step("windows-refusal-live", "Live Windows: a refused flag's message reaches stderr on the GUI exe (skips without ZB_WIN11_HOST)").dependOn(&windows_refusal_live.step);

    const run_step = b.step("run", "Run zigBrowser");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.step.dependOn(pkg_guard);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "build_options", .module = site_options_module },
        },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureBackend(test_module, b, backend, webview2_paths);

    const unit_tests = b.addTest(.{ .root_module = test_module });
    unit_tests.step.dependOn(pkg_guard);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.skip_foreign_checks = true;

    const ipc_module = b.createModule(.{
        .root_source_file = b.path("src/ipc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const ipc_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/ipc_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ipc_tests_module.addImport("ipc", ipc_module);
    const ipc_tests = b.addTest(.{ .root_module = ipc_tests_module });
    const run_ipc_tests = b.addRunArtifact(ipc_tests);
    run_ipc_tests.skip_foreign_checks = true;

    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
    });
    const ipc_windows_compile_module = b.createModule(.{
        .root_source_file = b.path("src/ipc.zig"),
        .target = windows_target,
        .optimize = optimize,
    });
    const ipc_windows_compile = b.addTest(.{ .root_module = ipc_windows_compile_module });
    const ipc_windows_step = b.step("ipc-test-win", "Compile backend-free IPC module for x86_64-windows");
    ipc_windows_step.dependOn(&ipc_windows_compile.step);

    // N12: a WebView2/WKWebView build must not need a GTK-only shim symbol
    // (zb_automation_*, zb_cookies_*, zb_native_*, ...). Compile src/main.zig
    // to an object for each non-GTK target (no SDK, no link) and check that
    // every zb_* symbol it leaves undefined is defined by that target's shim.
    // --require: the core symbols must show up, so a parser or object-layout
    // change cannot make the check pass vacuously.
    const cross_check = b.addSystemCommand(&.{ "python3", "tools/check_cross_symbols.py", "--require", "zb_app_run", "--require", "zb_version_line" });
    cross_check.addFileInput(b.path("tools/check_cross_symbols.py"));
    // Self-test per object format: a fixture needing a symbol no shim
    // defines must be reported as exactly that one missing symbol.
    const cross_self_test = b.addSystemCommand(&.{ "python3", "tools/check_cross_symbols.py", "--require", "zb_app_run", "--expect-missing", "zb_cross_fixture_probe" });
    cross_self_test.addFileInput(b.path("tools/check_cross_symbols.py"));
    const cross_targets = [_]struct { query: std.Target.Query, shim: []const u8 }{
        // The shipped floor (windowsAfUnixFloor), so the object reaches the automation server's start.
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu, .os_version_min = .{ .windows = .win10_rs4 } }, .shim = "src/webview2_shim.cpp" },
        // macOS: the ObjC shim plus the plain C files compiled into the exe (MS5's lock and spawn).
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .shim = "src/wkwebview_shim.m:src/agent_home_lock.c:src/agent_spawn_posix.c" },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .shim = "src/wkwebview_shim.m:src/agent_home_lock.c:src/agent_spawn_posix.c" },
    };
    for (cross_targets) |cross| {
        const cross_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "build_options", .module = site_options_module },
            },
            .target = b.resolveTargetQuery(cross.query),
            .optimize = optimize,
            .link_libc = true,
        });
        cross_module.addIncludePath(b.path("src"));
        const cross_object = b.addObject(.{ .name = "zigBrowser-cross", .root_module = cross_module });
        cross_check.addFileArg(cross_object.getEmittedBin());
        addShimArg(b, cross_check, cross.shim);

        const fixture_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/cross/missing_symbol.zig"),
            .target = b.resolveTargetQuery(cross.query),
            .optimize = optimize,
        });
        const fixture_object = b.addObject(.{ .name = "cross-fixture", .root_module = fixture_module });
        cross_self_test.addFileArg(fixture_object.getEmittedBin());
        addShimArg(b, cross_self_test, cross.shim);
    }
    const cross_check_step = b.step("cross-check", "Check that Windows/macOS builds need only zb_* symbols their shims define");
    cross_check_step.dependOn(&cross_check.step);
    cross_check_step.dependOn(&cross_self_test.step);

    // WS5 export-widening proof (plan line 639; sequencing override: this [L] cross-check is WS1-independent).
    // The x86_64-windows-gnu object must COMPILE and DEFINE the portable drawer logic (zb_drawer_*) once the
    // export gate in agent_drawer.zig widens from .linux to .linux/.windows. Pure compile — no SDK, no link.
    const cross_drawer_win_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{.{ .name = "build_options", .module = site_options_module }},
        .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }),
        .optimize = optimize,
        .link_libc = true,
    });
    cross_drawer_win_module.addIncludePath(b.path("src"));
    const cross_drawer_win_obj = b.addObject(.{ .name = "zigBrowser-cross-drawer-win", .root_module = cross_drawer_win_module });
    const cross_drawer_win = b.addSystemCommand(&.{
        "python3",            "tools/check_cross_symbols.py",
        "--require-defined",  "zb_drawer_classify",
        "--require-defined",  "zb_drawer_place",
        "--require-defined",  "zb_drawer_clamp",
        "--require-defined",  "zb_drawer_panel_rect",
        "--require-defined",  "zb_drawer_ratios_of",
        "--require-defined",  "zb_drawer_key_move",
        "--require-defined",  "zb_drawer_remember",
        "--require-defined",  "zb_drawer_anim_ms",
    });
    cross_drawer_win.addFileInput(b.path("tools/check_cross_symbols.py"));
    cross_drawer_win.addFileArg(cross_drawer_win_obj.getEmittedBin());
    cross_drawer_win.addFileArg(b.path("src/webview2_shim.cpp"));
    const cross_drawer_win_step = b.step("cross-check-drawer-win", "WS5: the Windows build compiles and exports the portable drawer logic (zb_drawer_*)");
    cross_drawer_win_step.dependOn(&cross_drawer_win.step);
    cross_check_step.dependOn(&cross_drawer_win.step);

    // WS3 .windows arm + WebView2 cookie port (red-first; UNREGISTERED — not in `cross-check`/`test`
    // until green). The x86_64-windows-gnu object compiles, and every zb_* it needs
    // (zb_cookies_*/zb_app_set_*/zb_automation_free) must be defined by webview2_shim.cpp. RED until
    // BlackRobin's Windows config/cookie shim pre-slice lands those; then wire this into `cross-check`.
    const ws3_win_module = b.createModule(.{
        .root_source_file = b.path("src/ws3_win_cross_root.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }),
        .optimize = optimize,
        .link_libc = true,
    });
    ws3_win_module.addIncludePath(b.path("src"));
    const ws3_win_obj = b.addObject(.{ .name = "zigBrowser-ws3-win", .root_module = ws3_win_module });
    // Require all seven zb_* the WS3 Windows path needs, so a mutant that drops any one from the Zig
    // side (making it vanish from the object's `needed` set) turns this red (RoseCat 6429).
    const cross_check_ws3_win = b.addSystemCommand(&.{
        "python3",            "tools/check_cross_symbols.py",
        "--require",          "zb_cookies_get_all",
        "--require",          "zb_cookies_add",
        "--require",          "zb_cookies_delete",
        "--require",          "zb_app_set_media_source",
        "--require",          "zb_app_set_hw_policy",
        "--require",          "zb_app_set_profile_dir",
        "--require",          "zb_automation_free",
    });
    cross_check_ws3_win.addFileInput(b.path("tools/check_cross_symbols.py"));
    cross_check_ws3_win.addFileArg(ws3_win_obj.getEmittedBin());
    cross_check_ws3_win.addFileArg(b.path("src/webview2_shim.cpp"));
    const cross_check_ws3_win_step = b.step("cross-check-ws3-win", "WS3: the Windows config arm + cookie port need only zb_* that webview2_shim.cpp defines (red until the shim lands)");
    cross_check_ws3_win_step.dependOn(&cross_check_ws3_win.step);

    const afunix_spike_module = b.createModule(.{
        .root_source_file = b.path("tests/spikes/af_unix_roundtrip.zig"),
        .target = target,
        .optimize = optimize,
    });
    const afunix_spike_tests = b.addTest(.{ .root_module = afunix_spike_module });
    const run_afunix_spike_tests = b.addRunArtifact(afunix_spike_tests);
    run_afunix_spike_tests.skip_foreign_checks = true;
    const afunix_spike_step = b.step("automation-afunix-spike-win", "Run AF_UNIX automation transport spike");
    afunix_spike_step.dependOn(&run_afunix_spike_tests.step);

    const nav_policy_module = b.createModule(.{
        .root_source_file = b.path("src/nav_policy.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const nav_policy_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/nav_policy_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nav_policy_tests_module.addImport("nav_policy", nav_policy_module);
    const nav_policy_tests = b.addTest(.{ .root_module = nav_policy_tests_module });
    const run_nav_policy_tests = b.addRunArtifact(nav_policy_tests);
    run_nav_policy_tests.skip_foreign_checks = true;

    // Chat drawer S3.3: the native validator of helper frames.
    const agent_protocol_module = b.createModule(.{
        .root_source_file = b.path("src/agent_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agent_protocol_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_protocol_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_protocol_tests_module.addImport("agent_protocol", agent_protocol_module);
    const run_agent_protocol_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_protocol_tests_module }));
    // Chat drawer S5c-1 (S5.6, rev 16.20.11 to 16.20.16): reply_capped, for the session's
    // active prompt only, once, after a delta of it.
    const agent_protocol_capped_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_protocol_capped_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_protocol_capped_tests_module.addImport("agent_protocol", agent_protocol_module);
    const run_agent_protocol_capped_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_protocol_capped_tests_module }));
    // Chat drawer S5d (rev 16.20.16, 16.20.17): every prompt-scoped frame names its prompt.
    const agent_protocol_prompt_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_protocol_prompt_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_protocol_prompt_tests_module.addImport("agent_protocol", agent_protocol_module);
    const run_agent_protocol_prompt_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_protocol_prompt_tests_module }));
    // Chat drawer S7.0 (rev 16.20.30): the real Bridge's tool_call (agent/host/tests/bridge_producer.py)
    // judged by the real validator.
    const bridge_producer = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \"$py\" bridge_producer.py",
    });
    bridge_producer.addFileInput(b.path("agent/host/tests/bridge_producer.py"));
    bridge_producer.addFileInput(b.path("agent/host/zb_agent_host/bridge.py"));
    bridge_producer.addFileInput(b.path("agent/host/zb_agent_host/frames.py"));
    const agent_bridge_frame_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_bridge_frame_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_bridge_frame_tests_module.addImport("agent_protocol", agent_protocol_module);
    agent_bridge_frame_tests_module.addAnonymousImport("bridge_frames", .{ .root_source_file = bridge_producer.captureStdOut(.{}) });
    const run_agent_bridge_frame_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_bridge_frame_tests_module }));
    // Chat drawer S5d fix-forward (rev 16.20.18; RoseCat 6286, 6307, 6314): the cap reason
    // order, prompt-id bounds, and the app's prompt path once a session's ids are spent.
    var s5d_fix_runs: [5]*std.Build.Step = undefined;
    const agent_frames_test_module = b.createModule(.{
        .root_source_file = b.path("src/agent_frames.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Chat drawer S7b (rev 16.20.34): the app's tool_result frame (zb_agent_out_tool_result).
    const agent_frames_tool_module = b.createModule(.{ .root_source_file = b.path("tests/agent_frames_tool_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    agent_frames_tool_module.addImport("agent_frames", agent_frames_test_module);
    const run_agent_frames_tool_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_frames_tool_module }));
    run_agent_frames_tool_tests.skip_foreign_checks = true;
    const agent_frames_tool_call_module = b.createModule(.{ .root_source_file = b.path("tests/agent_frames_tool_call_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    agent_frames_tool_call_module.addImport("agent_frames", agent_frames_test_module);
    const run_agent_frames_tool_call_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_frames_tool_call_module }));
    run_agent_frames_tool_call_tests.skip_foreign_checks = true;
    const agent_frames_deadline_module = b.createModule(.{ .root_source_file = b.path("tests/agent_frames_deadline_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    agent_frames_deadline_module.addImport("agent_frames", agent_frames_test_module);
    const run_agent_frames_deadline_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_frames_deadline_module }));
    run_agent_frames_deadline_tests.skip_foreign_checks = true;
    for ([_][]const u8{ "tests/agent_protocol_cap_reason_test.zig", "tests/agent_prompt_id_limit_test.zig", "tests/agent_frames_prompt_test.zig", "tests/agent_frames_out_test.zig", "tests/agent_prompt_base_test.zig" }, 0..) |path, i| {
        const m = b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize, .link_libc = true });
        if (i < 2) m.addImport("agent_protocol", agent_protocol_module) else m.addImport("agent_frames", agent_frames_test_module);
        const run = b.addRunArtifact(b.addTest(.{ .root_module = m }));
        run.skip_foreign_checks = true;
        s5d_fix_runs[i] = &run.step;
    }
    run_agent_protocol_tests.skip_foreign_checks = true;
    // Chat drawer S6 (rev 16.18): the one-shot login helper's frames.
    const agent_login_protocol_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_login_protocol_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_login_protocol_tests_module.addImport("agent_protocol", agent_protocol_module);
    const run_agent_login_protocol_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_login_protocol_tests_module }));
    run_agent_login_protocol_tests.skip_foreign_checks = true;

    // Chat drawer S1: the floating icon's pure logic (src/agent_drawer.zig).
    const agent_drawer_module = b.createModule(.{
        .root_source_file = b.path("src/agent_drawer.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const agent_drawer_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_drawer_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_drawer_tests_module.addImport("agent_drawer", agent_drawer_module);
    const agent_drawer_tests = b.addTest(.{ .root_module = agent_drawer_tests_module });
    const run_agent_drawer_tests = b.addRunArtifact(agent_drawer_tests);
    run_agent_drawer_tests.skip_foreign_checks = true;
    // Chat drawer S5c-1 (S5.6, rev 16.20.2): long unbroken runs get break points,
    // and Copy maps a selection back to the original bytes.
    const agent_drawer_breaks_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_drawer_breaks_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_drawer_breaks_tests_module.addImport("agent_drawer", agent_drawer_module);
    const run_agent_drawer_breaks_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_drawer_breaks_tests_module }));
    run_agent_drawer_breaks_tests.skip_foreign_checks = true;

    // Chat drawer S3n2, native spawn wiring: netd's socket directory, the e2e
    // seams' grammar and netd's argv and environment (src/agent_net.zig).
    const agent_net_module = b.createModule(.{
        .root_source_file = b.path("src/agent_net.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const agent_net_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_net_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_net_tests_module.addImport("agent_net", agent_net_module);
    const run_agent_net_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_net_tests_module }));
    run_agent_net_tests.skip_foreign_checks = true;
    // MS0 slice D: netd's argv names the backend's network manifest.
    const agent_net_manifest_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_net_manifest_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_net_manifest_tests_module.addImport("agent_net", agent_net_module);
    const run_agent_net_manifest_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_net_manifest_tests_module }));
    run_agent_net_manifest_tests.skip_foreign_checks = true;

    // MS8 macOS host spawner: the pure fail-closed core (reading netd's ready port + the helper argv +
    // the lifecycle decision) in src/agent_host_posix.zig (BlackRobin 7035). Inline tests;
    // @import("agent_net.zig") resolves to src/agent_net.zig by path.
    const agent_host_posix_tests_module = b.createModule(.{
        .root_source_file = b.path("src/agent_host_posix.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_agent_host_posix_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_host_posix_tests_module }));
    run_agent_host_posix_tests.skip_foreign_checks = true;
    // MS8 spawner integration (BlackRobin 7035/7108 seam 1+Q1): spawnNetd drives the C zb_agent_spawn_group_io
    // with a Linux stand-in netd; links src/agent_spawn_posix.c (the real seam). The both-Mac fake-netd e2e is separate.
    const agent_host_posix_module = b.createModule(.{
        .root_source_file = b.path("src/agent_host_posix.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agent_host_posix_spawn_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_host_posix_spawn_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_host_posix_spawn_module.addImport("agent_host_posix", agent_host_posix_module);
    agent_host_posix_spawn_module.addCSourceFile(.{ .file = b.path("src/agent_spawn_posix.c"), .flags = &.{"-std=gnu11"} });
    // test 8 sends SIGKILL to netd's OWN group, so the whole suite runs confined to a user+PID namespace per the
    // kill-safety rule (RoseCat 7172 #2); a plain addRunArtifact would run that signal outside any namespace.
    const agent_host_posix_spawn_test = b.addTest(.{ .root_module = agent_host_posix_spawn_module });
    const run_agent_host_posix_spawn_tests = b.addSystemCommand(&.{
        "unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc", "--",
    });
    run_agent_host_posix_spawn_tests.addArtifactArg(agent_host_posix_spawn_test);
    const agent_host_posix_spawn_step = b.step("test-agent-spawn", "spawnNetd Linux integration tests (namespaced)");
    agent_host_posix_spawn_step.dependOn(&run_agent_host_posix_spawn_tests.step);
    // zb_agent_kill_group signals only our own child's own group (RoseCat 7172, 7182; the 2026-10-21 logouts). The C
    // test routes every killpg/kill of src/agent_spawn_posix.c to a fake by -Wl,--wrap, and still runs only inside a
    // private user+PID namespace, as its own group leader (setsid). Its both-Mac gate is tests/mac/ms5_kill_group_gate.sh.
    const kill_group_tests = b.addSystemCommand(&.{
        "unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc", "--",
        "sh", "-c", "setsid tests/kill_group/run_linux.sh",
    });
    agent_host_posix_spawn_step.dependOn(&kill_group_tests.step);
    // MS6.5 (the user's decision 2026-10-21): the run-survivor classification core, src/agent_run_reaper.c.
    // Pure, no OS calls (the libproc sweep + guarded kill land with the both-Mac case), so a plain run artifact.
    const agent_run_reaper_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_run_reaper_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_run_reaper_module.addCSourceFile(.{ .file = b.path("src/agent_run_reaper.c"), .flags = &.{"-std=gnu11"} });
    agent_run_reaper_module.addIncludePath(b.path("src"));
    const run_agent_run_reaper_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_run_reaper_module }));
    run_agent_run_reaper_tests.skip_foreign_checks = true;
    const agent_run_reaper_step = b.step("test-agent-run-reaper", "MS6.5 run-survivor classification core");
    agent_run_reaper_step.dependOn(&run_agent_run_reaper_tests.step);
    // MS6.5 (RoseCat f907e95): the reaper's decision engine + gather, proven on Linux with the kill INTERCEPTED
    // before the OS via fake ops (no real signal). C executable, run inside a user+PID namespace per the rule.
    const reaper_engine_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    reaper_engine_module.addCSourceFile(.{ .file = b.path("src/agent_run_reaper.c"), .flags = &.{"-std=gnu11"} });
    reaper_engine_module.addCSourceFile(.{ .file = b.path("tests/agent_run_reaper_engine_test.c"), .flags = &.{"-std=gnu11"} });
    reaper_engine_module.addIncludePath(b.path("src"));
    const reaper_engine_exe = b.addExecutable(.{ .name = "reaper-engine-test", .root_module = reaper_engine_module });
    const run_reaper_engine_tests = b.addSystemCommand(&.{
        "unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc", "--",
    });
    run_reaper_engine_tests.addArtifactArg(reaper_engine_exe);
    const reaper_engine_step = b.step("test-agent-run-reaper-engine", "MS6.5 reaper decision engine (fake ops, kill intercepted)");
    reaper_engine_step.dependOn(&run_reaper_engine_tests.step);
    // MS6.5 (RoseCat 3da2862 #4): the run-dir pin + path-swap detection, on real Linux directories. Portable
    // (open O_NOFOLLOW + fstat/stat), no signals.
    const reaper_pin_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    reaper_pin_module.addCSourceFile(.{ .file = b.path("src/agent_run_reaper.c"), .flags = &.{"-std=gnu11"} });
    reaper_pin_module.addCSourceFile(.{ .file = b.path("tests/agent_run_reaper_pin_test.c"), .flags = &.{"-std=gnu11"} });
    reaper_pin_module.addIncludePath(b.path("src"));
    const reaper_pin_exe = b.addExecutable(.{ .name = "reaper-pin-test", .root_module = reaper_pin_module });
    const run_reaper_pin_tests = b.addRunArtifact(reaper_pin_exe);
    run_reaper_pin_tests.skip_foreign_checks = true;
    const reaper_pin_step = b.step("test-agent-run-reaper-pin", "MS6.5 run-dir pin + path-swap (Linux, real dirs)");
    reaper_pin_step.dependOn(&run_reaper_pin_tests.step);
    // MS6.5 (the user's decision 2026-10-21): the stubbed macOS VM-containment seam — off by default, reports
    // "not available yet", and the gate fails closed when on. Pure Linux unit (no OS calls).
    const mac_vm_containment_module = b.createModule(.{
        .root_source_file = b.path("tests/mac_vm_containment_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    mac_vm_containment_module.addImport("mac_vm_containment", b.createModule(.{
        .root_source_file = b.path("src/mac_vm_containment.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_mac_vm_containment_tests = b.addRunArtifact(b.addTest(.{ .root_module = mac_vm_containment_module }));
    run_mac_vm_containment_tests.skip_foreign_checks = true;
    const mac_vm_containment_step = b.step("test-mac-vm-containment", "the stubbed macOS VM-containment seam");
    mac_vm_containment_step.dependOn(&run_mac_vm_containment_tests.step);
    // RoseCat 7199 #2 — real-binary closure: the built binary run as --agent-setup fails closed before any
    // setup child when the VM setting is on/malformed, and passes when unset. Host-neutral; also run on both Macs.
    const mac_vm_containment_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/mac_vm_containment_e2e.py --binary \"$1\"",
        "mac-vm-containment-e2e",
    });
    mac_vm_containment_e2e.addArtifactArg(exe);
    mac_vm_containment_step.dependOn(&mac_vm_containment_e2e.step);

    // Chat drawer S3b: the helper's launch argv and environment, the app's
    // frames, the runtime-lock check and the backoff (src/agent_helper.zig).
    const agent_helper_module = b.createModule(.{
        .root_source_file = b.path("src/agent_helper.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agent_helper_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_helper_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_helper_tests_module.addImport("agent_helper", agent_helper_module);
    const run_agent_helper_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_helper_tests_module }));
    // S7b: the tool deadline seam's app side (ZIGBROWSER_AGENT_TEST_TOOL_DEADLINE_S).
    const agent_helper_deadline_module = b.createModule(.{ .root_source_file = b.path("tests/agent_helper_deadline_test.zig"), .target = target, .optimize = optimize });
    agent_helper_deadline_module.addImport("agent_helper", agent_helper_module);
    const run_agent_helper_deadline_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_helper_deadline_module }));
    run_agent_helper_deadline_tests.skip_foreign_checks = true;
    run_agent_helper_tests.skip_foreign_checks = true;

    // Chat drawer S3c: the per-session configuration check, `.claude` against
    // runtime/config-manifest.json (src/agent_config_check.zig).
    const agent_config_check_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_config_check_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_config_check_tests_module.addImport("agent_config_check", b.createModule(.{
        .root_source_file = b.path("src/agent_config_check.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_agent_config_check_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_config_check_tests_module }));
    run_agent_config_check_tests.skip_foreign_checks = true;

    // Chat drawer S4a: the token's shape and the explicit file store, read and
    // write (src/agent_secrets.zig).
    const agent_secrets_module = b.createModule(.{
        .root_source_file = b.path("src/agent_secrets.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const agent_secrets_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_secrets_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_secrets_tests_module.addImport("agent_secrets", agent_secrets_module);
    const run_agent_secrets_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_secrets_tests_module }));
    run_agent_secrets_tests.skip_foreign_checks = true;
    // The setup-token shape (the user's requirement after the S4a real-screen check).
    const agent_secrets_shape_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_secrets_shape_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_secrets_shape_tests_module.addImport("agent_secrets", agent_secrets_module);
    const run_agent_secrets_shape_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_secrets_shape_tests_module }));
    run_agent_secrets_shape_tests.skip_foreign_checks = true;

    // Chat drawer S6b1: the login helper's launch argv (src/agent_login.zig).
    const run_agent_login_tests = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/agent_login.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) }));
    run_agent_login_tests.skip_foreign_checks = true;

    // Chat drawer S6.2 (A2): the auth window's callback check (src/agent_auth.zig).
    const agent_auth_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_auth_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_auth_tests_module.addImport("agent_auth", b.createModule(.{
        .root_source_file = b.path("src/agent_auth.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_agent_auth_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_auth_tests_module }));
    run_agent_auth_tests.skip_foreign_checks = true;
    // Windows plan WS3 coordination (RoseCat 6389, 6405): the shared all-OS backend-flag decision,
    // literal from production's own parsing (src/backend_flag.zig).
    const backend_flag_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/backend_flag_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend_flag_tests_module.addImport("backend_flag", b.createModule(.{
        .root_source_file = b.path("src/backend_flag.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_backend_flag_tests = b.addRunArtifact(b.addTest(.{ .root_module = backend_flag_tests_module }));
    run_backend_flag_tests.skip_foreign_checks = true;
    // j76: the startup's flag step (backend_flag.startup): decide every present flag, then apply once.
    const backend_flag_startup_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/backend_flag_startup_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    backend_flag_startup_tests_module.addImport("backend_flag", b.createModule(.{
        .root_source_file = b.path("src/backend_flag.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_backend_flag_startup_tests = b.addRunArtifact(b.addTest(.{ .root_module = backend_flag_startup_tests_module }));
    run_backend_flag_startup_tests.skip_foreign_checks = true;
    const backend_flag_step = b.step("test-backend-flag", "Run the shared backend-flag decision's tests (WS3 coordination)");
    backend_flag_step.dependOn(&run_backend_flag_tests.step);
    backend_flag_step.dependOn(&run_backend_flag_startup_tests.step);
    // RoseCat 6564: the production entrypoints reach the native settings only through backend_flag.startup.
    const startup_entrypoint_test = b.addSystemCommand(&.{ "python3", "-I", "tests/startup_entrypoint_test.py" });
    backend_flag_step.dependOn(&startup_entrypoint_test.step);
    // Rev 16.18.16-16.18.17: S6b2's navigation decision (agent_auth.decideNavigation), the A2
    // cases among its unit cases, before any auth window exists.
    const agent_auth_navigation_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_auth_navigation_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_auth_navigation_tests_module.addImport("agent_auth", b.createModule(.{
        .root_source_file = b.path("src/agent_auth.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_agent_auth_navigation_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_auth_navigation_tests_module }));
    run_agent_auth_navigation_tests.skip_foreign_checks = true;
    // Rev 16.20.33 (RoseCat 6457 #1, 6466): the capture at the main-frame response.
    const agent_auth_response_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_auth_response_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_auth_response_tests_module.addImport("agent_auth", b.createModule(.{
        .root_source_file = b.path("src/agent_auth.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_agent_auth_response_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_auth_response_tests_module }));
    run_agent_auth_response_tests.skip_foreign_checks = true;
    // Rev 16.20.26: the user's decision: Google's and Apple's sign-in hosts, exactly.
    const agent_auth_thirdparty_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_auth_thirdparty_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_auth_thirdparty_tests_module.addImport("agent_auth", b.createModule(.{
        .root_source_file = b.path("src/agent_auth.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_agent_auth_thirdparty_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_auth_thirdparty_tests_module }));
    run_agent_auth_thirdparty_tests.skip_foreign_checks = true;
    // Rev 16.18.15 (RoseCat 5911): S6b2's ZIGBROWSER_AGENT_AUTH_TEST seam, decided before the
    // auth window exists (src/agent_auth_seam.zig).
    const agent_auth_seam_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_auth_seam_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_auth_seam_tests_module.addImport("agent_auth_seam", b.createModule(.{
        .root_source_file = b.path("src/agent_auth_seam.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_agent_auth_seam_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_auth_seam_tests_module }));
    run_agent_auth_seam_tests.skip_foreign_checks = true;
    // Rev 16.18.11-16.18.14 (BlackRobin 5924; RoseCat 6252, 6261): the app's own authorize-URL
    // check, over the case table shared with the login helper (agent_auth.authorizeUrl, then
    // zb_login_validate).
    const agent_auth_authorize_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_auth_authorize_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_auth_authorize_tests_module.addImport("agent_auth", b.createModule(.{
        .root_source_file = b.path("src/agent_auth.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_agent_auth_authorize_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_auth_authorize_tests_module }));
    run_agent_auth_authorize_tests.skip_foreign_checks = true;
    const agent_login_authorize_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_login_authorize_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_login_authorize_tests_module.addImport("agent_login", b.createModule(.{
        .root_source_file = b.path("src/agent_login.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    const run_agent_login_authorize_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_login_authorize_tests_module }));
    run_agent_login_authorize_tests.skip_foreign_checks = true;
    // S4.1 edge: the libsecret dlopen fails (built against a missing library;
    // in the browser WebKitGTK has it loaded already). GTK hosts only.
    const agent_secrets_dlopen_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_secrets_dlopen_module.addIncludePath(b.path("src"));
    agent_secrets_dlopen_module.addCSourceFile(.{ .file = b.path("tests/agent_secrets_dlopen_test.c"), .flags = &.{"-std=gnu11"} });
    agent_secrets_dlopen_module.addCSourceFile(.{
        .file = b.path("src/agent_secrets.c"),
        .flags = &.{ "-std=gnu11", "-DZB_LIBSECRET_SONAME=\"libzb-missing-secret.so.0\"" },
    });
    agent_secrets_dlopen_module.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
    const run_agent_secrets_dlopen_test = b.addRunArtifact(b.addExecutable(.{
        .name = "agent-secrets-dlopen-test",
        .root_module = agent_secrets_dlopen_module,
    }));
    run_agent_secrets_dlopen_test.skip_foreign_checks = true;
    // S4.2 edge (BlackRobin 5815): a token fetch that overlaps Remove's keyring clear
    // answers ABSENT. Built like the dlopen test, so every clear answers at once.
    const agent_secrets_clear_fetch_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_secrets_clear_fetch_module.addIncludePath(b.path("src"));
    agent_secrets_clear_fetch_module.addCSourceFile(.{ .file = b.path("tests/agent_secrets_clear_fetch_test.c"), .flags = &.{"-std=gnu11"} });
    agent_secrets_clear_fetch_module.addCSourceFile(.{
        .file = b.path("src/agent_secrets.c"),
        .flags = &.{ "-std=gnu11", "-DZB_LIBSECRET_SONAME=\"libzb-missing-secret.so.0\"" },
    });
    agent_secrets_clear_fetch_module.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
    const run_agent_secrets_clear_fetch_test = b.addRunArtifact(b.addExecutable(.{
        .name = "agent-secrets-clear-fetch-test",
        .root_module = agent_secrets_clear_fetch_module,
    }));
    run_agent_secrets_clear_fetch_test.skip_foreign_checks = true;

    const config_schema_module = b.createModule(.{
        .root_source_file = b.path("src/config_schema.zig"),
        .target = target,
        .optimize = optimize,
    });
    const config_schema_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/config_schema_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_schema_tests_module.addImport("config_schema", config_schema_module);
    const config_schema_tests = b.addTest(.{ .root_module = config_schema_tests_module });
    const run_config_schema_tests = b.addRunArtifact(config_schema_tests);
    run_config_schema_tests.skip_foreign_checks = true;

    const automation_module = b.createModule(.{
        .root_source_file = b.path("src/automation.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const automation_smoke_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_smoke_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_smoke_tests_module.addImport("automation", automation_module);
    const automation_smoke_tests = b.addTest(.{ .root_module = automation_smoke_tests_module });
    const run_automation_smoke_tests = b.addRunArtifact(automation_smoke_tests);
    run_automation_smoke_tests.skip_foreign_checks = true;

    const automation_error_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_error_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_error_tests_module.addImport("automation", automation_module);
    const automation_error_tests = b.addTest(.{ .root_module = automation_error_tests_module });
    const run_automation_error_tests = b.addRunArtifact(automation_error_tests);
    // S8a: -32015 expectation_mismatch (chat-drawer plan rev 16.20.38).
    const automation_error_expect_module = b.createModule(.{ .root_source_file = b.path("tests/automation_error_expect_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    automation_error_expect_module.addImport("automation", automation_module);
    const run_automation_error_expect_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_error_expect_module }));
    run_automation_error_tests.skip_foreign_checks = true;

    const automation_router_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_router_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_router_tests_module.addImport("automation", automation_module);
    const automation_router_tests = b.addTest(.{ .root_module = automation_router_tests_module });
    const run_automation_router_tests = b.addRunArtifact(automation_router_tests);
    run_automation_router_tests.skip_foreign_checks = true;

    const automation_engine_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_engine_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_engine_tests_module.addImport("automation", automation_module);
    const automation_engine_tests = b.addTest(.{ .root_module = automation_engine_tests_module });
    const run_automation_engine_tests = b.addRunArtifact(automation_engine_tests);
    run_automation_engine_tests.skip_foreign_checks = true;

    const automation_retry_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_retry_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_retry_tests_module.addImport("automation", automation_module);
    const automation_retry_tests = b.addTest(.{ .root_module = automation_retry_tests_module });
    const run_automation_retry_tests = b.addRunArtifact(automation_retry_tests);
    run_automation_retry_tests.skip_foreign_checks = true;

    const automation_queue_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_queue_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_queue_tests_module.addImport("automation", automation_module);
    const automation_queue_tests = b.addTest(.{ .root_module = automation_queue_tests_module });
    const run_automation_queue_tests = b.addRunArtifact(automation_queue_tests);
    run_automation_queue_tests.skip_foreign_checks = true;

    const automation_telemetry_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_telemetry_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_telemetry_tests_module.addImport("automation", automation_module);
    const automation_telemetry_tests = b.addTest(.{ .root_module = automation_telemetry_tests_module });
    const run_automation_telemetry_tests = b.addRunArtifact(automation_telemetry_tests);
    run_automation_telemetry_tests.skip_foreign_checks = true;

    const automation_social_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_social_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_social_tests_module.addImport("automation", automation_module);
    const automation_social_tests = b.addTest(.{ .root_module = automation_social_tests_module });
    const run_automation_social_tests = b.addRunArtifact(automation_social_tests);
    run_automation_social_tests.skip_foreign_checks = true;
    // S8a decision 14: options.guard, its grammar and the engine's hand-off and mapping.
    const automation_guard_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_guard_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_guard_tests_module.addImport("automation", automation_module);
    const run_automation_guard_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_guard_tests_module }));
    run_automation_guard_tests.skip_foreign_checks = true;
    // S8a decision 15: a guarded dom.type in 16-code-point chunks.
    const automation_guard_chunks_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_guard_chunks_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_guard_chunks_tests_module.addImport("automation", automation_module);
    const run_automation_guard_chunks_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_guard_chunks_tests_module }));
    run_automation_guard_chunks_tests.skip_foreign_checks = true;
    // S8a (RoseCat on 76cb14a): the chunks of a guarded dom.type are one action.
    const automation_guard_chunks2_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_guard_chunks2_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_guard_chunks2_tests_module.addImport("automation", automation_module);
    const run_automation_guard_chunks2_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_guard_chunks2_tests_module }));
    run_automation_guard_chunks2_tests.skip_foreign_checks = true;
    // S8a (RoseCat 7280 on 52cfb6c): the exact oracles of a guarded dom.type's chunk contract.
    const automation_guard_chunks3_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_guard_chunks3_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_guard_chunks3_tests_module.addImport("automation", automation_module);
    const run_automation_guard_chunks3_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_guard_chunks3_tests_module }));
    run_automation_guard_chunks3_tests.skip_foreign_checks = true;
    // S8a (RoseCat on 9295b0b): a selectorless dom.press cannot carry guard.target.
    const automation_guard_press_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_guard_press_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_guard_press_tests_module.addImport("automation", automation_module);
    const run_automation_guard_press_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_guard_press_tests_module }));
    run_automation_guard_press_tests.skip_foreign_checks = true;
    // S8a ("S8 in detail" decision 2): an approved flow's phases A to C, and phase B through the runner.
    const automation_expect_flow_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_expect_flow_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_expect_flow_tests_module.addImport("automation", automation_module);
    const run_automation_expect_flow_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_expect_flow_tests_module }));
    run_automation_expect_flow_tests.skip_foreign_checks = true;
    const automation_expect_flow_seam_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_expect_flow_seam_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_expect_flow_seam_tests_module.addImport("automation", automation_module);
    const run_automation_expect_flow_seam_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_expect_flow_seam_tests_module }));
    run_automation_expect_flow_seam_tests.skip_foreign_checks = true;
    // RoseCat 7155: before phase C a read is refused too.
    const automation_expect_flow_prenav_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_expect_flow_prenav_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_expect_flow_prenav_tests_module.addImport("automation", automation_module);
    const run_automation_expect_flow_prenav_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_expect_flow_prenav_tests_module }));
    run_automation_expect_flow_prenav_tests.skip_foreign_checks = true;

    const automation_cookie_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_cookie_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_cookie_tests_module.addImport("automation", automation_module);
    const automation_cookie_tests = b.addTest(.{ .root_module = automation_cookie_tests_module });
    const run_automation_cookie_tests = b.addRunArtifact(automation_cookie_tests);
    run_automation_cookie_tests.skip_foreign_checks = true;

    const automation_x_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_x_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_x_tests_module.addImport("automation", automation_module);
    const automation_x_tests = b.addTest(.{ .root_module = automation_x_tests_module });
    const run_automation_x_tests = b.addRunArtifact(automation_x_tests);
    run_automation_x_tests.skip_foreign_checks = true;

    const automation_server_module = b.createModule(.{
        .root_source_file = b.path("src/automation_server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const automation_server_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_server_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_server_tests_module.addImport("automation_server", automation_server_module);
    const automation_server_tests = b.addTest(.{ .root_module = automation_server_tests_module });
    const run_automation_server_tests = b.addRunArtifact(automation_server_tests);
    run_automation_server_tests.skip_foreign_checks = true;
    // S8a (chat-drawer plan, "S8 in detail" decision 2): options.expect's phase A, through callInProcess.
    const automation_expect_phase_a_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_expect_phase_a_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_expect_phase_a_tests_module.addImport("automation_server", automation_server_module);
    const run_automation_expect_phase_a_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_expect_phase_a_tests_module }));
    run_automation_expect_phase_a_tests.skip_foreign_checks = true;
    // RoseCat 0c1132b: phase A shares the command's one deadline and its cancellation.
    const automation_expect_budget_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_expect_budget_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_expect_budget_tests_module.addImport("automation_server", automation_server_module);
    const run_automation_expect_budget_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_expect_budget_tests_module }));
    run_automation_expect_budget_tests.skip_foreign_checks = true;
    // RoseCat db43ca1: phase A's deadline comes before what the check found.
    const automation_expect_deadline_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_expect_deadline_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_expect_deadline_tests_module.addImport("automation_server", automation_server_module);
    const run_automation_expect_deadline_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_expect_deadline_tests_module }));
    run_automation_expect_deadline_tests.skip_foreign_checks = true;
    // S8a (RoseCat 7098 #3): an approved flow through handleSocialFlow, the queue and the bound window.
    const automation_expect_flow_server_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_expect_flow_server_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_expect_flow_server_tests_module.addImport("automation_server", automation_server_module);
    const run_automation_expect_flow_server_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_expect_flow_server_tests_module }));
    run_automation_expect_flow_server_tests.skip_foreign_checks = true;
    // WS2.0 (Windows plan rev 2.6): the owner-only seam and where the socket lives.
    const owner_only_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/owner_only_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    owner_only_tests_module.addImport("owner_only", b.createModule(.{
        .root_source_file = b.path("src/owner_only.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    const run_owner_only_tests = b.addRunArtifact(b.addTest(.{ .root_module = owner_only_tests_module }));
    run_owner_only_tests.skip_foreign_checks = true;
    const transport_ws20_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_transport_ws20_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    transport_ws20_tests_module.addImport("automation_transport", b.createModule(.{
        .root_source_file = b.path("src/automation_transport.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_transport_ws20_tests = b.addRunArtifact(b.addTest(.{ .root_module = transport_ws20_tests_module }));
    run_transport_ws20_tests.skip_foreign_checks = true;
    const owner_only_step = b.step("test-owner-only", "Run WS2.0's owner-only seam and socket-place tests");
    owner_only_step.dependOn(&run_owner_only_tests.step);
    owner_only_step.dependOn(&run_transport_ws20_tests.step);
    // macOS plan rev 14 items 3 and 6 (MS5, BlueBeaver): where the agent runtime is per OS (an app bundle's
    // Contents/Frameworks/agent-host) and the setup gate (macOS refuses until MS6, never unsandboxed).
    const agent_setup_ms5_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_setup_ms5_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_setup_ms5_module.addImport("agent_setup", b.createModule(.{
        .root_source_file = b.path("src/agent_setup.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_agent_setup_ms5_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_setup_ms5_module }));
    run_agent_setup_ms5_tests.skip_foreign_checks = true;
    const agent_setup_ms5_python_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_setup_ms5_python_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_setup_ms5_python_module.addImport("agent_setup", b.createModule(.{
        .root_source_file = b.path("src/agent_setup.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_agent_setup_ms5_python_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_setup_ms5_python_module }));
    run_agent_setup_ms5_python_tests.skip_foreign_checks = true;
    const agent_setup_ms5_devtree_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_setup_ms5_devtree_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_setup_ms5_devtree_module.addImport("agent_setup", b.createModule(.{
        .root_source_file = b.path("src/agent_setup.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_agent_setup_ms5_devtree_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_setup_ms5_devtree_module }));
    run_agent_setup_ms5_devtree_tests.skip_foreign_checks = true;
    // MS5 rev 14 items 2 and 5: --browser-pid in setup's argv, and self_exe.path (libc: readlink / realpath).
    const agent_setup_ms5_wiring_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_setup_ms5_wiring_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_setup_ms5_wiring_module.addImport("agent_setup", b.createModule(.{
        .root_source_file = b.path("src/agent_setup.zig"),
        .target = target,
        .optimize = optimize,
    }));
    agent_setup_ms5_wiring_module.addImport("self_exe", b.createModule(.{
        .root_source_file = b.path("src/self_exe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    const run_agent_setup_ms5_wiring_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_setup_ms5_wiring_module }));
    run_agent_setup_ms5_wiring_tests.skip_foreign_checks = true;
    const agent_setup_ms5_step = b.step("test-agent-setup-ms5", "Run MS5's agent runtime location and setup-gate tests");
    agent_setup_ms5_step.dependOn(&run_agent_setup_ms5_tests.step);
    agent_setup_ms5_step.dependOn(&run_agent_setup_ms5_python_tests.step);
    agent_setup_ms5_step.dependOn(&run_agent_setup_ms5_devtree_tests.step);
    agent_setup_ms5_step.dependOn(&run_agent_setup_ms5_wiring_tests.step);
    // RoseCat 6948: the e2e's guarded group cleanup and unique-setup-child pick (tests/mac/lib_group_cleanup.sh),
    // pinned locally with stubbed pkill/pgrep/ps (never group 0, empty, malformed or our own; never a decoy child).
    const mac_group_cleanup = b.addSystemCommand(&.{ "bash", "tests/mac/lib_group_cleanup_test.sh" });
    mac_group_cleanup.addFileInput(b.path("tests/mac/lib_group_cleanup.sh"));
    mac_group_cleanup.addFileInput(b.path("tests/mac/lib_group_cleanup_test.sh"));
    agent_setup_ms5_step.dependOn(&mac_group_cleanup.step);
    // Chat drawer S7a (revs 16.20.30, 16.20.32): the core in process (callInProcess) and the
    // drawer's read-only broker over it; S7b (rev 16.20.36): its reply boundary and detach.
    var s7a_runs: [7]*std.Build.Step = undefined;
    for ([_][]const u8{ "tests/automation_inprocess_test.zig", "tests/agent_broker_test.zig", "tests/agent_broker_window_info_test.zig", "tests/agent_broker_reply_test.zig", "tests/agent_broker_detach_test.zig", "tests/agent_broker_detach_oom_test.zig", "tests/agent_broker_screenshot_test.zig" }, 0..) |path, i| {
        const s7a_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        s7a_module.addImport("automation_server", automation_server_module);
        const s7a_run = b.addRunArtifact(b.addTest(.{ .root_module = s7a_module }));
        s7a_run.skip_foreign_checks = true;
        s7a_runs[i] = &s7a_run.step;
    }
    // S7b (rev 16.20.35): the screenshot fit seam, src/agent_image.c (GdkPixbuf; Linux only).
    const agent_image_fit_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_image_fit_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_image_fit_module.addIncludePath(b.path("src"));
    agent_image_fit_module.addCSourceFile(.{ .file = b.path("src/agent_image.c"), .flags = &.{"-std=gnu11"} });
    agent_image_fit_module.linkSystemLibrary("gdk-pixbuf-2.0", .{ .use_pkg_config = .force });
    const run_agent_image_fit_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_image_fit_module }));
    run_agent_image_fit_tests.skip_foreign_checks = true;
    // RoseCat fb75e11: a PNG small enough to go as is still decodes first.
    const agent_image_small_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_image_fit_small_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_image_small_module.addIncludePath(b.path("src"));
    agent_image_small_module.addCSourceFile(.{ .file = b.path("src/agent_image.c"), .flags = &.{"-std=gnu11"} });
    agent_image_small_module.linkSystemLibrary("gdk-pixbuf-2.0", .{ .use_pkg_config = .force });
    const run_agent_image_small_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_image_small_module }));
    run_agent_image_small_tests.skip_foreign_checks = true;

    const automation_api_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_api_lifecycle_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-api-e2e",
    });
    automation_api_e2e.addArtifactArg(exe);

    // M12: external socket client drives the live page (fixture server).
    const automation_core_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_core_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-core-e2e",
    });
    automation_core_e2e.addArtifactArg(exe);

    // First-RPC dom.waitFor during a slow first load keeps the JS timeout authoritative.
    const automation_readiness_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_readiness_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-readiness-e2e",
    });
    automation_readiness_e2e.addArtifactArg(exe);

    // Python SDK driving the real binary (navigate -> type -> click -> getText).
    const sdk_python_live_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/sdk_python_live_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "sdk-python-live-e2e",
    });
    sdk_python_live_e2e.addArtifactArg(exe);

    // N11: x.post / x.schedule_post / x.login_check on the X composer fixture.
    const x_flows_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/x_flows_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "x-flows-e2e",
    });
    x_flows_e2e.addArtifactArg(exe);

    // N14: x.post / x.schedule_post with native, humanized input (isTrusted).
    const x_native_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/x_native_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "x-native-e2e",
    });
    x_native_e2e.addArtifactArg(exe);

    // N16: linkedin.* / instagram.* through the Python SDK on site-modelled fixtures.
    const social_flows_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/social_flows_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "social-flows-e2e",
    });
    social_flows_e2e.addArtifactArg(exe);
    // S8a: an approved flow on the real binary and the LinkedIn fixture (automation.js documentToken).
    const automation_expect_flow_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_expect_flow_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-expect-flow-e2e",
    });
    automation_expect_flow_e2e.addArtifactArg(exe);

    // N18: synthetic dom.scroll / dom.hover through the Python SDK; offsets
    // read back in the next command.
    const automation_scroll_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_scroll_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-scroll-e2e",
    });
    automation_scroll_e2e.addArtifactArg(exe);

    // PagePort v3.3/v3.4 on the real GTK adapter: screenshot PNG, file
    // chooser, native wheel scrolling.
    const automation_native_ports_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_native_ports_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-native-ports-e2e",
    });
    automation_native_ports_e2e.addArtifactArg(exe);

    // N21: pacing survives a restart on the same --profile-dir (real binary).
    const automation_pacing_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_pacing_persist_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-pacing-e2e",
    });
    automation_pacing_e2e.addArtifactArg(exe);

    // libsoup 3.6.5 HTTP/2 GOAWAY workaround: a local TLS HTTP/2 server ends each response
    // with GOAWAY(NO_ERROR); the page's fetch must succeed (SOUP_FORCE_HTTP1=1 by default).
    const http2_goaway_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/http2_goaway_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "http2-goaway-e2e",
    });
    http2_goaway_e2e.addArtifactArg(exe);

    // E2E harness hygiene: a browser started through the shared launcher
    // (tests/e2e/xsession.py) never outlives a test driver that dies mid-test.
    const harness_group_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/harness_group_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "harness-group-e2e",
    });
    harness_group_e2e.addArtifactArg(exe);

    // A window whose web process died says so in page.list and on stderr.
    const web_process_crash_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/web_process_crash_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "web-process-crash-e2e",
    });
    web_process_crash_e2e.addArtifactArg(exe);

    // --hardware-acceleration / --renderer reach WebKit's web process.
    const render_config_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/render_config_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "render-config-e2e",
    });
    render_config_e2e.addArtifactArg(exe);

    // The 15-second load timer never kills a committed page, nor a web
    // process related windows share.
    const slow_load_watchdog_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/slow_load_watchdog_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "slow-load-watchdog-e2e",
    });
    slow_load_watchdog_e2e.addArtifactArg(exe);

    // --media-source off / ZIGBROWSER_MEDIA_SOURCE=off: pages in every window,
    // popups and the screenshot see no MediaSource.
    const media_source_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/media_source_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "media-source-e2e",
    });
    media_source_e2e.addArtifactArg(exe);

    // Chat drawer S1: --agent-drawer, the overlay and the floating "S" icon,
    // driven by real X input on a private Xvfb (closure test S1). Missing
    // Xvfb, xwd or libXtst fails it (exit 1): no skip to green.
    const agent_drawer_icon_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_drawer_icon_test.py --binary \"$1\"",
        "agent-drawer-icon-e2e",
    });
    agent_drawer_icon_e2e.addArtifactArg(exe);

    // Chat drawer S2: the drawer shell (layout, '-' minimize animation,
    // keyboard, scrolling, Send with no agent) and threat test T1 (hostile
    // pages cannot reach or cover it). Real X input; never skips to green.
    const agent_drawer_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_drawer_test.py --binary \"$1\"",
        "agent-drawer-e2e",
    });
    agent_drawer_e2e.addArtifactArg(exe);
    // The user's requirement (2026-10-15): every drawer bubble and the status
    // text are selectable with the mouse and copied with Ctrl+C (real X input,
    // the private display's clipboard, a pre-seeded decoy).
    const agent_drawer_copy_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_drawer_copy_test.py --binary \"$1\"",
        "agent-drawer-copy-e2e",
    });
    agent_drawer_copy_e2e.addArtifactArg(exe);
    // Chat drawer S5a (S5.1-S5.3 and the S5 closure): the streamed reply grows one
    // bubble, Stop interrupts, and errors are plain sentences.
    const agent_chat_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_chat_test.py --binary \"$1\"",
        "agent-chat-e2e",
    });
    agent_chat_e2e.addArtifactArg(exe);
    // Chat drawer S7b (rev 16.20.34-16.20.36): the agent's read tools through the real chain
    // (Closure Test S7, S7.2, S7.4, S7.5, S7.8, the detach red) and S7.1's socket separation.
    const agent_tools_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_tools_test.py --binary \"$1\"",
        "agent-tools-e2e",
    });
    agent_tools_e2e.addArtifactArg(exe);
    const agent_socket_separation_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_socket_separation_test.py --binary \"$1\"",
        "agent-socket-separation-e2e",
    });
    agent_socket_separation_e2e.addArtifactArg(exe);
    // RoseCat 3b82071: the rest of S7's real-chain contracts (S7.2's other read tools, S7.6,
    // S7.7, S7.8) and the drawer-only boundary against a hostile page and the socket.
    const agent_tools_acceptance_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_tools_acceptance_test.py --binary \"$1\"",
        "agent-tools-acceptance-e2e",
    });
    agent_tools_acceptance_e2e.addArtifactArg(exe);
    // RoseCat 30b773e: all six tools under the S7.4 scanner, the failed tool's drawer bubble,
    // the exact forbidden-tool refusals, the S3.11 plant continuation, and the deadline seam.
    const agent_tools_acceptance2_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_tools_acceptance2_test.py --binary \"$1\"",
        "agent-tools-acceptance2-e2e",
    });
    agent_tools_acceptance2_e2e.addArtifactArg(exe);
    // Chat drawer S5b (S5.4): one session per window, transcripts in the agent's own home.
    const agent_window_sessions_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_window_sessions_test.py --binary \"$1\"",
        "agent-window-sessions-e2e",
    });
    agent_window_sessions_e2e.addArtifactArg(exe);
    // Chat drawer S5c-1 (S5.6, rev 16.20.2): a flood of output stays bounded, long
    // unbroken runs fold at once, Copy gives the original, an endless reply overflows.
    const agent_flood_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_flood_test.py --binary \"$1\"",
        "agent-flood-e2e",
    });
    agent_flood_e2e.addArtifactArg(exe);
    // Chat drawer S5c-1 (S5.6, rev 16.20.11 to 16.20.16): the cap is signalled, not counted,
    // and a completed bubble never shrinks.
    const agent_cap_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_cap_test.py --binary \"$1\"",
        "agent-cap-e2e",
    });
    agent_cap_e2e.addArtifactArg(exe);
    // Chat drawer S5d: a stale or future prompt's frame changes nothing in the app.
    const agent_prompt_scope_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_prompt_scope_test.py --binary \"$1\"",
        "agent-prompt-scope-e2e",
    });
    agent_prompt_scope_e2e.addArtifactArg(exe);
    // Chat drawer S5d fix-forward (RoseCat 6296): a session's first prompt waits for its
    // session_opened, and a failed open ends exactly the prompt that waited.
    const agent_open_order_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_open_order_test.py --binary \"$1\"",
        "agent-open-order-e2e",
    });
    agent_open_order_e2e.addArtifactArg(exe);
    // Chat drawer S5d fix-forward (RoseCat 6351): a session's spent prompt ids through the
    // real chain, by the e2e-only seam ZIGBROWSER_AGENT_TEST_PROMPT_BASE.
    const agent_prompt_exhaust_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_prompt_exhaust_test.py --binary \"$1\"",
        "agent-prompt-exhaust-e2e",
    });
    agent_prompt_exhaust_e2e.addArtifactArg(exe);
    // Chat drawer S5c-2 (S5.7): a credential echoed into an API error never stays in a
    // saved transcript, through the real chain.
    const agent_redact_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_redact_test.py --binary \"$1\"",
        "agent-redact-e2e",
    });
    agent_redact_e2e.addArtifactArg(exe);
    // Chat drawer S5b (S5.5, user answer 1): the drawer is on by default; with no agent
    // home Send says the runtime is not set up; stop_browser fails a test a helper ran in.
    const agent_default_on_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_default_on_test.py --binary \"$1\"",
        "agent-default-on-e2e",
    });
    agent_default_on_e2e.addArtifactArg(exe);
    // Chat drawer S3c (plan S3.10, section 2): a `.claude` changed outside the
    // sandbox refuses the next session; the writable state directories do not.
    const agent_config_check_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_config_check_test.py --binary \"$1\"",
        "agent-config-check-e2e",
    });
    agent_config_check_e2e.addArtifactArg(exe);
    const agent_isolation_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_isolation_test.py --binary \"$1\"",
        "agent-isolation-e2e",
    });
    agent_isolation_e2e.addArtifactArg(exe);

    // zbHost: the IPC rows, and the page's own promise settling (chat drawer
    // S1.6), on a private Xvfb.
    const ipc_roundtrip_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/ipc_roundtrip_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "ipc-roundtrip-e2e",
    });
    ipc_roundtrip_e2e.addArtifactArg(exe);

    // page.health: a frozen page turns responsive:false, out of band, while
    // another window stays responsive (watchdog slice 1).
    const page_health_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/page_health_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "page-health-e2e",
    });
    page_health_e2e.addArtifactArg(exe);

    // page.recover: a confirmed recovery ends a frozen web process and
    // reloads its windows; refusals end nothing (watchdog slice 2).
    const page_recover_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/page_recover_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "page-recover-e2e",
    });
    page_recover_e2e.addArtifactArg(exe);

    // Claude Agent helper (chat drawer P0): unit tests, and the boundary
    // contracts that run the real SDK and bundled CLI against a fake Messages
    // API. Both fail closed when the helper venv is missing (run
    // tools/agent_host_env.sh first); neither starts the browser.
    const agent_host_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_unit",
    });
    // WS item b: the pure Windows helper branches — path containment, argv quoting
    // (CommandLineToArgvW), and the fail-closed job-object containment choice. Stdlib-only, platform-neutral.
    // test_wincontain_win32_import_safe pins that the live Job Object backend module imports on a non-Windows
    // host (lazy kernel32 binding) and fails closed when a real kernel32 is absent (RoseCat 6544).
    const agent_host_wincontain = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_wincontain test_wincontain_win32_import_safe",
    });
    // macOS plan rev 14 item 5 (MS5): setup's Darwin parent watch, the fail-closed sequence with its OS
    // calls injected, so it runs here. Stdlib-only.
    const agent_host_parent_watch = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_parent_watch",
    });
    // macOS plan rev 14 items 5-6 (MS5): setup.py's Darwin branches with the platform injected: --browser-pid fails
    // closed and arms the parent watch first; setup's sandbox runs through MS6's sandbox_macos.setup_sandbox (the real
    // symbol, pure stdlib) or refuses.
    const agent_host_setup_darwin = b.addSystemCommand(&.{
        "sh",
        "-c",
        // -X dev shows every ResourceWarning (they fire in finalizers, where -W error cannot fail a test), so the
        // output is counted: any one fails the step (RoseCat 6966).
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_setup_darwin 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_setup_darwin: ResourceWarning' >&2; exit 1; fi",
    });
    // RoseCat 6966: also in the focused MS5 setup gate, as 2d65b12 does for the cleanup test.
    agent_setup_ms5_step.dependOn(&agent_host_setup_darwin.step);
    // R1 under Seatbelt, the probe's half (RoseCat 6958; BlackRobin 6975): probe-r1 adopts only setup's checked
    // 127.0.0.1:<port> listener (--listen-fd/--listen-port, macOS-only). Same ResourceWarning sentinel as above.
    const agent_host_route_probe_listen_fd = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_route_probe_listen_fd 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_route_probe_listen_fd: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_route_probe_listen_fd.step);
    // R1 on macOS, the probe's CLI-environment check (BlueBeaver 6977; BlackRobin 6983): proc_darwin's parser and walk,
    // and route_probe's canary-gated verdict. The real libproc/KERN_PROCARGS2 calls run in tests/mac/ms5_r1_env_gate.sh.
    const agent_host_proc_darwin = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_proc_darwin 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_proc_darwin: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_proc_darwin.step);
    const agent_host_route_probe_darwin_env = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_route_probe_darwin_env 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_route_probe_darwin_env: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_route_probe_darwin_env.step);
    // R1 under Seatbelt, setup's half (RoseCat 6958; JadeBeacon 7004): probe_r1 pre-binds 127.0.0.1:0, passes it by
    // pass_fds, and the setup profile permits exactly that port (through the real sandbox_macos.setup_sandbox).
    const agent_host_setup_darwin_r1 = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_setup_darwin_r1 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_setup_darwin_r1: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_setup_darwin_r1.step);
    // R1's census broker (RoseCat 7019; BlueBeaver 7021): setup runs the Darwin process census outside Seatbelt, the
    // probe asks over a socketpair (--census-fd). The kernel-properties half is tests/mac/ms6_r1_kernel_gate.sh (plan
    // MS6.6 (A)); the Mac production chain is MS6.6 (B).
    const agent_host_route_probe_census = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_route_probe_census 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_route_probe_census: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_route_probe_census.step);
    const agent_host_setup_census = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_setup_census 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_setup_census: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_setup_census.step);
    // Durable dual-family ownership (plan contract 6016938; bead zigBrowser-v9f): setup's R1 listener also holds
    // [::1]:<same port>, non-listening, and fails closed without it.
    const agent_host_setup_darwin_r1_v6 = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_setup_darwin_r1_v6 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_setup_darwin_r1_v6: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_setup_darwin_r1_v6.step);
    // launch.py's --egress-port + Session carrier (BlackRobin 7035/7108 seam 2); Linux-runnable (PLATFORM injected).
    const agent_host_launch = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_launch 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_launch: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_launch.step);
    // Chat drawer S3.1: --agent-setup's provisioning (unit and property
    // tests of the helper's setup command); fails closed without the venv.
    const agent_host_provision_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_provision",
    });
    // Chat drawer S3b: the helper's `chat` (real SDK and CLI against the fake
    // Messages API, token on fd 3, R1 only) and `launch` (the sandbox with its
    // own network, the outer relay as its command); fails closed without the venv.
    const agent_host_chat = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_chat",
    });
    // Chat drawer S5a (S5.3, rev 16.14): API errors become plain error frames with
    // the real CLI; the e2e-only no-retry setting; interrupt ends the prompt.
    const agent_host_chat_errors = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_chat_errors",
    });
    // Chat drawer S5c-1 (S5.6): no streamed character is lost, and every frame fits the
    // app's caps as encoded.
    const agent_host_chat_flood = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_chat_flood",
    });
    // Chat drawer S5c-1 (S5.6, rev 16.20.11 to 16.20.13): forwarding ends at the first code
    // point that does not fit, reply_capped says so, and no message shortens a bubble.
    const agent_host_chat_cap = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_chat_cap",
    });
    // Chat drawer S5d: the helper echoes each prompt's id on every frame of its reply.
    const agent_host_chat_prompt_id = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_chat_prompt_id",
    });
    // Chat drawer S5d fix-forward (RoseCat 6307, 6314): a message's frame is sized with its
    // prompt_id, at the largest seq the app accepts.
    const agent_host_chat_fit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_chat_fit",
    });
    // Chat drawer S5c-2 (S5.7): the transcript scrubber, driven directly, then in the helper.
    const agent_host_redact = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_redact",
    });
    const agent_host_chat_redact = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_chat_redact",
    });
    // Chat drawer S7.0 (rev 16.20.30, 16.20.32): the Bridge names the running prompt; tool_result by
    // id, in section 3's grammar; every ending ends its calls; S7b (rev 16.20.34): its six read tools.
    // Each module runs alone.
    const agent_host_bridge = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_bridge && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_bridge_result && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_bridge_endings && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_bridge_envelope && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_tools",
    });
    // Chat drawer S6 (rev 16.18): the one-shot sign-in helper drives the
    // setup-token fake on a pty; the token reaches fd 4 only.
    const agent_host_login = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_login",
    });
    // RoseCat 5967: the authorize URL's fixed values, the first code wins, one ending.
    const agent_host_login_contract = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_login_contract",
    });
    // The login tests' cleanup ends the helper by the end of its stdin, so its CLI is not orphaned.
    const agent_host_login_reap = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_login_reap",
    });
    // Rev 16.20.27 (Part B's second finding): a real-length code's Enter is its own write.
    const agent_host_login_paste = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_login_paste",
    });
    // Rev 16.20.28 (RoseCat 6493): no Enter after an ending; the Enter after all of the code.
    const agent_host_login_enter = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_login_enter",
    });
    // Rev 16.20.29 (RoseCat 6499): the code typed in pieces paced by the echo; fail closed.
    const agent_host_login_typing = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_login_typing",
    });
    // Rev 16.18.9 (S6b1 part B): the CLI's relay proxy; an OAuth error or silence
    // after a code ends the sign-in (error exchange, the 60 s exchange clock).
    const agent_host_login_exchange = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_login_exchange",
    });
    // Rev 16.18.11: login.authorize_url answers the same authorize-URL case table.
    const agent_host_authorize_parity = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_authorize_parity",
    });
    // WS7.5 (bead zigBrowser-2p3; reds 56e0bcd, 1b25a2d, 1f03e76; RoseCat 6324; AzureRidge 6335):
    // zb_agent_host imports on Windows (the deep import-time scan and a controlled win32 import),
    // and every command is refused there before its module loads, with each fork/exec seam
    // failing closed by name.
    const agent_host_win_import = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 python3 test_windows_import.py && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_windows_import_deep test_windows_entry",
    });
    b.step("agent-host-win-import", "Check that no zb_agent_host module imports a POSIX-only module at top level (WS7.5)").dependOn(&agent_host_win_import.step);
    // Chat drawer S3.1/S3.7: the real `zigBrowser --agent-setup` against a
    // decoy HOME, with the real token-route probe on the bundled CLI.
    const agent_setup_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_setup_test.py --binary \"$1\"",
        "agent-setup-e2e",
    });
    agent_setup_e2e.addArtifactArg(exe);
    // Chat drawer S3n2: the browser starts netd on the first Send (with a
    // provisioned agent home), reports its failures and stops it at quit.
    const agent_netd_spawn_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_netd_spawn_test.py --binary \"$1\"",
        "agent-netd-spawn-e2e",
    });
    agent_netd_spawn_e2e.addArtifactArg(exe);
    // MS0 slice D: the browser hands netd the backend's network manifest.
    const agent_netd_manifest_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_netd_manifest_test.py --binary \"$1\"",
        "agent-netd-manifest-e2e",
    });
    agent_netd_manifest_e2e.addArtifactArg(exe);
    // Chat drawer S3b: the first Send starts a confined helper, its frames are
    // validated natively, and every exit path cleans it up (Closure Test S3).
    // The whole run sits in a network namespace of its own: nothing real is reachable.
    const agent_host_lifecycle_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_host_lifecycle_test.py --binary \"$1\"",
        "agent-host-lifecycle-e2e",
    });
    agent_host_lifecycle_e2e.addArtifactArg(exe);
    // Chat drawer S4a: the Secrets window stores a typed token in a private
    // keyring or the explicit 0600 file, and Send with no token opens it. The
    // S4b cases (handoff, remove-session, hooks) join after S3b's helper.
    const agent_secrets_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_secrets_test.py --binary \"$1\" --only secret-service,file-flag,rejected,no-keyring,remove,unreachable,fallback-persists,stale-store,lookup-race,remove-both,remove-close,account-button,account-after-no-token,canary-self-test,shape,shape-file,handoff,remove-session,hooks,remove-during-fetch,remove-during-net,send-during-clear,replace-during-fetch,planted-keyring",
        "agent-secrets-e2e",
    });
    agent_secrets_e2e.addArtifactArg(exe);
    // Chat drawer S6b1 (rev 16.18.3): Sign in with Claude.ai through the paste path,
    // the login netd and helper, and S6.1's CLAUDE_CLI inertness.
    const agent_login_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_login_test.py --binary \"$1\"",
        "agent-login-e2e",
    });
    agent_login_e2e.addArtifactArg(exe);
    // RoseCat 6024 (rev 16.18.6): one credential change at a time, one ending through
    // the file fallback, and the inert route's Cancel.
    const agent_login_races_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_login_races_test.py --binary \"$1\"",
        "agent-login-races-e2e",
    });
    agent_login_races_e2e.addArtifactArg(exe);
    // RoseCat 6055 (rev 16.18.7): every credential control's lock, observed through
    // `SECRETS sensitive`, including during the signed-in token's own store.
    const agent_login_locks_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_login_locks_test.py --binary \"$1\"",
        "agent-login-locks-e2e",
    });
    agent_login_locks_e2e.addArtifactArg(exe);
    // Rev 16.18.9 (S6b1 part B's finding): the sign-in through the relay proxy, and
    // a visible reason, never a silent wait, when the CLI fails or says nothing.
    const agent_login_exchange_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_login_exchange_test.py --binary \"$1\"",
        "agent-login-exchange-e2e",
    });
    agent_login_exchange_e2e.addArtifactArg(exe);
    // Rev 16.20.27 (Part B's second finding): a real-length code pasted in the Secrets window.
    const agent_login_paste_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_login_paste_test.py --binary \"$1\"",
        "agent-login-paste-e2e",
    });
    agent_login_paste_e2e.addArtifactArg(exe);
    // S6b2 (rev 16.18.16-16.18.20): the auth window on the fake provider: capture, five A2 cases,
    // popup, isolation, and the seam refused or ignored (the last with no network).
    const agent_auth_window_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_auth_window_test.py --binary \"$1\"",
        "agent-auth-window-e2e",
    });
    agent_auth_window_e2e.addArtifactArg(exe);
    // Rev 16.20.33 (RoseCat 6457): the auth window's oracles: subframe capture refused, the
    // rejection stderr line, the view policies, the hand-close fallback.
    const agent_auth_window_oracles_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_auth_window_oracles_test.py --binary \"$1\"",
        "agent-auth-window-oracles-e2e",
    });
    agent_auth_window_oracles_e2e.addArtifactArg(exe);
    // Rev 16.18.10 (RoseCat 6184): the Secrets window never outlives its parent, and a
    // running sign-in is cancelled exactly once (defence in depth; the gnome-shell crash
    // at the user's part A quit stays open).
    const agent_secrets_shutdown_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_secrets_shutdown_test.py --binary \"$1\"",
        "agent-secrets-shutdown-e2e",
    });
    agent_secrets_shutdown_e2e.addArtifactArg(exe);
    // RoseCat 6321 (red 1555ddc): the teardown test's X watcher reads a vanished window as
    // not viewable (BadWindow trapped for its own request), on a bare private Xvfb.
    const agent_secrets_watch_e2e = b.addSystemCommand(&.{ "python3", "tests/e2e/agent_secrets_watch_test.py" });
    // Plan §7.1: the real-screen check's verdict and environment, with fake
    // captures (no display, no browser). The check itself runs only on the
    // user's screen, by the orchestrator.
    const real_screen_check_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/manual && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_real_screen_check && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_real_screen_tools",
    });
    // The same check's input guard against a real X server: decoy windows on
    // a private Xvfb (xsession.py) must receive no click or key.
    const real_screen_input_xvfb = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/manual && env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY python3 ../e2e/xsession.py --xvfb -- env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_real_screen_input",
    });
    // Chat drawer S5c-1 (S5.6, rev 16.20.11): the long-run real-screen case, run as the
    // orchestrator runs it on the user's screen, but on a private Xvfb.
    const real_screen_longrun_xvfb = b.addSystemCommand(&.{
        "sh",
        "-c",
        "bin=$(realpath \"$1\") && cd tests/manual && env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY ZB_LONGRUN_BIN=\"$bin\" python3 ../e2e/xsession.py --xvfb -- env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_real_screen_longrun",
        "real-screen-longrun",
    });
    real_screen_longrun_xvfb.addArtifactArg(exe);
    // The X input harness survives an X error about a window that just went away
    // (BlackRobin 5773), on its own private Xvfb.
    const xinput_errors_xvfb = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY python3 xsession.py --xvfb -- env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_xinput_errors",
    });
    // Chat drawer S6: the setup-token fake matches the real CLI's capture
    // (tests/fixtures/agent/setup_token_transcript.json) line for line, on a pty.
    const fake_setup_token_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v fake_claude_setup_token_test",
    });
    // MS1 (RoseCat 6101): the off-Mac census + resource-phase mutation suite — pure Python, no Mac,
    // no display. It carries the omission / single-arch / fail-closed-probe / wrong-location /
    // resource-mismatch / exact-MS1-browser-only mutants that made the MS1 red acceptable; register
    // it in the default Linux gate so breaking tests/e2e/mac_universal_test.py's census/resource
    // contracts fails `zig build test`. cwd is tests/e2e so `import mac_universal_test` resolves
    // (no -I: isolated mode drops the script dir from sys.path on this host).
    const mac_census_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v mac_universal_census_test",
    });
    const mac_census_step = b.step("test-mac-census", "Run the MS1 off-Mac census/resource-phase mutation suite (pure Python)");
    mac_census_step.dependOn(&mac_census_unit.step);
    // macOS plan rev 17 (MS5.1c-a): the generated MS5 inventory and its drift check, runtime.json's exact bytes,
    // and the exact zb_agent_host/ walk (no extra, no symlink, no special file). Pure Python, off-Mac.
    const mac_ms5_census_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v mac_ms5_census_test",
    });
    mac_census_step.dependOn(&mac_ms5_census_unit.step);
    // MS5 dependency pin (the user's decision): cryptography 48.0.1 on macOS only (a universal2 abi3 wheel for one fat
    // runtime tree), as a darwin-marked uv constraint; Linux keeps its own resolution. Pure file checks on uv.lock.
    const mac_ms5_crypto_pin_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 python3 -X dev -m unittest -v mac_ms5_crypto_pin_test 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'mac_ms5_crypto_pin_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&mac_ms5_crypto_pin_unit.step);
    // MS5 framework relocation: every Mach-O of the bundled python.org framework loads @loader_path-relative paths,
    // never /Library/Frameworks/Python.framework or a foreign absolute path. The off-Mac planner suite; the real
    // relocation and runtime proof is tests/mac/ms5_relocate_gate.sh on both Macs. Pure, no signal.
    const mac_relocate_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 python3 -X dev -m unittest -v mac_relocate_test 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'mac_relocate_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&mac_relocate_unit.step);
    // The staged runtime's one SDK .pth (27a9a62: ModuleNotFoundError claude_agent_sdk on both Macs): the committed line,
    // every stray/non-path refusal, and a real CPython under -I importing through it. Its Mac half is
    // tests/mac/ms5_stage_gate.sh. Spawns a venv python, sends no signal; namespaced like its siblings.
    const mac_sdk_pth_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest -v mac_sdk_pth_test' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'mac_sdk_pth_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&mac_sdk_pth_unit.step);
    // MS5 fat agent-host: the strict universal2 merge of the two per-arch site-packages trees (lipo pairs, WHEEL tags,
    // per-arch SBOMs, regenerated RECORDs, every boundary refused). Off-Mac with an injected lipo; the real merge is
    // tests/mac/ms5_deps_gate.sh on both Macs. Its FIFO case arms a SIGALRM on itself (no kill()), so it runs inside
    // a private user+PID namespace like every signal-receiving test (RoseCat 7233, 7238).
    const mac_merge_universal_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest -v mac_merge_universal_test' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'mac_merge_universal_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&mac_merge_universal_unit.step);
    // Plan rev 18.1: the ONE pre-seatbelt_ready MS6 hard-gate harness (tests/mac/ms6_hard_gate.sh). Off-Mac, its
    // driver's fail-closed rules (a failed check, a raise, no check, no NAME/run, a duplicate NAME, no cases, a scratch
    // left behind) and the NOT ARMED entry without the MS5-pinned tree.
    // Every ms6_hard_gate module runs inside a private user+PID namespace (RoseCat 7167): the harness sends real SIGKILL to
    // process groups, and there kill(-1) can reach nothing of the user's. setsid makes the test process lead a real group.
    const ms6_hard_gate_driver_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_driver_test' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms6_hard_gate_driver_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms6_hard_gate_driver_unit.step);
    // The hard gate runs only its reviewed cases: hard_gate_driver.py --manifest refuses an unreviewed, missing or
    // edited case before importing anything (RoseCat 7250 #2, #3). Namespaced like its siblings.
    const ms6_hard_gate_manifest_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_manifest_test' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms6_hard_gate_manifest_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms6_hard_gate_manifest_unit.step);
    // The R1 chain case's release inspection (RoseCat 7306): bytes argv classified, every non-clean scan drained to a
    // clean one within the row's horizon. Fakes only (no process, no signal); namespaced like its siblings.
    const ms6_hard_gate_r1_case_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_r1_case_test' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms6_hard_gate_r1_case_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms6_hard_gate_r1_case_unit.step);
    // The ARMED hard-gate entry: the MS5 pins, every bad precondition refused before any network, and the pinned pkg
    // download as its first network call (RoseCat 7250, 9dfc9c7). Recording shims only; no Mac is contacted.
    const ms6_hard_gate_entry_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_entry_test' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms6_hard_gate_entry_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms6_hard_gate_entry_unit.step);
    // RoseCat 7134: the harness itself. spawn_group owns each process group exactly once (signalled while the leader is
    // unreaped, then reaped), and NOT ARMED touches no network (recording ssh/scp/curl/nc shims, canary hosts).
    const ms6_hard_gate_harness_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_harness_test' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms6_hard_gate_harness_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms6_hard_gate_harness_unit.step);
    // The Harness signals only its own child's own group: never a mocked pid, 0/1/-1, our group, a child in our
    // group, or a group leader that is not our child (the 2026-10-21 logouts; RoseCat on efe2517). No real signal.
    const ms6_hard_gate_harness_safety_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_harness_safety_test' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms6_hard_gate_harness_safety_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms6_hard_gate_harness_safety_unit.step);
    const agent_host_contract = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_contract",
    });
    // MS0 (macOS launch plan, rev 6): the shared SandboxBackend seam — the
    // behaviour-preserving golden-argv oracle (LinuxBwrapBackend reproduces
    // helper_argv byte-for-byte) and the backend-supplied network capability
    // (egress endpoint + bridge policy); fails closed without the venv.
    const agent_host_backend_contract = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_backend_contract",
    });
    // MS6 macOS Seatbelt backend — the profile generator's content rules, unit-tested on Linux (pure
    // Python; the kernel enforcement is the MS6.1-6.5 Mac gate). Pins the token-isolation belt measured on
    // both arches: explicit (deny process-info*) + curated sysctl-read, scratchpad-only writes, hook bridges-only.
    const agent_host_sandbox_macos = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_sandbox_macos",
    });
    // Chat drawer S3n1 (plan rev 16.2 §3c): the host-side network helper and the
    // two relays, driven through their command lines, offline (private fakes on
    // 127.0.0.1 and short /tmp/zbn-* socket directories only).
    // macOS netd (BlueBeaver 6971; JadeBeacon 7004): a host-loopback TCP egress proxy on an OS-selected port, announced
    // as `netd ready 127.0.0.1:<port>`; netd's real main() with PLATFORM "darwin". The native run on both Macs is
    // tests/mac/ms6_netd_darwin_gate.sh.
    const agent_host_netd_darwin = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_netd_darwin 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_netd_darwin: ResourceWarning' >&2; exit 1; fi",
    });
    // Durable dual-family ownership (plan contract 6016938; bead zigBrowser-v9f): Darwin netd also holds
    // [::1]:<its port>, non-listening, and refuses without it; the native run is tests/mac/ms6_netd_darwin_gate.sh.
    const agent_host_netd_darwin_v6 = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_netd_darwin_v6 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_netd_darwin_v6: ResourceWarning' >&2; exit 1; fi",
    });
    const agent_host_netd = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_netd",
    });
    const agent_host_relay = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_relay",
    });
    // MS0 slices D and E: netd's manifest (allow-list and bridge ports) and the
    // inner relay's --ports, each module run alone like the others.
    const agent_host_netd_manifest = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_netd_manifest",
    });
    // Chat drawer S6 (rev 16.18.1): the sign-in's own netd (net-login.json, no
    // bridges) reaches platform.claude.com; chat's still refuses it.
    const agent_host_netd_login = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_netd_login",
    });
    // Rev 16.18.4: netd's --census (the sign-in's netd under --e2e-protocol).
    const agent_host_netd_census = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_netd_census",
    });
    // Chat drawer S6 (rev 16.18.1/16.18.2): the sign-in's network is its own
    // backend capability, launch spec and published runtime/net-login.json.
    const agent_host_login_network = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_login_network",
    });
    const agent_host_relay_ports = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_relay_ports",
    });
    // Chat drawer S3n2 (plan rev 16.2 §3c.8b): each hook's own sealed network, from a
    // real outer sandbox through the real zb-hook-run. The module runs in a disposable
    // network namespace with only loopback (it fails rather than skips elsewhere).
    const agent_host_hook_net = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" /usr/bin/bwrap --unshare-net --die-with-parent --dev-bind / / --proc /proc -- \"$py\" -m unittest -v test_hook_net",
    });

    // Page dialogs (alert/confirm/prompt/beforeunload) in the primary window
    // and a popup: dialog.get / dialog.respond, page.navigate onBeforeUnload.
    const automation_dialogs_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_dialogs_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-dialogs-e2e",
    });
    automation_dialogs_e2e.addArtifactArg(exe);

    // N23: popup window targeting through the socket (page.list, window_id,
    // page.close, then no_window for the closed popup).
    const automation_windows_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_windows_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-windows-e2e",
    });
    automation_windows_e2e.addArtifactArg(exe);
    // S8a decision 14: automation.js's per-event guard against page handlers, on the real binary.
    const automation_guard_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_guard_test.py --binary \"$1\"",
        "automation-guard-e2e",
    });
    automation_guard_e2e.addArtifactArg(exe);
    // S8a decision 15: the chunk boundary on the real binary (a page timer runs only between chunks).
    const automation_guard_chunks_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_guard_chunks_test.py --binary \"$1\"",
        "automation-guard-chunks-e2e",
    });
    automation_guard_chunks_e2e.addArtifactArg(exe);
    // S8a (RoseCat on 76cb14a): a same-selector clone or a new document between chunks stops the type.
    const automation_guard_chunks2_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_guard_chunks2_test.py --binary \"$1\"",
        "automation-guard-chunks2-e2e",
    });
    automation_guard_chunks2_e2e.addArtifactArg(exe);
    // S8a (RoseCat on 9295b0b): a guarded contenteditable insert counts only what was inserted.
    const automation_guard_insert_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_guard_insert_test.py --binary \"$1\"",
        "automation-guard-insert-e2e",
    });
    automation_guard_insert_e2e.addArtifactArg(exe);
    // S8a: each window's committed-load count (load_serial) in page.list and page.health.
    const automation_load_serial_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_load_serial_test.py --binary \"$1\"",
        "automation-load-serial-e2e",
    });
    automation_load_serial_e2e.addArtifactArg(exe);

    // Input verbs (contenteditable type/fill, ...) against the live page.
    const automation_input_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_input_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-input-e2e",
    });
    automation_input_e2e.addArtifactArg(exe);

    // --profile-dir keeps cookies across restarts (real binary, local HTTP).
    const automation_profile_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_profile_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-profile-e2e",
    });
    automation_profile_e2e.addArtifactArg(exe);

    // cookies.* against the real cookie store (local HTTP, restart on profile).
    const automation_cookies_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_cookies_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-cookies-e2e",
    });
    automation_cookies_e2e.addArtifactArg(exe);

    // --- Phase 4: Gaussian tests ---
    const gaussian_module = b.createModule(.{
        .root_source_file = b.path("src/automation/gaussian.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gaussian_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation/gaussian_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    gaussian_tests_module.addImport("gaussian", gaussian_module);
    const gaussian_tests = b.addTest(.{ .root_module = gaussian_tests_module });
    const run_gaussian_tests = b.addRunArtifact(gaussian_tests);

    // --- Phase 4: Bezier tests ---
    const bezier_module = b.createModule(.{
        .root_source_file = b.path("src/automation/bezier.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bezier_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation/bezier_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    bezier_tests_module.addImport("bezier", bezier_module);
    const bezier_tests = b.addTest(.{ .root_module = bezier_tests_module });
    const run_bezier_tests = b.addRunArtifact(bezier_tests);

    const stealth_module = b.createModule(.{
        .root_source_file = b.path("src/automation/stealth.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Phase 4: Pacing tests ---
    const pacing_module = b.createModule(.{
        .root_source_file = b.path("src/automation/pacing.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pacing_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation/pacing_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pacing_tests_module.addImport("pacing", pacing_module);
    pacing_tests_module.addImport("stealth", stealth_module);
    const pacing_tests = b.addTest(.{ .root_module = pacing_tests_module });
    const run_pacing_tests = b.addRunArtifact(pacing_tests);

    // --- Phase 4: Session tests ---
    const session_module = b.createModule(.{
        .root_source_file = b.path("src/automation/session.zig"),
        .target = target,
        .optimize = optimize,
    });
    const session_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation/session_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    session_tests_module.addImport("session", session_module);
    const session_tests = b.addTest(.{ .root_module = session_tests_module });
    const run_session_tests = b.addRunArtifact(session_tests);

    // --- Phase 4: Stealth telemetry tests ---
    const stealth_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation/stealth_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    stealth_tests_module.addImport("stealth", stealth_module);
    const stealth_tests = b.addTest(.{ .root_module = stealth_tests_module });
    const run_stealth_tests = b.addRunArtifact(stealth_tests);

    // --- Phase 5: Social contracts ---
    const social_module = b.createModule(.{
        .root_source_file = b.path("src/social.zig"),
        .target = target,
        .optimize = optimize,
    });
    const social_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/social_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    social_tests_module.addImport("social", social_module);
    const social_tests = b.addTest(.{ .root_module = social_tests_module });
    const run_social_tests = b.addRunArtifact(social_tests);
    run_social_tests.skip_foreign_checks = true;

    const x_module = b.createModule(.{
        .root_source_file = b.path("src/x.zig"),
        .target = target,
        .optimize = optimize,
    });
    const x_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/x_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    x_tests_module.addImport("x", x_module);
    const x_tests = b.addTest(.{ .root_module = x_tests_module });
    const run_x_tests = b.addRunArtifact(x_tests);
    run_x_tests.skip_foreign_checks = true;

    const linkedin_module = b.createModule(.{
        .root_source_file = b.path("src/linkedin.zig"),
        .target = target,
        .optimize = optimize,
    });
    const linkedin_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/linkedin_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkedin_tests_module.addImport("linkedin", linkedin_module);
    const linkedin_tests = b.addTest(.{ .root_module = linkedin_tests_module });
    const run_linkedin_tests = b.addRunArtifact(linkedin_tests);
    run_linkedin_tests.skip_foreign_checks = true;

    const instagram_module = b.createModule(.{
        .root_source_file = b.path("src/instagram.zig"),
        .target = target,
        .optimize = optimize,
    });
    const instagram_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/instagram_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    instagram_tests_module.addImport("instagram", instagram_module);
    const instagram_tests = b.addTest(.{ .root_module = instagram_tests_module });
    const run_instagram_tests = b.addRunArtifact(instagram_tests);
    run_instagram_tests.skip_foreign_checks = true;

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&windows_gate_selftest.step);
    test_step.dependOn(&windows_resolve_live.step);
    test_step.dependOn(&windows_twohost_selftest.step);
    test_step.dependOn(&windows_build_selftest.step);
    test_step.dependOn(&windows_pe_census_selftest.step);
    test_step.dependOn(&windows_png_census_selftest.step);
    test_step.dependOn(&windows_screenshot_diag_selftest.step);
    test_step.dependOn(&windows_wincontain_argv_live.step);
    test_step.dependOn(&windows_wincontain_resolve_live.step);
    test_step.dependOn(&windows_wincontain_job_live.step);
    test_step.dependOn(&windows_screenshot_live.step);
    test_step.dependOn(&windows_config_flags_live.step);
    test_step.dependOn(&windows_transport_live.step);
    test_step.dependOn(&windows_refusal_live.step);
    test_step.dependOn(&run_ipc_tests.step);
    test_step.dependOn(&run_nav_policy_tests.step);
    test_step.dependOn(&run_agent_drawer_tests.step);
    test_step.dependOn(&run_agent_drawer_breaks_tests.step);
    test_step.dependOn(&run_agent_net_tests.step);
    test_step.dependOn(&run_agent_net_manifest_tests.step);
    test_step.dependOn(&run_agent_host_posix_tests.step);
    test_step.dependOn(&run_agent_host_posix_spawn_tests.step);
    test_step.dependOn(&run_agent_run_reaper_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_reaper_engine_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_reaper_pin_tests.step);
    test_step.dependOn(&run_mac_vm_containment_tests.step);
    test_step.dependOn(&mac_vm_containment_e2e.step);
    test_step.dependOn(&run_agent_secrets_tests.step);
    test_step.dependOn(&run_agent_secrets_shape_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_agent_secrets_dlopen_test.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_agent_secrets_clear_fetch_test.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_agent_image_fit_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_agent_image_small_tests.step);
    const agent_secrets_step = b.step("test-agent-secrets", "Run the Claude Agent token store's unit tests");
    agent_secrets_step.dependOn(&run_agent_secrets_tests.step);
    agent_secrets_step.dependOn(&run_agent_secrets_shape_tests.step);
    if (target.result.os.tag == .linux) agent_secrets_step.dependOn(&run_agent_secrets_dlopen_test.step);
    if (target.result.os.tag == .linux) agent_secrets_step.dependOn(&run_agent_secrets_clear_fetch_test.step);
    test_step.dependOn(&run_agent_auth_tests.step);
    test_step.dependOn(&run_agent_login_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_login_e2e.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_login_races_e2e.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_login_locks_e2e.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_login_exchange_e2e.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_login_paste_e2e.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_auth_window_e2e.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_auth_window_oracles_e2e.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_secrets_shutdown_e2e.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_secrets_watch_e2e.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&fake_setup_token_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&mac_census_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&mac_ms5_census_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&mac_ms5_crypto_pin_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&mac_relocate_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&mac_sdk_pth_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&mac_merge_universal_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms6_hard_gate_driver_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms6_hard_gate_manifest_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms6_hard_gate_r1_case_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms6_hard_gate_entry_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms6_hard_gate_harness_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms6_hard_gate_harness_safety_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&kill_group_tests.step);
    test_step.dependOn(&run_agent_login_protocol_tests.step);
    test_step.dependOn(&run_backend_flag_tests.step);
    test_step.dependOn(&run_backend_flag_startup_tests.step);
    test_step.dependOn(&startup_entrypoint_test.step);
    test_step.dependOn(&run_agent_auth_navigation_tests.step);
    test_step.dependOn(&run_agent_auth_response_tests.step);
    test_step.dependOn(&run_agent_auth_thirdparty_tests.step);
    test_step.dependOn(&agent_host_win_import.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_agent_auth_seam_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_host_login.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_host_login_contract.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_host_login_reap.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_host_login_paste.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_host_login_enter.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_host_login_typing.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_host_login_exchange.step);
    test_step.dependOn(&run_agent_auth_authorize_tests.step);
    test_step.dependOn(&run_agent_login_authorize_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&agent_host_authorize_parity.step);
    const agent_auth_step = b.step("test-agent-auth", "Run the Claude Agent sign-in's callback check, login frames, login helper and setup-token fake tests");
    agent_auth_step.dependOn(&run_agent_auth_tests.step);
    if (target.result.os.tag == .linux) agent_auth_step.dependOn(&fake_setup_token_unit.step);
    agent_auth_step.dependOn(&run_agent_login_protocol_tests.step);
    agent_auth_step.dependOn(&run_agent_auth_navigation_tests.step);
    agent_auth_step.dependOn(&run_agent_auth_response_tests.step);
    agent_auth_step.dependOn(&run_agent_auth_thirdparty_tests.step);
    if (target.result.os.tag == .linux) agent_auth_step.dependOn(&run_agent_auth_seam_tests.step);
    if (target.result.os.tag == .linux) agent_auth_step.dependOn(&agent_host_login.step);
    if (target.result.os.tag == .linux) agent_auth_step.dependOn(&agent_host_login_contract.step);
    if (target.result.os.tag == .linux) agent_auth_step.dependOn(&agent_host_login_reap.step);
    if (target.result.os.tag == .linux) agent_auth_step.dependOn(&agent_host_login_paste.step);
    if (target.result.os.tag == .linux) agent_auth_step.dependOn(&agent_host_login_enter.step);
    if (target.result.os.tag == .linux) agent_auth_step.dependOn(&agent_host_login_typing.step);
    if (target.result.os.tag == .linux) agent_auth_step.dependOn(&agent_host_login_exchange.step);
    agent_auth_step.dependOn(&run_agent_auth_authorize_tests.step);
    agent_auth_step.dependOn(&run_agent_login_authorize_tests.step);
    if (target.result.os.tag == .linux) agent_auth_step.dependOn(&agent_host_authorize_parity.step);
    test_step.dependOn(&run_agent_protocol_tests.step);
    test_step.dependOn(&run_agent_protocol_capped_tests.step);
    test_step.dependOn(&run_agent_protocol_prompt_tests.step);
    test_step.dependOn(&run_agent_bridge_frame_tests.step);
    for (s5d_fix_runs) |run| test_step.dependOn(run);
    test_step.dependOn(&run_agent_frames_tool_tests.step);
    test_step.dependOn(&run_agent_frames_tool_call_tests.step);
    test_step.dependOn(&run_agent_helper_tests.step);
    test_step.dependOn(&run_agent_helper_deadline_tests.step);
    test_step.dependOn(&run_agent_frames_deadline_tests.step);
    test_step.dependOn(&run_agent_config_check_tests.step);
    test_step.dependOn(&run_config_schema_tests.step);
    test_step.dependOn(&run_automation_smoke_tests.step);
    test_step.dependOn(&run_automation_error_tests.step);
    test_step.dependOn(&run_automation_error_expect_tests.step);
    test_step.dependOn(&run_automation_router_tests.step);
    test_step.dependOn(&run_automation_engine_tests.step);
    test_step.dependOn(&run_automation_retry_tests.step);
    test_step.dependOn(&run_automation_queue_tests.step);
    test_step.dependOn(&run_automation_telemetry_tests.step);
    test_step.dependOn(&run_automation_social_tests.step);
    test_step.dependOn(&run_automation_cookie_tests.step);
    test_step.dependOn(&run_x_tests.step);
    test_step.dependOn(&run_automation_x_tests.step);
    test_step.dependOn(&run_automation_server_tests.step);
    test_step.dependOn(&run_automation_expect_phase_a_tests.step);
    test_step.dependOn(&run_automation_expect_budget_tests.step);
    test_step.dependOn(&run_automation_expect_deadline_tests.step);
    test_step.dependOn(&run_automation_expect_flow_tests.step);
    test_step.dependOn(&run_automation_expect_flow_seam_tests.step);
    test_step.dependOn(&run_automation_expect_flow_prenav_tests.step);
    test_step.dependOn(&run_automation_expect_flow_server_tests.step);
    test_step.dependOn(&automation_expect_flow_e2e.step);
    test_step.dependOn(&run_owner_only_tests.step);
    test_step.dependOn(&run_agent_setup_ms5_tests.step);
    test_step.dependOn(&run_agent_setup_ms5_python_tests.step);
    test_step.dependOn(&run_agent_setup_ms5_devtree_tests.step);
    test_step.dependOn(&run_agent_setup_ms5_wiring_tests.step);
    test_step.dependOn(&mac_group_cleanup.step);
    test_step.dependOn(&run_transport_ws20_tests.step);
    for (s7a_runs) |run| test_step.dependOn(run);
    test_step.dependOn(&automation_api_e2e.step);
    test_step.dependOn(&automation_core_e2e.step);
    test_step.dependOn(&automation_readiness_e2e.step);
    test_step.dependOn(&sdk_python_live_e2e.step);
    test_step.dependOn(&x_flows_e2e.step);
    test_step.dependOn(&x_native_e2e.step);
    test_step.dependOn(&social_flows_e2e.step);
    test_step.dependOn(&automation_input_e2e.step);
    test_step.dependOn(&automation_windows_e2e.step);
    test_step.dependOn(&run_automation_guard_tests.step);
    test_step.dependOn(&automation_guard_e2e.step);
    test_step.dependOn(&run_automation_guard_chunks_tests.step);
    test_step.dependOn(&automation_guard_chunks_e2e.step);
    test_step.dependOn(&run_automation_guard_chunks2_tests.step);
    test_step.dependOn(&run_automation_guard_chunks3_tests.step);
    test_step.dependOn(&automation_guard_chunks2_e2e.step);
    test_step.dependOn(&run_automation_guard_press_tests.step);
    test_step.dependOn(&automation_guard_insert_e2e.step);
    test_step.dependOn(&automation_load_serial_e2e.step);
    test_step.dependOn(&automation_scroll_e2e.step);
    test_step.dependOn(&automation_native_ports_e2e.step);
    test_step.dependOn(&automation_pacing_e2e.step);
    test_step.dependOn(&automation_profile_e2e.step);
    test_step.dependOn(&automation_cookies_e2e.step);
    test_step.dependOn(&http2_goaway_e2e.step);
    test_step.dependOn(&harness_group_e2e.step);
    test_step.dependOn(&web_process_crash_e2e.step);
    test_step.dependOn(&render_config_e2e.step);
    test_step.dependOn(&slow_load_watchdog_e2e.step);
    test_step.dependOn(&media_source_e2e.step);
    test_step.dependOn(&agent_drawer_icon_e2e.step);
    test_step.dependOn(&agent_drawer_e2e.step);
    test_step.dependOn(&agent_drawer_copy_e2e.step);
    test_step.dependOn(&agent_chat_e2e.step);
    test_step.dependOn(&agent_tools_e2e.step);
    test_step.dependOn(&agent_socket_separation_e2e.step);
    test_step.dependOn(&agent_tools_acceptance_e2e.step);
    test_step.dependOn(&agent_tools_acceptance2_e2e.step);
    test_step.dependOn(&agent_window_sessions_e2e.step);
    test_step.dependOn(&agent_flood_e2e.step);
    test_step.dependOn(&agent_cap_e2e.step);
    test_step.dependOn(&agent_prompt_scope_e2e.step);
    test_step.dependOn(&agent_open_order_e2e.step);
    test_step.dependOn(&agent_prompt_exhaust_e2e.step);
    test_step.dependOn(&agent_redact_e2e.step);
    test_step.dependOn(&agent_default_on_e2e.step);
    test_step.dependOn(&agent_config_check_e2e.step);
    test_step.dependOn(&agent_isolation_e2e.step);
    test_step.dependOn(&ipc_roundtrip_e2e.step);
    test_step.dependOn(&page_health_e2e.step);
    test_step.dependOn(&page_recover_e2e.step);
    test_step.dependOn(&agent_host_unit.step);
    test_step.dependOn(&agent_host_wincontain.step);
    test_step.dependOn(&agent_host_parent_watch.step);
    test_step.dependOn(&agent_host_setup_darwin.step);
    test_step.dependOn(&agent_host_route_probe_listen_fd.step);
    test_step.dependOn(&agent_host_proc_darwin.step);
    test_step.dependOn(&agent_host_route_probe_darwin_env.step);
    test_step.dependOn(&agent_host_setup_darwin_r1.step);
    test_step.dependOn(&agent_host_route_probe_census.step);
    test_step.dependOn(&agent_host_setup_census.step);
    test_step.dependOn(&agent_host_setup_darwin_r1_v6.step);
    test_step.dependOn(&agent_host_launch.step);
    test_step.dependOn(&agent_host_contract.step);
    test_step.dependOn(&agent_host_backend_contract.step);
    test_step.dependOn(&agent_host_sandbox_macos.step);
    test_step.dependOn(&agent_host_provision_unit.step);
    test_step.dependOn(&agent_host_chat.step);
    test_step.dependOn(&agent_host_chat_errors.step);
    test_step.dependOn(&agent_host_chat_flood.step);
    test_step.dependOn(&agent_host_chat_cap.step);
    test_step.dependOn(&agent_host_chat_prompt_id.step);
    test_step.dependOn(&agent_host_chat_fit.step);
    test_step.dependOn(&agent_host_redact.step);
    test_step.dependOn(&agent_host_chat_redact.step);
    test_step.dependOn(&agent_host_bridge.step);
    test_step.dependOn(&agent_host_netd.step);
    test_step.dependOn(&agent_host_netd_darwin.step);
    test_step.dependOn(&agent_host_netd_darwin_v6.step);
    test_step.dependOn(&agent_host_relay.step);
    test_step.dependOn(&agent_host_netd_manifest.step);
    test_step.dependOn(&agent_host_netd_login.step);
    test_step.dependOn(&agent_host_netd_census.step);
    test_step.dependOn(&agent_host_login_network.step);
    test_step.dependOn(&agent_host_relay_ports.step);
    test_step.dependOn(&agent_host_hook_net.step);
    test_step.dependOn(&agent_setup_e2e.step);
    test_step.dependOn(&agent_netd_spawn_e2e.step);
    test_step.dependOn(&agent_netd_manifest_e2e.step);
    test_step.dependOn(&agent_host_lifecycle_e2e.step);
    test_step.dependOn(&agent_secrets_e2e.step);
    test_step.dependOn(&real_screen_check_unit.step);
    test_step.dependOn(&real_screen_input_xvfb.step);
    test_step.dependOn(&real_screen_longrun_xvfb.step);
    test_step.dependOn(&xinput_errors_xvfb.step);
    test_step.dependOn(&automation_dialogs_e2e.step);
    test_step.dependOn(&ipc_windows_compile.step);
    test_step.dependOn(&cross_check.step);
    test_step.dependOn(&cross_drawer_win.step);
    test_step.dependOn(&cross_self_test.step);
    test_step.dependOn(&run_gaussian_tests.step);
    test_step.dependOn(&run_bezier_tests.step);
    test_step.dependOn(&run_pacing_tests.step);
    test_step.dependOn(&run_session_tests.step);
    test_step.dependOn(&run_stealth_tests.step);
    // --- Phase 4: JS contract tests ---
    const js_embed_module = b.createModule(.{
        .root_source_file = b.path("src/automation_script/js_embed.zig"),
        .target = target,
        .optimize = optimize,
    });
    const js_contract_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation/js_contract_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    js_contract_tests_module.addImport("js_embed", js_embed_module);
    const js_contract_tests = b.addTest(.{ .root_module = js_contract_tests_module });
    const run_js_contract_tests = b.addRunArtifact(js_contract_tests);

    test_step.dependOn(&run_social_tests.step);
    test_step.dependOn(&run_linkedin_tests.step);
    test_step.dependOn(&run_instagram_tests.step);
    test_step.dependOn(&run_js_contract_tests.step);

    // --- Track C: Sequences client facade + EV70 observability ---
    const sequences_module = b.createModule(.{
        .root_source_file = b.path("src/sequences.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sequences_client_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/sequences/client_facade_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sequences_client_tests_module.addImport("sequences", sequences_module);
    const sequences_client_tests = b.addTest(.{ .root_module = sequences_client_tests_module });
    const run_sequences_client_tests = b.addRunArtifact(sequences_client_tests);
    run_sequences_client_tests.skip_foreign_checks = true;
    test_step.dependOn(&run_sequences_client_tests.step);

    const sequences_ev70_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/sequences/ev70_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sequences_ev70_tests_module.addImport("sequences", sequences_module);
    const sequences_ev70_tests = b.addTest(.{ .root_module = sequences_ev70_tests_module });
    const run_sequences_ev70_tests = b.addRunArtifact(sequences_ev70_tests);
    run_sequences_ev70_tests.skip_foreign_checks = true;
    test_step.dependOn(&run_sequences_ev70_tests.step);

    // --- Track D: Dashboard UI — embed + IPC + mock data ---
    const dashboard_embed_module = b.createModule(.{
        .root_source_file = b.path("src/dashboard/embed.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dashboard_embed_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/dashboard/dashboard_embed_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    dashboard_embed_tests_module.addImport("dashboard_embed", dashboard_embed_module);
    const dashboard_embed_tests = b.addTest(.{ .root_module = dashboard_embed_tests_module });
    const run_dashboard_embed_tests = b.addRunArtifact(dashboard_embed_tests);
    run_dashboard_embed_tests.skip_foreign_checks = true;
    test_step.dependOn(&run_dashboard_embed_tests.step);

    const dashboard_ipc_module = b.createModule(.{
        .root_source_file = b.path("src/dashboard/ipc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dashboard_ipc_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/dashboard/dashboard_ipc_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    dashboard_ipc_tests_module.addImport("dashboard_ipc", dashboard_ipc_module);
    const dashboard_ipc_tests = b.addTest(.{ .root_module = dashboard_ipc_tests_module });
    const run_dashboard_ipc_tests = b.addRunArtifact(dashboard_ipc_tests);
    run_dashboard_ipc_tests.skip_foreign_checks = true;
    test_step.dependOn(&run_dashboard_ipc_tests.step);

    // --- Dashboard visual-regression check (Playwright + Chromium via Node) ---
    // Renders src/dashboard/content/index.html in connected + disconnected states
    // and asserts on the rendered DOM, guarding against a blank error state.
    // Kept out of `zig build test` (needs Node/Playwright/Chromium); run in CI as
    // its own step: `zig build dashboard-visual`.
    const dashboard_visual = b.addSystemCommand(&.{ "node", "tools/dashboard_visual_check.mjs" });
    dashboard_visual.setCwd(b.path("."));
    const dashboard_visual_step = b.step("dashboard-visual", "Visual-regression check for the automation dashboard (Node+Playwright)");
    dashboard_visual_step.dependOn(&dashboard_visual.step);

    // The display guard (orchestrator HARD RULE, 2026-10-15): a harmless step
    // that only prints, so tests/display_guard_test.py can show that the guard
    // stops a step on a display that is not a private Xvfb.
    const display_guard_probe = b.addSystemCommand(&.{ "sh", "-c", "echo display-guard-probe ran" });
    b.step("display-guard-probe", "Print one line (the display guard's test target)").dependOn(&display_guard_probe.step);
    // The nested builds share this build's cache (`zig build run` compiles the browser).
    const display_guard_test = b.addSystemCommand(&.{ "python3", "tests/display_guard_test.py", "--zig", b.graph.zig_exe, "--cache-dir", b.cache_root.path orelse ".zig-cache" });
    test_step.dependOn(&display_guard_test.step);

    guardDisplay(b);
}

/// The display guard (orchestrator HARD RULE, 2026-10-15): every step that a
/// top-level step depends on waits for tools/display_guard.py, which refuses a
/// display that is not a private Xvfb (and any WAYLAND_DISPLAY) unless
/// ZB_ALLOW_REAL_DISPLAY=1. `run` is guarded too (RoseCat 5625): on the real
/// screen it needs the override. Only the install steps, `agent-runtime` and
/// `mac-gate` (no window on this host) are left out. Called last, so every
/// step registered above is covered.
fn guardDisplay(b: *std.Build) void {
    const guard = b.addSystemCommand(&.{ "python3", "tools/display_guard.py" });
    guard.has_side_effects = true; // the environment is read on every run, never cached
    // ws3-shim-test-win and owner-only-test-win exist only in Windows-target builds and run on
    // Windows, which has no X display to guard (and no python3 to run the guard).
    const unguarded = [_][]const u8{ "install", "uninstall", "agent-runtime", "mac-gate", "ms1b-gate", "ms2a-gate", "ws3-shim-test-win", "owner-only-test-win" };
    next: for (b.top_level_steps.keys(), b.top_level_steps.values()) |name, top| {
        for (unguarded) |skip| if (std.mem.eql(u8, name, skip)) continue :next;
        for (top.step.dependencies.items) |dep| dep.dependOn(&guard.step);
    }
}

fn loadSiteConfig(b: *std.Build, path: []const u8) config_schema.SiteConfig {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        path,
        b.allocator,
        .limited(64 * 1024),
    ) catch |err| {
        std.debug.panic("failed to read site config '{s}': {s}", .{ path, @errorName(err) });
    };

    return config_schema.parse(b.allocator, bytes) catch |err| {
        std.debug.panic("invalid site config '{s}': {s}", .{ path, @errorName(err) });
    };
}

fn resolveBackend(target: std.Build.ResolvedTarget) Backend {
    return switch (target.result.os.tag) {
        .linux => .gtk_backend,
        .windows => .webview2_backend,
        .macos => .macos_backend,
        else => std.debug.panic("NoBackendLinked: no backend for target os '{s}'", .{@tagName(target.result.os.tag)}),
    };
}

fn configureBackend(
    module: *std.Build.Module,
    b: *std.Build,
    backend: Backend,
    webview2_paths: WebView2Paths,
) void {
    switch (backend) {
        .gtk_backend => configureGtkBackend(module, b),
        .webview2_backend => configureWebView2Backend(module, b, webview2_paths),
        .macos_backend => configureMacosBackend(module, b),
    }
}

fn configureGtkBackend(module: *std.Build.Module, b: *std.Build) void {
    module.addIncludePath(b.path("src"));
    module.addCSourceFile(.{
        .file = b.path("src/webkit_shim.c"),
        .flags = &.{"-std=c11"},
    });
    module.addCSourceFile(.{
        .file = b.path("src/agent_drawer.c"),
        .flags = &.{"-std=c11"},
    });
    module.addCSourceFile(.{
        .file = b.path("src/agent_host.c"),
        .flags = &.{"-std=gnu11"},
    });
    // macOS plan rev 14 item 4: the owner lock, POSIX only (shared with the macOS build).
    module.addCSourceFile(.{
        .file = b.path("src/agent_home_lock.c"),
        .flags = &.{"-std=gnu11"},
    });
    module.addCSourceFile(.{
        .file = b.path("src/agent_helper.c"),
        .flags = &.{"-std=gnu11"},
    });
    module.addCSourceFile(.{
        .file = b.path("src/agent_secrets.c"),
        .flags = &.{"-std=gnu11"},
    });
    module.addCSourceFile(.{
        .file = b.path("src/agent_secrets_window.c"),
        .flags = &.{"-std=gnu11"},
    });
    module.addCSourceFile(.{
        .file = b.path("src/agent_login.c"),
        .flags = &.{"-std=gnu11"},
    });
    // S6b2 (chat-drawer plan rev 16.18.15-16.18.20): the auth window's GTK body.
    module.addCSourceFile(.{
        .file = b.path("src/agent_auth_window.c"),
        .flags = &.{"-std=gnu11"},
    });
    // S7b (rev 16.20.35): the screenshot fit seam a drawer's broker hands page.screenshot to.
    module.addCSourceFile(.{
        .file = b.path("src/agent_image.c"),
        .flags = &.{"-std=gnu11"},
    });

    module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
}

fn configureWebView2Backend(module: *std.Build.Module, b: *std.Build, paths: WebView2Paths) void {
    module.addIncludePath(b.path("src"));
    if (paths.include_dir) |include_dir| {
        module.addSystemIncludePath(.{ .cwd_relative = include_dir });
    }
    if (paths.winrt_include_dir) |winrt_include_dir| {
        module.addSystemIncludePath(.{ .cwd_relative = winrt_include_dir });
    }
    if (paths.lib_dir) |lib_dir| {
        module.addLibraryPath(.{ .cwd_relative = lib_dir });
    }
    module.addCSourceFile(.{
        .file = b.path("src/webview2_shim.cpp"),
        .flags = &.{"-std=c++17"},
    });

    module.linkSystemLibrary("WebView2LoaderStatic", .{ .use_pkg_config = .no });
    module.linkSystemLibrary("ole32", .{ .use_pkg_config = .no });
    module.linkSystemLibrary("oleaut32", .{ .use_pkg_config = .no });
    module.linkSystemLibrary("user32", .{ .use_pkg_config = .no });
    module.linkSystemLibrary("gdi32", .{ .use_pkg_config = .no });
    module.linkSystemLibrary("shell32", .{ .use_pkg_config = .no });
    module.linkSystemLibrary("advapi32", .{ .use_pkg_config = .no });
}

/// The cross-check's shim argument: one source, or several joined by ':' (macOS: the ObjC shim plus the plain C
/// files compiled into the exe), passed as absolute paths and each registered as a file input.
fn addShimArg(b: *std.Build, run: *std.Build.Step.Run, shim: []const u8) void {
    var parts = std.mem.splitScalar(u8, shim, ':');
    var joined: std.ArrayList(u8) = .empty;
    while (parts.next()) |part| {
        if (joined.items.len > 0) joined.append(b.allocator, ':') catch @panic("OOM");
        joined.appendSlice(b.allocator, b.pathFromRoot(part)) catch @panic("OOM");
        run.addFileInput(b.path(part));
    }
    run.addArg(joined.items);
}

fn configureMacosBackend(module: *std.Build.Module, b: *std.Build) void {
    module.addIncludePath(b.path("src"));
    // macOS plan rev 14 items 4-5 (MS5): the POSIX owner lock and the process-group spawn behind macOS
    // `--agent-setup` (plain C, compiled into the exe).
    module.addCSourceFile(.{ .file = b.path("src/agent_home_lock.c"), .flags = &.{"-std=gnu11"} });
    module.addCSourceFile(.{ .file = b.path("src/agent_spawn_posix.c"), .flags = &.{"-std=gnu11"} });

    // MS1b (option d): build the Objective-C shim with the APPLE toolchain (xcrun clang -> ld64) as
    // a separate dylib, NOT compiled into the zig exe. zig 0.16's self-hosted Mach-O linker emits
    // only classic LC_DYLD_INFO_ONLY fixups; a code-signed x86_64 binary with ObjC metadata in a
    // classic-rebased __DATA_CONST segfaults in -[ZBAppHost init] [super init]. ld64 emits
    // LC_DYLD_CHAINED_FIXUPS, so the shim's ObjC metadata lives in a chained-fixups image and the
    // signed binary runs. Built NATIVE for the host arch (no -arch); the two-host gate lipos the two
    // per-arch dylibs into one fat dylib, exactly like the exe.
    // The shim calls back into two zig-exported symbols (zb_ipc_dispatch in src/ipc.zig,
    // zb_policy_decide in src/nav_policy.zig). As a separate dylib it resolves them at LOAD from the
    // main executable via flat-namespace dynamic lookup; the exe exports them (rdynamic, set
    // macOS-only at the exe below). This is the standard host-provides-symbols plugin pattern.
    // -Wl,-fixup_chains is REQUIRED: -undefined dynamic_lookup otherwise makes ld64 fall back to the
    // classic LC_DYLD_INFO_ONLY scheme, which is the very thing that crashes a signed x86_64 ObjC
    // __DATA_CONST. Forcing chained fixups keeps dynamic_lookup for the two back-ref symbols AND puts
    // the shim's ObjC metadata in a chained-fixups image, so the signed binary runs.
    const shim = b.addSystemCommand(&.{ "xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-Wl,-undefined,dynamic_lookup", "-Wl,-fixup_chains" });
    shim.addArg("-I");
    shim.addDirectoryArg(b.path("src"));
    shim.addFileArg(b.path("src/wkwebview_shim.m"));
    shim.addArgs(&.{ "-framework", "WebKit", "-framework", "Cocoa", "-framework", "Foundation" });
    // install_name is @executable_path-anchored, NOT @rpath: a hardened-runtime process refuses a
    // relative LC_RPATH ("relative path not allowed in hardened program"), and zig normalizes a
    // `.cwd_relative` "@executable_path/.." rpath down to a bare relative "Frameworks". Anchoring the
    // dylib's own install name to @executable_path/../Frameworks means dyld loads it directly from the
    // bundle (zig-out/bin/.. -> zig-out/Frameworks) with no rpath search, under ad-hoc AND hardened.
    shim.addArgs(&.{ "-install_name", "@executable_path/../Frameworks/libwkwebview_shim.dylib", "-o" });
    const dylib = shim.addOutputFileArg("libwkwebview_shim.dylib");

    // The exe links the dylib by name at build time (search path = the dylib's cache dir); at runtime
    // it loads via the @executable_path install name above, so no LC_RPATH is needed.
    module.addLibraryPath(dylib.dirname());
    module.linkSystemLibrary("wkwebview_shim", .{});

    module.linkFramework("WebKit", .{});
    module.linkFramework("Cocoa", .{});
    module.linkFramework("Foundation", .{});

    // Ship the dylib beside the binary, in the bundle's Frameworks/ (zig-out/Frameworks).
    const install_dylib = b.addInstallFileWithDir(dylib, .{ .custom = "Frameworks" }, "libwkwebview_shim.dylib");
    b.getInstallStep().dependOn(&install_dylib.step);
}
