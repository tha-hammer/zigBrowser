# Slice 5 — Distribution: Windows MSI + Linux .deb — TDD Implementation Plan

**Plan:** ENG-0007 · 2026-06-03 · Tier L1 (topology skipped — no data model)
**Decisions:** version `0.1.0` · Linux install `/usr/bin` · per-user MSI · icon from Figma node `8999-293` (`hQmruZnjNWlxE3FLYA5cJv`) · gates: Linux fresh container, Windows the live guest.

## Overview

Wrap the already-working, verified zigBrowser binary into two **real installers** — a Linux `.deb` (built on the host with `dpkg-deb`) and a Windows **MSI** (built with WiX in the Win11 KVM guest over Tailscale SSH). Packaging **wraps the artifact; it does not change the browser.** Every milestone ends in a human-observable artifact; the two install gates end in a **real page rendering on a clean target** (a fresh Debian container; the Win11 guest).

## Current State Analysis

The browser builds and runs on both targets (Slice 1–4 + M8). What's missing: any packaging. New files live under `packaging/{assets,linux,windows}/`; no `src/` or browser-logic changes.

### Key Discoveries (hostile audit, verified)
- **Windows exe is self-contained except the WebView2 runtime** — `dumpbin /dependents` on the guest's `zigBrowser.exe` shows only `ole32`/`user32`/`kernel32`/`ntdll`/`advapi32`; `WebView2LoaderStatic` is static-linked (no `WebView2Loader.dll`), no VCRuntime. The WebView2 Evergreen runtime is **COM-activated** (not a static import) → the MSI must **bundle `MicrosoftEdgeWebview2Setup.exe`** and run it on install.
- **Linux binary links the system GTK/WebKit stack** — `ldd zig-out/bin/zigBrowser`: `libwebkit2gtk-4.1.so.0`, `libgtk-3.so.0`, `libsoup-3.0.so.0`, `libjavascriptcoregtk-4.1.so.0`, glib/gio → `.deb` `Depends: libwebkit2gtk-4.1-0, libgtk-3-0`.
- **`build.zig` builds per-target** (`resolveBackend` gtk/webview2); artifact `zig-out/bin/zigBrowser[.exe]`.
- **`build.zig.zon` version = `0.0.0`** → set to `0.1.0`.
- **No packaging exists** (`git ls-files`) — clean slate.
- **Tooling:** host has `dpkg-deb`+`fakeroot` (lintian missing, optional); guest has **no WiX** → install it (winget `WiXToolset.WiX`) in M0. WebView2 bootstrapper not vendored → fetch it.
- **Verification harnesses to reuse:** `tests/guest/build-in-guest.sh` + the interactive-session Scheduled-Task screenshot recipe (Windows); Slice 1 xvfb/DISPLAY + pillow non-uniform PNG oracle (Linux).

## Desired End State

A fresh Debian container `apt install ./zigBrowser_0.1.0_amd64.deb` → real page screenshot; the Win11 guest `msiexec /i zigBrowser-0.1.0.msi` → installed app renders a real page (interactive-session screenshot) with the nolme icon on its shortcut; both uninstall cleanly. Host `zig build test` stays green (no browser regression).

### Observable Behaviors
1. **release_assets_and_toolchain** — version `0.1.0`; nolme icon exported from Figma → `.ico`+`.png`; WiX in guest; docker/podman+dpkg-deb on host.
2. **linux_deb_builds** — `zigBrowser_0.1.0_amd64.deb` with `Version: 0.1.0`, `Depends: libwebkit2gtk-4.1-0, libgtk-3-0`, `/usr/bin/zigBrowser` + `.desktop` + icon.
3. **linux_deb_installs_and_launches** — fresh Debian container, `apt install ./…deb` pulls deps, renders a real page (screenshot). **[Linux gate]**
4. **windows_msi_builds** — `zigBrowser-0.1.0.msi` (ProductVersion 0.1.0) bundling exe + WebView2 bootstrapper + per-user shortcut w/ icon.
5. **windows_msi_installs_and_launches** — guest, `msiexec /i … /qn`, WebView2 ensured, shortcut renders a real page (screenshot). **[Windows gate]**
6. **clean_uninstall_both** — `msiexec /x` + `dpkg -r` remove every installed file (leaving shared webkit/gtk + WebView2 runtime).

