# How to automate zigBrowser

This guide drives a running zigBrowser from another program over its
automation socket: navigate, type, click, read the page, and manage cookies.

## Prerequisites

- Build completed (`zig build`; see [How to build](how-to-build.md))
- A display server (`DISPLAY`, or `xvfb-run -a` for headless use)
- Optional: the Python SDK (`sdk/python`), the Node SDK (`sdk/node`) or the
  CLI (`sdk/cli`)

## Start the browser with the automation API

Pick the socket path yourself with `ZIGBROWSER_SOCKET`, so your client knows
where to connect:

```bash
export ZIGBROWSER_SOCKET="$XDG_RUNTIME_DIR/zigbrowser.sock"
DISPLAY="${DISPLAY:-:1}" ./zig-out/bin/zigBrowser "https://example.com/" \
  --automation-api --profile-dir "$HOME/.local/share/zigbrowser/work"
```

Without `ZIGBROWSER_SOCKET` the socket is created as
`$XDG_RUNTIME_DIR/zigbrowser-automation-<random hex>.sock` (`/tmp` when
`XDG_RUNTIME_DIR` is unset). The name is random, so set the variable whenever
another program needs to find it.

### Keep logins across restarts: `--profile-dir`

`--profile-dir <path>` stores cookies (`<path>/cookies.sqlite`), site data and
cache in that directory, created with mode 0700. Restart the browser with the
same directory and you are still logged in. Without the flag the profile is
`$XDG_DATA_HOME/zigbrowser/profile`, or `~/.local/share/zigbrowser/profile`.
Use one directory per account you automate.

## Connect: socket, framing and token

- **Transport:** a Unix socket, mode 0600 (only your user can connect).
- **Framing:** each message is a 4-byte big-endian length followed by that
  many bytes of UTF-8 JSON. Requests may be up to 64 KiB. One connection can
  carry any number of requests; send the next after reading the reply.
- **Protocol:** JSON-RPC 2.0. `id` must be a string, a number or null.
- **Token:** every request must carry `"auth": "<token>"`.
  - By default the browser generates a random per-session token and writes
    it next to the socket as `<socket>.token` (mode 0600, removed when the
    browser stops). The SDKs and the CLI read it automatically.
  - To choose the token yourself, pass `--automation-token-file <file>`. The
    file must not be empty. No `.token` file is written in that case, so
    clients must pass the token explicitly: `ZigBrowser(socket_path, token=...)`
    in Python, `new ZigBrowser({ socketPath, token })` in Node. The CLI has
    no token option yet; it only works with the generated sidecar token.
  - Trust boundary: other users cannot connect or read the token. Programs
    running as **your** user can, so treat any local process under your
    account as trusted, or keep the token in a file only your client reads.

A raw request, for reference:

```json
{"jsonrpc":"2.0","id":1,"method":"page.title","params":{},"auth":"<token>"}
```

### Python

```python
from zigbrowser import ZigBrowser

with ZigBrowser(socket_path="/run/user/1000/zigbrowser.sock") as zb:
    zb.page.navigate("https://example.com/login")
    zb.dom.type("css=#email", "me@example.com")
    zb.dom.press("Enter", selector="css=#email")
    zb.dom.wait_for("text=Welcome", timeout_ms=10000)
    print(zb.page.title())
```

### Node

```ts
import { ZigBrowser } from "@zigbrowser/sdk";

const zb = new ZigBrowser({ socketPath: "/run/user/1000/zigbrowser.sock" });
await zb.connect();
await zb.page.navigate("https://example.com/");
await zb.dom.click("role=button[name=\"Accept\"]");
console.log((await zb.dom.getText("css=h1")).text);
await zb.disconnect();
```

### CLI

```bash
zigbrowser-cli call page.title
zigbrowser-cli call dom.click --param selector='css=#go'
zigbrowser-cli trace <trace_id>
```

## Selectors

Every `dom.*` selector has an engine prefix:

| Selector | Matches |
|---|---|
| `css=button.primary` | CSS selector |
| `text=Sign in` | Elements whose accessible text (`aria-label`, else whitespace-normalized text) is exactly this |
| `testid=tweetButton` | `[data-testid="tweetButton"]` |
| `role=button[name="Send"]` | ARIA role (explicit or implicit) plus accessible name |
| `xpath=//main//button[1]` | XPath |

A selector without a prefix is malformed (`element_not_found`,
`data.reason = "malformed_selector"`). Most commands are **strict**: exactly
one element must match, otherwise they fail with `strict_zero` or
`strict_multiple`. Pass `"strict": false` to use the first match. `dom.query`
is non-strict by default.

## Waiting, retries and timeouts

