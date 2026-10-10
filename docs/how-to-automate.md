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

- Every `page.*` and `dom.*` command has a deadline, `timeout_ms`, which
  defaults to 30000. The deadline also bounds the page call itself, so keep
  it to at least a few hundred milliseconds. `timeout_ms: 0` still makes
  exactly one attempt, but leaves the page call almost no time, so it
  usually fails with `action_timeout`.
- Other namespaces have their own timing: `cookies.*` calls take up to 10 s
  (`cookies.import` up to 30 s for the whole file); `x.*`, `linkedin.*`
  and `instagram.*` flows run their steps under one 120 s budget; `social.pause` waits for its
  `duration_ms`; `social.login_check`, `social.rate_status`,
  `social.set_pacing` and `telemetry.query` answer at once.
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
| `page.screenshot` | `fullPage?`, `timeout_ms?` | `{data, width, height}`: `data` is a base64 PNG; a backend without screenshots answers -32603, a PNG over 16 MiB -32603 with `data.reason = "screenshot_too_large"`; a capture that ends past `timeout_ms` -32009 `screenshot_deadline` |

### DOM

| Method | Params | Result |
|---|---|---|
| `dom.query` | `selector`, `timeout_ms?`, `strict?` (false) | `{elements:[{id, tag, text, bbox}]}` |
| `dom.click` | `selector`, `options?: {force?, trial?, timeout_ms?, strict?, input?}` | `{ok:true}` |
| `dom.fill` | `selector`, `value`, `options?` | `{ok:true}` (replaces the content) |
| `dom.type` | `selector`, `text`, `delay_ms?`, `options?` (with `input?`) | `{ok:true}` (types character by character) |
| `dom.press` | `key`, `selector?`, `modifiers?` (`Shift`, `Control`, `Alt`, `Meta`), `timeout_ms?`, `options?: {input?}` | `{ok:true}` |
| `dom.selectOption` | `selector`, exactly one of `value`, `label`, `index`, `timeout_ms?` | `{value}` |
| `dom.getText` | `selector`, `timeout_ms?`, `strict?` | `{text}` |
| `dom.getAttribute` | `selector`, `name`, `timeout_ms?`, `strict?` | `{value}` (null if absent) |
| `dom.waitFor` | `selector`, `state?` (`attached`, `visible`, `hidden`, `detached`), `timeout_ms?`, `strict?` | `{ok:true}` |
| `dom.setInputFiles` | `selector` (an `<input type=file>`), `paths` (absolute file paths), `options?: {timeout_ms?, strict?}` | `{multiple, changed}` |
| `dom.hover` | `selector`, `options?: {input?, humanize?, timeout_ms?, strict?}` | `{}` (synthetic) or `{ok:true}` (native) |
| `dom.scroll` | exactly one of `selector` or `x`/`y` (CSS px; a missing one is 0), `options?: {input?, timeout_ms?, strict?}` | `{scrollX, scrollY}` |

- `force: true` skips the actionability checks; `trial: true` runs the
  checks without acting.
- `dom.press` with no selector sends the key to the focused element. Enter in
  a form field submits the form; Tab and Shift+Tab move focus.
- `dom.selectOption` works on native `<select>` elements and on ARIA
  comboboxes and listboxes. A missing option is retried, then fails with
  `element_not_found` and `data.reason = "no_option"`.
- `dom.setInputFiles` clicks the file input and answers the browser's own
  file chooser with `paths` (GTK backend only; others answer -32011
  `unsupported`). Hidden file inputs are fine. Each path must be an
  absolute, readable regular file, otherwise -32602 with
  `data.reason = "bad_file"` and nothing is clicked. More than one path
  needs an input with `multiple`. If the files were chosen but the page did
  not confirm in time, the answer is -32009 `files_unconfirmed`: they were
  applied once, so do not send the command again. `changed` is false when
  the input fired no `change` event (choosing the same files again).
- `dom.hover` with synthetic input (the default) only dispatches pointer
  and mouse events: CSS `:hover` rules do not apply. With
  `input: "native"` the real pointer moves onto the element (`humanize`:
  along a curved, paced path), so `:hover` menus and tooltips open.
- `dom.scroll` with a selector brings the element's centre into the view;
  with `x`/`y` it scrolls the page by that much. With `input: "native"` it
  uses real wheel events at the centre of the view and answers only once
  scrolling has finished, so the next command sees the final offsets. A
  native scroll to a selector tries three wheels, then fails with -32009
  `scroll_not_reached` (for example when an inner scroller under the
  centre takes the wheel). If the page navigates after a wheel, it stops
  with -32001 `document_changed` and never scrolls the new page.

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

### LinkedIn and Instagram

