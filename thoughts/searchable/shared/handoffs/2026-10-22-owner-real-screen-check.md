# Owner's real-screen check: the navigation approval card and its notification (decision 16)

**Who:** the owner, at the NVIDIA screen, with a few minutes to watch.
**Why:** the gate runs on a private Xvfb with software graphics. That has passed before while the real window was blank. The approval card (decision 16, commits `ebe6529` and `c2b4c38`) and its desktop notification are new UI, so they need to be seen on the real screen.
**Time:** about 3 minutes.

## What this run does and does not touch
- It uses a **throwaway profile** and a **throwaway agent home**, both in a new temporary folder that is deleted afterwards. It never uses `~/zb-live-profile` or your own agent home.
- It starts the browser with `--media-source off`.
- **No real Claude account and no external network.** A local fake Claude, started by the script on this machine's loopback address (127.0.0.1), asks to "open a page". The page is a local file. The agent's egress allowlist is replaced by that local fake alone, so nothing can reach Anthropic or any other outside host.
- **None of your shell's settings reach the test browser** (RoseCat d3985c9). It is started from an explicit allowlist: only your display (`DISPLAY`, `XAUTHORITY`) and your desktop's session bus (`DBUS_SESSION_BUS_ADDRESS`, for the notification). A live browser's socket (`ZIGBROWSER_SOCKET`), any other `ZIGBROWSER_*` or `ZB_*` setting, Claude or Anthropic credentials, and proxies are all dropped. `tests/manual/test_real_screen_env.py` checks this.
- The **desktop notification is real**: it goes to your desktop's own notification area. It carries only the fixed text "zigBrowser" and "Claude is waiting for your approval."

## Before you start
1. Close any open zigBrowser **Secrets** window. Closing a window while it was open once crashed the desktop session.
2. Keep the screen free: don't type or click while the script runs, except the one optional click in step 4 below.

## Commands
```sh
cd /home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59
git log --oneline -1            # must be c2b4c38 or later
zig build                       # builds zig-out/bin/zigBrowser
python3 tests/manual/real_screen_check.py --confirm-user-permission --case approval \
    --bin zig-out/bin/zigBrowser --out /tmp/zb-approval-$(date +%H%M%S)
```
The `--out` folder must be new. The command above makes a new one each time.

## What to watch, in order
1. A new zigBrowser window opens with a **blue test page**. The Claude drawer opens at the bottom, and the word `approve` is typed into it.
2. Within about 5 seconds, a **card** appears in the drawer:
   - the text: *Claude wants to open file:///tmp/…/approved.html in window 1.*
   - below it, two buttons, **Approve** and **Deny**: both fully visible, not clipped, readable.
3. At the same time, a **desktop notification** appears:
   - title **zigBrowser**;
   - text **Claude is waiting for your approval.**;
   - **no** web address, file path, or anything else from the page.
4. *(Optional, within the first 15 seconds.)* Click the notification. The browser window should come to the front with its drawer open. Clicking it must **not** approve anything: the card still shows both buttons.
5. After 15 seconds the script clicks **Approve** for you. The page turns **green** ("Approved: the navigation ran."), and the card's buttons give way to **"Done."**
6. The script folds the drawer, reopens it and types `deny`. A **second card** and a **second notification** appear (check steps 2 and 3 again).
7. After 15 seconds the script clicks **Deny**. The card shows **"Denied. Nothing was opened."**, and the page stays green.
8. The window closes. The script prints four lines and ends with `0 failed, 0 invalid`:
   ```
   PASS    approval-approve-drawn  ...
   PASS    approval-approve-done   card 1 ended ['done']
   PASS    approval-deny-drawn     ...
   PASS    approval-deny-denied    card 2 ended ['denied']
   ```

## What to send back (to the orchestrator)
- The four `PASS`/`FAIL` lines and the last line.
- Three yes/no answers:
  1. Was each card readable, with both buttons fully visible? (steps 2 and 6)
  2. Did each notification show, with only "zigBrowser" and "Claude is waiting for your approval."? (step 3)
  3. If you clicked a notification: did it bring the window forward with the drawer open, **without** approving? (step 4)
- If anything looked wrong: the `--out` folder. It holds `approval.approve.card.screen.png`, `approval.deny.card.screen.png`, `approval.after.screen.png`, the browser's log and its drawer rows.

## If something goes wrong
- **"refusing: … is not empty":** use a new `--out` folder.
- **`INVALID … stayed covered or inactive`:** something covered the window. Close or move it, then run again with a new `--out`.
- **No notification, but all four lines PASS:** report that. A card that waits without its notification is allowed: the card still works and expires, but the notification is part of what we're checking.

## What this run does not cover
These are covered in the automated tests (`tests/e2e/agent_navigate_approval_test.py`, `agent_navigate_stale_test.py`, `agent_navigate_prompt_test.py`):
- a card from **another** window's drawer, which shows in the first window's drawer;
- the 120-second expiry;
- closing a window while a card waits;
- Stop;
- a page that changes while a card waits.

This run only checks that the card and the notification are **drawn and usable on your real screen**.
