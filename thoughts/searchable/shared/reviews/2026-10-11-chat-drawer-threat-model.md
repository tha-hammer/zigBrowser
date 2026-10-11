# Threat model: privileged chat-drawer bridge

**Date:** 2026-10-11

**Status:** design constraint for the next TDD plan; no implementation is claimed here.

**Scope:** the proposed permanent drawer, its native bridge, the Claude Agent SDK subprocess, custom tools, and reuse of zigBrowser automation. This review was docs-only; no browser, display, or socket was used.

## Security objective

Treat browsing content, model output, and tool arguments as untrusted. A page, frame, popup, local automation client, or the model itself must not be able to acquire drawer authority, disclose a credential, read or write an unapproved file, select another logged-in window, or cause a committing action without the user's approval for that exact action.

The native application is the enforcement point. Neither JavaScript possession of a bridge object nor an Agent SDK permission decision is sufficient authorization.

## Why the existing bridges cannot be reused

- `zbHost` is registered in the default page world (`world_name == NULL`) on every browsing window and carries no origin, frame, nonce, or capability into Zig (`src/webkit_shim.c:648-726`, `:1176`). Giving it prompt, permission, filesystem, or agent commands would give those commands to every site.
- Related popups are made with `webkit_web_view_new_with_related_view` and share their opener's user-content manager and process group (`src/webkit_shim.c:728-766`). A popup is not an independent security boundary. The automation injector already accounts for the shared manager (`:1723-1758`).
- The automation socket is deliberately powerful. It is protected by a 0600 socket, a per-session token, and constant-time token comparison (`src/automation_server.zig:191-197`, `:443-445`, `:1071-1121`), but its documented boundary trusts processes running as the same user (`docs/how-to-automate.md:93-95`). Its token authenticates browser automation; it must not also authorize chat administration, API-key access, or tool approvals.
- Socket commands can target a stable `window_id` and reach social flows or raw page operations (`src/automation_server.zig:459-533`). A future drawer must preserve explicit target identity and must remain absent from `page.list` and from all socket-targetable browsing windows.

## Assets and authority

The drawer can send prompts to an Agent SDK session, choose which tools are available, answer tool-permission requests, expose filesystem operations, and invoke automation against sites where the user is already logged in. Consequently the protected assets are:

- the provider API key and any SDK/provider credentials;
- browser cookies, sessions, automation token, and logged-in account identity;
- local files and the boundaries of the permitted workspace;
- the exact target window, origin, account, action, recipient, and payload;
- approval grants, chat transcripts, and tool results.

A compromise could post as the user, follow or connect to the wrong person, send private content, read or alter files, consume API credit, or exfiltrate authenticated data.

## Entry paths and required controls

| Entry path | Main threat | Required control |
|---|---|---|
| Page world of any loaded site | A hostile site calls a privileged host command or feeds instructions that become authority. | Put the drawer in its own WebView with a **separate `WebKitUserContentManager`** and an app-owned custom-scheme origin. Never add privileged commands to `zbHost`. Register only the drawer bridge, only for the app-owned top frame/world, and validate origin, frame, method schema, message size, session, and capability natively on every call. The drawer must not navigate to remote content or execute remote scripts; use a restrictive CSP and render model text as inert text, not trusted HTML. |
| Related browsing popup | A popup inherits the opener's manager or uses shared process state to reach drawer authority. | The drawer must never be constructed with `webkit_web_view_new_with_related_view` and must not share a content manager with any browsing view. Disable drawer-created popups; open approved external links as ordinary browsing windows with the ordinary browsing manager. No drawer capability may be stored on a shared manager, DOM node, `window`, cookie, or profile storage. |
| Any iframe, including cross-origin | A subframe invokes the handler or overlays approval UI. | Inject/register for the top frame only and reject callbacks without the app-owned top-frame provenance. Do not host remote iframes in the drawer. Keep confirmation UI in trusted app chrome/drawer UI that browsing pages cannot cover, script, or imitate. |
| Authenticated automation socket client | A same-user process reuses the automation token to prompt the agent, approve a tool, inspect the API key, or target the drawer. | Keep the socket and drawer capability namespaces separate. A valid automation token grants only the existing automation API. Do not list or resolve the drawer as a `window_id`; do not expose chat, key, or approval methods on that socket. Any future remote-chat surface needs a separate, default-off capability and explicit user enablement. This does not reduce the existing fact that a token holder can already automate logged-in browsing windows. |
| Drawer JavaScript | XSS or stale/replayed messages turn the drawer renderer into a confused deputy. | Mint capabilities in native code, bind them to one drawer instance, session, method class, and selected window, and keep the bearer value outside page-visible state where possible. Expire and revoke grants on reload, crash, navigation, window close, session end, or target change. Reject unknown fields, replayed request IDs, and out-of-order approval responses. |
| Model, prompt, page-derived text, or tool output | Direct or indirect prompt injection asks for broader tools or claims that the user approved an action. | Treat all model decisions as requests. Start the Agent SDK with built-in tools disabled (`tools: []`) and expose only narrow, schema-validated custom tools. Do not use `bypassPermissions`, broad wildcard allowlists, or auto-approval for mutations. Page text and tool output can provide data but never capabilities or approval. Enforce policy after model output, in the native broker. |
| Automation tool acting on a logged-in site | Wrong-window or wrong-person action; a retry duplicates a side effect. | Bind every tool call to an explicit stable `window_id`, current origin/account context, exact operation, target, and payload. Revalidate immediately before dispatch. Use the existing `dry_run` result as a preview where available, but never as approval. Invalidate approval if navigation, document identity, selected account, target, or payload changes. After an ambiguous or partly dispatched mutation, do not retry without a fresh user decision. |
| Filesystem tool | Path traversal, symlink escape, secret-file reads, or unreviewed writes/deletes. | Deny by default. Give each session an explicit canonical root and separate read/write capabilities. Resolve and re-check paths after symlinks, reject special files, and keep shell/process execution unavailable unless separately designed. File writes, deletes, moves, and execution require the same trusted confirmation discipline as browser writes. |
| API-key path | The key leaks through WebKit child environments, DOM/storage, prompts, tool results, logs, telemetry, errors, or transcripts. | Store the key in the OS credential service (Secret Service/libsecret on Linux), not in the browser profile, cookies, `localStorage`, chat history, command line, or repository. Retrieve it in native/agent-host code and inject it only into the Agent SDK provider transport or that subprocess's private environment/file descriptor; do not put it in the browser process environment inherited by WebKit children. Redact it and derived auth headers at every logging/telemetry/error boundary. A plaintext fallback, if one is ever accepted, must be explicit, outside the profile, exclusively created mode 0600, and never read into the model context. |