## What We're NOT Doing
- macOS packaging (no Mac; M9 deferred).
- Code signing / notarization (follow-up; MSI unsigned for now).
- Auto-update (MSIX/Sparkle) — separate slice.
- AppImage / Flatpak (this slice is `.deb` only).
- Any change to browser logic (`src/`, the backends).

## Testing Strategy
- **Framework:** `dpkg-deb`+`fakeroot`+a fresh Debian/Ubuntu container (docker/podman)+xvfb+pillow non-uniform PNG oracle (Linux); WiX (candle/light or `wix build`)+`msiexec`+Windows Installer COM (`Get-MsiDatabase`)+the interactive-session Scheduled-Task screenshot recipe in the guest (Windows); figma MCP tools for the icon; `tests/e2e/slice2_common.py` for screenshot assertions.
- **Independent oracles only:** dpkg's own `--info`/`--contents` parse; apt's dependency resolution on a clean image; the Windows Installer DB; the rendered-page title/screenshot — never the packaging script's claims.

## Ownership (coordinator dispatch — no file overlap)
- **A** → `packaging/linux/*` (.deb tree, control, .desktop) + the container install-gate.
- **B** → `packaging/windows/*` (`zigBrowser.wxs`, WiX build script, MSI install-gate via the guest Scheduled-Task recipe).
- **C** → `packaging/assets/*` (Figma icon → `.ico`+`.png`) + version bump (`build.zig.zon` → 0.1.0) + the shared release-build helper.

---

## Milestone 0 — Release assets + packaging toolchain  (visible: icon image + tool versions)
- 🔴 Red: `build.zig.zon` is 0.0.0; no icon; `wix` absent in guest; confirm docker/podman + dpkg-deb on host.
- 🟢 Green: set `.version="0.1.0"`; export nolme icon from Figma (file `hQmruZnjNWlxE3FLYA5cJv`, node `8999-293`) via figma MCP tools → `packaging/assets/zigBrowser.ico` (16/32/48/256) + `zigBrowser.png`; install WiX in guest (`winget WiXToolset.WiX`); verify docker/podman on host (else install/flag); add a release-build helper (`zig build -Doptimize=ReleaseSafe` per target) so packaging consumes a known artifact path.
- 🔵 Refactor: single sh/make entrypoint for the release build.
- **Files:** `build.zig.zon`, `packaging/assets/zigBrowser.{ico,png}`, `packaging/release-build.sh`.
- **VISIBLE ARTIFACT:** exported icon shows the real nolme mark; `wix --version` (guest) + `dpkg-deb --version` (host) print; `build.zig.zon` shows 0.1.0. **STOP if Figma unreachable** (flag, no placeholder).

## Milestone 1 — Linux .deb builds with correct metadata  (visible: `dpkg-deb --info/--contents`)
- 🔴 Red: no `.deb`; metadata assertion (Version 0.1.0 + Depends + `/usr/bin/zigBrowser`) fails.
- 🟢 Green: `packaging/linux/` tree — `DEBIAN/control` (Package `zigbrowser`, Version 0.1.0, Architecture amd64, `Depends: libwebkit2gtk-4.1-0, libgtk-3-0`, Maintainer, Description), `/usr/bin/zigBrowser` (ReleaseSafe), `/usr/share/applications/zigBrowser.desktop` (`Exec=/usr/bin/zigBrowser %u`, `Icon=zigBrowser`), `/usr/share/icons/hicolor/256x256/apps/zigBrowser.png`; `build-deb.sh` stages from `zig-out`+assets under `fakeroot`; `dpkg-deb --build` → `zigBrowser_0.1.0_amd64.deb`.
- 🔵 Refactor: parametrize version/arch from `build.zig.zon`.
- **Files:** `packaging/linux/build-deb.sh`, `packaging/linux/control.in`, `packaging/linux/zigBrowser.desktop`.
- **VISIBLE ARTIFACT:** `dpkg-deb --info` → Version 0.1.0 + Depends line; `--contents` → `/usr/bin/zigBrowser` + `.desktop` + icon. **Oracle:** dpkg's own parse.

