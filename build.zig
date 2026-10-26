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
    // R4 (RoseCat 483cdf7; a8a8a37 item 2): the compile-only Mac tier's one build step. It installs the exe (on
    // macOS with the shim dylib it links) into the prefix and nothing else: no run, test, gate or tool step.
    b.step("mac-compile-only", "Compile and link the exe (and on macOS its shim dylib) only; runs nothing").dependOn(&b.addInstallArtifact(exe, .{}).step);

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

    // MS2b, MS2c and MS3 (bd 4pa.62, R29-REG): the hand-run Mac gates as named Mac-only steps; `test` never depends on
    // them. Each records its last approved run in tests/mac/approved_runs/<step>.json. Driven from Linux over SSH.
    for ([_][3][]const u8{
        .{ "ms2b-gate", "tests/mac/ms2b_gate.sh", "Run the macOS MS2b native-input gate (nativeKey/nativeText on both Macs)" },
        .{ "ms2c-gate", "tests/mac/ms2c_gate.sh", "Run the macOS MS2c gate (multi-window, freeze and recovery on both Macs)" },
        .{ "ms3-gate", "tests/mac/ms3_gate.sh", "Run the macOS MS3 gate (cookies, config and profile persistence on both Macs)" },
    }) |gate| {
        const gate_run = b.addSystemCommand(&.{ "bash", gate[1] });
        b.step(gate[0], gate[2]).dependOn(&gate_run.step);
    }

    // WS0: the Windows gate's Linux-side selftest drives tests/windows/gate.sh against fake
    // ssh/virsh/tar on PATH (fail-closed, lexical path-shape check, display scrub, transport
    // hygiene). Hermetic
    // — no Windows host, display or live socket. The [W] gate.sh --probe-only runs separately.
    const windows_gate_selftest = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/gate_selftest.py" });
    b.step("windows-gate-selftest", "Run the Windows gate's Linux-side selftest (fake ssh/virsh/tar)").dependOn(&windows_gate_selftest.step);

    // (WS0.5 remote-path fence removed — resolve_path.sh / resolve_live_test.py deleted; bead
    // zigBrowser-q92. A future remote file op uses the held-handle check-and-use design, its own milestone.)

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

    // 52a5aba: the forced screenshot-failure branches (ZB_E2E_FORCE_SCREENSHOT_FAIL) on the VM — each
    // branch fires only under --e2e-protocol (positive), and the seam stays INERT without the flag
    // (negative). Skips cleanly without ZB_WIN11_HOST/ZB_WIN_EXE; needs no slot.
    const windows_screenshot_branches_live = b.addSystemCommand(&.{ "python3", "-I", "tests/e2e/screenshot_branches_live_test.py" });
    b.step("windows-screenshot-branches-live", "Live Windows forced screenshot-failure branches + inert-without-flag on the VM (skips without ZB_WIN11_HOST)").dependOn(&windows_screenshot_branches_live.step);

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

    // bd zigBrowser-3ui.11: the root.zig unit tests start GTK in-process, so they run through runInProcessGtkTests
    // (the inherited variables gdk would unset are removed; a hang ends as a named failure). The two probes and the
    // selftest below prove that configuration on Linux.
    const run_unit_tests = runInProcessGtkTests(b, unit_tests, gtk_test_timeout_s);
    // 3ui.11 scope row (SilverRidge 99a44f3): prints how the root unit-test run is configured for this -Dtarget,
    // read from the run step; test-gtk-test-env checks it for Linux, both macOS arches and Windows.
    b.step("gtk-test-scope", "3ui.11: print how the root unit-test run step is configured for this target").dependOn(
        &b.addSystemCommand(&.{ "echo", gtkTestScopeLine(b, run_unit_tests, unit_tests.rootModuleTarget()) }).step,
    );
    if (backend == .gtk_backend) {
        inline for (.{
            .{ "gtk-env-failure-probe", "tests/gtk_env_failure_probe_test.zig", gtk_test_timeout_s },
            .{ "gtk-hang-probe", "tests/gtk_hang_probe_test.zig", "20" },
        }) |probe| {
            const probe_tests = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path(probe[1]),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }) });
            probe_tests.root_module.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
            b.step(probe[0], "3ui.11 probe (fails on purpose; run by test-gtk-test-env)").dependOn(&runInProcessGtkTests(b, probe_tests, probe[2]).step);
        }
    }
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
    const macos_shim_sources = "src/wkwebview_shim.m:src/agent_drawer_mac_host.m:src/agent_drawer_mac_panel.m:src/agent_secrets_mac.m:src/agent_secrets_window_mac.m:src/agent_token_fd_mac.c:src/agent_helper_mac.c:src/agent_home_lock.c:src/agent_spawn_posix.c";
    const cross_targets = [_]struct { query: std.Target.Query, shim: []const u8 }{
        // The shipped floor (windowsAfUnixFloor), so the object reaches the automation server's start.
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu, .os_version_min = .{ .windows = .win10_rs4 } }, .shim = "src/webview2_shim.cpp" },
        // macOS: the ObjC shim plus the plain C files compiled into the exe (MS5's lock and spawn).
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .shim = macos_shim_sources },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .shim = macos_shim_sources },
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
        "--require-defined",  "zb_drawer_anim_ms_from_env",
        "--require-defined",  "zb_drawer_icon_size_for_dpi",
        "--require-defined",  "zb_drawer_icon_size_from_dpi_env",
        "--require-defined",  "zb_drawer_inside_icon",
        "--require-defined",  "zb_drawer_window_count_from_env",
        "--require-defined",  "zb_drawer_extra_windows",
    });
    cross_drawer_win.addFileInput(b.path("tools/check_cross_symbols.py"));
    cross_drawer_win.addFileArg(cross_drawer_win_obj.getEmittedBin());
    cross_drawer_win.addFileArg(b.path("src/webview2_shim.cpp"));
    const cross_drawer_win_step = b.step("cross-check-drawer-win", "WS5: the Windows build compiles and exports the portable drawer logic (zb_drawer_*)");
    cross_drawer_win_step.dependOn(&cross_drawer_win.step);
    cross_check_step.dependOn(&cross_drawer_win.step);

    // MS7.0 (macOS plan line 2158): both macOS objects must COMPILE and DEFINE the portable drawer logic (zb_drawer_*)
    // the AppKit drawer requires (an AppKit-required inventory: each one a call the drawer's .m makes), once the
    // export gate in agent_drawer.zig covers .macos.
    // Pure compile — no SDK, no link. In `cross-check`.
    const cross_drawer_mac_step = b.step("cross-check-drawer-mac", "MS7.0: both macOS builds compile and export the portable drawer logic (zb_drawer_*)");
    for ([_]std.Target.Cpu.Arch{ .aarch64, .x86_64 }) |arch| {
        const cross_drawer_mac_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{.{ .name = "build_options", .module = site_options_module }},
            .target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .macos }),
            .optimize = optimize,
            .link_libc = true,
        });
        cross_drawer_mac_module.addIncludePath(b.path("src"));
        const cross_drawer_mac_obj = b.addObject(.{ .name = "zigBrowser-cross-drawer-mac", .root_module = cross_drawer_mac_module });
        const cross_drawer_mac = b.addSystemCommand(&.{ "python3", "tools/check_cross_symbols.py" });
        for (drawer_portable_exports) |sym| cross_drawer_mac.addArgs(&.{ "--require-defined", sym });
        cross_drawer_mac.addFileInput(b.path("tools/check_cross_symbols.py"));
        cross_drawer_mac.addFileArg(cross_drawer_mac_obj.getEmittedBin());
        addShimArg(b, cross_drawer_mac, macos_shim_sources);
        cross_drawer_mac_step.dependOn(&cross_drawer_mac.step);
        cross_check_step.dependOn(&cross_drawer_mac.step);
    }

    // MS8.0 (BlackRobin; BlueBeaver 8072/8088): the approval cards' one authority in the macOS build. Both macOS
    // objects of the shipped root must DEFINE agent_tools' two minters (the AppKit card's only way to approve or deny,
    // through agent_drawer.zig's bridge) and the cards' window lifecycle, and leave no zb_* undefined that the macOS
    // shims do not define (agent_tools' GTK-only C calls must not reach macOS). Pure compile — no SDK, no link.
    // In `cross-check` and `test` (MS8.0 green). The shim closure is the macOS build's: the real agent_drawer_mac.m
    // joins it once it supplies the native card calls (RoseCat ea73fe7).
    var cross_tools_mac_runs: [2]*std.Build.Step = undefined;
    const cross_tools_mac_step = b.step("cross-check-agent-tools-mac", "MS8.0: both macOS builds define the approval cards' minters and window lifecycle");
    for ([_]std.Target.Cpu.Arch{ .aarch64, .x86_64 }, 0..) |arch, i| {
        const cross_tools_mac_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{.{ .name = "build_options", .module = site_options_module }},
            .target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .macos }),
            .optimize = optimize,
            .link_libc = true,
        });
        cross_tools_mac_module.addIncludePath(b.path("src"));
        const cross_tools_mac_obj = b.addObject(.{ .name = "zigBrowser-cross-agent-tools-mac", .root_module = cross_tools_mac_module });
        const cross_tools_mac = b.addSystemCommand(&.{
            "python3",           "tools/check_cross_symbols.py",
            "--require-defined", "zb_agent_tools_approve",
            "--require-defined", "zb_agent_tools_deny",
            "--require-defined", "zb_agent_tools_window_opened",
            "--require-defined", "zb_agent_tools_window_closed",
        });
        cross_tools_mac.addFileInput(b.path("tools/check_cross_symbols.py"));
        cross_tools_mac.addFileArg(cross_tools_mac_obj.getEmittedBin());
        addShimArg(b, cross_tools_mac, macos_shim_sources);
        cross_tools_mac_step.dependOn(&cross_tools_mac.step);
        cross_check_step.dependOn(&cross_tools_mac.step);
        cross_tools_mac_runs[i] = &cross_tools_mac.step;
    }

    // MS7.6 / MS7.8 (RoseCat 8079 / 2796d94): the card's one minter proven on the real Darwin objects, by symbol and
    // relocation (tests/e2e/mac_card_authority_objects_test.py). The shipped executable's own root module, Debug so
    // no inlining hides a call, for both arches. Pure compile — no SDK, no link.
    // Green since the macOS build defines the minters (MS8.0) and the bridge (2aa1abb); in `test` (bd 4pa.29).
    const card_authority_mac_step = b.step("check-card-authority-mac", "MS7.6/7.8: the card's one minter, on both Darwin objects' relocations");
    const card_authority_mac = b.addSystemCommand(&.{ "python3", "tests/e2e/mac_card_authority_objects_test.py" });
    card_authority_mac.addFileInput(b.path("tests/e2e/mac_card_authority_objects_test.py"));
    for ([_]std.Target.Cpu.Arch{ .aarch64, .x86_64 }) |arch| {
        const card_authority_mac_module = b.createModule(.{
            .root_source_file = root_module.root_source_file.?,
            .imports = &.{.{ .name = "build_options", .module = site_options_module }},
            .target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .macos }),
            .optimize = .Debug,
            .link_libc = true,
        });
        card_authority_mac_module.addIncludePath(b.path("src"));
        const card_authority_mac_obj = b.addObject(.{ .name = "zigBrowser-card-authority-mac", .root_module = card_authority_mac_module });
        card_authority_mac.addFileArg(card_authority_mac_obj.getEmittedBin());
    }
    card_authority_mac_step.dependOn(&card_authority_mac.step);

    // bd zigBrowser-4pa.76 (plan R30-MS7, R30.2 T16): the Linux and macOS Secrets-window headers compile together in
    // one translation unit, so no two C functions share a name with different meanings. A TRIPWIRE (compiled, never
    // run), not proof: the macOS entry zb_secrets_window_mac_show is proven only by the MS7.5 compiled Mac gate.
    // In `test` (Linux: the Linux header needs GTK).
    const secrets_window_headers_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    secrets_window_headers_module.addIncludePath(b.path("src"));
    secrets_window_headers_module.addCSourceFile(.{ .file = b.path("tests/secrets_window_headers_test.c"), .flags = &.{"-std=gnu11"} });
    secrets_window_headers_module.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
    const secrets_window_headers_obj = b.addObject(.{ .name = "secrets_window_headers", .root_module = secrets_window_headers_module });
    const secrets_window_headers_step = b.step("check-secrets-window-headers", "4pa.76: the Linux and macOS Secrets-window headers compile together (tripwire)");
    secrets_window_headers_step.dependOn(&secrets_window_headers_obj.step);

    // WS6.1 (c): the Windows Credential Manager / DPAPI token store compiles for x86_64-windows and exports
    // its zb_secret_* C-ABI functions. A trivial Zig root pulls the C++ in (addCSourceFile); the object retains
    // every TU symbol, so check_cross_symbols can require them.
    const secrets_win_cross_module = b.createModule(.{
        .root_source_file = b.path("src/agent_secrets_win_crosscheck.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }),
        .optimize = optimize,
        .link_libc = true,
    });
    secrets_win_cross_module.addCSourceFile(.{ .file = b.path("src/agent_secrets_win.cpp"), .flags = &.{} });
    const secrets_win_cross_obj = b.addObject(.{ .name = "zigBrowser-cross-secrets-win", .root_module = secrets_win_cross_module });
    const secrets_win_cross = b.addSystemCommand(&.{
        "python3",           "tools/check_cross_symbols.py",
        "--require-defined", "zb_secret_cred_save",
        "--require-defined", "zb_secret_cred_read",
        "--require-defined", "zb_secret_cred_delete",
        "--require-defined", "zb_secret_dpapi_protect",
    });
    secrets_win_cross.addFileInput(b.path("tools/check_cross_symbols.py"));
    secrets_win_cross.addFileArg(secrets_win_cross_obj.getEmittedBin());
    secrets_win_cross.addFileArg(b.path("src/agent_secrets_win.cpp"));
    const secrets_win_cross_step = b.step("cross-check-secrets-win", "WS6.1: the Windows token store compiles and exports zb_secret_* (CredMan/DPAPI)");
    secrets_win_cross_step.dependOn(&secrets_win_cross.step);
    cross_check_step.dependOn(&secrets_win_cross.step);

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
    // bd zigBrowser-4pa.55 (V03-F1; R30.3 #1 option C): whether a load failure quits the macOS browser, and whether
    // the 15 s exit timer is armed, decided in portable Zig that wkwebview_shim.m calls back (as zb_policy_decide),
    // driven here through its C ABI and webkit_shim.h's constants. The shim's timer call sites are bound to it
    // lexically (no Objective-C runtime on Linux; SilverRidge 58c6543), and each proof rejects its production mutants.
    const load_failure_policy_module = b.createModule(.{
        .root_source_file = b.path("src/load_failure_policy.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const load_failure_policy_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/load_failure_policy_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    load_failure_policy_tests_module.addIncludePath(b.path("src"));
    load_failure_policy_tests_module.addImport("load_failure_policy", load_failure_policy_module);
    const run_load_failure_policy_tests = b.addRunArtifact(b.addTest(.{ .root_module = load_failure_policy_tests_module }));
    run_load_failure_policy_tests.skip_foreign_checks = true;
    const load_failure_policy_step = b.step("test-load-failure-policy", "4pa.55: a failed or recovered load quits the macOS browser only on the primary window's initial load");
    load_failure_policy_step.dependOn(&run_load_failure_policy_tests.step);
    const load_exit_timer_binding = b.addSystemCommand(&.{ "python3", "tests/e2e/mac_load_exit_timer_binding_test.py" });
    load_exit_timer_binding.addFileInput(b.path("tests/e2e/mac_load_exit_timer_binding_test.py"));
    load_exit_timer_binding.addFileInput(b.path("src/wkwebview_shim.m"));
    load_failure_policy_step.dependOn(&load_exit_timer_binding.step);
    const load_failure_policy_mutants = b.addSystemCommand(&.{
        "python3",            "tests/e2e/load_failure_policy_mutant_selftest.py",
        "--zig",              b.graph.zig_exe,
        "--global-cache-dir", b.graph.global_cache_root.path orelse ".zig-cache",
    });
    for ([_][]const u8{
        "tests/e2e/load_failure_policy_mutant_selftest.py",
        "tests/e2e/mac_load_exit_timer_binding_test.py",
        "tests/load_failure_policy_test.zig",
        "src/load_failure_policy.zig",
        "src/webkit_shim.h",
        "src/wkwebview_shim.m",
    }) |input| load_failure_policy_mutants.addFileInput(b.path(input));
    load_failure_policy_step.dependOn(&load_failure_policy_mutants.step);
    // 4pa.58 MS2c.6: the native close control's hostless binding oracle (the 4pa.55 lexer, over the real shim). The
    // runtime proof is the held Mac rows (mac_ms2c_close_button_test.py, mac_ms2c_close_primary_test.py).
    const native_close_binding = b.addSystemCommand(&.{ "python3", "tests/e2e/mac_native_close_binding_test.py" });
    for ([_][]const u8{
        "tests/e2e/mac_native_close_binding_test.py",
        "tests/e2e/mac_load_exit_timer_binding_test.py",
        "src/wkwebview_shim.m",
    }) |input| native_close_binding.addFileInput(b.path(input));
    b.step("test-native-close-binding", "4pa.58: the native close control reaches the registry through the one window-event destroy path").dependOn(&native_close_binding.step);
    // 4pa.56: each WKHTTPCookieStore call releases its job (DISPATCHING -> INFLIGHT) right after the submit, inside the
    // guarded main-queue block, so timeout_ms bounds the wait. The runtime proof is the held mac_cookie_timeout_test.py.
    const cookie_inflight_binding = b.addSystemCommand(&.{ "python3", "tests/e2e/mac_cookie_inflight_binding_test.py" });
    for ([_][]const u8{
        "tests/e2e/mac_cookie_inflight_binding_test.py",
        "tests/e2e/mac_load_exit_timer_binding_test.py",
        "src/wkwebview_shim.m",
    }) |input| cookie_inflight_binding.addFileInput(b.path(input));
    b.step("test-cookie-inflight-binding", "4pa.56: every cookie call is released to INFLIGHT after its submit, so its timeout applies").dependOn(&cookie_inflight_binding.step);
    // 4pa.57 MS2b.2: dialog.get, page.list and dialog.respond share the same stable windowId even after a middle
    // popup closes. The runtime proof is the held Mac row mac_ms2b_dialog_popup_id_test.py.
    const dialog_window_id_binding = b.addSystemCommand(&.{ "python3", "tests/e2e/mac_dialog_window_id_binding_test.py" });
    for ([_][]const u8{
        "tests/e2e/mac_dialog_window_id_binding_test.py",
        "tests/e2e/mac_load_exit_timer_binding_test.py",
        "src/wkwebview_shim.m",
    }) |input| dialog_window_id_binding.addFileInput(b.path(input));
    b.step("test-dialog-window-id-binding", "4pa.57: dialogs retain the page.list window id after another popup closes").dependOn(&dialog_window_id_binding.step);

    // Hook 16 inert row (SilverRidge 8721b6d, option B): the data-store selection decision of the e2e-only hook
    // ZB_DEBUG_EPHEMERAL_DATA_STORE, probed through src/zb_test_hook_gate.h with no AppKit and no WebKit store.
    // Portable: runs on every host.
    const hook16_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/hook16_decision_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    hook16_tests_module.addIncludePath(b.path("src"));
    hook16_tests_module.addAnonymousImport("wkwebview_shim_src", .{ .root_source_file = b.path("src/wkwebview_shim.m") });
    const run_hook16_tests = b.addRunArtifact(b.addTest(.{ .root_module = hook16_tests_module }));
    run_hook16_tests.skip_foreign_checks = true;
    b.step("test-hook16-decision", "Hook 16 is inert without --e2e-protocol: the store decision stays persistent").dependOn(&run_hook16_tests.step);

    // Hook 14 inert row (4pa.58, SilverRidge 7f8b217, the hook-16 option B shape): the close-title decision of the
    // e2e-only hook ZB_DEBUG_NATIVE_CLOSE_ON_TITLE, probed through src/zb_test_hook_gate.h with no AppKit and no window.
    // Portable: runs on every host. The Mac half is row 5 of tests/e2e/mac_ms2a_hook_inert_test.py.
    const hook14_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/hook14_decision_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    hook14_tests_module.addIncludePath(b.path("src"));
    hook14_tests_module.addAnonymousImport("wkwebview_shim_src", .{ .root_source_file = b.path("src/wkwebview_shim.m") });
    const run_hook14_tests = b.addRunArtifact(b.addTest(.{ .root_module = hook14_tests_module }));
    run_hook14_tests.skip_foreign_checks = true;
    b.step("test-hook14-decision", "Hook 14 is inert without --e2e-protocol: no page title closes a window").dependOn(&run_hook14_tests.step);

    // macOS plan R30-MS3 Red 1 (bd 4pa.60): the macOS profile step (profile_step.applyMacos, the macOS branch of
    // app.applyProfileDir, with the WebKit binder injected) creates a fresh --profile-dir before the bind, so the
    // pacing state saves there. Portable: runs on every host.
    const profile_step_module = b.createModule(.{
        .root_source_file = b.path("src/profile_step.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const app_profile_dir_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/app_profile_dir_macos_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app_profile_dir_tests_module.addImport("profile_step", profile_step_module);
    const run_app_profile_dir_tests = b.addRunArtifact(b.addTest(.{ .root_module = app_profile_dir_tests_module }));
    run_app_profile_dir_tests.skip_foreign_checks = true;
    b.step("test-app-profile-dir-macos", "The macOS profile step creates a fresh --profile-dir before the WebKit bind (4pa.60)").dependOn(&run_app_profile_dir_tests.step);

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
    // MS7.1 (macOS plan line 2158): the AppKit dock geometry (pageRect, appKitFrame) in the portable logic. In `test`.
    const agent_drawer_appkit_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_drawer_appkit_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_drawer_appkit_tests_module.addImport("agent_drawer", agent_drawer_module);
    const run_agent_drawer_appkit_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_drawer_appkit_tests_module }));
    run_agent_drawer_appkit_tests.skip_foreign_checks = true;
    const agent_drawer_appkit_step = b.step("test-agent-drawer-appkit", "MS7.1: the AppKit drawer's dock geometry in the portable logic");
    agent_drawer_appkit_step.dependOn(&run_agent_drawer_appkit_tests.step);
    // MS7.6/7.8 (RoseCat 8055/bdc8202): what a press on the AppKit card may do (own control, own card, the real
    // cards' single use and 120 s expiry), decided in the portable logic. In `test`.
    const agent_drawer_card_press_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_drawer_card_press_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_drawer_card_press_tests_module.addImport("agent_drawer", agent_drawer_module);
    agent_drawer_card_press_tests_module.addImport("agent_approval", b.createModule(.{
        .root_source_file = b.path("src/agent_approval.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_agent_drawer_card_press_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_drawer_card_press_tests_module }));
    run_agent_drawer_card_press_tests.skip_foreign_checks = true;
    const agent_drawer_card_press_step = b.step("test-agent-drawer-card-press", "MS7.6/7.8: the AppKit card press, decided in the portable logic");
    agent_drawer_card_press_step.dependOn(&run_agent_drawer_card_press_tests.step);
    // MS7.4 (RoseCat 8058; amended 44ca58e/07e55fd): the AppKit bubble text (UTF-16 copy map, invalid UTF-8 and NUL
    // policy, the contiguous-layout boundary) in the portable logic. In `test`.
    const agent_drawer_appkit_text_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_drawer_appkit_text_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_drawer_appkit_text_tests_module.addImport("agent_drawer", agent_drawer_module);
    const run_agent_drawer_appkit_text_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_drawer_appkit_text_tests_module }));
    run_agent_drawer_appkit_text_tests.skip_foreign_checks = true;
    const agent_drawer_appkit_text_step = b.step("test-agent-drawer-appkit-text", "MS7.4: the AppKit drawer's bubble text in the portable logic");
    agent_drawer_appkit_text_step.dependOn(&run_agent_drawer_appkit_text_tests.step);
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
    // MS6.5.1 (plan rev 27, "Clean fixed point"): the bounded census->kill->fresh-census FIXED POINT, proven on
    // Linux with the kill INTERCEPTED via fake ops (no real signal); a fork-after-gather child must be re-censused
    // and killed before `clean`. C executable, run inside a user+PID namespace per the rule.
    const reaper_fp_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    reaper_fp_module.addCSourceFile(.{ .file = b.path("src/agent_run_reaper.c"), .flags = &.{"-std=gnu11"} });
    reaper_fp_module.addCSourceFile(.{ .file = b.path("tests/agent_run_reaper_fixed_point_test.c"), .flags = &.{"-std=gnu11"} });
    reaper_fp_module.addIncludePath(b.path("src"));
    const reaper_fp_exe = b.addExecutable(.{ .name = "reaper-fixed-point-test", .root_module = reaper_fp_module });
    const run_reaper_fp_tests = b.addSystemCommand(&.{
        "unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc", "--",
    });
    run_reaper_fp_tests.addArtifactArg(reaper_fp_exe);
    const reaper_fp_step = b.step("test-agent-run-reaper-fixed-point", "MS6.5.1 census->kill->fresh-census fixed point (fake ops, kill intercepted)");
    reaper_fp_step.dependOn(&run_reaper_fp_tests.step);
    // MS6.5.1 (RoseCat 3ec386e): the false-Clean race — the engine must report a matched-but-unresolved candidate
    // (identity flips at the pre-kill inspect) DISTINCTLY, so the fixed point re-censuses and never declares Clean
    // while a child it would catch is still appearing. Fake ops, kill intercepted; user+PID namespace.
    const reaper_fc_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    reaper_fc_module.addCSourceFile(.{ .file = b.path("src/agent_run_reaper.c"), .flags = &.{"-std=gnu11"} });
    reaper_fc_module.addCSourceFile(.{ .file = b.path("tests/agent_run_reaper_false_clean_test.c"), .flags = &.{"-std=gnu11"} });
    reaper_fc_module.addIncludePath(b.path("src"));
    const reaper_fc_exe = b.addExecutable(.{ .name = "reaper-false-clean-test", .root_module = reaper_fc_module });
    const run_reaper_fc_tests = b.addSystemCommand(&.{
        "unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc", "--",
    });
    run_reaper_fc_tests.addArtifactArg(reaper_fc_exe);
    const reaper_fc_step = b.step("test-agent-run-reaper-false-clean", "MS6.5.1 false-Clean race: unresolved match forces another census (fake ops)");
    reaper_fc_step.dependOn(&run_reaper_fc_tests.step);
    // MS6.5.1 (RoseCat 413e3c5): a matched candidate whose first inspect is unidentifiable (have_bsd=0, uid=-1,
    // exactly as the production inspector reports a PROC_PIDTBSDINFO failure) must be classified UNRESOLVED before
    // the uid check, so the fixed point never reads it as an empty census. Fake ops, kill intercepted; user+PID ns.
    const reaper_uc_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    reaper_uc_module.addCSourceFile(.{ .file = b.path("src/agent_run_reaper.c"), .flags = &.{"-std=gnu11"} });
    reaper_uc_module.addCSourceFile(.{ .file = b.path("tests/agent_run_reaper_unreadable_test.c"), .flags = &.{"-std=gnu11"} });
    reaper_uc_module.addIncludePath(b.path("src"));
    const reaper_uc_exe = b.addExecutable(.{ .name = "reaper-unreadable-test", .root_module = reaper_uc_module });
    const run_reaper_uc_tests = b.addSystemCommand(&.{
        "unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc", "--",
    });
    run_reaper_uc_tests.addArtifactArg(reaper_uc_exe);
    const reaper_uc_step = b.step("test-agent-run-reaper-unreadable", "MS6.5.1 unidentifiable (have_bsd=0, uid=-1) match is unresolved, never Clean (fake ops)");
    reaper_uc_step.dependOn(&run_reaper_uc_tests.step);
    // MS6.5.1 (plan "Provenance"): the run ledger's per-entry creation-provenance decision, on REAL Linux dirs
    // (openat O_NOFOLLOW + fstat) — no signals. A dir is swept ONLY on an exact (dev,ino,uid,mode) match of an
    // active entry; swapped/symlinked/mode-changed/non-active are census/warn.
    const reaper_lg_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    reaper_lg_module.addCSourceFile(.{ .file = b.path("src/agent_run_reaper.c"), .flags = &.{"-std=gnu11"} });
    reaper_lg_module.addCSourceFile(.{ .file = b.path("tests/agent_run_ledger_test.c"), .flags = &.{"-std=gnu11"} });
    reaper_lg_module.addIncludePath(b.path("src"));
    const reaper_lg_exe = b.addExecutable(.{ .name = "reaper-ledger-test", .root_module = reaper_lg_module });
    const run_reaper_lg_tests = b.addRunArtifact(reaper_lg_exe);
    run_reaper_lg_tests.skip_foreign_checks = true;
    const reaper_lg_step = b.step("test-agent-run-reaper-ledger", "MS6.5.1 ledger provenance: swept only on an exact fstat match of an active entry (real dirs)");
    reaper_lg_step.dependOn(&run_reaper_lg_tests.step);
    // MS6.5.1 (RoseCat 2f57b1e): the ledger decision boundary — the exact four-field (dev,ino,uid,mode) match
    // and the single-component run-dir grammar enforced before openat (so "."/".."/absolute/embedded-slash/wrong
    // prefix,case,length can never reach another dir or SWEEP). Real dirs, no signals.
    const reaper_lb_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    reaper_lb_module.addCSourceFile(.{ .file = b.path("src/agent_run_reaper.c"), .flags = &.{"-std=gnu11"} });
    reaper_lb_module.addCSourceFile(.{ .file = b.path("tests/agent_run_ledger_boundary_test.c"), .flags = &.{"-std=gnu11"} });
    reaper_lb_module.addIncludePath(b.path("src"));
    const reaper_lb_exe = b.addExecutable(.{ .name = "reaper-ledger-boundary-test", .root_module = reaper_lb_module });
    const run_reaper_lb_tests = b.addRunArtifact(reaper_lb_exe);
    run_reaper_lb_tests.skip_foreign_checks = true;
    const reaper_lb_step = b.step("test-agent-run-reaper-ledger-boundary", "MS6.5.1 ledger boundary: exact 4-field match + single-component grammar (real dirs)");
    reaper_lb_step.dependOn(&run_reaper_lb_tests.step);
    // MS6.5.1 (crash-cut table C2/C3): a Clean teardown that crashed after unlinkat(run.marker) but before rmdir
    // leaves a provenance-valid marker-less dir — recognised via run.marker=>ENOENT as the durable teardown phase
    // (finish rmdir+remove, no signal, no permanent incident); C3 (entry naming no dir) => ZB_LEDGER_GONE. Real dirs.
    const reaper_cc_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    reaper_cc_module.addCSourceFile(.{ .file = b.path("src/agent_run_reaper.c"), .flags = &.{"-std=gnu11"} });
    reaper_cc_module.addCSourceFile(.{ .file = b.path("tests/agent_run_ledger_crashcut_test.c"), .flags = &.{"-std=gnu11"} });
    reaper_cc_module.addIncludePath(b.path("src"));
    const reaper_cc_exe = b.addExecutable(.{ .name = "reaper-ledger-crashcut-test", .root_module = reaper_cc_module });
    const run_reaper_cc_tests = b.addRunArtifact(reaper_cc_exe);
    run_reaper_cc_tests.skip_foreign_checks = true;
    const reaper_cc_step = b.step("test-agent-run-reaper-ledger-crashcut", "MS6.5.1 crash cuts C2/C3: marker-less teardown dir + entry naming no dir (real dirs, no signals)");
    reaper_cc_step.dependOn(&run_reaper_cc_tests.step);
    // MS6.5.1 (RoseCat 7575 #2): the C2 marker classifier is no-wedge (O_NONBLOCK) and shape-strict (fstat accepts
    // only a regular this-uid 0400 marker) — a FIFO/dir/socket/symlink/wrong-mode object can neither wedge nor
    // masquerade as PRESENT. Real dirs, no signals.
    const reaper_ms_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    reaper_ms_module.addCSourceFile(.{ .file = b.path("src/agent_run_reaper.c"), .flags = &.{"-std=gnu11"} });
    reaper_ms_module.addCSourceFile(.{ .file = b.path("tests/agent_run_ledger_marker_shape_test.c"), .flags = &.{"-std=gnu11"} });
    reaper_ms_module.addIncludePath(b.path("src"));
    const reaper_ms_exe = b.addExecutable(.{ .name = "reaper-ledger-marker-shape-test", .root_module = reaper_ms_module });
    const run_reaper_ms_tests = b.addRunArtifact(reaper_ms_exe);
    run_reaper_ms_tests.skip_foreign_checks = true;
    const reaper_ms_step = b.step("test-agent-run-reaper-ledger-marker-shape", "MS6.5.1 C2 marker classifier: no-wedge + shape-strict (regular 0400 only)");
    reaper_ms_step.dependOn(&run_reaper_ms_tests.step);
    // MS6.5.1 (plan "versioned/strict/bounded ledger schema"): the ledger parse (pure Zig std.json) — a
    // VERSIONED, STRICTLY typed, BOUNDED schema; an unknown version / over-cap / missing/extra/mistyped field /
    // bad state / duplicate basename / truncated input is rejected, so a malformed ledger never yields entries.
    const ledger_mod = b.createModule(.{ .root_source_file = b.path("src/agent_run_ledger.zig"), .target = target, .optimize = optimize });
    const ledger_parse_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_ledger_parse_test.zig"), .target = target, .optimize = optimize });
    ledger_parse_test_mod.addImport("agent_run_ledger", ledger_mod);
    const run_ledger_parse_tests = b.addRunArtifact(b.addTest(.{ .root_module = ledger_parse_test_mod }));
    run_ledger_parse_tests.skip_foreign_checks = true;
    const ledger_parse_step = b.step("test-agent-run-ledger-parse", "MS6.5.1 ledger schema parse (versioned/strict/bounded)");
    ledger_parse_step.dependOn(&run_ledger_parse_tests.step);
    // MS6.5.1 (RoseCat 0d2e91d #1): the parse validates each entry's fixed-length single-component basename
    // grammar, so one malformed row makes the whole ledger a malformed read (never an entry).
    const ledger_grammar_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_ledger_grammar_test.zig"), .target = target, .optimize = optimize });
    ledger_grammar_test_mod.addImport("agent_run_ledger", ledger_mod);
    const run_ledger_grammar_tests = b.addRunArtifact(b.addTest(.{ .root_module = ledger_grammar_test_mod }));
    run_ledger_grammar_tests.skip_foreign_checks = true;
    const ledger_grammar_step = b.step("test-agent-run-ledger-grammar", "MS6.5.1 ledger basename grammar in the parse (whole-ledger fail-closed)");
    ledger_grammar_step.dependOn(&run_ledger_grammar_tests.step);
    // MS6.5.1 (RoseCat 0d2e91d #2): load() size-limits the read (.limited(MAX_LEDGER_BYTES)) so a file over the
    // bound is TooManyEntries, not read/parsed in full — bounded before unbounded allocation.
    const ledger_load_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_ledger_load_test.zig"), .target = target, .optimize = optimize });
    ledger_load_test_mod.addImport("agent_run_ledger", ledger_mod);
    const run_ledger_load_tests = b.addRunArtifact(b.addTest(.{ .root_module = ledger_load_test_mod }));
    run_ledger_load_tests.skip_foreign_checks = true;
    const ledger_load_step = b.step("test-agent-run-ledger-load", "MS6.5.1 ledger load input-size bound (rejects an over-limit file before parsing)");
    ledger_load_step.dependOn(&run_ledger_load_tests.step);
    // MS6.5.1 (plan atomic-publish row): publish writes the ledger crash-safely (synced O_EXCL temp -> rename ->
    // dir fsync), so a reader only ever sees the old or the new complete store and a mid-publish crash leaves the
    // old store intact.
    const ledger_publish_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_ledger_publish_test.zig"), .target = target, .optimize = optimize });
    ledger_publish_test_mod.addImport("agent_run_ledger", ledger_mod);
    const run_ledger_publish_tests = b.addRunArtifact(b.addTest(.{ .root_module = ledger_publish_test_mod }));
    run_ledger_publish_tests.skip_foreign_checks = true;
    const ledger_publish_step = b.step("test-agent-run-ledger-publish", "MS6.5.1 ledger atomic publish (temp+fsync+rename+dir-fsync, crash cuts)");
    ledger_publish_step.dependOn(&run_ledger_publish_tests.step);
    // MS6.5.1 (RoseCat flock row): the cross-process advisory lock with bounded, cancellable LOCK_EX|LOCK_NB +
    // retry — a stalled holder in a SEPARATE process (fork) makes acquisition fail closed, mutating nothing.
    const ledger_lock_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_ledger_lock_test.zig"), .target = target, .optimize = optimize });
    ledger_lock_test_mod.addImport("agent_run_ledger", ledger_mod);
    const run_ledger_lock_tests = b.addRunArtifact(b.addTest(.{ .root_module = ledger_lock_test_mod }));
    run_ledger_lock_tests.skip_foreign_checks = true;
    const ledger_lock_step = b.step("test-agent-run-ledger-lock", "MS6.5.1 ledger cross-process flock (bounded, cancellable, fail-closed)");
    ledger_lock_step.dependOn(&run_ledger_lock_tests.step);
    // MS6.5.1 (RoseCat 53a467b #1): the lock is opened/created O_NOFOLLOW|O_CLOEXEC, so a symlink planted at
    // the lock path can never select another inode — a symlink (or any open error) fails closed.
    const ledger_lock_nofollow_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_ledger_lock_nofollow_test.zig"), .target = target, .optimize = optimize });
    ledger_lock_nofollow_test_mod.addImport("agent_run_ledger", ledger_mod);
    const run_ledger_lock_nofollow_tests = b.addRunArtifact(b.addTest(.{ .root_module = ledger_lock_nofollow_test_mod }));
    run_ledger_lock_nofollow_tests.skip_foreign_checks = true;
    const ledger_lock_nofollow_step = b.step("test-agent-run-ledger-lock-nofollow", "MS6.5.1 ledger lock O_NOFOLLOW fail-closed (symlink never followed)");
    ledger_lock_nofollow_step.dependOn(&run_ledger_lock_nofollow_tests.step);
    // MS6.5.1 (RoseCat 7511b79): the ledger is a macOS primitive, so it must cross-compile to Darwin. Build the
    // module as an object for both macOS arches through darwinGuardObject, whose root analyses every public non-generic
    // declaration (4pa.63), so an API misuse that only surfaces on Darwin (wrong flag/type/symbol) fails this check.
    // Generic functions are not analysed until instantiated. The lock's flock/close/errno
    // go through std.posix.system (the raw syscall on Linux, libc on Darwin) so they behave the same on Darwin.
    const ledger_darwin_aarch64_mod = b.createModule(.{ .root_source_file = b.path("src/agent_run_ledger.zig"), .target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos }), .optimize = optimize });
    const ledger_darwin_aarch64_obj = darwinGuardObject(b, "agent_run_ledger_darwin_aarch64", ledger_darwin_aarch64_mod);
    const ledger_darwin_x86_64_mod = b.createModule(.{ .root_source_file = b.path("src/agent_run_ledger.zig"), .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .macos }), .optimize = optimize });
    const ledger_darwin_x86_64_obj = darwinGuardObject(b, "agent_run_ledger_darwin_x86_64", ledger_darwin_x86_64_mod);
    const ledger_darwin_step = b.step("test-agent-run-ledger-darwin-build", "MS6.5.1 ledger cross-compiles to Darwin (aarch64 + x86_64 macOS)");
    ledger_darwin_step.dependOn(&ledger_darwin_aarch64_obj.step);
    ledger_darwin_step.dependOn(&ledger_darwin_x86_64_obj.step);
    // bd zigBrowser-4pa.63 (plan R30-MS6, R30.2 T5): the Darwin guards' selftest. Each probe holds an UNREFERENCED pub
    // fn (top level, and one container down) that is a type error on macOS only; built through the same
    // darwinGuardObject as the guards, for both macOS arches, it must fail with exactly that error, and the same probe
    // built for Linux must compile (so the error is Darwin's, not the probe's). In `test`.
    const darwin_guard_selftest_step = b.step("test-darwin-guard-selftest", "4pa.63: the Darwin guards analyse every declaration (a Darwin-only type error fails them)");
    for ([_][]const u8{ "tests/darwin_guard_probe_top.zig", "tests/darwin_guard_probe_nested.zig" }) |probe| {
        for ([_]std.Target.Cpu.Arch{ .aarch64, .x86_64 }) |arch| {
            const probe_mod = b.createModule(.{ .root_source_file = b.path(probe), .target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .macos }), .optimize = optimize });
            const probe_obj = darwinGuardObject(b, "darwin_guard_probe", probe_mod);
            probe_obj.expect_errors = .{ .contains = "error: index 1 outside array of length 1" };
            darwin_guard_selftest_step.dependOn(&probe_obj.step);
        }
        const probe_linux_mod = b.createModule(.{ .root_source_file = b.path(probe), .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux }), .optimize = optimize });
        darwin_guard_selftest_step.dependOn(&darwinGuardObject(b, "darwin_guard_probe_linux", probe_linux_mod).step);
    }
    // MS6.5.1 (SCOPED, RoseCat c11bff8): a ONE-live-process liveness probe keyed on the recorded owner (pid,start)
    // mapped to an action LABEL — proved-dead -> .recover, same live owner -> .leave, PID reuse/unreadable ->
    // fail closed. The fork is ONE live process to probe; nothing is signalled/retired, no whole-recovery.
    // Signal-free. Linux-gated (/proc probe).
    const ledger_recovery_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_ledger_recovery_test.zig"), .target = target, .optimize = optimize });
    ledger_recovery_test_mod.addImport("agent_run_ledger", ledger_mod);
    const run_ledger_recovery_tests = b.addRunArtifact(b.addTest(.{ .root_module = ledger_recovery_test_mod }));
    run_ledger_recovery_tests.skip_foreign_checks = true;
    const ledger_recovery_step = b.step("test-agent-run-ledger-recovery", "MS6.5.1 ledger (pid,start) one-live-process liveness probe + fail-closed action label (SCOPED, not whole-recovery)");
    ledger_recovery_step.dependOn(&run_ledger_recovery_tests.step);
    // MS6.5.1 (SCOPED, RoseCat c11bff8): the v2 platform-tagged owner-start schema — a known start_kind parses, an
    // unknown/missing kind and an impossible per-kind shape are Malformed, (kind,sec,usec) preserved. Pure parse.
    const ledger_start_kind_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_ledger_start_kind_test.zig"), .target = target, .optimize = optimize });
    ledger_start_kind_test_mod.addImport("agent_run_ledger", ledger_mod);
    const run_ledger_start_kind_tests = b.addRunArtifact(b.addTest(.{ .root_module = ledger_start_kind_test_mod }));
    run_ledger_start_kind_tests.skip_foreign_checks = true;
    const ledger_start_kind_step = b.step("test-agent-run-ledger-start-kind", "MS6.5.1 ledger v2 platform-tagged owner-start schema (start_kind, canonical shape)");
    ledger_start_kind_step.dependOn(&run_ledger_start_kind_tests.step);
    // MS6.5.1 (SCOPED, RoseCat c11bff8 / 0e36742 #4): liveness is SAME-KIND only — a cross-kind identity never
    // matches even when numerically equal (fails closed). One-live-process fork, signal-free, Linux-gated.
    const ledger_samekind_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_ledger_samekind_test.zig"), .target = target, .optimize = optimize });
    ledger_samekind_test_mod.addImport("agent_run_ledger", ledger_mod);
    const run_ledger_samekind_tests = b.addRunArtifact(b.addTest(.{ .root_module = ledger_samekind_test_mod }));
    run_ledger_samekind_tests.skip_foreign_checks = true;
    const ledger_samekind_step = b.step("test-agent-run-ledger-samekind", "MS6.5.1 ledger liveness same-kind-only: a cross-kind identity never matches (fails closed)");
    ledger_samekind_step.dependOn(&run_ledger_samekind_tests.step);
    // MS6.5.1 (RoseCat d3b31cb #1/#2): the liveness probe keeps absence distinct from unreadability — only a
    // proved-absent process is dead; a permission/read/truncation/parse failure fails closed (.unreadable). Pure
    // injectable classifier/parser unit (no /proc, no fork), so it runs on every host.
    const ledger_unreadable_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_ledger_unreadable_test.zig"), .target = target, .optimize = optimize });
    ledger_unreadable_test_mod.addImport("agent_run_ledger", ledger_mod);
    const run_ledger_unreadable_tests = b.addRunArtifact(b.addTest(.{ .root_module = ledger_unreadable_test_mod }));
    run_ledger_unreadable_tests.skip_foreign_checks = true;
    const ledger_unreadable_step = b.step("test-agent-run-ledger-unreadable", "MS6.5.1 ledger liveness: unreadable fails closed, never dead");
    ledger_unreadable_step.dependOn(&run_ledger_unreadable_tests.step);
    // MS6.5.1 (RoseCat 83d3a0f #2): drive the PRODUCTION readStart outcome mapping through the injectable StatIo
    // boundary — only open_absent is absence; a non-absence open error, read error, empty read, or unparseable
    // bytes all map to .unreadable and fail closed. Pure injected outcomes (no /proc, no fork), every host.
    const ledger_statio_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_ledger_statio_test.zig"), .target = target, .optimize = optimize });
    ledger_statio_test_mod.addImport("agent_run_ledger", ledger_mod);
    const run_ledger_statio_tests = b.addRunArtifact(b.addTest(.{ .root_module = ledger_statio_test_mod }));
    run_ledger_statio_tests.skip_foreign_checks = true;
    const ledger_statio_step = b.step("test-agent-run-ledger-statio", "MS6.5.1 ledger readStart outcome mapping: only absence recovers, every unreadable class fails closed");
    ledger_statio_step.dependOn(&run_ledger_statio_tests.step);
    // MS6.5.1 (RoseCat e665676 #1): acquisition honors ONE absolute monotonic deadline (not try-count arithmetic)
    // — retry only while the clock is before the deadline, stop AT it. Fake clock + counting attempt, fork-free.
    const ledger_deadline_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_ledger_deadline_test.zig"), .target = target, .optimize = optimize });
    ledger_deadline_test_mod.addImport("agent_run_ledger", ledger_mod);
    const run_ledger_deadline_tests = b.addRunArtifact(b.addTest(.{ .root_module = ledger_deadline_test_mod }));
    run_ledger_deadline_tests.skip_foreign_checks = true;
    const ledger_deadline_step = b.step("test-agent-run-ledger-deadline", "MS6.5.1 bounded flock acquisition honors one absolute monotonic deadline");
    ledger_deadline_step.dependOn(&run_ledger_deadline_tests.step);
    // MS6.5.1 (RoseCat e665676 #3): the bounded-acquire test's watchdog is bounded by an absolute monotonic
    // deadline even under an EINTR storm (waitWithinDeadline checks the deadline before each poll). Fake clock.
    const ledger_watchdog_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_ledger_watchdog_test.zig"), .target = target, .optimize = optimize });
    ledger_watchdog_test_mod.addImport("agent_run_ledger", ledger_mod);
    const run_ledger_watchdog_tests = b.addRunArtifact(b.addTest(.{ .root_module = ledger_watchdog_test_mod }));
    run_ledger_watchdog_tests.skip_foreign_checks = true;
    const ledger_watchdog_step = b.step("test-agent-run-ledger-watchdog", "MS6.5.1 bounded-acquire watchdog is EINTR-bounded by an absolute monotonic deadline");
    ledger_watchdog_step.dependOn(&run_ledger_watchdog_tests.step);
    // MS6.5.1 (SCOPED, RoseCat c11bff8): a live owner holding the global flock that stalls must not wedge the
    // bounded acquire — acquireRunLockBounded fails closed within the total deadline (acquired=false,
    // lock_unavailable incident), performing no recovery and no mutation. Two real processes + a parent watchdog;
    // signal-free (the SIGKILL in the wedge path is confined to the PID-ns sentinel). Linux-gated.
    const ledger_recovery_busy_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_ledger_recovery_busy_test.zig"), .target = target, .optimize = optimize });
    ledger_recovery_busy_test_mod.addImport("agent_run_ledger", ledger_mod);
    const ledger_recovery_busy_exe = b.addTest(.{ .root_module = ledger_recovery_busy_test_mod });
    // SAFETY (RoseCat e665676 #2): this test sends SIGKILL to its holder in the wedge path, so it runs ONLY inside
    // a private PID namespace. The launcher holds its OUTER /proc/self/ns/pid as fd 9 (`exec 9<…`) BEFORE unshare,
    // so the test's kernel-proof sentinel can prove it is strictly below it; `unshare --fork` makes a shell pid 1
    // that runs the test (orphans adopt to pid 1, as in production). No signal is reachable outside the namespace.
    const run_ledger_recovery_busy_tests = b.addSystemCommand(&.{
        "sh", "-c",
        "exec 9</proc/self/ns/pid; exec unshare --user --map-root-user --pid --fork --mount-proc sh -c '\"$@\"; rc=$?; exit $rc' sh \"$1\"",
        "sh",
    });
    run_ledger_recovery_busy_tests.addArtifactArg(ledger_recovery_busy_exe);
    // bd zigBrowser-3ui.4: every fd-9 PID-namespace launcher string in this file is driven on a stub test that exits 7
    // and one that exits 0, and must report 7, then 0 (a launcher ending `; :` exited 0 whatever its test returned).
    const pidns_launcher_status = b.addSystemCommand(&.{ "python3", "-I", "tests/e2e/pidns_launcher_status_test.py" });
    pidns_launcher_status.addFileInput(b.path("tests/e2e/pidns_launcher_status_test.py"));
    pidns_launcher_status.addFileInput(b.path("build.zig"));
    pidns_launcher_status.addFileInput(b.path("tools/agent_host_env.sh"));
    const pidns_launcher_status_step = b.step("test-pidns-launcher-status", "3ui.4: every PID-namespace launcher passes its test's exit status through");
    pidns_launcher_status_step.dependOn(&pidns_launcher_status.step);
    const ledger_recovery_busy_step = b.step("test-agent-run-ledger-recovery-busy", "MS6.5.1 bounded acquire fails closed on a stalled live flock holder (SCOPED, not whole-recovery; PID-ns sentinel)");
    ledger_recovery_busy_step.dependOn(&run_ledger_recovery_busy_tests.step);
    // MS6.5.1 bd zigBrowser-3gl (RoseCat 9f62ea4 #1 / mail 7806): the CONCRETE recovery lease over the reviewed
    // reaper C path (src/agent_run_reaper.c). MANUAL step — deliberately NOT attached to the aggregate `test` step
    // until the intercepted-action / early-unlock / path-swap matrix passes and the destructive slice is accepted.
    // It runs inside a private user/PID/mount namespace; the launcher holds its OUTER /proc/self/ns/pid as fd 9
    // (`exec 9<…`) BEFORE unshare, so the test's sentinel refuses before any signal if fd 9 is absent. UNARMED.
    const recovery_concrete_mod = b.createModule(.{ .root_source_file = b.path("src/agent_run_recovery.zig"), .target = target, .optimize = optimize, .link_libc = true });
    recovery_concrete_mod.addImport("agent_run_ledger", ledger_mod);
    recovery_concrete_mod.addIncludePath(b.path("src"));
    const recovery_concrete_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_recovery_concrete_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    recovery_concrete_test_mod.addImport("agent_run_ledger", ledger_mod);
    recovery_concrete_test_mod.addImport("agent_run_recovery", recovery_concrete_mod);
    recovery_concrete_test_mod.addIncludePath(b.path("src"));
    recovery_concrete_test_mod.addCSourceFile(.{ .file = b.path("src/agent_run_reaper.c"), .flags = &.{"-std=gnu11"} });
    const recovery_concrete_exe = b.addTest(.{ .root_module = recovery_concrete_test_mod });
    const run_recovery_concrete = b.addSystemCommand(&.{
        "sh", "-c",
        "exec 9</proc/self/ns/pid; exec unshare --user --map-root-user --pid --fork --mount-proc sh -c '\"$@\"; rc=$?; exit $rc' sh \"$1\"",
        "sh",
    });
    run_recovery_concrete.addArtifactArg(recovery_concrete_exe);
    const recovery_concrete_step = b.step("test-agent-run-recovery-txn", "MS6.5.1 bd zigBrowser-3gl CONCRETE recovery lease over the reaper C (private ns, fd-9 sentinel; MANUAL, not in aggregate)");
    recovery_concrete_step.dependOn(&run_recovery_concrete.step);
    // Prove the Darwin build path for the recovery slice (RoseCat 671c986 #3) AND compile the reviewed reaper C's
    // __APPLE__ body here (RoseCat afdffbf #3): cross-compile the Zig actuator + src/agent_run_reaper.c to aarch64 +
    // x86_64 macOS as objects. The Zig actuator calls the Apple-only `zb_reaper_prod_recover`, so the reaper C must
    // compile for Darwin in THIS step — invalid Apple C (e.g. the capability binder) fails the manual step, not just
    // the far-off Mac gate. Zig ships the macOS libproc headers, so the libproc + real-kill wrappers compile here.
    inline for (.{ .{ "aarch64", std.Target.Cpu.Arch.aarch64 }, .{ "x86_64", std.Target.Cpu.Arch.x86_64 } }) |m| {
        const dl = b.createModule(.{ .root_source_file = b.path("src/agent_run_ledger.zig"), .target = b.resolveTargetQuery(.{ .cpu_arch = m[1], .os_tag = .macos }), .optimize = optimize });
        const dr = b.createModule(.{ .root_source_file = b.path("src/agent_run_recovery.zig"), .target = b.resolveTargetQuery(.{ .cpu_arch = m[1], .os_tag = .macos }), .optimize = optimize, .link_libc = true });
        dr.addImport("agent_run_ledger", dl);
        dr.addIncludePath(b.path("src"));
        dr.addCSourceFile(.{ .file = b.path("src/agent_run_reaper.c"), .flags = &.{"-std=gnu11"} }); // compiles the __APPLE__ body
        const dobj = darwinGuardObject(b, "agent_run_recovery_darwin_" ++ m[0], dr);
        recovery_concrete_step.dependOn(&dobj.step);
    }
    // MS6.5.1 bd zigBrowser-3gl: the reaper_ready arming gate + startup-recovery CORE (RoseCat 428d06e APPROVED the
    // red 3bfb8dc). UNARMED (reaper_ready ships false); signal-free fakes, no fork/namespace/display. The reaper C is
    // linked because the module @cImports its header. A real app-startup owner calling recoverAllAtStartup is an OPEN
    // integration blocker, not this slice.
    const recovery_startup_mod = b.createModule(.{ .root_source_file = b.path("src/agent_run_recovery.zig"), .target = target, .optimize = optimize, .link_libc = true });
    recovery_startup_mod.addImport("agent_run_ledger", ledger_mod);
    recovery_startup_mod.addIncludePath(b.path("src"));
    const recovery_startup_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_recovery_startup_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    recovery_startup_test_mod.addImport("agent_run_ledger", ledger_mod);
    recovery_startup_test_mod.addImport("agent_run_recovery", recovery_startup_mod);
    recovery_startup_test_mod.addIncludePath(b.path("src"));
    recovery_startup_test_mod.addCSourceFile(.{ .file = b.path("src/agent_run_reaper.c"), .flags = &.{"-std=gnu11"} });
    const run_recovery_startup = b.addRunArtifact(b.addTest(.{ .root_module = recovery_startup_test_mod }));
    run_recovery_startup.skip_foreign_checks = true;
    const recovery_startup_step = b.step("test-agent-run-recovery-startup", "MS6.5.1 reaper_ready gate + startup-recovery core (unarmed; signal-free fakes)");
    recovery_startup_step.dependOn(&run_recovery_startup.step);
    // 4pa.65 / 4pa.68 (plan R30-MS6): the real store name `zigbrowser-agent-runs.json` recovers, and an entry pid below
    // 2 or unlike its basename's never reaches the actuator. Through the production startup core; signal-free fakes.
    const recovery_store_pid_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_recovery_store_pid_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    recovery_store_pid_test_mod.addImport("agent_run_ledger", ledger_mod);
    recovery_store_pid_test_mod.addImport("agent_run_recovery", recovery_startup_mod);
    recovery_store_pid_test_mod.addIncludePath(b.path("src"));
    recovery_store_pid_test_mod.addCSourceFile(.{ .file = b.path("src/agent_run_reaper.c"), .flags = &.{"-std=gnu11"} });
    const run_recovery_store_pid = b.addRunArtifact(b.addTest(.{ .root_module = recovery_store_pid_test_mod }));
    run_recovery_store_pid.skip_foreign_checks = true;
    const recovery_store_pid_step = b.step("test-agent-run-recovery-store-pid", "MS6.5.1 4pa.65/4pa.68: the real store name recovers; a bad entry pid never reaches the actuator");
    recovery_store_pid_step.dependOn(&run_recovery_store_pid.step);
    // 4pa.71 (plan R30-MS6): the PRODUCTION recovery transaction `ledger.recoverOneUnderLock` with an injected,
    // signal-free fake lease (two forked recoverers, a live owner, the deadline, crash cut C3, mismatch, unreadable).
    // It forks, and a stuck child is SIGKILLed, so it runs only in a private user+PID namespace: the launcher holds
    // the OUTER /proc/self/ns/pid as fd 9 for the test's sentinel, the shell stays PID 1 (orphans adopt to it), and
    // it exits with the test's own status (`rc=$?; exit $rc`), so a failing test fails the step.
    const ledger_recovery_txn_test_mod = b.createModule(.{ .root_source_file = b.path("tests/agent_run_ledger_recovery_txn_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    ledger_recovery_txn_test_mod.addImport("agent_run_ledger", ledger_mod);
    ledger_recovery_txn_test_mod.addImport("agent_run_recovery", recovery_startup_mod); // the transaction lives there (I-W3)
    ledger_recovery_txn_test_mod.addIncludePath(b.path("src"));
    ledger_recovery_txn_test_mod.addCSourceFile(.{ .file = b.path("src/agent_run_reaper.c"), .flags = &.{"-std=gnu11"} });
    const run_ledger_recovery_txn_tests = b.addSystemCommand(&.{
        "sh", "-c",
        "exec 9</proc/self/ns/pid; exec unshare --user --map-root-user --pid --fork --mount-proc sh -c '\"$@\"; rc=$?; exit $rc' sh \"$1\"",
        "sh",
    });
    run_ledger_recovery_txn_tests.addArtifactArg(b.addTest(.{ .root_module = ledger_recovery_txn_test_mod }));
    const ledger_recovery_txn_step = b.step("test-agent-run-ledger-recovery-txn", "MS6.5.1 4pa.71: the production recovery transaction (signal-free fake lease; PID-ns sentinel)");
    ledger_recovery_txn_step.dependOn(&run_ledger_recovery_txn_tests.step);
    // R29.6 I-W3 / R30.2 T20 (4pa.71): a PRODUCTION (non-test) build can reach recovery only through the readiness-bound
    // recoverAllAtStartup. Each probe is a generated non-test object that names one bypass -- the transaction or a
    // readiness-taking startup entry, directly, through `test_support`, or on the ledger -- and must FAIL to compile with
    // exactly that refusal; a control probe naming recoverAllAtStartup must compile. Compiled, never run.
    const bypass_closed_step = b.step("test-agent-run-recovery-bypass-closed", "4pa.71 / T20: a production build reaches recovery only through recoverAllAtStartup");
    const bypass_probes = b.addWriteFiles();
    const BypassProbe = struct { name: []const u8, ref: []const u8, want: []const u8 };
    const bypasses = [_][]const u8{ "recoverOneUnderLock", "recoverOneUnderLockP", "recoverAllAtStartupGated", "recoverAllAtStartupGatedH", "recoverAllAtStartupFull" };
    var bypass_rows: [2 * bypasses.len + 2 + 1]BypassProbe = undefined;
    var n_rows: usize = 0;
    for (bypasses) |name| {
        bypass_rows[n_rows] = .{ .name = b.fmt("direct_{s}", .{name}), .ref = b.fmt("recovery.{s}", .{name}), .want = b.fmt("error: '{s}' is not marked 'pub'", .{name}) };
        bypass_rows[n_rows + 1] = .{ .name = b.fmt("test_support_{s}", .{name}), .ref = b.fmt("recovery.test_support.{s}", .{name}), .want = b.fmt("has no member named '{s}'", .{name}) };
        n_rows += 2;
    }
    for ([_][]const u8{ "recoverOneUnderLock", "recoverOneUnderLockP" }) |name| {
        bypass_rows[n_rows] = .{ .name = b.fmt("ledger_{s}", .{name}), .ref = b.fmt("ledger.{s}", .{name}), .want = b.fmt("has no member named '{s}'", .{name}) };
        n_rows += 1;
    }
    bypass_rows[n_rows] = .{ .name = "control_recoverAllAtStartup", .ref = "recovery.recoverAllAtStartup", .want = "" };
    n_rows += 1;
    for (bypass_rows[0..n_rows]) |row| {
        const src = bypass_probes.add(b.fmt("{s}.zig", .{row.name}), b.fmt("const recovery = @import(\"agent_run_recovery\");\nconst ledger = @import(\"agent_run_ledger\");\ncomptime {{\n    _ = recovery;\n    _ = ledger;\n    _ = {s};\n}}\n", .{row.ref}));
        const probe_mod = b.createModule(.{ .root_source_file = src, .target = target, .optimize = optimize, .link_libc = true });
        probe_mod.addImport("agent_run_recovery", recovery_startup_mod);
        probe_mod.addImport("agent_run_ledger", ledger_mod);
        probe_mod.addIncludePath(b.path("src"));
        const probe_obj = b.addObject(.{ .name = b.fmt("bypass_{s}", .{row.name}), .root_module = probe_mod });
        if (row.want.len > 0) probe_obj.expect_errors = .{ .contains = row.want };
        bypass_closed_step.dependOn(&probe_obj.step);
    }
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
    // Chat drawer S8 decision 16: the platform-free core of navigate/reload approval (the selector x the
    // mode, the store, the main window's cards; src/agent_approval.zig).
    const agent_approval_policy_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_approval_policy_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_approval_policy_tests_module.addImport("agent_approval", b.createModule(.{
        .root_source_file = b.path("src/agent_approval.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_agent_approval_policy_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_approval_policy_tests_module }));
    run_agent_approval_policy_tests.skip_foreign_checks = true;
    // S8 decision 16 part 4 (RoseCat f87368e #4): the store's owner and its settings directory.
    const agent_approval_owner_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_approval_owner_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_approval_owner_tests_module.addImport("agent_approval", b.createModule(.{
        .root_source_file = b.path("src/agent_approval.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_agent_approval_owner_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_approval_owner_tests_module }));
    run_agent_approval_owner_tests.skip_foreign_checks = true;
    // S8 decision 16 part 5 (rev 16.20.58): the store's one writer (the Secrets window's control).
    const agent_approval_writer_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_approval_writer_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_approval_writer_tests_module.addImport("agent_approval", b.createModule(.{
        .root_source_file = b.path("src/agent_approval.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const run_agent_approval_writer_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_approval_writer_tests_module }));
    run_agent_approval_writer_tests.skip_foreign_checks = true;

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

    // WS6.1 (a): the PORTABLE token shape as its own module, and its [L] property test. agent_secrets.zig
    // re-exports from this module; here it is exercised directly, proving it needs no std.os.linux.
    const agent_secrets_shape_module = b.createModule(.{
        .root_source_file = b.path("src/agent_secrets_shape.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shape_portable_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/windows/agent_secrets_shape_portable_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    shape_portable_tests_module.addImport("agent_secrets_shape", agent_secrets_shape_module);
    const run_shape_portable_tests = b.addRunArtifact(b.addTest(.{ .root_module = shape_portable_tests_module }));
    run_shape_portable_tests.skip_foreign_checks = true;

    // WS6 (b): the portable TokenStore interface + WS6.3 safety refusal, [L] with fakes.
    const agent_secrets_store_module = b.createModule(.{
        .root_source_file = b.path("src/agent_secrets_store.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agent_secrets_store_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/windows/agent_secrets_store_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_secrets_store_tests_module.addImport("agent_secrets_store", agent_secrets_store_module);
    const run_agent_secrets_store_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_secrets_store_tests_module }));
    run_agent_secrets_store_tests.skip_foreign_checks = true;

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
    // S8a decision 2 for the X flows: an approved x.post / x.schedule_post runs phases A to C.
    const automation_expect_x_flow_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_expect_x_flow_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_expect_x_flow_tests_module.addImport("automation", automation_module);
    const run_automation_expect_x_flow_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_expect_x_flow_tests_module }));
    run_automation_expect_x_flow_tests.skip_foreign_checks = true;
    // S8a decision 13: an approved message or DM checks its recipient in two stages, per step.
    const automation_recipient_guard_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_recipient_guard_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_recipient_guard_tests_module.addImport("automation", automation_module);
    const run_automation_recipient_guard_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_recipient_guard_tests_module }));
    run_automation_recipient_guard_tests.skip_foreign_checks = true;
    // S8a decision 13 stage 1 (RoseCat 8b05366): the opener binds the profile's owner from the approval.
    const automation_recipient_owner_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_recipient_owner_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_recipient_owner_tests_module.addImport("automation", automation_module);
    const run_automation_recipient_owner_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_recipient_owner_tests_module }));
    run_automation_recipient_owner_tests.skip_foreign_checks = true;
    // S8a decision 13 (rev 16.20.55): a thread that opens as a new page gets phase C again, and every
    // guarded action names its document.
    const automation_thread_document_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_thread_document_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_thread_document_tests_module.addImport("automation", automation_module);
    const run_automation_thread_document_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_thread_document_tests_module }));
    run_automation_thread_document_tests.skip_foreign_checks = true;

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
    // 4pa.62 (Linux shared-parser half) + V03-F14: the window, dialog and recovery parsers and the ZB_AUTO_* map that
    // both PagePort adapters use (src/automation_port_parse.zig), run on Linux on every gate; the macOS port's copies
    // had no test. The macOS runtime of these paths is still proven only by a released Mac run.
    const automation_port_parse_module = b.createModule(.{
        .root_source_file = b.path("src/automation_port_parse.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_port_parse_module.addIncludePath(b.path("src"));
    const automation_port_parse_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_port_parse_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_port_parse_tests_module.addIncludePath(b.path("src"));
    automation_port_parse_tests_module.addImport("automation_port_parse", automation_port_parse_module);
    const run_automation_port_parse_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_port_parse_tests_module }));
    const automation_port_parse_step = b.step("test-automation-port-parse", "4pa.62: the shared shim-answer parsers both PagePort adapters use");
    automation_port_parse_step.dependOn(&run_automation_port_parse_tests.step);

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
    // S8a: the server's x.* route hands the bound window to an approved X flow.
    const automation_expect_x_flow_server_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_expect_x_flow_server_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_expect_x_flow_server_tests_module.addImport("automation_server", automation_server_module);
    const run_automation_expect_x_flow_server_tests = b.addRunArtifact(b.addTest(.{ .root_module = automation_expect_x_flow_server_tests_module }));
    run_automation_expect_x_flow_server_tests.skip_foreign_checks = true;
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
    var s7a_runs: [11]*std.Build.Step = undefined;
    for ([_][]const u8{ "tests/automation_inprocess_test.zig", "tests/agent_broker_test.zig", "tests/agent_broker_window_info_test.zig", "tests/agent_broker_reply_test.zig", "tests/agent_broker_detach_test.zig", "tests/agent_broker_detach_oom_test.zig", "tests/agent_broker_screenshot_test.zig", "tests/agent_broker_navigate_test.zig", "tests/agent_navigate_card_test.zig", "tests/agent_navigate_bind_test.zig", "tests/agent_broker_hover_test.zig" }, 0..) |path, i| {
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
        "python3 tests/e2e/automation_api_lifecycle_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "automation-api-e2e",
    });
    automation_api_e2e.addArtifactArg(exe);

    // M12: external socket client drives the live page (fixture server).
    const automation_core_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_core_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "automation-core-e2e",
    });
    automation_core_e2e.addArtifactArg(exe);

    // First-RPC dom.waitFor during a slow first load keeps the JS timeout authoritative.
    const automation_readiness_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_readiness_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "automation-readiness-e2e",
    });
    automation_readiness_e2e.addArtifactArg(exe);

    // Python SDK driving the real binary (navigate -> type -> click -> getText).
    const sdk_python_live_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/sdk_python_live_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "sdk-python-live-e2e",
    });
    sdk_python_live_e2e.addArtifactArg(exe);

    // N11: x.post / x.schedule_post / x.login_check on the X composer fixture.
    const x_flows_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/x_flows_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "x-flows-e2e",
    });
    x_flows_e2e.addArtifactArg(exe);

    // N14: x.post / x.schedule_post with native, humanized input (isTrusted).
    const x_native_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/x_native_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "x-native-e2e",
    });
    x_native_e2e.addArtifactArg(exe);

    // N16: linkedin.* / instagram.* through the Python SDK on site-modelled fixtures.
    const social_flows_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/social_flows_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "social-flows-e2e",
    });
    social_flows_e2e.addArtifactArg(exe);
    // MS4.4 (macOS plan): the flows' login gate reads the session cookie through the platform's cookie port and
    // opens only while it is in the store (f234ad9; RoseCat 7886). Real binary, its own PID namespace, private Xvfb.
    const ms4_4_login_gate_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "timeout -k 10 600 unshare --map-current-user --pid --fork --kill-child --mount-proc env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY python3 tests/e2e/ms4_4_login_gate_test.py --binary \"$1\"",
        "ms4-4-login-gate-e2e",
    });
    ms4_4_login_gate_e2e.addArtifactArg(exe);
    // MS4.4's macOS driver stops the browser's exact process group on SIGTERM/SIGINT/SIGHUP (RoseCat 7886 #1);
    // a stand-in group, no browser. Our uid, PID namespace.
    const ms4_4_login_gate_cleanup_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c 'setsid -w python3 -X dev -m unittest -v ms4_4_login_gate_cleanup_test; exit $?' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms4_4_login_gate_cleanup_test: ResourceWarning' >&2; exit 1; fi",
    });
    // S8a: an approved flow on the real binary and the LinkedIn fixture (automation.js documentToken).
    const automation_expect_flow_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_expect_flow_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "automation-expect-flow-e2e",
    });
    automation_expect_flow_e2e.addArtifactArg(exe);
    // S8a: an approved x.post on the real binary and the X composer fixture.
    const automation_expect_x_flow_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_expect_x_flow_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "automation-expect-x-flow-e2e",
    });
    automation_expect_x_flow_e2e.addArtifactArg(exe);
    // S8a decision 13: the recipient checks on the real binary and the LinkedIn/Instagram fixtures.
    const automation_recipient_guard_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_recipient_guard_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "automation-recipient-guard-e2e",
    });
    automation_recipient_guard_e2e.addArtifactArg(exe);
    // S8a decision 13 stage 1: a wrong owner at the unchanged approved path, on the real binary.
    const automation_recipient_owner_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_recipient_owner_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "automation-recipient-owner-e2e",
    });
    automation_recipient_owner_e2e.addArtifactArg(exe);
    // S8a decision 13 (rev 16.20.55): the thread page on the real binary and the Instagram fixture.
    const automation_thread_document_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_thread_document_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "automation-thread-document-e2e",
    });
    automation_thread_document_e2e.addArtifactArg(exe);

    // N18: synthetic dom.scroll / dom.hover through the Python SDK; offsets
    // read back in the next command.
    const automation_scroll_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_scroll_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "automation-scroll-e2e",
    });
    automation_scroll_e2e.addArtifactArg(exe);

    // 3ui.6: a relative ZIGBROWSER_SOCKET is refused (exit 1, a fixed line), never a panic. The real binary runs
    // under a private Xvfb, HOME and XDG dirs; the test relaunches itself below a held PID namespace and proves it
    // (pidns_guard) before it starts anything it may have to signal.
    const automation_relative_socket_e2e = b.addSystemCommand(&.{ "python3", "tests/e2e/automation_relative_socket_test.py", "--binary" });
    automation_relative_socket_e2e.addArtifactArg(exe);
    automation_relative_socket_e2e.addFileInput(b.path("tests/e2e/automation_relative_socket_test.py"));
    automation_relative_socket_e2e.addFileInput(b.path("agent/host/tests/pidns_guard.py"));
    const automation_relative_socket_step = b.step("test-automation-relative-socket", "3ui.6: a relative ZIGBROWSER_SOCKET is refused with a clear error, never a panic");
    automation_relative_socket_step.dependOn(&automation_relative_socket_e2e.step);

    // PagePort v3.3/v3.4 on the real GTK adapter: screenshot PNG, file
    // chooser, native wheel scrolling.
    const automation_native_ports_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_native_ports_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "automation-native-ports-e2e",
    });
    automation_native_ports_e2e.addArtifactArg(exe);

    // N21: pacing survives a restart on the same --profile-dir (real binary).
    const automation_pacing_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_pacing_persist_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "automation-pacing-e2e",
    });
    automation_pacing_e2e.addArtifactArg(exe);

    // libsoup 3.6.5 HTTP/2 GOAWAY workaround: a local TLS HTTP/2 server ends each response
    // with GOAWAY(NO_ERROR); the page's fetch must succeed (SOUP_FORCE_HTTP1=1 by default).
    const http2_goaway_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/http2_goaway_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "http2-goaway-e2e",
    });
    http2_goaway_e2e.addArtifactArg(exe);

    // E2E harness hygiene: a browser started through the shared launcher
    // (tests/e2e/xsession.py) never outlives a test driver that dies mid-test.
    const harness_group_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/harness_group_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "harness-group-e2e",
    });
    harness_group_e2e.addArtifactArg(exe);

    // A window whose web process died says so in page.list and on stderr.
    const web_process_crash_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/web_process_crash_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "web-process-crash-e2e",
    });
    web_process_crash_e2e.addArtifactArg(exe);

    // --hardware-acceleration / --renderer reach WebKit's web process.
    const render_config_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/render_config_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "render-config-e2e",
    });
    render_config_e2e.addArtifactArg(exe);

    // The 15-second load timer never kills a committed page, nor a web
    // process related windows share.
    const slow_load_watchdog_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/slow_load_watchdog_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "slow-load-watchdog-e2e",
    });
    slow_load_watchdog_e2e.addArtifactArg(exe);

    // --media-source off / ZIGBROWSER_MEDIA_SOURCE=off: pages in every window,
    // popups and the screenshot see no MediaSource.
    const media_source_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/media_source_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
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
    // S8 decision 16 part 3 (rev 16.20.56): navigate and reload cards in the main window's drawer,
    // the desktop notification (a private bus and a fake server), main and bound window closes.
    const agent_navigate_approval_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_navigate_approval_test.py --binary \"$1\"",
        "agent-navigate-approval-e2e",
    });
    agent_navigate_approval_e2e.addArtifactArg(exe);
    // S8e part 1 (S8 decision 12): the model's hover and scroll through the real chain, with no
    // card even with the store at `yes`. It runs in a PID namespace of its own.
    const agent_hover_scroll_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_hover_scroll_test.py --binary \"$1\"",
        "agent-hover-scroll-e2e",
    });
    agent_hover_scroll_e2e.addArtifactArg(exe);
    // S8 decision 16 part 4 (S9.3, decision 8): Stop, a navigation, a reload, a crash, a recovery and
    // a killed helper while a card waits dispatch nothing. It runs in a PID namespace of its own.
    const agent_navigate_stale_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_navigate_stale_test.py --binary \"$1\"",
        "agent-navigate-stale-e2e",
    });
    agent_navigate_stale_e2e.addArtifactArg(exe);
    // S8 decision 8 at the app boundary (RoseCat 7802): the scripted helper's result, error,
    // Stop, and a late or duplicate end for an earlier prompt.
    const agent_navigate_prompt_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_navigate_prompt_test.py --binary \"$1\"",
        "agent-navigate-prompt-e2e",
    });
    agent_navigate_prompt_e2e.addArtifactArg(exe);
    // S8 decision 16 part 5 (rev 16.20.58): the Secrets window's Navigation approval drop-down.
    const agent_navigate_selector_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_navigate_selector_test.py --binary \"$1\"",
        "agent-navigate-selector-e2e",
    });
    agent_navigate_selector_e2e.addArtifactArg(exe);
    // RoseCat 7fcfadf: a refused write shows the stored value again, read back from the control.
    const agent_navigate_selector_refused_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_navigate_selector_refused_test.py --binary \"$1\"",
        "agent-navigate-selector-refused-e2e",
    });
    agent_navigate_selector_refused_e2e.addArtifactArg(exe);
    // RoseCat d3985c9: the real-screen fake-API cases launch from an explicit allowlist (non-live).
    const real_screen_env_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY PYTHONDONTWRITEBYTECODE=1 python3 tests/manual/test_real_screen_env.py",
    });
    real_screen_env_unit.addFileInput(b.path("tests/manual/test_real_screen_env.py"));
    real_screen_env_unit.addFileInput(b.path("tests/manual/real_screen_check.py"));
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
    // S7b follow-ups (RoseCat 6843 on 83c9d96): the tool deadline seam reaches the broker's H, a bad
    // value refuses the agent, and without --e2e-protocol it is inert.
    const agent_tool_deadline_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_tool_deadline_test.py --binary \"$1\"",
        "agent-tool-deadline-e2e",
    });
    agent_tool_deadline_e2e.addArtifactArg(exe);
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
        "python3 tests/e2e/ipc_roundtrip_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "ipc-roundtrip-e2e",
    });
    ipc_roundtrip_e2e.addArtifactArg(exe);

    // page.health: a frozen page turns responsive:false, out of band, while
    // another window stays responsive (watchdog slice 1).
    const page_health_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/page_health_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "page-health-e2e",
    });
    page_health_e2e.addArtifactArg(exe);

    // page.recover: a confirmed recovery ends a frozen web process and
    // reloads its windows; refusals end nothing (watchdog slice 2).
    const page_recover_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/page_recover_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
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
    // WS7.3 [L] (RoseCat 1a06bb0): the portable launcher contract — direct [claude_exe, *args], case-insensitive
    // .bat/.cmd refusal, exit-code propagation, wait+reap. Platform-neutral stdlib; the [W] e2e drives the native
    // zb-claude.exe in the session Job.
    const agent_host_launcher_contract = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_launcher_contract",
    });
    b.step("test-launcher-contract", "WS7.3 [L] portable launcher contract").dependOn(&agent_host_launcher_contract.step);
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
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c 'sh -c \"setsid -w \\\"\\$ZB_AGENT_HOST_PYTHON\\\" -X dev -m unittest -v test_setup_darwin; exit \\$?\"; exit $?' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_setup_darwin: ResourceWarning' >&2; exit 1; fi",
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
    // The probe's listening check where getsockopt(SO_ACCEPTCONN) is ENOPROTOOPT, as on macOS (db1f05b on both Macs):
    // the non-blocking accept() fallback with exact flag restoration, an early client closed unserved (RoseCat 7387).
    const agent_host_route_probe_darwin_listen = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_route_probe_darwin_listen 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_route_probe_darwin_listen: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_route_probe_darwin_listen.step);
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
    // The census names WHY it is not clean: one fixed, token-free reason; a vanished child is benign only when
    // confirmed and another live CLI is fully checked (RoseCat 7986/7995). Faked walk, no signal; namespaced.
    const agent_host_proc_darwin_census_reason = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c '\"$0\" -X dev -m unittest -v test_proc_darwin_census_reason; exit $?' \"$py\" 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_proc_darwin_census_reason: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_proc_darwin_census_reason.step);
    // A pid the census confirmed gone is never traversed, so a reused pid lends it no children (RoseCat 8010).
    const agent_host_proc_darwin_pid_reuse = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c '\"$0\" -X dev -m unittest -v test_proc_darwin_pid_reuse; exit $?' \"$py\" 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_proc_darwin_pid_reuse: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_proc_darwin_pid_reuse.step);
    // R1 under Seatbelt, setup's half (RoseCat 6958; JadeBeacon 7004): probe_r1 pre-binds 127.0.0.1:0, passes it by
    // pass_fds, and the setup profile permits exactly that port (through the real sandbox_macos.setup_sandbox).
    const agent_host_setup_darwin_r1 = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c 'sh -c \"setsid -w \\\"\\$ZB_AGENT_HOST_PYTHON\\\" -X dev -m unittest -v test_setup_darwin_r1; exit \\$?\"; exit $?' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_setup_darwin_r1: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_setup_darwin_r1.step);
    // Setup's Darwin sandboxed runs get TMPDIR = their writable SCRATCHPAD (4c0a3db on both Macs: the probe found no
    // usable temporary directory under Seatbelt); Linux runs are unchanged.
    const agent_host_setup_darwin_tmpdir = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c 'sh -c \"setsid -w \\\"\\$ZB_AGENT_HOST_PYTHON\\\" -X dev -m unittest -v test_setup_darwin_tmpdir; exit \\$?\"; exit $?' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_setup_darwin_tmpdir: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_setup_darwin_tmpdir.step);
    // Setup's and the probe's throwaway trees are removed, a 0300 FIFO directory included, and a failed removal is
    // reported (16bad65 left such trees on both Macs). Plain like its siblings: a root-mapped namespace would hide it.
    const agent_host_scratch_cleanup = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_scratch_cleanup 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_scratch_cleanup: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_scratch_cleanup.step);
    // The scratch removal holds fds and never escapes its tree; reports name only the root (RoseCat 7421). Plain.
    const agent_host_scratch_cleanup_fd = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_scratch_cleanup_fd 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_scratch_cleanup_fd: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_scratch_cleanup_fd.step);
    // Setup's sandboxed runs as an owned process group (RoseCat 7418-7444): kill-safety refusals, bounded stops with a
    // group-gone proof, a fail-closed escapee, and the whole tree ended at setup's bound. Real signals: ONLY through the
    // held-fd launcher pidns_guard proves (RoseCat 7433), a shell kept as pid 1; a skipped row fails the step.
    const agent_host_owned_group = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(sh -c 'exec 9</proc/self/ns/pid; exec unshare --user --map-root-user --pid --fork --mount-proc sh -c \"\\\"\\$@\\\"; rc=\\$?; exit \\$rc\" sh env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$1\" ZB_OUTER_PIDNS_FD=9 \"$1\" -X dev -m unittest -v test_owned_group' sh \"$py\" 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_owned_group: ResourceWarning' >&2; exit 1; fi; if printf '%s\\n' \"$out\" | grep -q 'skipped'; then echo 'test_owned_group: real-signal rows skipped: not armed' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_owned_group.step);
    const agent_host_setup_sandbox_lifetime = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(sh -c 'exec 9</proc/self/ns/pid; exec unshare --user --map-root-user --pid --fork --mount-proc sh -c \"\\\"\\$@\\\"; rc=\\$?; exit \\$rc\" sh env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$1\" ZB_OUTER_PIDNS_FD=9 \"$1\" -X dev -m unittest -v test_setup_sandbox_lifetime' sh \"$py\" 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_setup_sandbox_lifetime: ResourceWarning' >&2; exit 1; fi; if printf '%s\\n' \"$out\" | grep -q 'skipped'; then echo 'test_setup_sandbox_lifetime: real-signal rows skipped: not armed' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_setup_sandbox_lifetime.step);
    const agent_host_pidns_guard = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_pidns_guard 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_pidns_guard: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_pidns_guard.step);
    // owned_group and setup fail closed whenever a run's group cannot be proven stopped (RoseCat 7450). Signal-interposed
    // (killpg a recorder, os.kill failing), so plain.
    const agent_host_owned_group_failclosed = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_owned_group_failclosed 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_owned_group_failclosed: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_owned_group_failclosed.step);
    // Every StopFailed names which stop proof failed as a fixed reason code (e567a51 Macs). Signal-interposed, plain.
    const agent_host_owned_group_reasons = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_owned_group_reasons 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_owned_group_reasons: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_owned_group_reasons.step);
    // A cleanup stop's own StopFailed reason is kept (RoseCat 7476). Signal-interposed, plain.
    const agent_host_owned_group_reasons_cleanup = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_owned_group_reasons_cleanup 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_owned_group_reasons_cleanup: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_owned_group_reasons_cleanup.step);
    // Darwin killpg EPERM on our own exited leader's group is a completed stop only on an independent census
    // (5b24bc1 Macs). Signal-interposed, plain.
    const agent_host_owned_group_zombie_eperm = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_owned_group_zombie_eperm 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_owned_group_zombie_eperm: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_owned_group_zombie_eperm.step);
    // Without os.waitid (macOS) the no-wait exit check polls the kqueue once. Fakes only, plain.
    const agent_host_owned_group_kqueue_poll = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_owned_group_kqueue_poll 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_owned_group_kqueue_poll: ResourceWarning' >&2; exit 1; fi",
    });
    agent_setup_ms5_step.dependOn(&agent_host_owned_group_kqueue_poll.step);
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
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c 'sh -c \"setsid -w \\\"\\$ZB_AGENT_HOST_PYTHON\\\" -X dev -m unittest -v test_setup_darwin_r1_v6; exit \\$?\"; exit $?' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_setup_darwin_r1_v6: ResourceWarning' >&2; exit 1; fi",
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
    // MS6.3 follow-up: contract-config without a usable fd-3 token writes one fixed error frame and exits 2 (no
    // traceback, nothing after the read). Pinned interpreter; its runs live in an our-uid PID namespace.
    // MS6.3: the CLI's per-uid temp dir lives in the scratchpad (CLAUDE_CODE_TMPDIR = TMPDIR; 24f8d49 both Macs).
    const agent_host_cli_env_tmpdir = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c '\"$0\" -X dev -m unittest -v test_cli_env_tmpdir; exit $?' \"$py\" 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_cli_env_tmpdir: ResourceWarning' >&2; exit 1; fi",
    });
    const agent_host_contract_no_token = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c '\"$0\" -X dev -m unittest -v test_contract_no_token; exit $?' \"$py\" 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_contract_no_token: ResourceWarning' >&2; exit 1; fi",
    });
    const agent_host_chat_redact = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c '\"$0\" -m unittest -v test_chat_redact; exit $?' \"$py\"",
    });
    // Chat drawer S7.0 (rev 16.20.30, 16.20.32): the Bridge names the running prompt; tool_result by
    // id, in section 3's grammar; every ending ends its calls; S7b (rev 16.20.34): its six read tools.
    // Each module runs alone.
    const agent_host_bridge = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_bridge && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_bridge_result && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_bridge_endings && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_bridge_envelope && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_tools && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_tools_navigate && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_tools_hover_scroll",
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
        "sh tests/e2e/run_step.sh agent-netd-spawn-e2e --summary '^[0-9]+ checks, [0-9]+ failed$' -- python3 tests/e2e/agent_netd_spawn_test.py --binary \"$1\"",
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
    // The agent-host step wrappers keep the test's exit status and contain what it starts (RoseCat 7647). It runs
    // every wrapped step's exact command with a stand-in python, so it runs inside its own private PID namespace.
    const gate_step_wrappers_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i HOME=\"$HOME\" PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c 'setsid -w python3 -X dev -m unittest -v test_gate_step_wrappers; exit $?' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_gate_step_wrappers: ResourceWarning' >&2; exit 1; fi",
    });
    // zigBrowser-44h: stop_browser returns only after the xsession guardian removed the private display. The test
    // makes and cleans X locks, so it runs ONLY in a private tmpfs /tmp (RoseCat 7681) and a private PID namespace.
    const xsession_teardown_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i HOME=\"$HOME\" PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 sh -c 'exec 7</tmp; exec unshare --map-current-user --keep-caps --mount --pid --fork --kill-child --mount-proc sh -c \"mount --rbind /tmp /mnt && mount -t tmpfs -o mode=1777 tmpfs /tmp && mkdir -m 1777 /tmp/.X11-unix || exit 99; case \\$PWD in /tmp/*) cd \\\"/mnt\\${PWD#/tmp}\\\" || exit 98;; esac; ZB_OUTER_TMP_FD=7 setsid -w python3 -X dev -m unittest -v test_xsession_teardown; rc=\\$?; left=\\$(find /tmp -mindepth 1 ! -path /tmp/.X11-unix; ls -A /tmp/.X11-unix); [ -z \\\"\\$left\\\" ] || { echo \\\"private /tmp not empty: \\$left\\\"; exit 1; }; exit \\$rc\"' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_xsession_teardown: ResourceWarning' >&2; exit 1; fi",
    });
    const xinput_errors_xvfb = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY python3 xsession.py --xvfb -- env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_xinput_errors",
    });
    // The X input harness survives its X server going away (agent-netd-spawn-e2e lost a loaded gate to Xlib's
    // exit(1) in XCloseDisplay after the guardian stopped Xvfb). Each child starts and stops its own private
    // Xvfb (no DISPLAY inherited); namespaced like its siblings.
    const xinput_vanished_server = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c 'setsid -w python3 -X dev -m unittest -v test_xinput_vanished_server; exit $?' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_xinput_vanished_server: ResourceWarning' >&2; exit 1; fi",
    });
    // tests/e2e/run_step.sh: a step's output labelled in one block, and why it ended (exit, signal, no summary).
    const run_step_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c 'setsid -w python3 -X dev -m unittest -v test_run_step; exit $?' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_run_step: ResourceWarning' >&2; exit 1; fi",
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
    // MS6.3's hard-gate case (the real CLI on the production fd-3 channel under the CLI profile; BlueBeaver 7514):
    // its chain, bearer, census, home and release rows against a fake staged host. Fakes only (no signal; the only
    // processes are /bin/sh fd-placement runs); namespaced like its siblings.
    const ms6_hard_gate_fd3_cli_case_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_fd3_cli_case_test' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms6_hard_gate_fd3_cli_case_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms6_hard_gate_fd3_cli_case_unit.step);
    // The fd3 case records only the census's fixed reason, "invalid" for anything else (RoseCat 7986/7995). Fakes only.
    const ms6_hard_gate_fd3_census_reason_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_fd3_census_reason_test' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms6_hard_gate_fd3_census_reason_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms6_hard_gate_fd3_census_reason_unit.step);
    // The fd3 case builds every home under the real path of its scratch (11b3ac4; RoseCat 7627). Namespaced.
    const ms6_hard_gate_fd3_cli_realpath_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_fd3_cli_realpath_test' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms6_hard_gate_fd3_cli_realpath_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms6_hard_gate_fd3_cli_realpath_unit.step);
    // The fd3 case leaves its scratch removable: every token-fifo dir it left is 0700 again (bcbc989, e2c20a7;
    // 24f8d49 left /tmp/zb-hardgate-run-* on both Macs). Our uid without capabilities (a 0300 dir is unlistable).
    const ms6_hard_gate_fd3_cli_cleanup_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c 'setsid -w python3 -X dev -m unittest -v ms6_hard_gate_fd3_cli_cleanup_test; exit $?' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms6_hard_gate_fd3_cli_cleanup_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms6_hard_gate_fd3_cli_cleanup_unit.step);
    // The fd3 case reads the helper's frames as the helper writes them: compact NDJSON, one parsed result frame
    // that succeeded (11eaceb on both Macs; BlueBeaver 7832, RoseCat 7835). Fakes only; our uid, PID namespace.
    const ms6_hard_gate_fd3_cli_frames_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c 'setsid -w python3 -X dev -m unittest -v ms6_hard_gate_fd3_cli_frames_test; exit $?' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms6_hard_gate_fd3_cli_frames_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms6_hard_gate_fd3_cli_frames_unit.step);
    // MS5.1b (5745264, 7369db8): every outbound link shape is skipped; no target byte in the whole home. Pinned agent-host python, our uid, PID namespace.
    const ms5_1b_skipped_link_bytes_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c '\"$0\" -X dev -m unittest -v test_ms5_1b_skipped_link_bytes; exit $?' \"$py\" 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_ms5_1b_skipped_link_bytes: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms5_1b_skipped_link_bytes_unit.step);
    // MS5.1b's hard-gate case against a fake staged prefix (7b9d499, a501481; RoseCat 7933). Pinned agent-host python, our uid, PID namespace.
    const ms5_1b_hard_gate_case_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c '\"$0\" -X dev -m unittest -v ms5_1b_hard_gate_case_test; exit $?' \"$py\" 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms5_1b_hard_gate_case_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms5_1b_hard_gate_case_unit.step);
    // MS5.1's S3a-corrections hard-gate case against a fake staged prefix (e019b90, f120854; RoseCat 7934). Pinned agent-host python, our uid, PID namespace.
    const ms5_1_hard_gate_case_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c '\"$0\" -X dev -m unittest -v ms5_1_hard_gate_case_test; exit $?' \"$py\" 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms5_1_hard_gate_case_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms5_1_hard_gate_case_unit.step);
    // The zb-hook-run Darwin hard-gate case against a fake staged prefix (2c1357b..7092544; RoseCat 7973). Pinned
    // agent-host python, our uid, its own network namespace (the case listens on the real bridge ports) + PID ns.
    const ms8_hook_sandbox_case_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --keep-caps --net --pid --fork --kill-child --mount-proc sh -c 'ip link set lo up || exit 97; \"$0\" -X dev -m unittest -v ms8_hook_sandbox_case_test; exit $?' \"$py\" 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms8_hook_sandbox_case_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms8_hook_sandbox_case_unit.step);
    // Its launch-environment row: the real staged zb-hook-run chain reaches /usr/bin/env, whose output must be exactly
    // the allowlist's names and values (RoseCat 7986). Same namespaces as its sibling (real bridge ports).
    const ms8_hook_launch_env_case_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --keep-caps --net --pid --fork --kill-child --mount-proc sh -c 'ip link set lo up || exit 97; \"$0\" -X dev -m unittest -v ms8_hook_launch_env_case_test; exit $?' \"$py\" 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms8_hook_launch_env_case_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms8_hook_launch_env_case_unit.step);
    // The R1 case names which owned-group stop proof failed, as a fixed code only (e567a51 Macs). Fakes only.
    const ms6_hard_gate_r1_reason_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_r1_reason_test' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms6_hard_gate_r1_reason_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms6_hard_gate_r1_reason_unit.step);
    // Every R1 row fails on a stop failure, naming its fixed reason (RoseCat 7476). Fakes only.
    const ms6_hard_gate_r1_reason_modes_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_r1_reason_modes_test' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'ms6_hard_gate_r1_reason_modes_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_census_step.dependOn(&ms6_hard_gate_r1_reason_modes_unit.step);
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
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" sh -c 'exec 9</proc/self/ns/pid; exec unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c \"\\\"\\$@\\\"; exit \\$?\" sh env ZB_OUTER_PIDNS_FD=9 \"$0\" -m unittest -v test_contract' \"$py\"",
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
    // bd 4pa.22 (plan R29-MS6 I1, SilverRidge 6fde992b): both backends conform to the SandboxBackend Protocol, with
    // state_dirs=None as the backend-default sentinel, the macOS refusals and the network= sentinel; fails closed
    // without the venv. The signature rows are a tripwire: MS6.8's launch.build_launch is the production proof.
    const agent_host_backend_conformance = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_backend_conformance",
    });
    b.step("test-agent-backend-conformance", "4pa.22: both sandbox backends conform to the SandboxBackend Protocol").dependOn(&agent_host_backend_conformance.step);
    // bd 4pa.21 (plan MS6.8 slice 1, SilverRidge a365949c): the one launch connector over the backend Protocol
    // (launch.build_launch): the frozen Linux argv, the shared lease, the relay from the spec, the inner helpers' proxy
    // from the spec port, and macOS spawning inside the lease. Fails closed without the venv and on a ResourceWarning.
    const agent_host_launch_connector = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -X dev -m unittest -v test_launch_connector 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_launch_connector: ResourceWarning' >&2; exit 1; fi",
    });
    b.step("test-agent-launch-connector", "4pa.21: the MS6.8 launch connector over the backend Protocol").dependOn(&agent_host_launch_connector.step);
    // bd 4pa.21 (plan MS6.8 slice 2a, SilverRidge d751d158/e39f6c90): the Zig launch builders compose with the real
    // Python consumer. A test-only bridge (src/agent_launch_bridge.zig) prints the REAL agent_helper/agent_login launch
    // argv; test_launch_bridge hands it to the real launch.main (Darwin lease/spawn, Linux exec). A preparatory seam:
    // no browser Darwin caller until 4pa.27/MS8. Fails closed without the venv and on a ResourceWarning. The bridge's
    // artifact path is resolved before the cd: Zig passes it relative to the build root (SilverRidge 382494c5).
    const agent_launch_bridge_exe = b.addExecutable(.{ .name = "zb-launch-bridge", .root_module = b.createModule(.{
        .root_source_file = b.path("src/agent_launch_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const agent_host_launch_bridge = b.addSystemCommand(&.{
        "sh",
        "-c",
        "bridge=$(realpath \"$1\") || exit 1; py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" ZB_LAUNCH_BRIDGE=\"$bridge\" \"$py\" -X dev -m unittest -v test_launch_bridge 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_launch_bridge: ResourceWarning' >&2; exit 1; fi",
        "zb-launch-bridge",
    });
    agent_host_launch_bridge.addArtifactArg(agent_launch_bridge_exe);
    b.step("test-agent-launch-bridge", "4pa.21: the Zig launch builders compose with the real Python launch consumer").dependOn(&agent_host_launch_bridge.step);
    // MS6 macOS Seatbelt backend — the profile generator's content rules, unit-tested on Linux (pure
    // Python; the kernel enforcement is the MS6.1-6.5 Mac gate). Pins the token-isolation belt measured on
    // both arches: explicit (deny process-info*) + curated sysctl-read, scratchpad-only writes, hook bridges-only.
    const agent_host_sandbox_macos = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_sandbox_macos",
    });
    // 4pa.66 (plan R29-MS6 D2, R30-MS6): the macOS seatbelt readiness is one fact. The production profile generator's
    // readiness source and rendered profiles are generated into `seatbelt_facts` and judged beside
    // agent_setup.seatbelt_ready (seatbelt_ready => CURATED, no bare allow, and only then the macOS gate runs), plus
    // the seatbelt_ready pin. Both are tripwires (Rev 31 L3, T8); the closing proof is the Mac kernel-denial rows.
    const seatbelt_facts_gen = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 \"$py\" agent/host/tests/seatbelt_readiness_facts.py \"$1\"",
        "sh",
    });
    const seatbelt_facts_zig = seatbelt_facts_gen.addOutputFileArg("seatbelt_facts.zig");
    seatbelt_facts_gen.addFileInput(b.path("agent/host/tests/seatbelt_readiness_facts.py"));
    seatbelt_facts_gen.addFileInput(b.path("agent/host/zb_agent_host/sandbox_macos.py"));
    seatbelt_facts_gen.addFileInput(b.path("agent/host/zb_agent_host/sandbox.py"));
    seatbelt_facts_gen.addFileInput(b.path("agent/host/zb_agent_host/relay.py"));
    const seatbelt_agent_setup_module = b.createModule(.{
        .root_source_file = b.path("src/agent_setup.zig"),
        .target = target,
        .optimize = optimize,
    });
    const seatbelt_invariant_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_seatbelt_readiness_invariant_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    seatbelt_invariant_module.addImport("agent_setup", seatbelt_agent_setup_module);
    seatbelt_invariant_module.addAnonymousImport("seatbelt_facts", .{ .root_source_file = seatbelt_facts_zig });
    const run_seatbelt_invariant_tests = b.addRunArtifact(b.addTest(.{ .root_module = seatbelt_invariant_module }));
    const seatbelt_pin_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_setup_seatbelt_ready_pin_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    seatbelt_pin_module.addImport("agent_setup", seatbelt_agent_setup_module);
    const run_seatbelt_pin_tests = b.addRunArtifact(b.addTest(.{ .root_module = seatbelt_pin_module }));
    const seatbelt_readiness_step = b.step("test-agent-seatbelt-readiness", "Run the macOS seatbelt readiness invariant and pin (4pa.66)");
    seatbelt_readiness_step.dependOn(&run_seatbelt_invariant_tests.step);
    seatbelt_readiness_step.dependOn(&run_seatbelt_pin_tests.step);
    // SilverRidge 1915e0d: drive the Zig derivation in both states. The real src/agent_setup.zig (and its xdg.zig) is
    // compiled beside a null and a non-null fixture seatbelt_gate.zig; production imports are unchanged.
    const seatbelt_derivation_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_seatbelt_derivation_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    inline for (.{
        .{ "agent_setup_unaccepted", "null" },
        .{ "agent_setup_accepted", "\"fixture-accepted-commit\"" },
    }) |fixture| {
        const tree = b.addWriteFiles();
        _ = tree.addCopyFile(b.path("src/agent_setup.zig"), "agent_setup.zig");
        _ = tree.addCopyFile(b.path("src/xdg.zig"), "xdg.zig");
        _ = tree.add("seatbelt_gate.zig", "pub const accepted_commit: ?[]const u8 = " ++ fixture[1] ++ ";\n");
        seatbelt_derivation_module.addImport(fixture[0], b.createModule(.{
            .root_source_file = tree.getDirectory().path(b, "agent_setup.zig"),
            .target = target,
            .optimize = optimize,
        }));
    }
    const run_seatbelt_derivation_tests = b.addRunArtifact(b.addTest(.{ .root_module = seatbelt_derivation_module }));
    seatbelt_readiness_step.dependOn(&run_seatbelt_derivation_tests.step);
    // The Seatbelt write root must be the scratchpad's own real path (11b3ac4: /tmp -> private/tmp denied every
    // write; RoseCat 7627). Plain: no process, no signal.
    const agent_host_sandbox_macos_scratch_real = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_sandbox_macos_scratch_real",
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
    // The sign-in CLI's TMPDIR and CLAUDE_CODE_TMPDIR are the scratchpad's tmp (4f326ee; RoseCat 0c476b8).
    const agent_host_login_cli_tmpdir = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c '\"$0\" -X dev -m unittest -v test_login_cli_tmpdir; exit $?' \"$py\" 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_login_cli_tmpdir: ResourceWarning' >&2; exit 1; fi",
    });
    // The sign-in reaches its temp dirs through a checked chain from / and rechecks them right before the
    // launch; nothing is repaired (cd992e9, aec8fc5, 6c249f4; RoseCat 7739-7774). Popen is a recorder.
    const agent_host_login_scratch_tmp = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c '\"$0\" -X dev -m unittest -v test_login_scratch_tmp; exit $?' \"$py\" 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'test_login_scratch_tmp: ResourceWarning' >&2; exit 1; fi",
    });
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
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" unshare --map-current-user --pid --fork --kill-child --mount-proc sh -c '/usr/bin/bwrap --unshare-net --die-with-parent --dev-bind / / --proc /proc -- \"$0\" -m unittest -v test_hook_net; exit $?' \"$py\"",
    });

    // Page dialogs (alert/confirm/prompt/beforeunload) in the primary window
    // and a popup: dialog.get / dialog.respond, page.navigate onBeforeUnload.
    const automation_dialogs_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_dialogs_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "automation-dialogs-e2e",
    });
    automation_dialogs_e2e.addArtifactArg(exe);

    // N23: popup window targeting through the socket (page.list, window_id,
    // page.close, then no_window for the closed popup).
    const automation_windows_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_windows_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
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
        "python3 tests/e2e/automation_input_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "automation-input-e2e",
    });
    automation_input_e2e.addArtifactArg(exe);

    // --profile-dir keeps cookies across restarts (real binary, local HTTP).
    const automation_profile_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_profile_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
        "automation-profile-e2e",
    });
    automation_profile_e2e.addArtifactArg(exe);

    // cookies.* against the real cookie store (local HTTP, restart on profile).
    const automation_cookies_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_cookies_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then echo \"$0: skipped, and a skip is a failure under the gate\" >&2; exit 1; fi; exit \"$rc\"",
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
    // bd zigBrowser-4pa.81: these 29 E2Es execute the native GTK/WebKit binary through Linux Xvfb/xsession
    // (some also inspect /proc or Linux WebKit processes). Do not schedule them for a foreign or non-Linux artifact;
    // when they are scheduled on native Linux, exit 77 is a gate failure rather than a passing skip.
    const native_linux_browser_e2e = b.graph.host.result.os.tag == .linux and
        target.result.os.tag == .linux and
        b.graph.host.result.cpu.arch == target.result.cpu.arch;
    const skip_is_failure_census = b.addSystemCommand(&.{
        "sh",
        "-c",
        "set -eu; py=$(command -v python3); t=$(mktemp -d \"${TMPDIR:-/tmp}/zb-skip-census-XXXXXX\"); trap 'case \"$t\" in */zb-skip-census-??????) rm -rf -- \"$t\";; esac' EXIT; mkdir -p \"$t/home\" \"$t/tmp\" \"$t/xdg-cache\" \"$t/xdg-data\"; env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 HOME=\"$t/home\" TMPDIR=\"$t/tmp\" XDG_CACHE_HOME=\"$t/xdg-cache\" XDG_DATA_HOME=\"$t/xdg-data\" \"$py\" -X dev -m unittest -v tests/e2e/skip_is_failure_census_test.py",
    });
    skip_is_failure_census.has_side_effects = true;
    for ([_][]const u8{
        "build.zig",
        "tests/e2e/skip_is_failure_census_test.py",
    }) |input| skip_is_failure_census.addFileInput(b.path(input));
    const skip_is_failure_census_step = b.step(
        "test-skip-is-failure-census",
        "Registered E2E wrappers fail on skip; nonportable browser E2Es are host-gated",
    );
    skip_is_failure_census_step.dependOn(&skip_is_failure_census.step);
    test_step.dependOn(skip_is_failure_census_step);
    // bd zigBrowser-4pa.82: every registered detect_runner E2E requests a private Xvfb on its real target argv,
    // and a strict request refuses rather than falling back to an inherited display or the conventional X1 socket.
    const registered_e2e_private_display = b.addSystemCommand(&.{
        "sh",
        "-c",
        "set -eu; t=$(mktemp -d \"${TMPDIR:-/tmp}/zb-private-display-XXXXXX\"); trap 'case \"$t\" in */zb-private-display-??????) rm -rf -- \"$t\";; esac' EXIT; mkdir -p \"$t/home\" \"$t/tmp\" \"$t/xdg-cache\" \"$t/xdg-data\"; env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=\"$t/home\" TMPDIR=\"$t/tmp\" XDG_CACHE_HOME=\"$t/xdg-cache\" XDG_DATA_HOME=\"$t/xdg-data\" DISPLAY=:59999 python3 -I -B tests/e2e/registered_e2e_private_display_test.py -v",
    });
    registered_e2e_private_display.has_side_effects = true;
    for ([_][]const u8{
        "build.zig",
        "tests/e2e/slice2_common.py",
        "tests/e2e/registered_e2e_private_display_test.py",
        "tests/e2e/automation_api_lifecycle_test.py",
        "tests/e2e/automation_core_test.py",
        "tests/e2e/automation_readiness_test.py",
        "tests/e2e/sdk_python_live_test.py",
        "tests/e2e/x_flows_test.py",
        "tests/e2e/x_native_test.py",
        "tests/e2e/social_flows_test.py",
        "tests/e2e/automation_expect_flow_test.py",
        "tests/e2e/automation_expect_x_flow_test.py",
        "tests/e2e/automation_recipient_guard_test.py",
        "tests/e2e/automation_recipient_owner_test.py",
        "tests/e2e/automation_thread_document_test.py",
        "tests/e2e/automation_scroll_test.py",
        "tests/e2e/automation_native_ports_test.py",
        "tests/e2e/automation_pacing_persist_test.py",
        "tests/e2e/automation_windows_test.py",
        "tests/e2e/automation_input_test.py",
        "tests/e2e/automation_profile_test.py",
        "tests/e2e/automation_cookies_test.py",
        "tests/e2e/ipc_roundtrip_test.py",
    }) |input| registered_e2e_private_display.addFileInput(b.path(input));
    const registered_e2e_private_display_step = b.step(
        "test-registered-e2e-private-display",
        "Registered detect_runner E2E steps use only a private Xvfb or refuse",
    );
    registered_e2e_private_display_step.dependOn(&registered_e2e_private_display.step);
    test_step.dependOn(registered_e2e_private_display_step);
    // bd zigBrowser-3ui.11: a failure after GTK start is reported, not a hang, and a hanging test is named.
    if (backend == .gtk_backend) {
        const gtk_test_env_selftest = b.addSystemCommand(&.{
            "python3",                                "tests/e2e/gtk_test_env_selftest.py",
            "--zig",                                  b.graph.zig_exe,
            "--cache-dir",                            b.cache_root.path orelse ".zig-cache",
            "--global-cache-dir",                     b.graph.global_cache_root.path orelse ".zig-cache",
        });
        gtk_test_env_selftest.addFileInput(b.path("tests/e2e/gtk_test_env_selftest.py"));
        gtk_test_env_selftest.addFileInput(b.path("tests/gtk_env_failure_probe_test.zig"));
        gtk_test_env_selftest.addFileInput(b.path("tests/gtk_hang_probe_test.zig"));
        gtk_test_env_selftest.addFileInput(b.path("build.zig"));
        const gtk_test_env_step = b.step("test-gtk-test-env", "3ui.11: GTK-in-process test steps fail cleanly and fast, never hang");
        gtk_test_env_step.dependOn(&gtk_test_env_selftest.step);
        test_step.dependOn(&gtk_test_env_selftest.step);
        // bd zigBrowser-3ui.12: a desktop-launched browser (DESKTOP_STARTUP_ID etc. inherited, no startup setenv)
        // does not hang on its first Zig environ scan after GTK start. The real browser on a private Xvfb, below a
        // proven PID namespace with no network; a missing requirement fails it (no skip to green). The unit test
        // proves the guard also primes main's init.io, which no product path scans today.
        const gtk_launch_env_e2e = b.addSystemCommand(&.{
            "sh",
            "-c",
            "python3 tests/e2e/gtk_launch_env_product_test.py --binary \"$1\"",
            "gtk-launch-env-e2e",
        });
        gtk_launch_env_e2e.addArtifactArg(exe);
        for ([_][]const u8{
            "tests/e2e/gtk_launch_env_product_test.py", "tests/e2e/agent_common.py",
            "tests/e2e/slice2_common.py",               "tests/e2e/xsession.py",
            "agent/host/tests/pidns_guard.py",
        }) |input| gtk_launch_env_e2e.addFileInput(b.path(input));
        const environ_guard_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("tests/environ_guard_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "environ_guard", .module = b.createModule(.{
                .root_source_file = b.path("src/environ_guard.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }) }},
        }) });
        const run_environ_guard_tests = b.addRunArtifact(environ_guard_tests);
        const gtk_launch_env_step = b.step("test-gtk-launch-env", "3ui.12: a desktop-launched browser does not hang on its first Zig environ scan after GTK start");
        gtk_launch_env_step.dependOn(&gtk_launch_env_e2e.step);
        gtk_launch_env_step.dependOn(&run_environ_guard_tests.step);
        test_step.dependOn(&gtk_launch_env_e2e.step);
        test_step.dependOn(&run_environ_guard_tests.step);
    }
    // WS5 (RoseCat 05f2549): register the agent_drawer.zig geometry property tests so deleting a portable
    // helper (incl. zb_drawer_anim_ms_from_env / animMsFromEnv) reds the gate. Host-run, link libc (atomic_file).
    const drawer_props_dep = b.createModule(.{
        .root_source_file = b.path("src/agent_drawer.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const drawer_props_module = b.createModule(.{
        .root_source_file = b.path("tests/windows/agent_drawer_props_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    drawer_props_module.addImport("agent_drawer", drawer_props_dep);
    const run_drawer_props_tests = b.addRunArtifact(b.addTest(.{ .root_module = drawer_props_module }));
    b.step("drawer-props-test", "WS5: agent_drawer.zig geometry property tests").dependOn(&run_drawer_props_tests.step);
    test_step.dependOn(&run_drawer_props_tests.step);
    // WS5 entry (1e5ff2d; RoseCat 1e5ff2d closure #1): register the native Win32 drawer harness so the red/green
    // chain is causal in the gate. Isolated mode (python3 -I) so no user site / PYTHON* env leaks in. Hostless:
    // the pure oracles run and exactly the 8 WinDrawerLive rows skip (ZB_WIN11_HOST unset) — zero host contact.
    const windows_drawer_live = b.addSystemCommand(&.{
        "sh",
        "-c",
        // Scrub the live connection vars (RoseCat 7862 #1) so an ordinary `zig build test` can NEVER contact the
        // VM, even if a dev has them exported — the 8 live rows then skip deterministically. Isolated (-I).
        "env -u ZB_WIN11_HOST -u ZB_WIN_EXE -u ZB_WIN11_PORT -u ZB_WIN11_USER -u ZB_WIN_KEY -u ZB_WIN_KNOWN_HOSTS PYTHONDONTWRITEBYTECODE=1 python3 -I tests/windows/win_drawer_test.py -v",
    });
    windows_drawer_live.addFileInput(b.path("tests/windows/win_drawer_test.py"));
    b.step("windows-drawer-live", "WS5: native Win32 drawer harness — offline oracles run, VM live rows skip").dependOn(&windows_drawer_live.step);
    test_step.dependOn(&windows_drawer_live.step);
    // WS5.1-5.7 behaviour oracle + model suites (drag/fold/DPI/bubble/multiwindow/isolation), likewise isolated
    // and hostless (its WinDrawerBehaviorsLive rows skip without ZB_WIN11_HOST).
    const windows_drawer_behaviors = b.addSystemCommand(&.{
        "sh",
        "-c",
        "env -u ZB_WIN11_HOST -u ZB_WIN_EXE -u ZB_WIN11_PORT -u ZB_WIN11_USER -u ZB_WIN_KEY -u ZB_WIN_KNOWN_HOSTS PYTHONDONTWRITEBYTECODE=1 python3 -I tests/windows/win_drawer_behaviors_test.py -v",
    });
    windows_drawer_behaviors.addFileInput(b.path("tests/windows/win_drawer_behaviors_test.py"));
    windows_drawer_behaviors.addFileInput(b.path("tests/windows/win_drawer_test.py"));
    b.step("windows-drawer-behaviors", "WS5.1-5.7: drawer behaviour oracle + model suites (VM live rows skip)").dependOn(&windows_drawer_behaviors.step);
    test_step.dependOn(&windows_drawer_behaviors.step);

    // WS5.5b-2 #2 (RoseCat 8150): the AST proof that the four WINDOWS-seam methods settle on the terminal `live`
    // row. Pure source analysis (no VM); reads win_drawer_behaviors_test.py.
    const windows_drawer_settle = b.addSystemCommand(&.{
        "sh",
        "-c",
        "PYTHONDONTWRITEBYTECODE=1 python3 -I tests/windows/ws5_5b2_settle_ast_test.py -v",
    });
    windows_drawer_settle.addFileInput(b.path("tests/windows/ws5_5b2_settle_ast_test.py"));
    windows_drawer_settle.addFileInput(b.path("tests/windows/win_drawer_behaviors_test.py"));
    b.step("windows-drawer-settle", "WS5.5b-2 #2: the four WINDOWS-seam methods settle on the terminal `live` row (AST proof)").dependOn(&windows_drawer_settle.step);
    test_step.dependOn(&windows_drawer_settle.step);

    // WS5.5b-2 #3 (RoseCat 28d6f8d): the causal recording-seam model of the drawer lifecycle + owned-Job teardown
    // (per-HWND registration, partial-control cleanup, retire-once WM_DESTROY, live-count transitions, and the
    // leader-exit + zero-owned-members no-kill gate). Driven; bound to the production _RUNNER Teardown bytes.
    const windows_drawer_lifecycle = b.addSystemCommand(&.{
        "sh",
        "-c",
        "PYTHONDONTWRITEBYTECODE=1 python3 -I tests/windows/ws5_5b2_lifecycle_seam_test.py -v",
    });
    windows_drawer_lifecycle.addFileInput(b.path("tests/windows/ws5_5b2_lifecycle_seam_test.py"));
    windows_drawer_lifecycle.addFileInput(b.path("tests/windows/win_drawer_test.py"));
    b.step("windows-drawer-lifecycle", "WS5.5b-2 #3: drawer lifecycle + teardown recording-seam model (driven; bound to the runner)").dependOn(&windows_drawer_lifecycle.step);
    test_step.dependOn(&windows_drawer_lifecycle.step);
    // R4 (RoseCat a8a8a37 item 5): the compile-only Mac harness's hostless safety selftest: a fake ssh, stubbed
    // Mac tools, every refusal and failure route; no Mac, network or signal.
    const mac_compile_only_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/mac_compile_only_selftest.sh" });
    mac_compile_only_selftest.addFileInput(b.path("tests/mac/mac_compile_only.sh"));
    mac_compile_only_selftest.addFileInput(b.path("tests/mac/mac_compile_only_selftest.sh"));
    mac_compile_only_selftest.addFileInput(b.path("tests/mac/mac_config.sh"));
    b.step("test-mac-compile-only", "Run the R4 compile-only Mac harness's hostless safety selftest").dependOn(&mac_compile_only_selftest.step);
    test_step.dependOn(&mac_compile_only_selftest.step);
    // bd zigBrowser-3ui.16: producers are allowed to finish and their status is checked before matching their
    // completed output. Executes only bounded extracted predicate blocks; never runs the destructive reaper gate.
    const mac_pipefail_producer_selftest = b.addSystemCommand(&.{ "python3", "tests/mac/mac_pipefail_producer_selftest.py" });
    for ([_][]const u8{
        "tests/mac/mac_pipefail_producer_selftest.py", "tests/mac/ms5_relocate_gate.sh",
        "tests/mac/ms5_stage_gate.sh",                 "tests/mac/ms5_deps_gate.sh",
        "tests/mac/mac_compile_only.sh",               "tests/mac/ms6_5_reaper_gate.sh",
    }) |input| mac_pipefail_producer_selftest.addFileInput(b.path(input));
    b.step("test-mac-pipefail-producers", "Mac script producer output is completed and its status checked before matching").dependOn(&mac_pipefail_producer_selftest.step);
    test_step.dependOn(&mac_pipefail_producer_selftest.step);
    // Hostless selftest of the destructive reaper gate's disable-by-default guard (plan R29-SAFETY, bd 4pa.70).
    const mac_reaper_gate_guard_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/ms6_5_reaper_gate_guard_selftest.sh" });
    mac_reaper_gate_guard_selftest.addFileInput(b.path("tests/mac/ms6_5_reaper_gate.sh"));
    mac_reaper_gate_guard_selftest.addFileInput(b.path("tests/mac/ms6_5_reaper_gate_guard_selftest.sh"));
    const mac_reaper_gate_guard_step = b.step("test-mac-reaper-gate-guard", "Run the hostless selftests of the destructive reaper gate's disable-by-default guard");
    mac_reaper_gate_guard_step.dependOn(&mac_reaper_gate_guard_selftest.step);
    test_step.dependOn(&mac_reaper_gate_guard_selftest.step);
    const mac_reaper_gate_shared_host_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/ms6_5_reaper_gate_shared_host_selftest.sh" });
    mac_reaper_gate_shared_host_selftest.addFileInput(b.path("tests/mac/ms6_5_reaper_gate.sh"));
    mac_reaper_gate_shared_host_selftest.addFileInput(b.path("tests/mac/ms6_5_reaper_gate_shared_host_selftest.sh"));
    mac_reaper_gate_guard_step.dependOn(&mac_reaper_gate_shared_host_selftest.step);
    test_step.dependOn(&mac_reaper_gate_shared_host_selftest.step);
    // Hostless selftest of the shared Mac build step: git archive <sha>, a fresh run dir, pinned host keys (bd 4pa.59, 4pa.77).
    const mac_build_script_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/build_on_mac_selftest.sh" });
    mac_build_script_selftest.addFileInput(b.path("tests/mac/build-on-mac.sh"));
    mac_build_script_selftest.addFileInput(b.path("tests/mac/known_hosts"));
    mac_build_script_selftest.addFileInput(b.path("tests/mac/mac_config.sh"));
    mac_build_script_selftest.addFileInput(b.path("tests/mac/build_on_mac_selftest.sh"));
    const mac_build_script_step = b.step("test-mac-build-script", "Run the hostless selftests of the shared Mac build step and its eight callers (exact commit, fresh run dir, pinned host keys)");
    mac_build_script_step.dependOn(&mac_build_script_selftest.step);
    mac_build_script_step.dependOn(&mac_pipefail_producer_selftest.step);
    test_step.dependOn(&mac_build_script_selftest.step);
    // Every in-scope two-host Mac gate requires the remote test's own exact PASS line at the intended leg call;
    // successful transport with missing, wrong-call, wrong-marker or one-architecture evidence is a failure (3ui.14).
    const mac_gate_empty_output_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/mac_gate_empty_output_selftest.sh" });
    mac_gate_empty_output_selftest.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/mac_gate_empty_output_selftest.sh", "tests/mac/mac_gate_output.sh",
        "tests/mac/mac_config.sh",                      "tests/mac/build-on-mac.sh",
        "tests/mac/ms2a_gate.sh",                      "tests/mac/ms2b_gate.sh",
        "tests/mac/ms2c_gate.sh",                      "tests/mac/ms3_gate.sh",
        "tests/mac/ms4_gate.sh",                       "tests/mac/ms5_gate.sh",
        "tests/mac/ms5_deps_gate.sh",                  "tests/mac/ms5_kill_group_gate.sh",
        "tests/mac/ms5_r1_env_gate.sh",                "tests/mac/ms5_relocate_gate.sh",
        "tests/mac/ms5_setup_e2e.sh",                  "tests/mac/ms5_setup_refusal_gate.sh",
        "tests/mac/ms5_spawn_gate.sh",                 "tests/mac/ms5_spawn_io_gate.sh",
        "tests/mac/ms5_token_fd_gate.sh",              "tests/mac/ms6_5_reaper_census_gate.sh",
        "tests/mac/ms6_gate.sh",                       "tests/mac/ms6_harness_mac_gate.sh",
        "tests/mac/ms6_netd_darwin_gate.sh",           "tests/mac/ms6_r1_kernel_gate.sh",
    }) |input| mac_gate_empty_output_selftest.addFileInput(b.path(input));
    b.step("test-mac-gate-empty-output", "Mac gates causally require their remote tests' exact PASS evidence").dependOn(&mac_gate_empty_output_selftest.step);
    mac_build_script_step.dependOn(&mac_gate_empty_output_selftest.step);
    test_step.dependOn(&mac_gate_empty_output_selftest.step);
    // Every caller of build-on-mac.sh works only in its fresh run dir (bd 4pa.59, 4pa.77; GREEN B).
    const mac_gate_callers_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/mac_gate_callers_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/mac_gate_callers_selftest.sh", "tests/mac/mac_gate_lib.sh",    "tests/mac/build-on-mac.sh",
        "tests/mac/known_hosts", "tests/mac/mac_config.sh",                  "tests/mac/gate.sh",            "tests/mac/ms1b_signed_gate.sh",
        "tests/mac/ms2a_gate.sh",                 "tests/mac/ms2b_gate.sh",       "tests/mac/ms2c_gate.sh",
        "tests/mac/ms3_gate.sh",                  "tests/mac/ms4_gate.sh",        "packaging/macos/build-dmg.sh",
        "tests/mac/ms_runtime_rows_gate.sh",      "tests/mac/mac_varfolders_audit.sh",
        "tests/mac/mac_crashreports_audit.sh",
    }) |input| mac_gate_callers_selftest.addFileInput(b.path(input));
    mac_build_script_step.dependOn(&mac_gate_callers_selftest.step);
    test_step.dependOn(&mac_gate_callers_selftest.step);
    // The owner's /var/folders rule (2026-10-23; SilverRidge 94ebe76b): the one shared audit helper that every Mac gate
    // launching the browser sources (the runtime rows gate, the MS1c .app gate), its per-user parent census (every
    // complete P/T/C delta is recorded and never fails a run, SilverRidge 0a7f52b1), and its helper mutants. Hostless: a
    // getconf stub and private temp roots. V7 and the mutants need a non-root user (root reads a mode-000 directory).
    const mac_varfolders_audit_step = b.step("test-mac-varfolders-audit", "The /var/folders audit helper: physical roots, every delta unfiltered, INCONCLUSIVE when incomplete, nothing deleted");
    for ([_][]const u8{
        "tests/e2e/mac_varfolders_audit_test.py",
        "tests/e2e/mac_varfolders_census_test.py",
        "tests/e2e/mac_varfolders_audit_mutant_selftest.py",
    }) |script| {
        const run = b.addSystemCommand(&.{ "python3", script });
        for ([_][]const u8{
            "tests/e2e/mac_varfolders_audit_test.py",
            "tests/e2e/mac_varfolders_census_test.py",
            "tests/e2e/mac_varfolders_audit_mutant_selftest.py",
            "tests/mac/mac_varfolders_audit.sh",
        }) |input| run.addFileInput(b.path(input));
        mac_varfolders_audit_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    const mac_varfolders_protected_paths = b.addSystemCommand(&.{ "python3", "tests/e2e/mac_varfolders_protected_paths_test.py" });
    mac_varfolders_protected_paths.has_side_effects = true;
    for ([_][]const u8{
        "tests/e2e/mac_varfolders_protected_paths_test.py",
        "tests/e2e/mac_varfolders_audit_test.py",
        "tests/mac/mac_varfolders_audit.sh",
    }) |input| mac_varfolders_protected_paths.addFileInput(b.path(input));
    mac_varfolders_audit_step.dependOn(&mac_varfolders_protected_paths.step);
    test_step.dependOn(&mac_varfolders_protected_paths.step);
    const mac_varfolders_digest_protected = b.addSystemCommand(&.{ "python3", "tests/e2e/mac_varfolders_digest_protected_test.py" });
    mac_varfolders_digest_protected.has_side_effects = true;
    for ([_][]const u8{
        "tests/e2e/mac_varfolders_digest_protected_test.py",
        "tests/e2e/mac_varfolders_audit_test.py",
        "tests/mac/mac_varfolders_audit.sh",
    }) |input| mac_varfolders_digest_protected.addFileInput(b.path(input));
    mac_varfolders_audit_step.dependOn(&mac_varfolders_digest_protected.step);
    test_step.dependOn(&mac_varfolders_digest_protected.step);
    const mac_varfolders_directory_protected = b.addSystemCommand(&.{ "python3", "tests/e2e/mac_varfolders_directory_protected_test.py" });
    mac_varfolders_directory_protected.has_side_effects = true;
    for ([_][]const u8{
        "tests/e2e/mac_varfolders_directory_protected_test.py",
        "tests/e2e/mac_varfolders_audit_test.py",
        "tests/mac/mac_varfolders_audit.sh",
    }) |input| mac_varfolders_directory_protected.addFileInput(b.path(input));
    mac_varfolders_audit_step.dependOn(&mac_varfolders_directory_protected.step);
    test_step.dependOn(&mac_varfolders_directory_protected.step);
    const mac_varfolders_path_codec = b.addSystemCommand(&.{ "python3", "-X", "dev", "tests/e2e/mac_varfolders_path_codec_test.py" });
    mac_varfolders_path_codec.has_side_effects = true;
    for ([_][]const u8{
        "tests/e2e/mac_varfolders_path_codec_test.py",
        "tests/e2e/mac_varfolders_audit_test.py",
        "tests/mac/mac_varfolders_audit.sh",
    }) |input| mac_varfolders_path_codec.addFileInput(b.path(input));
    mac_varfolders_audit_step.dependOn(&mac_varfolders_path_codec.step);
    test_step.dependOn(&mac_varfolders_path_codec.step);
    const mac_varfolders_marker_only = b.addSystemCommand(&.{
        "python3", "-X", "dev", "-W", "error", "-B", "tests/e2e/mac_varfolders_marker_only_test.py",
    });
    mac_varfolders_marker_only.has_side_effects = true;
    for ([_][]const u8{
        "tests/e2e/mac_varfolders_marker_only_test.py",
        "tests/e2e/mac_varfolders_audit_test.py",
        "tests/mac/mac_varfolders_audit.sh",
    }) |input| mac_varfolders_marker_only.addFileInput(b.path(input));
    mac_varfolders_audit_step.dependOn(&mac_varfolders_marker_only.step);
    test_step.dependOn(&mac_varfolders_marker_only.step);
    const mac_varfolders_lstat_first_protected = b.addSystemCommand(&.{
        "python3", "-X", "dev", "-W", "error", "-B",
        "tests/e2e/mac_varfolders_lstat_first_protected_test.py",
    });
    mac_varfolders_lstat_first_protected.has_side_effects = true;
    for ([_][]const u8{
        "tests/e2e/mac_varfolders_lstat_first_protected_test.py",
        "tests/e2e/mac_varfolders_audit_test.py",
        "tests/mac/mac_varfolders_audit.sh",
    }) |input| mac_varfolders_lstat_first_protected.addFileInput(b.path(input));
    mac_varfolders_audit_step.dependOn(&mac_varfolders_lstat_first_protected.step);
    test_step.dependOn(&mac_varfolders_lstat_first_protected.step);
    const mac_varfolders_parent_policy = b.addSystemCommand(&.{
        "python3", "-X", "dev", "-W", "error", "-B", "tests/e2e/mac_varfolders_parent_policy_test.py",
    });
    mac_varfolders_parent_policy.has_side_effects = true;
    for ([_][]const u8{
        "tests/e2e/mac_varfolders_parent_policy_test.py",
        "tests/e2e/mac_varfolders_audit_test.py",
        "tests/e2e/mac_varfolders_census_test.py",
        "tests/mac/mac_varfolders_audit.sh",
    }) |input| mac_varfolders_parent_policy.addFileInput(b.path(input));
    mac_varfolders_audit_step.dependOn(&mac_varfolders_parent_policy.step);
    test_step.dependOn(&mac_varfolders_parent_policy.step);
    // The crash-report rule (orchestrator 2026-10-23): the shared, read-only DiagnosticReports listing helper that the
    // runtime rows gate sources (a new, changed or removed report is INCONCLUSIVE), proven hostlessly with the same
    // inotify boundary. Non-root, as its unreadable-entry rows need.
    const mac_crashreports_audit = b.addSystemCommand(&.{ "python3", "tests/e2e/mac_crashreports_audit_test.py" });
    for ([_][]const u8{
        "tests/e2e/mac_crashreports_audit_test.py",
        "tests/e2e/mac_varfolders_audit_test.py",
        "tests/mac/mac_crashreports_audit.sh",
    }) |input| mac_crashreports_audit.addFileInput(b.path(input));
    b.step("test-mac-crashreports-audit", "The crash-report listing helper: read-only, every report change INCONCLUSIVE, fails closed").dependOn(&mac_crashreports_audit.step);
    test_step.dependOn(&mac_crashreports_audit.step);
    // The runtime rows gate's request controls (4pa.55): ZB_RUNTIME_ROWS selection before any contact, the 4pa.55 rows
    // as greens, the crash-report listing, the helper self-audit before any row, all driven hostlessly.
    const mac_rows_select_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/ms_runtime_rows_gate_select_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/ms_runtime_rows_gate_select_selftest.sh", "tests/mac/ms_runtime_rows_gate.sh",
        "tests/mac/mac_varfolders_audit.sh",                 "tests/mac/mac_crashreports_audit.sh",
        "tests/mac/mac_config.sh",                           "tests/mac/mac_gate_lib.sh",
        "tests/mac/build-on-mac.sh",                         "tests/mac/known_hosts",
    }) |input| mac_rows_select_selftest.addFileInput(b.path(input));
    mac_build_script_step.dependOn(&mac_rows_select_selftest.step);
    test_step.dependOn(&mac_rows_select_selftest.step);
    // The runtime rows gate's evidence and cleanup (SilverRidge 0632602f): each leg's deterministic evidence archive is
    // copied back and verified before any removal, and the shared mac_remove_run_dirs verifies every removal and fails
    // closed (REMOVED or RETAINED), driven on two fake Macs whose ssh runs each command as the remote shell does.
    const mac_rows_evidence_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/ms_runtime_rows_evidence_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/ms_runtime_rows_evidence_selftest.sh", "tests/mac/ms_runtime_rows_gate.sh",
        "tests/mac/mac_varfolders_audit.sh",              "tests/mac/mac_crashreports_audit.sh",
        "tests/mac/mac_config.sh",                        "tests/mac/mac_gate_lib.sh",
        "tests/mac/build-on-mac.sh",                      "tests/mac/known_hosts",
    }) |input| mac_rows_evidence_selftest.addFileInput(b.path(input));
    mac_build_script_step.dependOn(&mac_rows_evidence_selftest.step);
    test_step.dependOn(&mac_rows_evidence_selftest.step);
    // 3ui.14 (SilverRidge 917b7c7e, e5eb7d37): the runtime rows gate judges each Mac by its exact remote success lines
    // (every selected ROW record, the five self-audit statuses, the audit completions and EVIDENCE_ARMED, each exactly
    // once); an empty or altered leg output is refused on that host with one remote-success line, exit 1.
    const mac_rows_output_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/ms_runtime_rows_output_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/ms_runtime_rows_output_selftest.sh", "tests/mac/ms_runtime_rows_gate.sh",
        "tests/mac/mac_gate_output.sh",                 "tests/mac/mac_varfolders_audit.sh",
        "tests/mac/mac_crashreports_audit.sh",          "tests/mac/mac_config.sh",
        "tests/mac/mac_gate_lib.sh",                    "tests/mac/build-on-mac.sh",
        "tests/mac/known_hosts",
    }) |input| mac_rows_output_selftest.addFileInput(b.path(input));
    mac_build_script_step.dependOn(&mac_rows_output_selftest.step);
    test_step.dependOn(&mac_rows_output_selftest.step);
    // Item D (SilverRidge 0b4c44bd): the shim installs only ignored dispositions plus main-queue dispatch signal
    // sources, and the packaged exact-commit app's live signal row is driven through two executing fake Macs.
    // Both hostless oracles are side-effecting and always run inside a private user/PID/mount/network namespace.
    const mac_signal_delivery = b.addSystemCommand(&.{
        "unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc", "--net",
        "python3", "-X", "dev", "tests/e2e/mac_signal_delivery_test.py",
    });
    mac_signal_delivery.has_side_effects = true;
    for ([_][]const u8{
        "tests/e2e/mac_signal_delivery_test.py", "src/wkwebview_shim.m",
    }) |input| mac_signal_delivery.addFileInput(b.path(input));
    const mac_signal_runtime = b.addSystemCommand(&.{
        "unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc", "--net",
        "python3", "-X", "dev", "tests/e2e/mac_signal_runtime_test.py", "--selftest",
    });
    mac_signal_runtime.has_side_effects = true;
    for ([_][]const u8{
        "tests/e2e/mac_signal_runtime_test.py",      "tests/e2e/automation_core_test.py",
        "tests/e2e/mac_signal_delivery_test.py",     "src/wkwebview_shim.m",
        "tests/mac/ms_signal_runtime_gate_red.sh",   "tests/mac/ms_runtime_rows_gate.sh",
        "tests/mac/ms_runtime_rows_evidence_selftest.sh",
        "tests/mac/ms_runtime_rows_output_selftest.sh",
        "tests/mac/mac_varfolders_audit.sh",         "tests/mac/mac_crashreports_audit.sh",
        "tests/mac/mac_config.sh",                   "tests/mac/mac_gate_lib.sh",
        "tests/mac/mac_gate_output.sh",              "tests/mac/build-on-mac.sh",
        "tests/mac/known_hosts",                     "packaging/macos/build-dmg.sh",
        "packaging/macos/Info.plist",                "packaging/macos/entitlements.plist",
        "packaging/assets/zigBrowser.png",
    }) |input| mac_signal_runtime.addFileInput(b.path(input));
    // Consumed-run portability repairs: canonical nonzero varfolders COMPLETE counts and unpadded BSD wc sizes
    // must both stay bound to the runtime-row gate and its aggregate Mac/default entry points.
    const mac_runtime_selfaudit_complete = b.addSystemCommand(&.{
        "bash", "tests/mac/ms_runtime_rows_selfaudit_complete_red.sh",
    });
    mac_runtime_selfaudit_complete.has_side_effects = true;
    const mac_runtime_bsd_sizes = b.addSystemCommand(&.{
        "bash", "tests/mac/ms_runtime_rows_bsd_sizes_red.sh",
    });
    mac_runtime_bsd_sizes.has_side_effects = true;
    for ([_]*std.Build.Step.Run{ mac_runtime_selfaudit_complete, mac_runtime_bsd_sizes }) |run| {
        for ([_][]const u8{
            "tests/mac/ms_runtime_rows_selfaudit_complete_red.sh",
            "tests/mac/ms_runtime_rows_bsd_sizes_red.sh",
            "tests/mac/ms_signal_runtime_gate_red.sh",
            "tests/mac/ms_runtime_rows_gate.sh",
            "tests/e2e/mac_signal_runtime_test.py",
            "tests/e2e/automation_core_test.py",
            "tests/e2e/automation_fixture_server.py",
            "tests/e2e/slice2_common.py",
            "tests/e2e/mac_signal_delivery_test.py",
            "src/wkwebview_shim.m",
            "tests/mac/ms_runtime_rows_evidence_selftest.sh",
            "tests/mac/ms_runtime_rows_output_selftest.sh",
            "tests/mac/mac_varfolders_audit.sh",
            "tests/mac/mac_crashreports_audit.sh",
            "tests/mac/mac_config.sh",
            "tests/mac/mac_gate_lib.sh",
            "tests/mac/mac_gate_output.sh",
            "tests/mac/build-on-mac.sh",
            "tests/mac/known_hosts",
            "packaging/macos/build-dmg.sh",
            "packaging/macos/Info.plist",
            "packaging/macos/entitlements.plist",
            "packaging/assets/zigBrowser.png",
        }) |input| run.addFileInput(b.path(input));
    }
    const mac_signal_runtime_step = b.step("test-mac-signal-runtime", "Dispatch-source delivery and exact-package signal runtime gate (hostless)");
    mac_signal_runtime_step.dependOn(&mac_signal_delivery.step);
    mac_signal_runtime_step.dependOn(&mac_signal_runtime.step);
    mac_signal_runtime_step.dependOn(&mac_runtime_selfaudit_complete.step);
    mac_signal_runtime_step.dependOn(&mac_runtime_bsd_sizes.step);
    mac_build_script_step.dependOn(&mac_signal_runtime.step);
    mac_build_script_step.dependOn(&mac_runtime_selfaudit_complete.step);
    mac_build_script_step.dependOn(&mac_runtime_bsd_sizes.step);
    test_step.dependOn(&mac_signal_delivery.step);
    test_step.dependOn(&mac_signal_runtime.step);
    test_step.dependOn(&mac_runtime_selfaudit_complete.step);
    test_step.dependOn(&mac_runtime_bsd_sizes.step);
    // MS1.4: the two-host gate fails closed on no GUI session, wrong arch, a missing SDK and zero recorded assertions.
    const mac_gate_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/gate_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/gate_selftest.sh",      "tests/mac/gate.sh",                         "tests/mac/build-on-mac.sh",
        "tests/mac/mac_gate_lib.sh",       "tests/mac/known_hosts", "tests/mac/mac_config.sh",                     "tests/e2e/mac_resource_compat.py",
        "tests/e2e/mac_universal_test.py", "packaging/macos/universal_components.json",
    }) |input| mac_gate_selftest.addFileInput(b.path(input));
    b.step("test-mac-gate-selftest", "Run the hostless selftest of the MS1 two-host gate's fail-closed runner (MS1.4)").dependOn(&mac_gate_selftest.step);
    test_step.dependOn(&mac_gate_selftest.step);
    // The dmg script ships the shim in Contents/Frameworks and signs inside out, never --deep (bd 4pa.73).
    const mac_dmg_script_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/dmg_script_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/dmg_script_selftest.sh",   "packaging/macos/build-dmg.sh",    "tests/mac/build-on-mac.sh",
        "tests/mac/mac_gate_lib.sh",          "tests/mac/known_hosts", "tests/mac/mac_config.sh",           "packaging/macos/Info.plist",
        "packaging/macos/entitlements.plist", "packaging/assets/zigBrowser.png",
    }) |input| mac_dmg_script_selftest.addFileInput(b.path(input));
    const mac_dmg_script_step = b.step("test-mac-dmg-script", "Run the hostless selftests of the dmg script: a universal .app (both Macs, lipo), shim in Contents/Frameworks, inside-out signing (4pa.73)");
    mac_dmg_script_step.dependOn(&mac_dmg_script_selftest.step);
    test_step.dependOn(&mac_dmg_script_selftest.step);
    // Its .app is universal: built on both Macs, joined with lipo, every Mach-O fat (MS1c, bd 4pa.73; red 89fa9c2).
    const mac_dmg_universal_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/dmg_universal_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/dmg_universal_selftest.sh", "packaging/macos/build-dmg.sh",       "tests/mac/build-on-mac.sh",
        "tests/mac/mac_gate_lib.sh",           "tests/mac/known_hosts",              "tests/mac/mac_config.sh",
        "packaging/macos/Info.plist",          "packaging/macos/entitlements.plist", "packaging/assets/zigBrowser.png",
    }) |input| mac_dmg_universal_selftest.addFileInput(b.path(input));
    mac_dmg_script_step.dependOn(&mac_dmg_universal_selftest.step);
    test_step.dependOn(&mac_dmg_universal_selftest.step);
    // Its otool check holds however otool's output is timed: a later write after the shim line (SilverRidge 2e8e0190).
    const mac_dmg_otool_late_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/dmg_otool_late_write_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/dmg_otool_late_write_selftest.sh", "tests/mac/dmg_script_selftest.sh", "packaging/macos/build-dmg.sh",
        "tests/mac/build-on-mac.sh",                  "tests/mac/mac_gate_lib.sh",        "tests/mac/known_hosts",
        "tests/mac/mac_config.sh",                    "packaging/macos/Info.plist",       "packaging/macos/entitlements.plist",
        "packaging/assets/zigBrowser.png",
    }) |input| mac_dmg_otool_late_selftest.addFileInput(b.path(input));
    mac_dmg_script_step.dependOn(&mac_dmg_otool_late_selftest.step);
    test_step.dependOn(&mac_dmg_otool_late_selftest.step);
    // The MS1c gate runs the MS1b workload on the .app that dmg makes, on both Macs: one universal dmg, every Mach-O fat,
    // strict signature, mount/detach and leak contracts, the /var/folders, home and crash-report audits (4pa.73; reds
    // d22a985c, 0036b11b, 1164c172, 9a545a20); its workload stops every browser with one group SIGTERM.
    const mac_ms1c_gate_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/ms1c_app_gate_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/ms1c_app_gate_selftest.sh", "tests/mac/ms1c_app_gate.sh",         "tests/mac/ms1c_crash_audit.py",
        "tests/mac/ms1c_home_protected_paths.txt", "packaging/macos/build-dmg.sh",
        "tests/mac/build-on-mac.sh",           "tests/mac/mac_gate_lib.sh",          "tests/mac/mac_config.sh",
        "tests/mac/known_hosts",               "tests/mac/mac_varfolders_audit.sh",  "tests/mac/exec_arch_probe.py",
        "tests/e2e/m9_render_test.py",         "tests/e2e/m9_reply_channel_test.py", "tests/e2e/m9_load_fail_test.py",
        "tests/e2e/mac_term_teardown.py",      "tests/fixtures/app/index.html",      "packaging/macos/Info.plist",
        "packaging/macos/entitlements.plist",  "packaging/assets/zigBrowser.png",
    }) |input| mac_ms1c_gate_selftest.addFileInput(b.path(input));
    const mac_ms1c_otool_slices = b.addSystemCommand(&.{ "bash", "tests/mac/ms1c_otool_slices_red.sh" });
    mac_ms1c_otool_slices.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/ms1c_otool_slices_red.sh", "tests/mac/ms1c_app_gate_selftest.sh", "tests/mac/ms1c_app_gate.sh",
        "tests/mac/ms1c_home_protected_paths.txt",
        "packaging/macos/build-dmg.sh",       "tests/mac/build-on-mac.sh",           "tests/mac/mac_gate_lib.sh",
        "tests/mac/mac_config.sh",            "tests/mac/known_hosts",               "tests/mac/mac_varfolders_audit.sh",
        "tests/mac/exec_arch_probe.py",       "tests/e2e/m9_render_test.py",          "tests/e2e/m9_reply_channel_test.py",
        "tests/e2e/m9_load_fail_test.py",     "tests/e2e/mac_term_teardown.py",       "tests/fixtures/app/index.html",
        "packaging/macos/Info.plist",         "packaging/macos/entitlements.plist",  "packaging/assets/zigBrowser.png",
    }) |input| mac_ms1c_otool_slices.addFileInput(b.path(input));
    const mac_ms1c_home_protected = b.addSystemCommand(&.{ "bash", "tests/mac/ms1c_home_protected_red.sh" });
    mac_ms1c_home_protected.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/ms1c_home_protected_red.sh", "tests/mac/ms1c_home_protected_paths.txt", "tests/mac/ms1c_app_gate_selftest.sh",
        "tests/mac/ms1c_app_gate.sh",          "packaging/macos/build-dmg.sh",          "tests/mac/build-on-mac.sh",
        "tests/mac/mac_gate_lib.sh",           "tests/mac/mac_config.sh",                "tests/mac/known_hosts",
        "tests/mac/mac_varfolders_audit.sh",   "tests/mac/exec_arch_probe.py",           "tests/e2e/m9_render_test.py",
        "tests/e2e/m9_reply_channel_test.py",  "tests/e2e/m9_load_fail_test.py",         "tests/e2e/mac_term_teardown.py",
        "tests/fixtures/app/index.html",       "packaging/macos/Info.plist",             "packaging/macos/entitlements.plist",
        "packaging/assets/zigBrowser.png",
    }) |input| mac_ms1c_home_protected.addFileInput(b.path(input));
    const mac_ms1c_home_codec = b.addSystemCommand(&.{ "bash", "tests/mac/ms1c_home_codec_red.sh" });
    mac_ms1c_home_codec.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/ms1c_home_codec_red.sh", "tests/mac/ms1c_app_gate.sh", "tests/mac/ms1c_home_protected_paths.txt",
    }) |input| mac_ms1c_home_codec.addFileInput(b.path(input));
    const mac_ms1c_exec_arch_socket = b.addSystemCommand(&.{ "python3", "-B", "tests/mac/ms1c_exec_arch_socket_red.py" });
    mac_ms1c_exec_arch_socket.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/ms1c_exec_arch_socket_red.py", "tests/mac/exec_arch_probe.py",       "tests/e2e/mac_term_teardown.py",
        "tests/mac/ms1c_app_gate.sh",              "tests/mac/ms1c_app_gate_selftest.sh", "tests/mac/ms1c_home_protected_paths.txt",
        "packaging/macos/build-dmg.sh",             "tests/mac/build-on-mac.sh",          "tests/mac/mac_gate_lib.sh",
        "tests/mac/mac_config.sh",                  "tests/mac/known_hosts",              "tests/mac/mac_varfolders_audit.sh",
        "tests/e2e/m9_render_test.py",              "tests/e2e/m9_reply_channel_test.py", "tests/e2e/m9_load_fail_test.py",
        "tests/fixtures/app/index.html",            "packaging/macos/Info.plist",          "packaging/macos/entitlements.plist",
        "packaging/assets/zigBrowser.png",
    }) |input| mac_ms1c_exec_arch_socket.addFileInput(b.path(input));
    const mac_ms1c_term_eperm = b.addSystemCommand(&.{ "python3", "-B", "tests/mac/ms1c_term_eperm_red.py" });
    mac_ms1c_term_eperm.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/ms1c_term_eperm_red.py", "tests/e2e/mac_term_teardown.py",       "tests/mac/exec_arch_probe.py",
        "tests/mac/ms1c_app_gate.sh",        "tests/mac/ms1c_app_gate_selftest.sh", "tests/mac/ms1c_home_protected_paths.txt",
        "packaging/macos/build-dmg.sh",      "tests/mac/build-on-mac.sh",           "tests/mac/mac_gate_lib.sh",
        "tests/mac/mac_config.sh",           "tests/mac/known_hosts",               "tests/mac/mac_varfolders_audit.sh",
        "tests/e2e/m9_render_test.py",       "tests/e2e/m9_reply_channel_test.py",  "tests/e2e/m9_load_fail_test.py",
        "tests/fixtures/app/index.html",     "packaging/macos/Info.plist",           "packaging/macos/entitlements.plist",
        "packaging/assets/zigBrowser.png",
    }) |input| mac_ms1c_term_eperm.addFileInput(b.path(input));
    // MS1c item D: process identity/status comes from the real helper wait boundary, and retained macOS 15 two-value
    // report shapes are attributed only after every workload and the missing-dylib control have completed.
    const mac_ms1c_crash_attribution = b.addSystemCommand(&.{ "python3", "-B", "tests/mac/ms1c_crash_attribution_red.py" });
    mac_ms1c_crash_attribution.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/ms1c_crash_attribution_red.py", "tests/mac/ms1c_crash_audit.py",      "tests/mac/ms1c_app_gate.sh",
        "tests/mac/ms1c_app_gate_selftest.sh",      "tests/e2e/mac_term_teardown.py",    "tests/e2e/m9_render_test.py",
        "tests/e2e/m9_reply_channel_test.py",      "tests/e2e/m9_load_fail_test.py",    "tests/mac/exec_arch_probe.py",
        "tests/mac/ms1c_home_protected_paths.txt", "tests/mac/mac_varfolders_audit.sh", "packaging/macos/build-dmg.sh",
        "tests/mac/build-on-mac.sh",               "tests/mac/mac_gate_lib.sh",          "tests/mac/mac_config.sh",
        "tests/mac/known_hosts",                   "tests/fixtures/app/index.html",      "packaging/macos/Info.plist",
        "packaging/macos/entitlements.plist",      "packaging/assets/zigBrowser.png",
    }) |input| mac_ms1c_crash_attribution.addFileInput(b.path(input));
    // The final crash scan retains a bounded typed incident and its exact attribution reason. Missing-shim CONTROL
    // accepts only the exact legacy details item or macOS 15 reasons item with code 1; both gate legs copy each ordered
    // CONTROL/PRODUCT sequence into crash.delta, leg.log and crashreports.
    const mac_ms1c_incident_evidence = b.addSystemCommand(&.{
        "python3", "-X", "dev", "-W", "error", "-B", "tests/mac/ms1c_incident_evidence_red.py",
    });
    mac_ms1c_incident_evidence.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/ms1c_incident_evidence_red.py", "tests/mac/ms1c_crash_attribution_red.py",
        "tests/mac/ms1c_crash_audit.py",           "tests/mac/ms1c_app_gate.sh",
        "tests/mac/ms1c_app_gate_selftest.sh",     "tests/e2e/mac_term_teardown.py",
        "tests/e2e/m9_render_test.py",             "tests/e2e/m9_reply_channel_test.py",
        "tests/e2e/m9_load_fail_test.py",          "tests/mac/exec_arch_probe.py",
        "tests/mac/ms1c_home_protected_paths.txt", "tests/mac/mac_varfolders_audit.sh",
        "packaging/macos/build-dmg.sh",            "tests/mac/build-on-mac.sh",
        "tests/mac/mac_gate_lib.sh",               "tests/mac/mac_config.sh",
        "tests/mac/known_hosts",                   "tests/fixtures/app/index.html",
        "packaging/macos/Info.plist",              "packaging/macos/entitlements.plist",
        "packaging/assets/zigBrowser.png",
    }) |input| mac_ms1c_incident_evidence.addFileInput(b.path(input));
    // The one macOS 15 privacy-redacted control procPath is accepted only inside the complete pid/status/DYLD/diagnostic proof.
    const mac_ms1c_control_redacted = b.addSystemCommand(&.{
        "python3", "-X", "dev", "-W", "error", "-B", "tests/mac/ms1c_control_redacted_path_red.py",
    });
    mac_ms1c_control_redacted.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/ms1c_control_redacted_path_red.py", "tests/mac/ms1c_crash_audit.py",
    }) |input| mac_ms1c_control_redacted.addFileInput(b.path(input));
    // Real GUI launches use shell/launchctl envelopes; process evidence comes only from the common post-terminal
    // Popen boundary, with the actual pid and explicit requested browser executable.
    const mac_ms1c_process_ledger = b.addSystemCommand(&.{
        "python3", "-X", "dev", "-W", "error", "-B", "tests/mac/ms1c_process_ledger_red.py",
    });
    mac_ms1c_process_ledger.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/ms1c_process_ledger_red.py", "tests/e2e/mac_term_teardown.py",    "tests/e2e/m9_render_test.py",
        "tests/e2e/m9_reply_channel_test.py",  "tests/e2e/m9_load_fail_test.py",   "tests/e2e/slice2_common.py",
        "tests/mac/ms1c_app_gate.sh",           "tests/mac/ms1c_crash_audit.py",    "tests/mac/exec_arch_probe.py",
    }) |input| mac_ms1c_process_ledger.addFileInput(b.path(input));
    // MS1c consumed-run item 3: exact row/ordinal terminal statuses are joined to the one causal TERM marker written
    // after a successful identity-checked group signal, and the same lifecycle ledger is revalidated at final reports.
    const mac_ms1c_process_status = b.addSystemCommand(&.{
        "python3", "-X", "dev", "-W", "error", "-B", "tests/mac/ms1c_process_status_red.py",
    });
    mac_ms1c_process_status.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/ms1c_process_status_red.py", "tests/mac/ms1c_crash_audit.py",      "tests/mac/ms1c_app_gate.sh",
        "tests/mac/ms1c_app_gate_selftest.sh",  "tests/e2e/mac_term_teardown.py",    "tests/e2e/m9_render_test.py",
        "tests/e2e/m9_reply_channel_test.py",   "tests/e2e/m9_load_fail_test.py",    "tests/mac/exec_arch_probe.py",
        "tests/mac/ms1c_home_protected_paths.txt", "tests/mac/mac_varfolders_audit.sh", "packaging/macos/build-dmg.sh",
        "tests/mac/build-on-mac.sh",            "tests/mac/mac_gate_lib.sh",          "tests/mac/mac_config.sh",
        "tests/mac/known_hosts",                "tests/fixtures/app/index.html",      "packaging/macos/Info.plist",
        "packaging/macos/entitlements.plist",   "packaging/assets/zigBrowser.png",
    }) |input| mac_ms1c_process_status.addFileInput(b.path(input));
    // MS1c item C: the complete canonical HOME census records every delta, while only bundle-owned paths, its exact
    // Saved Application State subtree and non-control crash reports fail the owner-policy verdict.
    const mac_ms1c_home_owner_policy = b.addSystemCommand(&.{ "python3", "-B", "tests/mac/ms1c_home_owner_policy_red.py" });
    mac_ms1c_home_owner_policy.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/ms1c_home_owner_policy_red.py", "tests/mac/ms1c_app_gate.sh",         "tests/mac/ms1c_app_gate_selftest.sh",
        "tests/mac/ms1c_crash_audit.py",            "tests/mac/ms1c_home_protected_paths.txt", "tests/mac/mac_varfolders_audit.sh",
        "tests/mac/exec_arch_probe.py",             "tests/e2e/mac_term_teardown.py",          "tests/e2e/m9_render_test.py",
        "tests/e2e/m9_reply_channel_test.py",       "tests/e2e/m9_load_fail_test.py",          "packaging/macos/build-dmg.sh",
        "tests/mac/build-on-mac.sh",                "tests/mac/mac_gate_lib.sh",                "tests/mac/mac_config.sh",
        "tests/mac/known_hosts",                    "tests/fixtures/app/index.html",            "packaging/macos/Info.plist",
        "packaging/macos/entitlements.plist",       "packaging/assets/zigBrowser.png",
    }) |input| mac_ms1c_home_owner_policy.addFileInput(b.path(input));
    // Malformed UNVERIFIED records with only one pid/path field present are rejected once; the bounded outer timeout
    // makes any regression that leaves the indexed HOME consumer on the same record fail the registered step.
    const mac_ms1c_home_crash_pair = b.addSystemCommand(&.{
        "/usr/bin/unshare", "--user", "--map-root-user", "--net", "--pid", "--fork", "--mount-proc",
        "/usr/bin/timeout", "--signal=TERM", "12s",
        "python3", "-X", "dev", "-W", "error", "-B", "tests/mac/ms1c_home_crash_pair_red.py",
    });
    mac_ms1c_home_crash_pair.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/ms1c_home_crash_pair_red.py", "tests/mac/ms1c_app_gate.sh",
        "tests/mac/ms1c_home_protected_paths.txt",
    }) |input| mac_ms1c_home_crash_pair.addFileInput(b.path(input));
    // The retained-root cleanup oracle is destructive only inside its private PID/mount/user/network namespace. It
    // binds the sealed inventory to descriptor-relative no-follow deletion and rejects every preflight or identity drift.
    const mac_exact_root_cleanup = b.addSystemCommand(&.{
        "/usr/bin/unshare", "--user", "--map-root-user", "--net", "--pid", "--fork", "--mount-proc",
        "python3", "-X", "dev", "-W", "error", "-B", "tests/mac/mac_exact_root_cleanup_red.py",
    });
    mac_exact_root_cleanup.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/mac_exact_root_cleanup_red.py", "tests/mac/mac_exact_root_cleanup.py",
    }) |input| mac_exact_root_cleanup.addFileInput(b.path(input));
    // The production entry's second real process probe sees its own open root descriptor.  A PID-1 shell reaps every
    // helper while the exact stable cleanup PID alone is exempted; an outer timeout bounds every readiness handshake.
    const mac_exact_root_cleanup_process = b.addSystemCommand(&.{
        "/usr/bin/timeout", "--signal=TERM", "--kill-after=2s", "20s",
        "/usr/bin/unshare", "--user", "--map-root-user", "--net", "--pid", "--fork", "--mount-proc",
        "/bin/sh", "-c",
        "set -eu; env PYTHONDONTWRITEBYTECODE=1 python3 -I -X dev -W error -B tests/mac/mac_exact_root_cleanup_process_red.py & child=$!; wait \"$child\"",
    });
    mac_exact_root_cleanup_process.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/mac_exact_root_cleanup_process_red.py", "tests/mac/mac_exact_root_cleanup.py",
    }) |input| mac_exact_root_cleanup_process.addFileInput(b.path(input));
    const mac_exact_root_cleanup_process_step = b.step(
        "test-mac-exact-root-cleanup-process",
        "Run the real process-boundary oracle for exact retained-root cleanup",
    );
    mac_exact_root_cleanup_process_step.dependOn(&mac_exact_root_cleanup_process.step);
    const mac_ms1c_term_only = b.addSystemCommand(&.{ "python3", "-B", "tests/e2e/mac_m9_term_only_test.py" });
    for ([_][]const u8{
        "tests/e2e/mac_m9_term_only_test.py", "tests/e2e/m9_reply_channel_test.py", "tests/e2e/m9_render_test.py",
        "tests/e2e/slice2_common.py",         "tests/e2e/mac_term_teardown.py",     "tests/mac/exec_arch_probe.py",
    }) |input| mac_ms1c_term_only.addFileInput(b.path(input));
    const mac_ms1c_gate_step = b.step("test-mac-ms1c-gate", "Run the hostless selftests of the MS1c .app gate and its SIGTERM-only workload (4pa.73)");
    mac_ms1c_gate_step.dependOn(&mac_ms1c_gate_selftest.step);
    mac_ms1c_gate_step.dependOn(&mac_ms1c_otool_slices.step);
    mac_ms1c_gate_step.dependOn(&mac_ms1c_home_protected.step);
    mac_ms1c_gate_step.dependOn(&mac_ms1c_home_codec.step);
    mac_ms1c_gate_step.dependOn(&mac_ms1c_exec_arch_socket.step);
    mac_ms1c_gate_step.dependOn(&mac_ms1c_term_eperm.step);
    mac_ms1c_gate_step.dependOn(&mac_ms1c_crash_attribution.step);
    mac_ms1c_gate_step.dependOn(&mac_ms1c_incident_evidence.step);
    mac_ms1c_gate_step.dependOn(&mac_ms1c_control_redacted.step);
    mac_ms1c_gate_step.dependOn(&mac_ms1c_process_ledger.step);
    mac_ms1c_gate_step.dependOn(&mac_ms1c_process_status.step);
    mac_ms1c_gate_step.dependOn(&mac_ms1c_home_owner_policy.step);
    mac_ms1c_gate_step.dependOn(&mac_ms1c_home_crash_pair.step);
    mac_ms1c_gate_step.dependOn(&mac_exact_root_cleanup.step);
    mac_ms1c_gate_step.dependOn(mac_exact_root_cleanup_process_step);
    mac_ms1c_gate_step.dependOn(&mac_ms1c_term_only.step);
    test_step.dependOn(&mac_ms1c_gate_selftest.step);
    test_step.dependOn(&mac_ms1c_otool_slices.step);
    test_step.dependOn(&mac_ms1c_home_protected.step);
    test_step.dependOn(&mac_ms1c_home_codec.step);
    test_step.dependOn(&mac_ms1c_exec_arch_socket.step);
    test_step.dependOn(&mac_ms1c_term_eperm.step);
    test_step.dependOn(&mac_ms1c_crash_attribution.step);
    test_step.dependOn(&mac_ms1c_incident_evidence.step);
    test_step.dependOn(&mac_ms1c_control_redacted.step);
    test_step.dependOn(&mac_ms1c_process_ledger.step);
    test_step.dependOn(&mac_ms1c_process_status.step);
    test_step.dependOn(&mac_ms1c_home_owner_policy.step);
    test_step.dependOn(&mac_ms1c_home_crash_pair.step);
    test_step.dependOn(&mac_exact_root_cleanup.step);
    test_step.dependOn(mac_exact_root_cleanup_process_step);
    test_step.dependOn(&mac_ms1c_term_only.step);
    // The 4pa.80 bundle-layout spike stages the real .app, signs it inside out and reports strict verification per Mac,
    // with every Mac-side write-capable phase under one Seatbelt profile (SilverRidge de82cf2).
    const mac_bundle_layout_spike_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/bundle_layout_spike_containment_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/bundle_layout_spike_containment_selftest.sh", "tests/mac/bundle_layout_spike.sh",       "tests/mac/bundle_layout_spike_leg.sh",
        "tests/mac/build-on-mac.sh",                             "tests/mac/mac_gate_lib.sh",              "tests/mac/known_hosts", "tests/mac/mac_config.sh",
        "packaging/macos/Info.plist",                            "packaging/macos/relocate_agent_data.py", "tests/mac/bundle_layout_spike_audit.py",
    }) |input| mac_bundle_layout_spike_selftest.addFileInput(b.path(input));
    const mac_bundle_layout_spike_step = b.step("test-mac-bundle-layout-spike", "Run the hostless selftests of the 4pa.80 bundle-layout spike (prep and run)");
    mac_bundle_layout_spike_step.dependOn(&mac_bundle_layout_spike_selftest.step);
    test_step.dependOn(&mac_bundle_layout_spike_selftest.step);
    // Its fix-forward rows reuse that scaffolding: a not-signed verify, the snapshot sort under the profile, and a failed
    // ordinary remove that fails closed (SilverRidge 0d0656f4).
    const mac_bundle_layout_spike_ff_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/bundle_layout_spike_containment_ff_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/bundle_layout_spike_containment_ff_selftest.sh", "tests/mac/bundle_layout_spike_containment_selftest.sh",
        "tests/mac/bundle_layout_spike.sh",                         "tests/mac/bundle_layout_spike_leg.sh",
        "tests/mac/build-on-mac.sh",                                "tests/mac/mac_gate_lib.sh",
        "tests/mac/known_hosts", "tests/mac/mac_config.sh",                                    "packaging/macos/Info.plist",
        "packaging/macos/relocate_agent_data.py",                   "tests/mac/bundle_layout_spike_audit.py",
    }) |input| mac_bundle_layout_spike_ff_selftest.addFileInput(b.path(input));
    mac_bundle_layout_spike_step.dependOn(&mac_bundle_layout_spike_ff_selftest.step);
    test_step.dependOn(&mac_bundle_layout_spike_ff_selftest.step);
    // The 4pa.80 relocated-layout hypothesis (SilverRidge a365949c): non-code agent-host data moves to
    // Contents/Resources/agent-host behind relative links. The helper's own suite runs in a private user+mount
    // namespace (its device row bind-mounts /dev/null); the layout rows drive the real runner and leg with a codesign
    // that derives its verdict from the tree: candidate, gated control, SIGNFAIL evidence, one attempt.
    const mac_relocate_agent_data_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --user --map-root-user --mount --net sh -c 'python3 -X dev -m unittest -v mac_relocate_agent_data_test' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'mac_relocate_agent_data_test: ResourceWarning' >&2; exit 1; fi",
    });
    mac_bundle_layout_spike_step.dependOn(&mac_relocate_agent_data_unit.step);
    test_step.dependOn(&mac_relocate_agent_data_unit.step);
    const mac_bundle_layout_spike_layout_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/bundle_layout_spike_layout_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/bundle_layout_spike_layout_selftest.sh", "tests/mac/bundle_layout_spike_containment_selftest.sh",
        "tests/mac/bundle_layout_spike.sh",                 "tests/mac/bundle_layout_spike_leg.sh",
        "tests/mac/build-on-mac.sh",                        "tests/mac/mac_gate_lib.sh",
        "tests/mac/known_hosts", "tests/mac/mac_config.sh",                            "packaging/macos/Info.plist",
        "packaging/macos/relocate_agent_data.py",           "tests/mac/bundle_layout_spike_audit.py",
    }) |input| mac_bundle_layout_spike_layout_selftest.addFileInput(b.path(input));
    mac_bundle_layout_spike_step.dependOn(&mac_bundle_layout_spike_layout_selftest.step);
    test_step.dependOn(&mac_bundle_layout_spike_layout_selftest.step);
    // The 4pa.80 audit classifier (SilverRidge 7f3b4c70, 1950c0bb): the outside-the-root deltas, classified from the raw
    // snapshots by literal reviewed shapes (AUDIT-CLEAN/AMBIENT/UNKNOWN), against fixtures normalized from the released
    // Stage B evidence; then the runner boundary: physical roots, the canary proof, the classified SHA-256, the manifest.
    const mac_spike_audit_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/e2e && out=$(env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 unshare --user --map-current-user --net sh -c 'python3 -X dev -m unittest -v mac_spike_audit_test' 2>&1); rc=$?; printf '%s\\n' \"$out\"; [ $rc -eq 0 ] || exit $rc; if printf '%s\\n' \"$out\" | grep -q ResourceWarning; then echo 'mac_spike_audit_test: ResourceWarning' >&2; exit 1; fi",
    });
    for ([_][]const u8{
        "tests/e2e/mac_spike_audit_test.py",              "tests/mac/bundle_layout_spike_audit.py",
        "tests/mac/fixtures/4pa80_audit/provenance.txt",  "tests/mac/fixtures/4pa80_audit/intel.roots",
        "tests/mac/fixtures/4pa80_audit/intel.before",    "tests/mac/fixtures/4pa80_audit/intel.after",
        "tests/mac/fixtures/4pa80_audit/intel.synthetic", "tests/mac/fixtures/4pa80_audit/arm.roots",
        "tests/mac/fixtures/4pa80_audit/arm.before",      "tests/mac/fixtures/4pa80_audit/arm.after",
        "tests/mac/fixtures/4pa80_audit/arm.synthetic",
    }) |input| mac_spike_audit_unit.addFileInput(b.path(input));
    mac_bundle_layout_spike_step.dependOn(&mac_spike_audit_unit.step);
    test_step.dependOn(&mac_spike_audit_unit.step);
    const mac_bundle_layout_spike_audit_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/bundle_layout_spike_audit_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/bundle_layout_spike_audit_selftest.sh", "tests/mac/bundle_layout_spike_containment_selftest.sh",
        "tests/mac/bundle_layout_spike.sh",                "tests/mac/bundle_layout_spike_leg.sh",
        "tests/mac/build-on-mac.sh",                       "tests/mac/mac_gate_lib.sh",
        "tests/mac/known_hosts",                           "tests/mac/mac_config.sh",
        "packaging/macos/Info.plist",                      "packaging/macos/relocate_agent_data.py",
        "tests/mac/bundle_layout_spike_audit.py",
    }) |input| mac_bundle_layout_spike_audit_selftest.addFileInput(b.path(input));
    mac_bundle_layout_spike_step.dependOn(&mac_bundle_layout_spike_audit_selftest.step);
    test_step.dependOn(&mac_bundle_layout_spike_audit_selftest.step);
    // Its prep reads the commit's pins, installs the hash-locked verifier and keeps every cache in scratch (8f28c5d).
    const mac_bundle_layout_spike_prep_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/bundle_layout_spike_prep_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/bundle_layout_spike_prep_selftest.sh", "tests/mac/bundle_layout_spike.sh", "packaging/macos/build_site_packages.sh",
    }) |input| mac_bundle_layout_spike_prep_selftest.addFileInput(b.path(input));
    mac_bundle_layout_spike_step.dependOn(&mac_bundle_layout_spike_prep_selftest.step);
    test_step.dependOn(&mac_bundle_layout_spike_prep_selftest.step);
    // Its prep against the real /usr/bin/python3 and the real uv, offline, with an executing curl: the verifier venv,
    // the hash-locked install and the refused redirect (SilverRidge 6ea4636b).
    const mac_bundle_layout_spike_prep_fv_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/bundle_layout_spike_prep_fetch_venv_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/bundle_layout_spike_prep_fetch_venv_selftest.sh", "tests/mac/bundle_layout_spike_prep_selftest.sh",
        "tests/mac/bundle_layout_spike.sh",                          "packaging/macos/build_site_packages.sh",
    }) |input| mac_bundle_layout_spike_prep_fv_selftest.addFileInput(b.path(input));
    mac_bundle_layout_spike_step.dependOn(&mac_bundle_layout_spike_prep_fv_selftest.step);
    test_step.dependOn(&mac_bundle_layout_spike_prep_fv_selftest.step);
    // The Mac gates are real steps that run their scripts and pass a gate failure through, each with an approved-run
    // manifest (bd 4pa.62, R29-REG).
    const mac_gate_steps_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/gate_steps_selftest.sh" });
    mac_gate_steps_selftest.setEnvironmentVariable("ZIG", b.graph.zig_exe);
    for ([_][]const u8{
        "tests/mac/gate_steps_selftest.sh",
        "build.zig",
        "tests/mac/ms2b_gate.sh",
        "tests/mac/ms2c_gate.sh",
        "tests/mac/ms3_gate.sh",
        "tests/mac/build-on-mac.sh",
        "tests/mac/mac_gate_lib.sh",
        "tests/mac/known_hosts", "tests/mac/mac_config.sh",
        "tests/mac/approved_runs/ms2b-gate.json",
        "tests/mac/approved_runs/ms2c-gate.json",
        "tests/mac/approved_runs/ms3-gate.json",
        "tests/mac/ms2a_gate.sh",
        "tests/mac/approved_runs/ms2a-gate.json",
        "tests/mac/gate.sh",
        "tests/mac/ms1b_signed_gate.sh",
        "tests/mac/approved_runs/mac-gate.json",
        "tests/mac/approved_runs/ms1b-gate.json",
        "tests/e2e/mac_resource_compat.py",
        "packaging/macos/universal_components.json",
    }) |input| mac_gate_steps_selftest.addFileInput(b.path(input));
    b.step("test-mac-gate-steps", "Run the hostless selftest of the Mac gate steps (mac-gate, ms1b-gate, ms2a/2b/2c/3-gate) and their approved-run manifests").dependOn(&mac_gate_steps_selftest.step);
    test_step.dependOn(&mac_gate_steps_selftest.step);
    // Every remote zig invocation keeps both zig caches inside its run dir (bd 3ui.5).
    const mac_zig_cache_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/zig_cache_isolation_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/zig_cache_isolation_selftest.sh", "tests/mac/build-on-mac.sh",    "tests/mac/mac_gate_lib.sh",
        "tests/mac/known_hosts", "tests/mac/mac_config.sh",                     "tests/mac/gate.sh",            "tests/mac/ms1b_signed_gate.sh",
        "tests/mac/ms2a_gate.sh",                    "tests/mac/ms2b_gate.sh",       "tests/mac/ms2c_gate.sh",
        "tests/mac/ms3_gate.sh",                     "tests/mac/ms4_gate.sh",        "packaging/macos/build-dmg.sh",
    }) |input| mac_zig_cache_selftest.addFileInput(b.path(input));
    mac_build_script_step.dependOn(&mac_zig_cache_selftest.step);
    test_step.dependOn(&mac_zig_cache_selftest.step);
    // The harnesses that run zig on their own keep both zig caches in their run dir too (bd 3ui.5).
    const mac_zig_cache_direct_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/zig_cache_direct_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/zig_cache_direct_selftest.sh", "tests/mac/ms5_setup_refusal_gate.sh", "tests/mac/ms5_setup_e2e.sh",
        "tests/mac/ms5_gate.sh",                  "tests/mac/lib_group_cleanup.sh",      "tests/mac/ms7_appkit_gate.sh",
        "tests/mac/ms7_appkit_case.py",           "tests/mac/ms7_appkit_check.py",       "tests/mac/hard_gate/harness.py",
    }) |input| mac_zig_cache_direct_selftest.addFileInput(b.path(input));
    mac_build_script_step.dependOn(&mac_zig_cache_direct_selftest.step);
    test_step.dependOn(&mac_zig_cache_direct_selftest.step);
    // ms5_gate.sh reaches the Macs only with the pinned host keys, BatchMode and no display (SilverRidge 1915e0d).
    const mac_ms5_gate_hostkey_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/ms5_gate_hostkey_selftest.sh" });
    for ([_][]const u8{ "tests/mac/ms5_gate_hostkey_selftest.sh", "tests/mac/ms5_gate.sh", "tests/mac/known_hosts", "tests/mac/mac_config.sh", "tests/mac/mac_config.sh" }) |input|
        mac_ms5_gate_hostkey_selftest.addFileInput(b.path(input));
    mac_build_script_step.dependOn(&mac_ms5_gate_hostkey_selftest.step);
    test_step.dependOn(&mac_ms5_gate_hostkey_selftest.step);
    // ms5_setup_refusal_gate.sh and ms5_setup_e2e.sh use the same pinned transport (bd 3ui.5.1).
    const mac_ms5_setup_hostkey_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/ms5_setup_hostkey_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/ms5_setup_hostkey_selftest.sh", "tests/mac/ms5_setup_refusal_gate.sh", "tests/mac/ms5_setup_e2e.sh",
        "tests/mac/lib_group_cleanup.sh",          "tests/mac/known_hosts", "tests/mac/mac_config.sh",
    }) |input| mac_ms5_setup_hostkey_selftest.addFileInput(b.path(input));
    mac_build_script_step.dependOn(&mac_ms5_setup_hostkey_selftest.step);
    test_step.dependOn(&mac_ms5_setup_hostkey_selftest.step);
    // Every Mac gate with its own ssh/scp line pins tests/mac/known_hosts, BatchMode, no display or askpass (bd 4pa.77,
    // 3ui.9 parts 2+3). Its census reads the tests/mac and packaging/macos directories, so it runs every time.
    const mac_direct_hostkey_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/mac_direct_transport_hostkey_selftest.sh" });
    mac_direct_hostkey_selftest.has_side_effects = true;
    mac_build_script_step.dependOn(&mac_direct_hostkey_selftest.step);
    test_step.dependOn(&mac_direct_hostkey_selftest.step);
    // The three exact-commit launchers take known_hosts from their own export, never the outer checkout (SilverRidge
    // 7f58dd72): the outer file is changed after the commit and must not reach any ssh/scp call.
    const mac_exact_hostkey_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/mac_exact_commit_hostkey_selftest.sh" });
    mac_exact_hostkey_selftest.has_side_effects = true;
    mac_build_script_step.dependOn(&mac_exact_hostkey_selftest.step);
    test_step.dependOn(&mac_exact_hostkey_selftest.step);
    // No Mac script reaches a Mac unless ZB_MAC_HOST/ZB_MAC_KEY (and ZB_MAC_ARM_HOST) are named explicitly, through the one
    // helper tests/mac/mac_config.sh (bd 3ui.13, SilverRidge a473a027). Its census reads tests/, packaging/ and tools/, so
    // it runs every time; it drives every caller in a private network namespace.
    const mac_config_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/mac_config_selftest.sh" });
    mac_config_selftest.has_side_effects = true;
    mac_build_script_step.dependOn(&mac_config_selftest.step);
    test_step.dependOn(&mac_config_selftest.step);
    // Every Mac gate ships only the exact commit it prints, into a fresh per-run directory (bd 4pa.59). This drives
    // all gates with fake transports inside its own user+network namespace and must re-run as a filesystem census.
    const mac_gate_provenance_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/mac_gate_provenance_selftest.sh" });
    mac_gate_provenance_selftest.has_side_effects = true;
    mac_build_script_step.dependOn(&mac_gate_provenance_selftest.step);
    test_step.dependOn(&mac_gate_provenance_selftest.step);
    // The shared transport (build-on-mac.sh, mac_gate_lib.sh) passes no display or askpass to ssh/scp (bd 3ui.9).
    const mac_transport_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/mac_transport_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/mac_transport_selftest.sh", "tests/mac/build-on-mac.sh",    "tests/mac/mac_gate_lib.sh",
        "tests/mac/known_hosts", "tests/mac/mac_config.sh",               "packaging/macos/build-dmg.sh", "packaging/macos/Info.plist",
        "packaging/assets/zigBrowser.png",
    }) |input| mac_transport_selftest.addFileInput(b.path(input));
    mac_build_script_step.dependOn(&mac_transport_selftest.step);
    test_step.dependOn(&mac_transport_selftest.step);
    // Every Mac ssh/scp construction ignores user and system ssh configuration: exactly one separated `-F none`
    // appears before its first operand. The executing census covers all direct definitions, build-on-mac and the
    // shared helper; the destructive reaper definition is evaluated but its gate is never run (SilverRidge 353222dc).
    const mac_ssh_config_none_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/mac_ssh_config_none_selftest.sh" });
    mac_ssh_config_none_selftest.has_side_effects = true;
    for ([_][]const u8{
        "tests/mac/mac_ssh_config_none_selftest.sh",
        "tests/mac/mac_direct_transport_hostkey_selftest.sh",
        "tests/mac/ms5_gate_hostkey_selftest.sh",
        "tests/mac/ms5_setup_hostkey_selftest.sh",
        "tests/mac/mac_transport_selftest.sh",
        "tests/mac/build-on-mac.sh",
        "tests/mac/mac_compile_only.sh",
        "tests/mac/mac_gate_lib.sh",
        "tests/mac/ms5_deps_gate.sh",
        "tests/mac/ms5_gate.sh",
        "tests/mac/ms5_kill_group_gate.sh",
        "tests/mac/ms5_r1_env_gate.sh",
        "tests/mac/ms5_relocate_gate.sh",
        "tests/mac/ms5_setup_e2e.sh",
        "tests/mac/ms5_setup_refusal_gate.sh",
        "tests/mac/ms5_spawn_gate.sh",
        "tests/mac/ms5_spawn_io_gate.sh",
        "tests/mac/ms5_stage_gate.sh",
        "tests/mac/ms5_token_fd_gate.sh",
        "tests/mac/ms6_5_reaper_census_gate.sh",
        "tests/mac/ms6_5_reaper_gate.sh",
        "tests/mac/ms6_gate.sh",
        "tests/mac/ms6_hard_gate.sh",
        "tests/mac/ms6_harness_mac_gate.sh",
        "tests/mac/ms6_netd_darwin_gate.sh",
        "tests/mac/ms6_r1_kernel_gate.sh",
        "tests/mac/ms7_appkit_gate.sh",
    }) |input| mac_ssh_config_none_selftest.addFileInput(b.path(input));
    const mac_ssh_config_none_step = b.step("test-mac-ssh-config-none", "Run the full hostless Mac ssh/scp -F none argv census");
    mac_ssh_config_none_step.dependOn(&mac_ssh_config_none_selftest.step);
    mac_build_script_step.dependOn(&mac_ssh_config_none_selftest.step);
    test_step.dependOn(&mac_ssh_config_none_selftest.step);
    // A Mac run logged to a file keeps every evidence line: no `tee /dev/stderr` truncation (bd 3ui.10).
    const mac_log_integrity_selftest = b.addSystemCommand(&.{ "bash", "tests/mac/mac_log_integrity_selftest.sh" });
    for ([_][]const u8{
        "tests/mac/mac_log_integrity_selftest.sh", "tests/mac/gate.sh",               "tests/mac/ms2b_gate.sh",
        "tests/mac/build-on-mac.sh",               "tests/mac/mac_gate_lib.sh",       "tests/mac/known_hosts", "tests/mac/mac_config.sh",
        "tests/e2e/mac_resource_compat.py",        "tests/e2e/mac_universal_test.py", "packaging/macos/universal_components.json",
        "packaging/macos/entitlements.plist",      "packaging/macos/build-dmg.sh",    "packaging/macos/Info.plist",
        "packaging/assets/zigBrowser.png",
    }) |input| mac_log_integrity_selftest.addFileInput(b.path(input));
    mac_build_script_step.dependOn(&mac_log_integrity_selftest.step);
    test_step.dependOn(&mac_log_integrity_selftest.step);
    test_step.dependOn(&windows_gate_selftest.step);
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
    test_step.dependOn(&run_load_failure_policy_tests.step);
    test_step.dependOn(&load_exit_timer_binding.step);
    test_step.dependOn(&load_failure_policy_mutants.step);
    test_step.dependOn(&run_hook16_tests.step);
    test_step.dependOn(&native_close_binding.step);
    test_step.dependOn(&cookie_inflight_binding.step);
    test_step.dependOn(&dialog_window_id_binding.step);
    test_step.dependOn(&run_hook14_tests.step);
    test_step.dependOn(&run_app_profile_dir_tests.step);
    test_step.dependOn(&run_agent_drawer_tests.step);
    test_step.dependOn(&run_agent_drawer_breaks_tests.step);
    test_step.dependOn(&run_agent_drawer_appkit_tests.step);
    test_step.dependOn(&run_agent_drawer_card_press_tests.step);
    test_step.dependOn(&card_authority_mac.step); // 4pa.29: the card's one minter on both Darwin objects (green)
    if (target.result.os.tag == .linux) test_step.dependOn(&secrets_window_headers_obj.step); // 4pa.76 tripwire
    test_step.dependOn(&run_agent_drawer_appkit_text_tests.step);
    test_step.dependOn(&run_agent_net_tests.step);
    test_step.dependOn(&run_agent_net_manifest_tests.step);
    test_step.dependOn(&run_agent_host_posix_tests.step);
    test_step.dependOn(&run_agent_host_posix_spawn_tests.step);
    test_step.dependOn(&run_agent_run_reaper_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_reaper_engine_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_reaper_pin_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_reaper_fp_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_reaper_fc_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_reaper_uc_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_reaper_lg_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_reaper_lb_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_reaper_cc_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_reaper_ms_tests.step);
    test_step.dependOn(&run_ledger_parse_tests.step);
    test_step.dependOn(&run_ledger_grammar_tests.step);
    test_step.dependOn(&run_ledger_load_tests.step);
    test_step.dependOn(&run_ledger_publish_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_ledger_lock_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_ledger_lock_nofollow_tests.step);
    test_step.dependOn(&ledger_darwin_aarch64_obj.step); // cross-compile guard: ledger must build for Darwin
    test_step.dependOn(&ledger_darwin_x86_64_obj.step);
    test_step.dependOn(darwin_guard_selftest_step); // 4pa.63: the guard above really analyses every declaration
    if (target.result.os.tag == .linux) test_step.dependOn(&run_ledger_recovery_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_recovery_startup.step); // MS6.5.1 reaper_ready gate + startup core (unarmed)
    if (target.result.os.tag == .linux) test_step.dependOn(&run_recovery_store_pid.step); // 4pa.65/4pa.68: real store name, entry pid
    if (target.result.os.tag == .linux) test_step.dependOn(&run_ledger_recovery_txn_tests.step); // 4pa.71: the production transaction
    if (target.result.os.tag == .linux) test_step.dependOn(bypass_closed_step); // 4pa.71 / T20: no production bypass of reaper_ready
    test_step.dependOn(&run_ledger_unreadable_tests.step); // pure unit: unreadable liveness fails closed
    test_step.dependOn(&run_ledger_statio_tests.step); // pure unit: readStart outcome mapping fails closed
    test_step.dependOn(&run_ledger_start_kind_tests.step); // pure unit: v2 start_kind schema + canonical shape
    if (target.result.os.tag == .linux) test_step.dependOn(&run_ledger_samekind_tests.step); // same-kind-only liveness
    test_step.dependOn(&run_ledger_deadline_tests.step); // pure unit: acquisition honors one absolute deadline
    test_step.dependOn(&run_ledger_watchdog_tests.step); // pure unit: watchdog EINTR-bounded by the deadline
    if (target.result.os.tag == .linux) test_step.dependOn(&run_ledger_recovery_busy_tests.step);
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
    agent_secrets_step.dependOn(&run_shape_portable_tests.step);
    agent_secrets_step.dependOn(&run_agent_secrets_store_tests.step);
    // WS6 [L] (RoseCat): the shape-portable and TokenStore tests must also join the AGGREGATE gate, not only
    // the focused step, with the registered Windows compile proof.
    test_step.dependOn(&run_shape_portable_tests.step);
    test_step.dependOn(&run_agent_secrets_store_tests.step);
    test_step.dependOn(&secrets_win_cross.step);
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
    if (target.result.os.tag == .linux) test_step.dependOn(&ms6_hard_gate_fd3_cli_case_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms6_hard_gate_fd3_cli_realpath_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms6_hard_gate_fd3_cli_cleanup_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms6_hard_gate_fd3_cli_frames_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms5_1b_skipped_link_bytes_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms5_1b_hard_gate_case_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms5_1_hard_gate_case_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms8_hook_sandbox_case_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms6_hard_gate_r1_reason_unit.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms6_hard_gate_r1_reason_modes_unit.step);
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
    test_step.dependOn(&run_agent_approval_policy_tests.step);
    test_step.dependOn(&run_agent_approval_owner_tests.step);
    test_step.dependOn(&run_agent_approval_writer_tests.step);
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
    test_step.dependOn(automation_port_parse_step);
    test_step.dependOn(&run_x_tests.step);
    test_step.dependOn(&run_automation_x_tests.step);
    test_step.dependOn(&run_automation_server_tests.step);
    test_step.dependOn(automation_relative_socket_step);
    test_step.dependOn(&run_automation_expect_phase_a_tests.step);
    test_step.dependOn(&run_automation_expect_budget_tests.step);
    test_step.dependOn(&run_automation_expect_deadline_tests.step);
    test_step.dependOn(&run_automation_expect_flow_tests.step);
    test_step.dependOn(&run_automation_expect_flow_seam_tests.step);
    test_step.dependOn(&run_automation_expect_flow_prenav_tests.step);
    test_step.dependOn(&run_automation_expect_flow_server_tests.step);
    test_step.dependOn(&run_automation_expect_x_flow_server_tests.step);
    if (native_linux_browser_e2e) test_step.dependOn(&automation_expect_flow_e2e.step);
    test_step.dependOn(&run_automation_expect_x_flow_tests.step);
    if (native_linux_browser_e2e) test_step.dependOn(&automation_expect_x_flow_e2e.step);
    test_step.dependOn(&run_automation_recipient_guard_tests.step);
    if (native_linux_browser_e2e) test_step.dependOn(&automation_recipient_guard_e2e.step);
    test_step.dependOn(&run_automation_recipient_owner_tests.step);
    if (native_linux_browser_e2e) test_step.dependOn(&automation_recipient_owner_e2e.step);
    test_step.dependOn(&run_automation_thread_document_tests.step);
    if (native_linux_browser_e2e) test_step.dependOn(&automation_thread_document_e2e.step);
    test_step.dependOn(&run_owner_only_tests.step);
    test_step.dependOn(&run_agent_setup_ms5_tests.step);
    test_step.dependOn(&run_agent_setup_ms5_python_tests.step);
    test_step.dependOn(&run_agent_setup_ms5_devtree_tests.step);
    test_step.dependOn(&run_agent_setup_ms5_wiring_tests.step);
    test_step.dependOn(&mac_group_cleanup.step);
    test_step.dependOn(&run_transport_ws20_tests.step);
    for (s7a_runs) |run| test_step.dependOn(run);
    if (native_linux_browser_e2e) test_step.dependOn(&automation_api_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&automation_core_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&automation_readiness_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&sdk_python_live_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&x_flows_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&x_native_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&social_flows_e2e.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms4_4_login_gate_e2e.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&ms4_4_login_gate_cleanup_unit.step);
    if (native_linux_browser_e2e) test_step.dependOn(&automation_input_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&automation_windows_e2e.step);
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
    if (native_linux_browser_e2e) test_step.dependOn(&automation_scroll_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&automation_native_ports_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&automation_pacing_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&automation_profile_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&automation_cookies_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&http2_goaway_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&harness_group_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&web_process_crash_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&render_config_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&slow_load_watchdog_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&media_source_e2e.step);
    test_step.dependOn(&agent_drawer_icon_e2e.step);
    test_step.dependOn(&agent_drawer_e2e.step);
    test_step.dependOn(&agent_drawer_copy_e2e.step);
    test_step.dependOn(&agent_chat_e2e.step);
    test_step.dependOn(&agent_tools_e2e.step);
    test_step.dependOn(&agent_navigate_approval_e2e.step);
    test_step.dependOn(&agent_hover_scroll_e2e.step);
    test_step.dependOn(&agent_navigate_stale_e2e.step);
    test_step.dependOn(&agent_navigate_prompt_e2e.step);
    test_step.dependOn(&agent_navigate_selector_e2e.step);
    test_step.dependOn(&agent_navigate_selector_refused_e2e.step);
    test_step.dependOn(&real_screen_env_unit.step);
    test_step.dependOn(&agent_socket_separation_e2e.step);
    test_step.dependOn(&agent_tools_acceptance_e2e.step);
    test_step.dependOn(&agent_tools_acceptance2_e2e.step);
    test_step.dependOn(&agent_tool_deadline_e2e.step);
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
    if (native_linux_browser_e2e) test_step.dependOn(&ipc_roundtrip_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&page_health_e2e.step);
    if (native_linux_browser_e2e) test_step.dependOn(&page_recover_e2e.step);
    test_step.dependOn(&agent_host_unit.step);
    test_step.dependOn(&agent_host_launcher_contract.step); // WS7.3 [L] portable launcher contract
    test_step.dependOn(&agent_host_wincontain.step);
    test_step.dependOn(&agent_host_parent_watch.step);
    test_step.dependOn(&agent_host_setup_darwin.step);
    test_step.dependOn(&agent_host_route_probe_listen_fd.step);
    test_step.dependOn(&agent_host_route_probe_darwin_listen.step);
    test_step.dependOn(&agent_host_proc_darwin.step);
    test_step.dependOn(&agent_host_route_probe_darwin_env.step);
    test_step.dependOn(&agent_host_setup_darwin_r1.step);
    test_step.dependOn(&agent_host_setup_darwin_tmpdir.step);
    test_step.dependOn(&agent_host_scratch_cleanup.step);
    test_step.dependOn(&agent_host_scratch_cleanup_fd.step);
    test_step.dependOn(&agent_host_owned_group.step);
    test_step.dependOn(&agent_host_setup_sandbox_lifetime.step);
    test_step.dependOn(&agent_host_pidns_guard.step);
    test_step.dependOn(&agent_host_owned_group_failclosed.step);
    test_step.dependOn(&agent_host_owned_group_reasons.step);
    test_step.dependOn(&agent_host_owned_group_reasons_cleanup.step);
    test_step.dependOn(&agent_host_owned_group_zombie_eperm.step);
    test_step.dependOn(&agent_host_owned_group_kqueue_poll.step);
    test_step.dependOn(&agent_host_route_probe_census.step);
    test_step.dependOn(&agent_host_setup_census.step);
    test_step.dependOn(&agent_host_setup_darwin_r1_v6.step);
    test_step.dependOn(&agent_host_launch.step);
    test_step.dependOn(&agent_host_contract.step);
    test_step.dependOn(&agent_host_backend_contract.step);
    test_step.dependOn(&agent_host_backend_conformance.step);
    test_step.dependOn(&agent_host_launch_connector.step);
    test_step.dependOn(&agent_host_launch_bridge.step);
    test_step.dependOn(&agent_host_sandbox_macos.step);
    test_step.dependOn(pidns_launcher_status_step);
    test_step.dependOn(seatbelt_readiness_step);
    test_step.dependOn(&agent_host_sandbox_macos_scratch_real.step);
    test_step.dependOn(&agent_host_provision_unit.step);
    test_step.dependOn(&agent_host_chat.step);
    test_step.dependOn(&agent_host_chat_errors.step);
    test_step.dependOn(&agent_host_chat_flood.step);
    test_step.dependOn(&agent_host_chat_cap.step);
    test_step.dependOn(&agent_host_chat_prompt_id.step);
    test_step.dependOn(&agent_host_chat_fit.step);
    test_step.dependOn(&agent_host_redact.step);
    test_step.dependOn(&agent_host_chat_redact.step);
    test_step.dependOn(&agent_host_contract_no_token.step);
    test_step.dependOn(&agent_host_cli_env_tmpdir.step);
    test_step.dependOn(&agent_host_bridge.step);
    test_step.dependOn(&agent_host_netd.step);
    test_step.dependOn(&agent_host_netd_darwin.step);
    test_step.dependOn(&agent_host_netd_darwin_v6.step);
    test_step.dependOn(&agent_host_relay.step);
    test_step.dependOn(&agent_host_netd_manifest.step);
    test_step.dependOn(&agent_host_netd_login.step);
    test_step.dependOn(&agent_host_netd_census.step);
    test_step.dependOn(&agent_host_login_network.step);
    test_step.dependOn(&agent_host_login_cli_tmpdir.step);
    test_step.dependOn(&agent_host_login_scratch_tmp.step);
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
    test_step.dependOn(&xsession_teardown_unit.step);
    test_step.dependOn(&xinput_vanished_server.step);
    test_step.dependOn(&run_step_unit.step);
    test_step.dependOn(&gate_step_wrappers_unit.step);
    if (native_linux_browser_e2e) test_step.dependOn(&automation_dialogs_e2e.step);
    test_step.dependOn(&ipc_windows_compile.step);
    test_step.dependOn(&cross_check.step);
    test_step.dependOn(&cross_drawer_win.step);
    for (cross_tools_mac_runs) |run| test_step.dependOn(run); // MS8.0: the approval cards' minters in both macOS builds
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
    const unguarded = [_][]const u8{ "install", "uninstall", "agent-runtime", "mac-gate", "ms1b-gate", "ms2a-gate", "ms2b-gate", "ms2c-gate", "ms3-gate", "ws3-shim-test-win", "owner-only-test-win" };
    next: for (b.top_level_steps.keys(), b.top_level_steps.values()) |name, top| {
        for (unguarded) |skip| if (std.mem.eql(u8, name, skip)) continue :next;
        for (top.step.dependencies.items) |dep| {
            // Aggregate test may depend on another top-level step that already received this guard.
            if (dep == &guard.step) continue;
            dep.dependOn(&guard.step);
        }
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

/// bd zigBrowser-3ui.11: gdk removes DESKTOP_STARTUP_ID, GIO_LAUNCHED_DESKTOP_FILE(_PID) and XDG_ACTIVATION_TOKEN
/// at startup when they are inherited (any shell launched from a desktop has them). unsetenv shifts libc's environ
/// array in place, so Zig 0.16's startup copy of it gains a null entry; the test runner's first stderr lock then
/// panics in Environ.scan and the panic handler deadlocks on the same mutex, so a failing test hangs the step.
const gtk_inherited_env = [_][]const u8{ "DESKTOP_STARTUP_ID", "GIO_LAUNCHED_DESKTOP_FILE", "GIO_LAUNCHED_DESKTOP_FILE_PID", "XDG_ACTIVATION_TOKEN" };
/// The whole test binary's time bound. The root.zig unit tests take about 20 s on this machine and the gate runs them
/// beside many other steps (-j4, VMs alongside), so 600 s is far above a slow normal run, and still ends a hang.
const gtk_test_timeout_s = "600";

/// A test binary that runs GTK in-process. Only a native Linux (GTK) binary changes: it runs without the variables gdk
/// would unset (so a failure is reported) and under `timeout` (Zig 0.16 has no per-step test timeout, only
/// `zig build --test-timeout`), so a hang ends as a failure named after the running test; the binary still speaks the
/// build runner's test protocol. Every other binary (macOS, Windows, a foreign Linux arch, which skip_foreign_checks
/// must still skip) gets the exact plain `b.addRunArtifact`: the same command and the same environment as before.
/// SilverRidge 99a44f3: the environment removals and the timeout share this one Linux/GTK boundary.
fn runInProcessGtkTests(b: *std.Build, tests: *std.Build.Step.Compile, timeout_s: []const u8) *std.Build.Step.Run {
    const host = b.graph.host.result;
    const built = tests.rootModuleTarget();
    const native_linux = host.os.tag == .linux and built.os.tag == .linux and built.cpu.arch == host.cpu.arch;
    if (!native_linux) return b.addRunArtifact(tests);
    tests.setExecCmd(&.{ "timeout", "-k", "10", timeout_s, null });
    const run = b.addRunArtifact(tests);
    for (gtk_inherited_env) |name| run.removeEnvironmentVariable(name);
    return run;
}

/// 3ui.11 scope row: what the configured run step really holds, read from the Run step itself. `wrapped`: its argv
/// starts with `timeout`; `env`: unchanged (no environment of its own, the plain run) or its own copy, and how many
/// of gtk_inherited_env that copy lacks.
fn gtkTestScopeLine(b: *std.Build, run: *std.Build.Step.Run, built: std.Target) []const u8 {
    const wrapped = switch (run.argv.items[0]) {
        .bytes => |text| std.mem.eql(u8, text, "timeout"),
        else => false,
    };
    var stripped: usize = 0;
    const env: []const u8 = if (run.environ_map) |map| blk: {
        for (gtk_inherited_env) |name| {
            if (map.get(name) == null) stripped += 1;
        }
        break :blk "own";
    } else "unchanged";
    return b.fmt("GTK-TEST-SCOPE\tos={s}\tarch={s}\twrapped={d}\tenv={s}\tstripped={d}", .{
        @tagName(built.os.tag), @tagName(built.cpu.arch), @intFromBool(wrapped), env, stripped,
    });
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
/// MS7.0: the portable drawer logic a native (AppKit) drawer calls; the macOS objects must define each one.
const drawer_portable_exports = [_][]const u8{
    "zb_drawer_classify",          "zb_drawer_place",           "zb_drawer_clamp",
    "zb_drawer_panel_rect",        "zb_drawer_ratios_of",       "zb_drawer_key_move",
    "zb_drawer_remember",          "zb_drawer_start_ratios",    "zb_drawer_lerp",
    "zb_drawer_ease",              "zb_drawer_anim_ms",         "zb_drawer_anim_ms_from_env",
    "zb_drawer_break_runs",        "zb_drawer_row_text_len",    "zb_drawer_original_offset",
    "zb_drawer_reply_text_max",    "zb_drawer_reply_content_max", "zb_drawer_label_text_max",
    "zb_drawer_inside_icon",       "zb_drawer_page_rect",       "zb_drawer_appkit_frame",
    "zb_drawer_appkit_shown",      "zb_drawer_appkit_original_offset", "zb_drawer_bubble_layout_contiguous",
};

/// bd zigBrowser-4pa.63: a Darwin cross-compile guard, `guarded` (its target set) built as an object rooted at
/// src/darwin_guard_root.zig, which analyses every public non-generic declaration of `guarded` (Zig analyses lazily,
/// so `guarded` as its own root would analyse only what it exports). Every Darwin guard and its selftest
/// (`test-darwin-guard-selftest`) build through this one helper.
fn darwinGuardObject(b: *std.Build, name: []const u8, guarded: *std.Build.Module) *std.Build.Step.Compile {
    const root = b.createModule(.{ .root_source_file = b.path("src/darwin_guard_root.zig"), .target = guarded.resolved_target, .optimize = guarded.optimize });
    root.addImport("guarded", guarded);
    return b.addObject(.{ .name = name, .root_module = root });
}

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
    // The shim calls back into zig-exported symbols (zb_ipc_dispatch in src/ipc.zig,
    // zb_policy_decide in src/nav_policy.zig, and since 4pa.55 zb_load_failure_action and
    // zb_load_exit_timer_armed in src/load_failure_policy.zig). As a separate dylib it resolves them at LOAD from the
    // main executable via flat-namespace dynamic lookup; the exe exports them (rdynamic, set
    // macOS-only at the exe below). This is the standard host-provides-symbols plugin pattern.
    // -Wl,-fixup_chains is REQUIRED: -undefined dynamic_lookup otherwise makes ld64 fall back to the
    // classic LC_DYLD_INFO_ONLY scheme, which is the very thing that crashes a signed x86_64 ObjC
    // __DATA_CONST. Forcing chained fixups keeps dynamic_lookup for the back-ref symbols AND puts
    // the shim's ObjC metadata in a chained-fixups image, so the signed binary runs.
    const shim = b.addSystemCommand(&.{ "xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-Wl,-undefined,dynamic_lookup", "-Wl,-fixup_chains" });
    shim.addArg("-I");
    shim.addDirectoryArg(b.path("src"));
    shim.addFileArg(b.path("src/wkwebview_shim.m"));
    shim.addFileArg(b.path("src/agent_drawer_mac_host.m"));
    shim.addFileArg(b.path("src/agent_drawer_mac_panel.m"));
    shim.addFileArg(b.path("src/agent_secrets_mac.m"));
    shim.addFileArg(b.path("src/agent_secrets_window_mac.m"));
    shim.addFileArg(b.path("src/agent_token_fd_mac.c"));
    shim.addFileArg(b.path("src/agent_helper_mac.c"));
    shim.addArgs(&.{ "-framework", "WebKit", "-framework", "Cocoa", "-framework", "AppKit", "-framework", "Foundation", "-framework", "Security" });
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
    module.linkFramework("AppKit", .{});
    module.linkFramework("Foundation", .{});
    module.linkFramework("Security", .{});

    // Ship the dylib beside the binary, in the bundle's Frameworks/ (zig-out/Frameworks).
    const install_dylib = b.addInstallFileWithDir(dylib, .{ .custom = "Frameworks" }, "libwkwebview_shim.dylib");
    b.getInstallStep().dependOn(&install_dylib.step);
}
