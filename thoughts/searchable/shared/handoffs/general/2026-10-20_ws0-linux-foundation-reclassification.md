---
date: 2026-10-20
author: AzureRidge (cc_4)
supersedes_commit_subject: "1b58f85 — feat(windows): WS0 green — Windows two-host gate + Linux selftest, registered"
status: authoritative fix-forward (Route B of RoseCat 48ed0a6 / mail 6631)
scope: WS0 of 2026-10-19-windows-launch-tdd-plan.md
---

# WS0 is a Linux foundation only — NOT "WS0 green"

This note is an authoritative docs fix-forward. It **explicitly supersedes the commit subject of
`1b58f85`** ("WS0 green — Windows two-host gate + Linux selftest, registered") and reclassifies the
WS0 foundation commits. It takes **Route B** of RoseCat's closure routes (mail 6631, review commit
`48ed0a6`): narrow the delivered scope to the truthful Linux foundation; the full `[W]` two-host gate
remains an explicit, unmet prerequisite.

## Reclassification

`1b58f85` + `b8dcd21` + `3097d78` deliver the **WS0 `[L]` Linux foundation ONLY**:
- the `tests/windows/gate.sh` driver, `host_probe.ps1`, `session_probe.ps1`, `resolve_path.sh`,
  `stage_manifest.txt`, `hosts.env.example`, `known_hosts` template;
- the hostless `windows-gate-selftest` (`tests/windows/gate_selftest.py`), registered in `build.zig`;
- the injection-safe resolver, the whole-gate display scrub, and the fail-closed selftest cases.

They are **NOT** full "WS0 green."

## The `[W]` two-host milestone is INCOMPLETE

**WS0 `[W]` is incomplete. No later milestone, slice, or dependency may cite WS0 as complete.**
The two-host product gate is its own later slice — call it **WS0-completion** (Route A of RoseCat
48ed0a6). Until WS0-completion lands and is reviewed, treat WS0 as `[L]`-only.

What WS0-completion (`[W]`) still requires, none of which the foundation commits deliver:

1. **The no-argument, two-host product gate is NOT implemented.** `gate.sh` driving both hosts in one
   run does not exist yet. A **refusal or a SKIP from it is never success** — a run that cannot reach
   a host, or that skips, must be read as "not proven," not as green.
2. **Full WS0.1–WS0.8 field production + fail-closed validation.** Today the probe does not produce
   the complete schema: `interactive_session` and `locked` are `null`, and the probe omits
   `console_user`, `shares`, `zbtest_write_paths`, `fw_rules_hash` and `snapshot_marker`; the gate
   does not yet validate the whole WS0.1 readiness schema fail-closed.
3. **A live two-host run with fail-closed evidence:** bounded `gate.sh --probe-only` against the
   **Win11 VM** *and* the **Win10 file server**, with the WS0.7 pre/post probe pair, exactly one
   `WIN11 <JSON>` and one `WIN10 <JSON>` line, both JSON objects satisfying the plan, and the Win10
   pre/post listeners + firewall hash identical. The **orchestrator watches the first run** on each
   host to confirm the reported interactive session is the one on the monitor.
4. **The live resolver regression** (`tests/windows/resolve_live_test.py`) asserting on the VM
   (`PASS live resolver regression ASSERTS 2`), never `SKIP`.

## Evidence for the delivered `[L]` foundation

Clean export of `3097d78` (`git archive 3097d78 | tar -x`), Linux, display scrubbed:

- `env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY python3 -I tests/windows/gate_selftest.py`
  → **`Ran 15 tests in 3.931s` / `OK`**, exit 0. (`gate_twohost_selftest.py` did not exist at
  `3097d78`; the 17-test two-host selftest belongs to WS0-completion.)
- Full private-Xvfb gate, clean export of `3097d78`,
  `env -u WAYLAND_DISPLAY xvfb-run -a zig build test --summary all -j1` (DISPLAY/WAYLAND unset,
  private Xvfb), exit 0:

```
Build Summary: 163/163 steps succeeded; 920/920 tests passed
```

Run 2026-10-20 in the shared Linux gate slot (BlackRobin → AzureRidge). The two Windows
selftest steps (`windows-gate-selftest`) ran; the live two-host steps skip hostless, which is
not success (see the `[W]` requirements above).

No Windows-host run is required to approve this deliberately narrow foundation. This preserves the
full `[W]` gate as an explicit unmet prerequisite and does not waive any full-WS0 evidence.
