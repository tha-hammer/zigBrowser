---
date: 2026-07-04T13:04:50+0000
researcher: RoseMeadow
git_commit: af2e4c35a9a6f927d9b3d1e3bcff835fcc97aa21
branch: master
repository: zigBrowser
topic: "Linux deb launch failure debug and fix"
tags: [packaging, linux, deb, webkitgtk, clerk, debug]
status: complete
last_updated: 2026-07-04
last_updated_by: RoseMeadow
type: implementation_strategy
---

# Handoff: Linux Packaged App Launch/Debug

## Task(s)

**Task:** Debug why `zigBrowser_0.1.0_amd64.deb` installs successfully and appears in the Linux app picker, but launching produces no visible output and no errors.

**Status: Implementation complete, pending user desktop verification.**

Three root causes found and fixed. Deb rebuilt at 0.1.2. All unit and E2E tests pass. User has been asked to install and test (`sudo apt install ./zigBrowser_0.1.2_amd64.deb`) but has not yet confirmed results on their desktop.

## Critical References

- `src/cli.zig` — CLI argument parsing, no-args default
- `src/webkit_shim.c` — WebKitGTK interactive (`zb_app_run`) and screenshot (`run_screenshot_internal`) entry points
- `packaging/linux/build-deb.sh` + `packaging/linux/control.in` — deb version and build

## Recent Changes

All changes are uncommitted on `master` at `af2e4c3`.

### 1. No-args default URL (`src/cli.zig:21`)
- **Root cause:** `.desktop` file `Exec=/usr/bin/zigBrowser %u` — desktop launcher strips `%u` when no URL, invoking zigBrowser with zero args. `cli.zig:21` returned `.usage`, wrote to stderr (invisible with `Terminal=false`), exited 1.
- **Fix:** `if (args.len <= 1) return .{ .open = .{ .url = "https://cosmic-hr-development.up.railway.app/" } };`
- Added test `parseArgs no args yields open with default URL`.

### 2. `about:` URI scheme support (`src/uri.zig:14-15`)
- Added `about` to the allowed scheme list so `about:blank` passes validation (used during initial development; hardcoded URL now overrides, but the scheme support remains).
- Added test `validate accepts about:blank`.

### 3. WebKitGTK cookie policy (`src/webkit_shim.c:1123-1127, 1557-1559`)
- **Root cause:** Default `WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY` blocks Clerk auth SDK cross-origin cookies from `evolved-treefrog-83.clerk.accounts.dev` (`SameSite=None; Secure`).
- **Fix:** Set `WEBKIT_COOKIE_POLICY_ACCEPT_ALWAYS` on both interactive and screenshot web contexts.

### 4. Hardware acceleration disabled (`src/webkit_shim.c:929-930, 1565-1568`)
- **Root cause:** WebKitGTK's GPU compositing fails when GBM/DRM devices aren't accessible (`Failed to create GBM buffer ... Permission denied`), causing blank renders.
- **Fix:** `webkit_settings_set_hardware_acceleration_policy(settings, WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER)` on both paths.

### 5. Version bump (`packaging/linux/build-deb.sh`, `packaging/linux/control.in`)
- 0.1.0 → 0.1.1 → 0.1.2 (two bumps during debugging; current version is 0.1.2).

## Learnings

1. **Clerk dev-mode init flow:** Clerk loads `clerk.browser.js` and `ui.browser.js` from `evolved-treefrog-83.clerk.accounts.dev`, then calls `/v1/dev_browser` (POST), `/v1/environment` (POST), `/v1/client` (GET). These cross-origin requests require cookies with `SameSite=None`. Without cookie policy fix, Clerk hangs on its loading spinner indefinitely.

2. **WebKitGTK vs Playwright WebKit:** Playwright's WebKit engine renders the full Clerk sign-in page fine (92 visible elements). WebKitGTK has stricter cookie defaults and hardware acceleration requirements. The `decide-policy` signal only fires for navigations and responses, NOT for sub-resource requests (scripts, CSS, XHR/fetch).