| Method | Params | Result |
|---|---|---|
| `linkedin.visit` | `profileUrl` | `{ok:true}` |
| `linkedin.connect` | `profileUrl`, `note?` (cut to 300 characters), `timeout_ms?` | `{ok:true}` once the profile shows the invitation as pending |
| `linkedin.follow` | `profileUrl` | `{ok:true}` once it shows Following |
| `linkedin.message` | `text`, and exactly one of `conversationUrl`, `profileUrl`, `timeout_ms?` | `{ok:true}` |
| `linkedin.like` | `postUrl` | `{ok:true}` once the Like is pressed |
| `linkedin.comment` | `postUrl`, `text`, `timeout_ms?` | `{ok:true}` |
| `linkedin.search` | `query`, `searchType?` (`people`, `companies`, `jobs`, `content`, `all`) | `{ok:true, url, resultCount}` |
| `linkedin.extract` | `profileUrl` | `{name, headline, location}` (read-only; null when absent) |
| `linkedin.selfcheck` | — | `{<selector name>: count, ...}` on the current page |
| `instagram.follow` | `profileUrl` | `{ok:true}` once it shows Following or Requested |
| `instagram.like` | `postUrl` | `{ok:true}` once it shows Unlike |
| `instagram.comment` | `postUrl`, `text`, `timeout_ms?` | `{ok:true}` |
| `instagram.dm` | `username`, `text`, `timeout_ms?` | `{ok:true}` (profile, Message, send) |
| `instagram.story_view` | `username` | `{ok:true, framesViewed}` (each frame ~1.5 s, Next until the viewer closes) |
| `instagram.selfcheck` | — | `{<selector name>: count, ...}` on the current page |

- Each call is one command, like `x.*`: other page commands wait until it
  has finished, and the whole flow has 120 s
  (`linkedin_flow_deadline` / `instagram_flow_deadline`). The flows that
  type text take `timeout_ms` (1 to 600000) for long texts.
- Logged in means the site's session cookie is in the profile (`li_at` for
  LinkedIn, `sessionid` for Instagram). Without it the call fails with
  -32011 `logged_out` before anything is opened. After opening the page the
  flow also checks the page shows a signed-in account; a sign-in page is
  -32011 `logged_out` too. Use `--profile-dir` and log in, or import
  cookies. `selfcheck` needs no session.
- URLs must be on `https://www.linkedin.com/` or `https://www.instagram.com/`
  (exactly that host; no other host, port or user info): otherwise -32602.
- Typed text (notes, messages, comments) goes in character by character,
  like `dom.type`.
- Actions share the social pacing: a random 3-8 s pause before each and at
  most 100 a day (`social.set_pacing`, `social.rate_status`; only
  successful actions count, actions in progress hold their place). At the
  cap: -32010 `social_daily_cap`. `linkedin.extract` and the `selfcheck`
  calls do not count and do not pause.
- The selectors live in one table at the top of `src/linkedin.zig` and
  `src/instagram.zig`; run the `selfcheck` on a logged-in page to see
  which still match.
- Testing only: `ZIGBROWSER_SOCIAL_FIXTURE_ORIGIN=http://127.0.0.1:<port>`
  in the browser's environment lets both sites' flows run against local
  fixture pages on that origin. Requests cannot change it.

### X (x.com)

| Method | Params | Result |
|---|---|---|
| `x.post` | `text` (1-280 characters), `compose_url?`, `options?: {input?, humanize?}`, `timeout_ms?` | `{ok:true}` once X shows its confirmation |
| `x.schedule_post` | `text`, `date` (`YYYY-MM-DD`), `time` (`HH:MM`, 24-hour), `compose_url?`, `options?`, `timeout_ms?` | `{ok:true, scheduledFor:"YYYY-MM-DDTHH:MM"}` |
| `x.login_check` | — | `{loggedIn, platform:"x"}` (composer on the current page; does not navigate) |
| `x.selfcheck` | — | `{<selector name>: count, ...}` for every entry of the X selector table on the current page (read-only, not paced) |

- Each flow is one command: it opens the composer (`https://x.com/compose/post`
  unless `compose_url` names another page, e.g. a test fixture), clears any
  restored draft, types the text, picks the Post button that is actually
  clickable, clicks it and waits for X's confirmation. Other page commands
  wait until the whole flow has finished.
- Use a logged-in profile (`--profile-dir`, or import cookies). On a
  logged-out page the flow stops with -32011 and `data.reason =
  "logged_out"`, and nothing is typed.
