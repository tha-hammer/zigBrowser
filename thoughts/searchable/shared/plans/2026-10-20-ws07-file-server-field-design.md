# WS0.7 file-server field design (console_user, zbtest_write_paths, fw_rules_hash, listener churn)

**Author:** AzureRidge (cc_4, Windows)  **Date:** 2026-10-20  **Status:** design — owner decisions flagged
**Backs:** `tests/windows/gate.sh` `validate_probes` (commit 9a203eb) and RoseCat's cumulative block on
`fb77e25` item 3 ("host_probe does not emit console_user / zbtest_write_paths / fw_rules_hash; no Win10
marker validation"). This is design + sourcing only — nothing here is run tonight.

## Why these fields exist

The file server (physical Win10, `100.123.34.15`, user `zbtest`) doubles as a production file server. WS0.7
is the promise that *running the gate there leaves the box undisturbed*. `validate_probes` already fails
closed when any of these is missing or mistyped (commit 9a203eb); this doc says how `host_probe.ps1` should
**source** each one so a real file-server probe can satisfy the validator. Until then a live file-server
run correctly fails closed ("cannot validate") — honest, not a regression.

### 1. `console_user` — who owns the physical console
- **Need:** the gate must confirm the *test* user (not a real operator mid-session) is at the console, so a
  gate run cannot run on top of someone's live work.
- **Blocker:** an SSH logon lands in **session 0 (NT AUTHORITY\NETWORK)**, which cannot read the console
  session's logged-on user from the network security context (confirmed on win11-m8).
- **Source:** the in-console **session helper** already prototyped as `session_probe.ps1`, run via a
  scheduled task *in the console session*, calling `WTSQuerySessionInformation(WTS_CURRENT_SERVER_HANDLE,
  <WTSGetActiveConsoleSessionId>, WTSUserName)`. It writes `console_user` into a small JSON that
  `host_probe.ps1` reads back (same pattern as `interactive_session`/`locked`).
- **Owner-gated (morning):** staging the helper + registering the scheduled task on the **file server** is a
  write to a production box — needs the orchestrator. Interim: field absent → fail closed.

### 2. `zbtest_write_paths` — served paths the test user can write
- **Need:** the shares the box serves must be **read-only** to `zbtest`; a non-empty list means a gate run
  could mutate served data. Must be `[]`.
- **Source (ACL math):** enumerate share paths (`net share` / `Get-SmbShare`), and for each, resolve the
  effective access for the `zbtest` SIDs from `Get-Acl` (Allow entries granting Write / Modify / FullControl
  minus Deny). List any path that resolves to writable.
- **Blocker:** `Get-SmbShare` is CIM-backed (Access-denied to a standard user); `net share` may also require
  elevation. `Get-Acl` on a path the user can traverse works.
- **Owner decision (morning — the queued "share-enumeration decision"):** either (a) run the enumeration
  **once at provisioning as admin** and pin the expected empty set as a baseline the read-only probe
  re-confirms, or (b) accept a read-only probe that reports writable paths only among shares it can see and
  treat "cannot enumerate shares" as fail-closed. Recommend (a): a pinned baseline is strongest and keeps
  the per-run probe standard-user-safe.

### 3. `fw_rules_hash` — firewall rule-set fingerprint
- **Need:** detect a run that opens a firewall hole (a new inbound allow).
- **Source:** a stable hash (SHA-256) over the *normalized* firewall rule set — sorted, each rule reduced to
  (Name, Direction, Action, Protocol, LocalPort, Profile). Captured pre-run and post-run; any change fails.
- **Blocker:** `Get-NetFirewallRule` is CIM-backed (denied to standard user). `netsh advfirewall firewall
  show rule name=all` is the standard-user-safe fallback *if* readable; needs live confirmation on the file
  server (it is often readable without elevation, unlike the CIM path).
- **Owner decision (morning):** confirm `netsh advfirewall ... show rule` is readable by `zbtest`; if not,
  pin a provisioning-time baseline hash like option (a) above. Interim: field absent → fail closed.

### 4. Win10 identity marker — DONE in validator, provisioning pending
- `validate_probes` now requires the file-server probe's `identity_marker` to equal the pinned
  `ZB_WIN10_MARKER` (commit 9a203eb), mirroring the Win11 `.gate-identity` nonce mechanism.
- **Owner-gated (morning):** write the nonce to `C:\Users\zbtest\zb\.gate-identity` on the file server and
  record `ZB_WIN10_MARKER` in the private `hosts.env`. `host_probe.ps1` already reads `.gate-identity`.

## Listener churn — the deferred upgrade (resolves fb77e25 item 1 properly)

**Now (committed, fail-closed):** `validate_probes` compares the **full** listening-port set pre/post with
**no range exemption**. The old `>=49152` exemption was a bypass — a product service binding port 50000 was
silently approved. Strict comparison is correct and fail-closed; its only cost is that genuine OS
dynamic-port churn (e.g. an already-running `svchost` grabbing another dynamic port between the two probes)
can trip it.

**Proposed upgrade (owner/RoseCat approval before implementing):** distinguish churn from a planted listener
by **ownership**, not by port range.
- `host_probe.ps1` emits `listeners` as `[{port, pid}]` (both available from `netstat -ano`, standard-user
  safe; process name is denied for other sessions, but PID is enough).
- Rule: the set of `(port)` must match pre/post **except** a port that appears only in `post` is tolerated
  **iff** its owning `pid` already owned a listener in the `pre` probe *and* the port is in the dynamic range
  (≥49152). A listener owned by a **new** pid, or any change to a service port, is a disturbance → fail.
- This tolerates "same service, new ephemeral port" while still catching "new process opened a listener,"
  including on high ports.
- **Gated on:** host_probe emitting `pid` + a live re-verification run on the file server (two-host gate,
  needs the Linux slot and the orchestrator's go, since it probes the production box twice).

**Filed as a plan item / bead** rather than rushed in, per RoseCat: "needs a stronger identity/ownership/
state representation or an explicit plan revision, not deletion of every high-port signal."

## Summary of states
| field | validator (now) | host_probe emits | unblock |
|---|---|---|---|
| console_user | required, fail-closed | no (needs in-console helper) | orchestrator: stage session helper on FS |
| zbtest_write_paths | required list, fail-closed | no (ACL math, admin-gated) | orchestrator: provisioning baseline decision |
| fw_rules_hash | required non-empty, fail-closed | no (netsh vs CIM) | confirm netsh readable / pin baseline |
| identity_marker (Win10) | required == ZB_WIN10_MARKER | yes (reads .gate-identity) | orchestrator: write nonce + hosts.env |
| listeners (churn) | strict full-set, fail-closed | port only | approve PID-ownership upgrade + live verify |