3. **Screenshot timing for SPAs:** zigBrowser's snapshot captures on `didFinishLoad`, which fires when the HTML document loads — before JS SPA frameworks like Next.js/Clerk hydrate. The `ZB_SNAPSHOT_SETTLE_MS` env var helps but Clerk takes 5-15s to fully render. Interactive window mode works fine since the window stays open.

4. **Nav policy is clean for HTTPS bases:** When `app_base` is `https://...`, `canonicalBaseDirPath` returns `null` (not `file://`), so the policy falls through to `.use` for all navigations. No blocking.

5. **Playwright setup:** Project has `@playwright/test` v1.61.1 in `node_modules/` with browsers at `~/.cache/ms-playwright/` (chromium-1228, webkit-2311). System `/usr/bin/playwright` is v1.38.0 with mismatched browser revisions — must use project `playwright-core` via `require('/home/maceo/ntm_Dev/zigBrowser/node_modules/playwright-core')`.

## Artifacts

- `src/cli.zig` — modified lines 21, 88-92 (default URL, test)
- `src/uri.zig` — modified lines 14-15, 22-27 (about: scheme, test)
- `src/webkit_shim.c` — modified lines 1123-1127 (cookie policy interactive), 929-930 (hw accel interactive), 1557-1559 (cookie policy screenshot), 1565-1568 (hw accel screenshot)
- `packaging/linux/build-deb.sh` — version 0.1.2
- `packaging/linux/control.in` — version 0.1.2
- `zigBrowser_0.1.2_amd64.deb` — rebuilt package at project root
- Beads: `zigBrowser-y45` (closed) — "Fix desktop launch: no-args opens about:blank"

## Action Items & Next Steps

1. **User must install and test the deb on their desktop:** `sudo apt install ./zigBrowser_0.1.2_amd64.deb` then launch from app picker. Verify:
   - Window opens (no silent exit)
   - CosmicHR/Clerk sign-in page renders (not stuck on "Loading...")
   - If still blank: check if it's a hw accel issue on the user's real GPU (may want to revert `HARDWARE_ACCELERATION_POLICY_NEVER` to `HARDWARE_ACCELERATION_POLICY_ON_DEMAND`)

2. **Commit changes** once user confirms the deb works:
   ```
   git add src/cli.zig src/uri.zig src/webkit_shim.c packaging/linux/build-deb.sh packaging/linux/control.in
   git commit -m "Fix Linux desktop launch: default URL, cookie policy, software rendering"
   ```

3. **Consider making hw accel configurable:** `WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER` is a safe default but forces software rendering even when GPU is available. Could check for `ZB_HW_ACCEL=1` env var to opt back in.

4. **Consider making default URL configurable:** Currently hardcoded. Could read from `zigbrowser.json` config (see open bead `zigBrowser-2aa`).

## Other Notes

### Git Status (dirty, uncommitted)
```
 M .gitignore
 M packaging/linux/build-deb.sh
 M packaging/linux/control.in
 M src/cli.zig
 M src/uri.zig
 M src/webkit_shim.c
```
Untracked files from other agents' work: `.github/`, `e2e/`, `package.json`, `package-lock.json`, `playwright.config.ts`, and thoughts docs. Do NOT commit these — they belong to other work streams.

### Agent Mail
- Registered as **RoseMeadow** (id 639) on project `home-maceo-ntm-dev-zigbrowser`
- Active peers: **PurpleCliff** (coordinator), **FrostyGrove** (claude-code)
- Inbox: empty. No open threads or tasks.

### Beads
- `zigBrowser-y45` — CLOSED — "Fix desktop launch: no-args opens about:blank"
- `zigBrowser-2aa` — OPEN — "Build-time JSON config ingestion" (unrelated, do not touch)
- `zigBrowser-98g` — OPEN — "Research local isolated cosmic-HR04 runtime packaging" (unrelated)

### Verification Results (all pass)
- `zig build test` — PASS
- `zig build` — PASS
- E2E `lifecycle_test.py` — PASS (sigint-exit-130-within-3s)
- E2E `ipc_roundtrip_test.py` — PASS (ipc-echo-success-and-badargs)
- E2E `reload_test.py` — PASS (reload-nav-a-to-b)
- E2E `gtk_close_during_load_test.py` — PASS (gtk-close-during-load-cancels)
- Deb rebuild — PASS (0.1.2)