- Every command has a deadline, `timeout_ms`, which defaults to 30000.
  The deadline also bounds the page call itself, so keep it to at least a
  few hundred milliseconds; `timeout_ms: 0` leaves the call almost no time
  and usually fails with `action_timeout`.
- If the element is missing or not yet actionable (not visible, moving,
  covered, disabled, read-only), the command is retried every 16 ms until
  the deadline. You rarely need an explicit wait before a click.
  Exception: `dom.query` is non-strict and answers immediately with whatever
  matches, possibly `{elements: []}`; use `dom.waitFor` to wait for an
  element.
- When the deadline passes: never found gives `element_not_found`; found but
  never actionable gives `action_timeout` with `data.last_error`.
- Commands for the page run one at a time, in arrival order. Time spent
  waiting behind earlier commands counts against the deadline.
- Right after start-up, page commands wait for the first page load to
  finish. `page.navigate` and `cookies.*` do not wait for it.

## Methods

Options shown with `?` are optional. Results are the JSON-RPC `result`.

### Page

| Method | Params | Result |
|---|---|---|
| `page.navigate` | `url`, `timeout_ms?`, `waitUntil?` | `{ok:true}` after the load finishes |
| `page.reload` | `timeout_ms?`, `waitUntil?` | `{ok:true}` |
| `page.url` | — | `{url}` |
| `page.title` | — | `{title}` |
| `page.evaluate` | `expression` (JavaScript expression, may be a Promise) | `{result}`; a thrown error gives -32603 with `data.name` |
| `page.screenshot` | `fullPage?` | not supported yet (-32603) |

### DOM

| Method | Params | Result |
|---|---|---|
| `dom.query` | `selector`, `timeout_ms?`, `strict?` (false) | `{elements:[{id, tag, text, bbox}]}` |
| `dom.click` | `selector`, `options?: {force?, trial?, timeout_ms?, strict?}` | `{ok:true}` |
| `dom.fill` | `selector`, `value`, `options?` | `{ok:true}` (replaces the content) |
| `dom.type` | `selector`, `text`, `delay_ms?`, `options?` | `{ok:true}` (types character by character) |
| `dom.press` | `key`, `selector?`, `modifiers?` (`Shift`, `Control`, `Alt`, `Meta`), `timeout_ms?` | `{ok:true}` |
| `dom.selectOption` | `selector`, exactly one of `value`, `label`, `index`, `timeout_ms?` | `{value}` |
| `dom.getText` | `selector`, `timeout_ms?`, `strict?` | `{text}` |
| `dom.getAttribute` | `selector`, `name`, `timeout_ms?`, `strict?` | `{value}` (null if absent) |
| `dom.waitFor` | `selector`, `state?` (`attached`, `visible`, `hidden`, `detached`), `timeout_ms?`, `strict?` | `{ok:true}` |

- `force: true` skips the actionability checks; `trial: true` runs the
  checks without acting.
- `dom.press` with no selector sends the key to the focused element. Enter in
  a form field submits the form; Tab and Shift+Tab move focus.
- `dom.selectOption` works on native `<select>` elements and on ARIA
  comboboxes and listboxes. A missing option is retried, then fails with
  `element_not_found` and `data.reason = "no_option"`.

### Cookies

| Method | Params | Result |
|---|---|---|
| `cookies.getAll` | `url?` (only cookies sent to that URL) | `{cookies:[{name, value, domain, path, expires, httpOnly, secure, sameSite?}]}` |
| `cookies.set` | `name`, `value`, `domain`, `path?` (`/`), `expires?` (Unix seconds, -1 = session), `httpOnly?`, `secure?`, `sameSite?` (`Lax`, `Strict`, `None`) | `{ok:true}` |
| `cookies.delete` | `name`, `domain?` (absent = every domain) | `{ok:true}` |
| `cookies.import` | `path`, `format` (`netscape` or `json`) | `{imported, skipped}` |

Cookies live in the active profile, so with `--profile-dir` they survive a
restart. Cookie values are never logged or written to telemetry.

### Social helpers

| Method | Params | Result |
|---|---|---|
| `social.login_check` | — | `{loggedIn, platform, username}` (LinkedIn and Instagram heuristics) |
| `social.rate_status` | — | `{remaining_actions, reset_at, daily_cap}` |
| `social.set_pacing` | `min_delay_ms?`, `max_delay_ms?`, `daily_cap?` | `{ok:true}` |
| `social.pause` | `duration_ms` | `{ok:true}` after the pause; page commands wait behind it |

`linkedin.*` and `instagram.*` wrappers exist in the SDKs but are not served
by the socket yet; they answer -32601.

### Diagnostics

| Method | Params | Result |
|---|---|---|
| `telemetry.query` | `trace_id` | `{spans:[...]}` for one of the last 128 commands (root first) |