## Milestone 2 — Linux .deb installs + launches on a CLEAN target  (visible: screenshot)  [LINUX GATE]
- 🔴 Red: in a fresh Debian container (no webkit), install+launch fails.
- 🟢 Green: `packaging/linux/gate.sh` — docker/podman run a clean `debian`/`ubuntu` image, copy the `.deb`, `apt-get update && apt-get install -y ./zigBrowser_0.1.0_amd64.deb` (apt resolves+pulls `libwebkit2gtk-4.1-0`/`libgtk-3-0`), then `xvfb-run /usr/bin/zigBrowser <uri> --screenshot /out/page.png` (or run+capture).
- 🔵 Refactor: parametrize base image; cache apt layer.
- **Files:** `packaging/linux/gate.sh`, `tests/e2e/deb_install_test.py`.
- **VISIBLE ARTIFACT:** screenshot from inside the clean container of a real rendered page. **Oracle:** non-uniform PNG (Slice 1 pillow oracle) + page title; apt resolving deps on a clean image.

## Milestone 3 — Windows MSI builds with correct metadata  (visible: MSI + ProductVersion via Installer DB)
- 🔴 Red: no `.msi`; ProductVersion/file-table assertion fails.
- 🟢 Green: `packaging/windows/zigBrowser.wxs` — `InstallScope perUser`, ProductVersion 0.1.0, stable UpgradeCode, payload `zigBrowser.exe`, Start-Menu (+Desktop) shortcut with `zigBrowser.ico`, the vendored WebView2 Evergreen bootstrapper chained/run on install; build with WiX in the guest over SSH.
- 🔵 Refactor: `build-msi.ps1` driven from the guest; GUIDs in one place.
- **Files:** `packaging/windows/zigBrowser.wxs`, `packaging/windows/build-msi.ps1`.
- **VISIBLE ARTIFACT:** `zigBrowser-0.1.0.msi` exists in guest; ProductVersion 0.1.0 + File table lists `zigBrowser.exe` + bootstrapper. **Oracle:** Windows Installer COM / `Get-MsiDatabase`.

## Milestone 4 — Windows MSI installs + launches in the guest  (visible: screenshot)  [WINDOWS GATE]
- 🔴 Red: from clean state, installed-exe launch fails.
- 🟢 Green: uninstall-first, `msiexec /i zigBrowser-0.1.0.msi /qn` (per-user); bundled bootstrapper ensures WebView2; launch the **installed** exe via the interactive-session Scheduled-Task recipe against a real URL; screenshot.
- 🔵 Refactor: `packaging/windows/gate.ps1` reusing the proven screenshot helper.
- **Files:** `packaging/windows/gate.ps1`, `tests/e2e/msi_install_test.py`.
- **VISIBLE ARTIFACT:** guest interactive-session screenshot of the **installed** zigBrowser rendering a real page; Start-Menu shortcut with the nolme icon. **Oracle:** rendered page + installed-exe `--version` (WebView2 runtime matching the registry).

## Milestone 5 — Clean uninstall, both platforms  (visible: files gone)
- 🔴 Red: after uninstall, leftover files remain.
- 🟢 Green: `dpkg -r zigbrowser` removes `/usr/bin/zigBrowser`+`.desktop`+icon (not the shared libs); `msiexec /x` removes the per-user install dir + shortcut (leaves the shared WebView2 runtime); re-install after uninstall works (stable GUIDs).
- 🔵 Refactor: assert via `dpkg -L` / filesystem + install-dir listing.
- **Files:** extend the two gate scripts + tests.
- **VISIBLE ARTIFACT:** post-uninstall listings show the binary/.desktop gone (container) and install dir + shortcut gone (guest).

## Final Visible-Output Gate (whole slice)
Fresh container `apt install ./zigBrowser_0.1.0_amd64.deb` → real page screenshot; guest `msiexec /i zigBrowser-0.1.0.msi` → installed app renders a real page (interactive session) with the nolme shortcut icon; both uninstall cleanly; host `zig build test` still green.

## Order
M0 assets+toolchain → M1 deb-build → M2 deb-install-gate → M3 msi-build → M4 msi-install-gate → M5 uninstall.