## Approval invariant

Tool permission and user intent are different checks. Read-only tools may receive a revocable, session-scoped capability after the user enables them. Every committing browser action—such as Post, Send, Follow, Connect, Like, Comment, story Next, raw click/type that can commit, cookie mutation—or filesystem write must stop at a trusted confirmation point.

The confirmation must show the action, selected window/site/account, target or recipient, and the exact payload (or a clear digest plus preview). Its grant is single-use, short-lived, and bound to that normalized tuple. It cannot approve a different payload, another window, a later retry, or a sequence of actions. Cancel and timeout dispatch nothing and consume neither approval nor pacing. This preserves today's per-action approval rule; `dry_run` (`docs/how-to-automate.md:571-610`, `src/flow_steps.zig:132-179`) supplies useful preview evidence but is not a substitute for consent.

No credential—provider key, cookie, session token, automation token, authorization header, or key-store material—is ever included in a user/model message, system prompt, tool argument/result, transcript, or model-visible error. The broker uses credentials out of band and returns the minimum redacted result.

## Residual risks

- A process running as the user that holds the existing automation token is already authorized to drive browsing pages. Drawer separation prevents that token from gaining *additional* agent/key authority; it cannot make that existing automation boundary safe from a malicious same-user process.
- The model can still propose harmful actions and page content can still influence it. Correctness therefore depends on native, deterministic policy and an approval UI the model and page cannot control.
- A compromised native process can access all in-process authority. Process sandboxing and least-privilege Agent SDK hosting should be a later defense-in-depth layer, not a replacement for the controls above.

## Failing-first tests required by the TDD plan

1. **Hostile-content reachability:** load an attacker top-level page, same-origin iframe, cross-origin iframe, and related popup. Each attempts every drawer message-handler name and privileged command. All are absent or denied, while the app-owned drawer top frame alone can complete a harmless capability-checked ping.
2. **Origin/world/capability enforcement:** from the drawer, vary origin, frame, world, session, method, selected `window_id`, expiry, request ID, and capability. Wrong, expired, replayed, or cross-method grants are rejected before any SDK/tool call; a valid one succeeds once.
3. **Socket separation:** authenticate with the real automation token, then attempt to enumerate/target the drawer and invoke prompt, permission, session, or key operations. The drawer is absent and every drawer operation is unavailable. A drawer capability is likewise invalid as socket authentication.
4. **Indirect-injection denial:** return page/tool text that instructs the model to reveal secrets, enable a tool, or approve Post/Follow/Connect. Even if the model emits the requested tool call, the native broker records zero committing events until the trusted user UI approves it.
5. **Exact per-action confirmation:** dry-run a social action, approve one exact `(tool, window, origin/account, target, payload)` tuple, then mutate each field, replay the approval, cancel it, and simulate an ambiguous post-dispatch failure. Only the original tuple commits once; variants and retries dispatch nothing and do not consume pacing.
6. **Credential non-disclosure:** use canary API key, cookie, authorization header, and automation token values. Assert none appears in drawer JavaScript/DOM/storage, WebKit child environments, model input, system prompt, tool data, transcript, logs, telemetry, crash text, or errors; only the isolated provider transport receives the API credential.
7. **Filesystem confinement:** try `..`, absolute paths, symlink swaps, special files, and write/delete/execute without a matching grant. All fail closed outside the canonical root and before I/O; an approved regular-file operation inside the root succeeds exactly once.
8. **Lifecycle and target invalidation:** navigate/crash/close the selected browsing window and reload/crash the drawer between preview, approval, and dispatch. Capabilities and approvals are revoked, no stale action reaches a replacement document/window, and browsing popups never acquire the replacement drawer session.