Failed commands return `error.data.trace_id`. Pass it to `telemetry.query`
(or `zigbrowser-cli trace <trace_id>`) to see the command, its retries and
each page call. Span data never contains selectors, typed text, URL paths
or cookie values; those are hashed or reduced to lengths.

## Type into rich editors (contenteditable)

`dom.fill` and `dom.type` work on `<input>`, `<textarea>` and
`contenteditable` editors such as the X or LinkedIn composers:

- The element is focused and the caret moves to the end.
- `dom.type`: for each character the page receives `keydown`, a cancelable
  `beforeinput` (`insertText`), the inserted text, then `keyup`.
- `dom.fill`: the existing content is selected and replaced in one edit: a
  single cancelable `beforeinput` for the whole value and no key events. An
  empty value clears the editor.
- Text is inserted with the browser's own editing command, so frameworks like
  Draft.js and Lexical see a normal edit. If the page cancels `beforeinput`,
  zigBrowser inserts nothing itself and leaves the edit to the page's
  handler. This is what those editors expect.

Check the result with `dom.getText` on the editor, or on the counter or
preview the site shows.

## Native and synthetic input

All `dom.*` input is **synthetic**: zigBrowser's script dispatches DOM events
inside the page. They behave like real input for nearly all sites, but
`event.isTrusted` is `false`. A site that ignores untrusted events will not
react.

Native input (real GDK pointer and key events, `isTrusted: true`) is being
built (milestone N7) and is not exposed over the socket yet.

## Import cookies from another browser

Use this to bring a logged-in session into zigBrowser.

1. Export the cookies from your everyday browser:
   - **Netscape format** (`cookies.txt`): a browser extension such as
     "Get cookies.txt LOCALLY", or `yt-dlp --cookies-from-browser`.
   - **JSON**: an extension export such as "Cookie-Editor" (an array of
     `{name, value, domain, path, expirationDate, httpOnly, secure,
     sameSite, session}`).
2. Start zigBrowser with the profile you want the login in:
   `--automation-api --profile-dir <dir>`.
3. Import the file. The path is read by the browser process:

   ```python
   zb.cookies.import_file("/home/me/cookies.txt", "netscape")
   # {'imported': 42, 'skipped': 3}
   ```

4. Reload or navigate to the site: `zb.page.reload()`.

Import rules:

- At most 4 MiB and 5000 entries per file, and only regular files.
- Malformed entries are skipped, never imported with weaker settings. This
  covers wrong types, contradictory `session`/expiry fields, expiry after
  the year 9999, and a Netscape include-subdomains flag that disagrees with
  the domain's leading dot.
- The whole import shares one 30-second budget. If the store fails part-way,
  the error carries `data.reason = "import_partial"` with `imported` and
  `failed_index`.
- Treat the export file like a password and delete it after importing.

## Event channel (WebSocket)

Connect to the same socket with an HTTP upgrade (`GET /events`, the usual
`Upgrade: websocket` headers, and `Authorization: Bearer <token>`). Today the
channel sends one notification, `automation.ready`.

## Error codes

| Code | Name | Meaning |
|---|---|---|
| -32700 | Parse error | The frame is not JSON, or is larger than 64 KiB |
| -32600 | Invalid Request | Not JSON-RPC 2.0, or `id` is an object, array or boolean |
| -32601 | Method not found | Unknown method (including `linkedin.*`, `instagram.*`) |
| -32602 | Invalid params | Missing, unknown or wrong-typed params; `data.reason` explains file problems for `cookies.import` |
| -32603 | Internal error | Page script exception, malformed page answer, unsupported method |
| -32000 | Authentication failed | Missing or wrong `auth` token |
| -32001 | element_not_found | No match (see `data.reason`: `strict_zero`, `strict_multiple`, `no_match`, `no_option`, `timeout`, `malformed_selector`) |
| -32002 | element_not_visible | Matched but hidden or zero-size |
| -32003 | element_not_stable | Matched but still moving |
| -32004 | element_obscured | Another element covers the click point |
| -32005 | element_disabled | Matched but disabled |
| -32006 | element_not_editable | Fill/type target is not editable |
| -32007 | navigation_timeout | Navigation did not finish before the deadline |
| -32008 | navigation_failed | The load failed |
| -32009 | action_timeout | Deadline passed (`data.last_error` names the last actionability failure) |
| -32010 | platform_rate_limited | Pacing limit reached |
| -32011 | session_invalid | No page or cookie store is available |
| -32012 | cancelled | The browser stopped while the command was queued or running |

Errors -32001 to -32012 carry `data.trace_id` and `data.command_id`; the SDKs
raise them as `AutomationError` with those fields.

## Result

Your program drives the live page through the socket, keeps logins in a
profile directory, and can explain any failure with `telemetry.query`.