- `options: {input: "native", humanize: true}` makes the composer click,
  the typing, the Post click and the schedule clicks real (trusted,
  human-paced) input, with the rules of [native input](#native-and-synthetic-input).
- At most 50 posts and scheduled posts per UTC day; the next one fails with
  -32010 and `data.reason = "x_daily_cap"` without touching the page. Only
  successful posts count.
- The whole flow has 120 s unless `timeout_ms` says otherwise (1 to
  600000). With `humanize` and no `timeout_ms`, the budget is sized from
  the typing schedule (120 s plus the slowest possible human typing of the
  text plus 10 s for the clicks, at most 600 s), so a full 280-character
  humanized post fits. When the budget runs out the flow stops with -32009
  and `data.reason = "x_flow_deadline"`. With no Post button at all after 10 s:
  -32001 and `data.reason = "x_post_button_missing"`.
- Selectors live in one table at the top of `src/x.zig`; update it when X
  changes its markup. `x.selfcheck` on a logged-in x.com page shows which
  entries still match (a 0 for `composer` or both `post_button.*` means the
  table needs updating; `login_link` and `post_success` are normally 0).

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

- The element is focused. `dom.type` moves the caret to the end and inserts
  there; `dom.fill` selects the whole content and replaces it.
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

By default `dom.*` input is **synthetic**: zigBrowser's script dispatches DOM
events inside the page. They behave like real input for nearly all sites,
but `event.isTrusted` is `false`. A site that ignores untrusted events will
not react.

`options: {input: "native"}` on `dom.click`, `dom.type`, `dom.press`,
`dom.hover` and `dom.scroll` sends real pointer, key and wheel events instead (`isTrusted: true`; Linux/GTK
build only, elsewhere -32011 with `data.reason = "unsupported"`):

- The target is found and checked like a synthetic action (retried until the
  deadline), then the events go to its centre. `dom.type` and `dom.press`
  focus it first (caret at the end); there is no extra click.
- `trial: true` only checks the target. `force: true` is not allowed with
  native input (-32602): a real click on a covered element would hit the
  cover.
- Native `dom.press` keys: `Enter`, `Tab`, `Escape`, `Backspace`, `Delete`,
  `Insert`, `ArrowLeft`, `ArrowRight`, `ArrowUp`, `ArrowDown`, `Home`, `End`,
  `PageUp`, `PageDown`, `Space`, `Shift`, `Control`, `Alt`, `Meta`, `F1`-`F12`,
  or exactly one character. Anything else is -32602.
- Input is bound to the page it was aimed at: if the page navigates away
  before anything is sent, the target is found again; once input was sent
  nothing is repeated.
- A `dom.type` that stops part-way (deadline, or the page navigated, e.g. a
  newline submitted a form) reports `data.reason = "partial_input"` and
  `data.sent_chars`: that many characters were typed and the rest were not.
  Do not retype the whole text.
- `options: {input: "native", humanize: true}` adds human-like timing:
  `dom.click` and `dom.hover` move the pointer along a curved path (from
  where the last native move or click left it, or from a random point
  80-240 px away), and a click pauses before clicking; `dom.type` waits 80-200 ms between
  characters and 300-600 ms before a space; `dom.press` waits once before
  the key. The whole schedule is planned first: if it does not fit the
  deadline the command fails with -32009 and `data.reason =
  "humanize_budget"` before any input (raise `timeout_ms`). `humanize`
  needs native input and cannot be combined with `delay_ms` (-32602). If
  the page navigates after the pointer started moving, the command stops
  with -32001 `document_changed` and does not click the new page.

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
| -32601 | Method not found | Unknown method |
| -32602 | Invalid params | Missing, unknown or wrong-typed params; `data.reason` explains file problems for `cookies.import` |
| -32603 | Internal error | Page script exception, malformed page answer, unsupported method |
| -32000 | Authentication failed | Missing or wrong `auth` token |
| -32001 | element_not_found | No match (see `data.reason`: `strict_zero`, `strict_multiple`, `no_match`, `no_option`, `timeout`, `malformed_selector`, `document_changed`, `x_post_button_missing`) |
| -32002 | element_not_visible | Matched but hidden or zero-size |
| -32003 | element_not_stable | Matched but still moving |
| -32004 | element_obscured | Another element covers the click point |
| -32005 | element_disabled | Matched but disabled |
| -32006 | element_not_editable | Fill/type target is not editable |
| -32007 | navigation_timeout | Navigation did not finish before the deadline |
| -32008 | navigation_failed | The load failed |
| -32009 | action_timeout | Deadline passed (`data.last_error` names the last actionability failure) |
| -32010 | platform_rate_limited | Pacing limit reached (`x_daily_cap` for `x.*`, `social_daily_cap` for `linkedin.*`/`instagram.*`) |
| -32011 | session_invalid | No page or cookie store is available; `logged_out` for `x.*`, `linkedin.*`, `instagram.*`; `unsupported` when the build has no native input |
| -32012 | cancelled | The browser stopped while the command was queued or running |

Errors -32001 to -32012 carry `data.trace_id` and `data.command_id`; the SDKs
raise them as `AutomationError` with those fields.

## Result

Your program drives the live page through the socket, keeps logins in a
profile directory, and can explain any failure with `telemetry.query`.
