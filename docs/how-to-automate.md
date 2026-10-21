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

### HTTP/1.1 by default (Linux): `ZIGBROWSER_HTTP2`

On Linux the browser sets `SOUP_FORCE_HTTP1=1` when it starts, so WebKit's
network process uses HTTP/1.1. The reason is a bug in libsoup 3.6.5
(WebKitGTK 2.52.6). Some servers send a complete HTTP/2 response and then
GOAWAY(NO_ERROR). libsoup fails that response, and the page's `fetch()`
rejects with "TypeError: Load failed". On X this breaks login with
"Something went wrong".

- To keep HTTP/2, start the browser with `ZIGBROWSER_HTTP2=1`.
- A `SOUP_FORCE_HTTP1` value you export yourself is never changed.

### Rendering by default (Linux): WebKit's policy and shared memory

On Linux the browser leaves the hardware-acceleration policy to WebKit and
sets `WEBKIT_DMABUF_RENDERER_FORCE_SHM=1` when it starts, so rendered
frames reach the window through shared memory instead of GPU buffers. The
reason: on an NVIDIA desktop (RTX 3080, driver 550.163.01, WebKitGTK
2.54.0), the old default, policy `never`, made a YouTube window show its
thumbnail and then go blank because its web process died. Such a window
now shows `"crashed"` in `page.list`. WebKit's policy with shared memory
played the same video in real time.

- To opt out, start with `--hardware-acceleration never` and/or
  `--renderer default` (or `--renderer mesa-egl`). These flags also work
  with `--screenshot`.
- A `WEBKIT_DMABUF_RENDERER_FORCE_SHM` value you export yourself is never
  changed.
- The details and measurements are in `docs/how-to-run.md` ("Rendering").

### Media Source Extensions: `--media-source on|off`

`--media-source off` (or `ZIGBROWSER_MEDIA_SOURCE=off`) hides
`window.MediaSource` from every page in every window, popups included.
It is a mitigation for a WebKitGTK 2.54.0 deadlock that froze an
Instagram window's web process. The default is `on`. While it is off,
`page.evaluate("typeof MediaSource")` answers `"undefined"`; video sites
that have a plain-video fallback use it. Details: `docs/how-to-run.md` ("Media
Source Extensions").

### The Claude Agent drawer (Linux): `--agent-drawer on|off`

Every browsing window shows the drawer's floating **S** icon by default. It
is a native GTK widget over the page, not page content: automation input
goes to the page itself, `page.screenshot` captures only the page, and the
socket has no drawer or agent methods. Nothing starts an agent until someone
presses Send in a drawer. To run without it, start the browser with
`--agent-drawer off` (or `ZIGBROWSER_AGENT_DRAWER=off`). Details:
`docs/agent-drawer.md`.

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
| `pierce=role=button[name="Send"]` | A `css=`, `role=`, `text=` or `testid=` selector that also searches open shadow roots |

The other engines never look inside a shadow root (a web component's own
DOM). `pierce=` searches the page, then every open shadow root, nested ones
included, and counts each element once. Closed shadow roots stay out of
reach, and `xpath=` cannot be pierced (`pierce=xpath=...` is malformed).
Each root is matched on its own, so a CSS combinator never crosses a shadow
boundary: `pierce=css=#host button` does not match a button inside
`#host`'s shadow root (use `pierce=css=button` or a name). `pierce=` walks
every element of the page and of each root on every try, so it is slower
than the other engines on large pages: use it only where a shadow root is
in the way.
Actions on an element inside a shadow root run the same checks as anywhere
else; an element covered inside the shadow tree still fails
`element_obscured`. Synthetic clicks, key presses and typed text are
composed events, as real input is, so listeners outside the shadow root see
them too.

A selector without a prefix is malformed (`element_not_found`,
`data.reason = "malformed_selector"`). Most commands are **strict**: exactly
one element must match, otherwise they fail with `strict_zero` or
`strict_multiple`. Pass `"strict": false` to use the first match. `dom.query`
is non-strict by default.

Strictness also applies to `dom.waitFor`, which is strict by default: if
the selector matches more than one element, it fails at once with -32001
`strict_multiple` instead of waiting. To wait for "at least one", pass
`"strict": false`.

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
  finish. `page.navigate` and `cookies.*` do not wait for it. The same holds
  for each new window (a popup) and its first page.
- A page load that you did not start with `page.navigate` or `page.reload`
  (the start page, a popup, a link the page follows) has a 15-second timer:
  - If the page has appeared by then (its load committed) but is still
    loading, nothing is stopped or closed: the page keeps loading and stays
    usable. Commands waiting for that window's first load stop waiting and
    run.
  - If nothing has arrived by then (the load never committed), the load is
    given up (`LOAD_FAIL` on the `--e2e-protocol` stdout). Its web process
    is ended only when no other window shares it, so a popup that hangs
    never takes its opener's page down.

## Methods

Options shown with `?` are optional. Results are the JSON-RPC `result`.

### Page

| Method | Params | Result |
|---|---|---|
| `page.navigate` | `url`, `timeout_ms?`, `waitUntil?`, `onBeforeUnload?` (`"fail"` default, `"accept"`, `"dismiss"`) | `{ok:true}` after the load finishes; see [Dialogs](#dialogs) for a page that asks "Leave site?" |
| `page.reload` | `timeout_ms?`, `waitUntil?` | `{ok:true}` |
| `page.url` | — | `{url}` |
| `page.title` | — | `{title}` |
| `page.evaluate` | `expression` (JavaScript expression, may be a Promise) | `{result}`; a thrown error gives -32603 with `data.name` |
| `page.screenshot` | `fullPage?`, `timeout_ms?` | `{data, width, height}`: `data` is a base64 PNG; a backend without screenshots answers -32603, a PNG over 16 MiB -32603 with `data.reason = "screenshot_too_large"`; a capture that ends past `timeout_ms` -32009 `screenshot_deadline` |
| `page.list` | — | `{pages:[{window_id, url, title, primary, opener_window_id?, crashed?}]}`: every open window, primary first. `crashed` (`"crashed"`, `"memory_limit"`, `"terminated_by_api"`): that window's web process died since its last page load. The browser also prints `zigBrowser: window <n>: web process terminated (<reason>)` on stderr. After `"crashed"` or `"memory_limit"` the window is not left blank: the same view shows a crash page, "This page crashed (<reason in words>)", with a Reload link to the last committed URL, and the browser prints `zigBrowser: window <n>: showing crash page`. While it shows, `url` is still that URL, `title` is `Page crashed` and `crashed` stays; nothing is reloaded by itself. `crashed` clears when a real page load commits (Reload, `page.navigate`). After `"terminated_by_api"` no crash page is shown: the page is gone (calls on it fail) until it loads a page again. The browser's own endings print nothing: `page.close` and a normal quit (SIGINT or SIGTERM) |
| `page.close` | `window_id` | `{ok:true}`; the primary window cannot be closed (-32602 `primary_window`) |
| `page.health` | — | `{debounce_ms, pages:[{window_id, url, responsive, unresponsive_ms, loading, dialog_open, crashed?}]}`: every open window's health, primary first. It never waits behind a window's commands. See [A frozen page](#a-frozen-page-pagehealth) |
| `page.recover` | `window_id`; to confirm also `incident`, `acknowledge` | Two calls. The first: `{incident, window_id, unresponsive_ms, at_risk:[{window_id, url}], expires_in_ms}`, nothing ended. The second, with that `incident` and `acknowledge` = every `at_risk` window: `{recovered:[{window_id, url, ended, reloaded}]}`. See [Recovering a frozen page](#recovering-a-frozen-page-pagerecover) |

Other `page.*` calls and every `dom.*` call take an optional `window_id` (from
`page.list`, e.g. `"window-2"`) to act on that window instead of the
primary one, for example a login popup the page opened. Each window has its
own command queue. A window that is gone answers -32011 with
`data.reason = "no_window"`; backends without window support answer
-32011 `unsupported`. The site flows (`x.*`, `linkedin.*`, `instagram.*`)
take `window_id` the same way: every step of the flow (and its stop-sign
scans) runs in that window, in that window's queue turn, and other windows
are not touched. The session-cookie gate, pacing and the daily caps stay
shared by all windows (one account). Without `window_id` a flow uses the
primary window, as before. In the SDKs: `window_id=` (Python) and
`{ windowId }` (Node) on every `x`, `linkedin` and `instagram` call.

Closing a popup, with `page.close` or by the page's own `window.close()`
(for example when a login popup finishes), leaves its opener's page as it
was: same URL, same page state.

### A frozen page: `page.health`

A page whose web process stops answering (a script stuck in a loop, or the
WebKitGTK 2.54.0 media deadlock that froze an Instagram window) makes every
command on that window wait until its deadline. `page.health` answers at
once anyway, like `page.list`: it never waits in a window's command queue,
and the browser's own thread answers it, not the page. The SDK clients
send one request at a time per connection, so to poll `page.health`
while another call is blocked, use a second client (a second connection).

For each window:
- `responsive`: false once WebKit has said the window's web process is
  unresponsive for `debounce_ms` (2000) without a break. WebKit itself says
  so only after the process has missed a reply for about 3 s, so a frozen
  page shows `responsive: false` about 5 s after it froze. It turns true
  again as soon as WebKit says the process answers.
- `unresponsive_ms`: how long WebKit has said unresponsive without a break,
  0 when it has not. A value below `debounce_ms` still has
  `responsive: true`.
- `loading`: a page load is in progress.
- `dialog_open`: a page dialog is open (see Dialogs below). A dialog blocks
  the page's script on purpose; it does not make the window unresponsive.
- `crashed`: as in `page.list`.

WebKit checks only while it waits for the page to take input: a click,
a key, a scroll or a mouse move, from a person or from native input
(`input: "native"`). A page that freezes while nothing is sent to it, or
that only gets script commands (`page.evaluate`, synthetic `dom.*`), keeps
`responsive: true` (measured: 20 s with no change). Those commands still
end at their deadline. Native input is sent one command at a time across
all windows, so a native command waiting on a frozen page delays native
input to other windows until its deadline.

stderr says the same for anyone watching the browser's log, once per
stretch, like the crash line:
`zigBrowser: window <n>: page not responding for <s>s` when `responsive`
turns false (`<s>` is how long WebKit has said so, the debounce or a
little more), and `zigBrowser: window <n>: page responding again` when it
turns true again. Nothing is repeated while the state holds, and a normal
quit or closing a window prints neither line.

`responsive: false` is a suspicion, not a verdict: a script that is busy
for a long time and then finishes looks the same until it finishes. Windows
that share a web process (a popup and its opener) freeze together.
`page.health` never ends or reloads anything; `page.recover` (below) does,
only when a caller confirms it.

### Recovering a frozen page: `page.recover`

`page.recover` ends a frozen window's web process and reloads its page.
Nothing does this automatically: only an explicit caller, in two calls,
and live use is for a person to approve per incident.

Ending a web process loses everything in memory in every page it runs: form
input not yet sent, the place in a video or a feed, a page's script state.
Windows created from one another (a popup and the page that opened it)
can share one web process, and WebKit does not say which do. So the
browser counts every window of the same family as at risk.

1. **Ask.** `page.recover {window_id}` works only while `page.health`
   reports that window `responsive: false` (otherwise -32602
   `not_unresponsive`; a window that is gone: -32011 `no_window`). It ends
   nothing. It answers:
   - `incident`: a token for this freeze, valid once, for
     `expires_in_ms` (60000), and only while the window stays frozen
     without a break;
   - `at_risk`: every window that may lose its page, with its URL, the
     frozen window included.
2. **Confirm.** `page.recover {window_id, incident, acknowledge}`, where
   `acknowledge` lists exactly the `at_risk` windows (any order). It is
   refused, with nothing ended, as -32602 with `data.reason`:
   - `incident_unknown`: not the current token for that window (wrong,
     expired, already used, or replaced by a newer first call);
   - `incident_over`: the window answered again, or froze anew, since;
     ask again;
   - `acknowledge_mismatch`: the list is not exactly the windows at risk
     now (`data.at_risk` lists them; a window may have opened or closed
     since).

   Confirmed, the browser:
   - refuses new commands for the windows at risk with -32014
     `recovering` until it is done (`page.health`, `page.list` and
     `dialog.*` keep working, and other windows are not affected);
   - ends their queued and running commands with -32012 `cancelled`, one
     reply each (a running one as soon as its call to the page returns);
   - ends the frozen window's web process and waits until WebKit reports it
     ended (stderr: `zigBrowser: window <n>: web process ended by
     page.recover` for each window whose page it ran);
   - forgets the native input state of those windows (no input is owed to
     the old page);
   - loads each ended window again from the URL it showed.

   It answers `recovered`: for each window at risk, `ended` (its page ran
   in that process) and `reloaded` (it is loading its URL again). A window
   in a process of its own is `ended: false` and keeps its page.

Not covered: the reloaded page starts fresh (a popup's `window.opener`
link to its opener is not restored), and a window frozen without input
pending (see above) is not reported frozen, so it cannot be recovered
this way.

### Dialogs

Page dialogs are `alert`, `confirm`, `prompt`, and the `beforeunload` "Leave site?" prompt.

zigBrowser does not answer a dialog for you. The one exception is a "Leave
site?" prompt that `page.navigate` raises with `onBeforeUnload` set to
`"accept"` or `"dismiss"` (see below). A dialog stays open, as a normal window a
person can answer, until that person or `dialog.respond` answers it.

While a dialog is open, the page's script and rendering are blocked. Commands
that need them end at once with -32013 `dialog_open` instead of waiting for
their deadline. These are every `dom.*` command, `page.evaluate`, `page.title`,
`page.navigate`, `page.reload` and `page.screenshot` (the viewport too).
Commands that do not need the page keep working: `page.url`, `page.list`,
`dialog.get` and `dialog.respond`.

This applies on the dialog's window and on every window that shares its page
process: a popup and the page that opened it block each other. It also covers
the command that made the dialog open, if the dialog opened first. No native
input is sent while a dialog is open, so none can arrive after it closes.

| Method | Params | Result |
|---|---|---|
| `dialog.get` | `window_id?` | `{open:false}` or `{open:true, type, message, window_id, default_text?}`. `type` is `alert`, `confirm`, `prompt` or `beforeunload`. `default_text` is given for prompts only. Without `window_id` you get the first open dialog, the primary window's first. |
| `dialog.respond` | `accept`, `text?`, `window_id?` | `{ok:true}`. `accept: true` is OK / Leave, `false` is Cancel / Stay. `text` answers an accepted prompt; without it, the prompt's default is used. Without `window_id` it answers the dialog `dialog.get` reports. When no dialog is open you get -32602 `no_dialog`. |

Neither call waits in the window's command queue, so they work while another
command is blocked by the dialog.

`page.navigate` on a page that asks "Leave site?" follows `onBeforeUnload`:

- `"fail"` (default): -32013 `dialog_open`, about as soon as the prompt opens.
  The prompt stays open. If someone then answers Leave, the navigation
  continues.
- `"accept"`: leave the page and finish the navigation.
- `"dismiss"`: stay on the page. You get -32008 `navigation_failed` with
  `data.reason = "beforeunload_dismissed"`.

With `"accept"` or `"dismiss"`, the navigation answers the prompt itself, at
once. The prompt is never shown, `dialog.get` does not list it, and
`dialog.respond` cannot answer it, so nothing can race that answer.

A window that already shows a dialog refuses any navigation with -32013, and
nothing loads. Closing a window dismisses its dialog.

- Python: `zb.dialog.get()`, `zb.dialog.respond(accept, text=None, window_id=None)`,
  `zb.page.navigate(url, on_before_unload="accept")`.
- Node: `zb.dialog.get({windowId})`, `zb.dialog.respond(accept, {text, windowId})`,
  `zb.page.navigate(url, {onBeforeUnload: "accept"})`.

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
  along a curved, paced path), so `:hover` menus and tooltips open. It
  answers only once the page has received the final move, so a `:hover`
  check or a read of the opened menu right after sees it.
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

The pacing state survives a restart: the day's counts (the shared
LinkedIn/Instagram cap and the separate X cap) and the `social.set_pacing`
settings are saved in `<profile dir>/automation-pacing.json` (mode 0600)
after every counted action and every `social.set_pacing`, and loaded when
the browser starts. The profile is `--profile-dir`, or the default one
under `$XDG_DATA_HOME` / `~/.local/share`. Counts reset at UTC midnight as
before (a file from an earlier day keeps its settings, not its counts). A
missing or damaged file means defaults; the browser's log says so (without
the file's contents). To reset the counts by hand, stop the browser and
delete the file.

### LinkedIn and Instagram

| Method | Params | Result |
|---|---|---|
| `linkedin.visit` | `profileUrl` | `{ok:true}` |
| `linkedin.connect` | `profileUrl`, `note?` (cut to 300 characters), `timeout_ms?`, `options?: {dry_run?}` | `{ok:true}` once the profile shows the invitation as pending (see below) |
| `linkedin.follow` | `profileUrl`, `options?` | `{ok:true}` once it shows Following (see below) |
| `linkedin.message` | `text`, and exactly one of `conversationUrl`, `profileUrl`, `timeout_ms?` | `{ok:true}` (from a profile: switched off for now, see below) |
| `linkedin.like` | `postUrl`, `options?` | `{ok:true}` once the post's reaction button no longer says "no reaction" |
| `linkedin.comment` | `postUrl`, `text`, `timeout_ms?`, `options?` | `{ok:true}` |
| `linkedin.search` | `query`, `searchType?` (`people`, `companies`, `jobs`, `content`, `all`) | `{ok:true, url, resultCount}` |
| `linkedin.extract` | `profileUrl` | `{name, headline, location}` (read-only; the name is from the page title; null when absent) |
| `linkedin.selfcheck` | — | `{<selector name>: count, ...}` on the current page |
| `instagram.follow` | `profileUrl`, `options?` | `{ok:true}` once it shows Following or Requested |
| `instagram.like` | `postUrl`, `options?` | `{ok:true}` once it shows Unlike |
| `instagram.comment` | `postUrl`, `text`, `timeout_ms?`, `options?` | `{ok:true}` |
| `instagram.dm` | `username`, `text`, `timeout_ms?` | `{ok:true}` (profile, Message, send) |
| `instagram.story_view` | `username`, `options?` | `{ok:true, framesViewed}` (each frame ~1.5 s, Next until the viewer closes or moves on to someone else; see below) |
| `instagram.selfcheck` | — | `{<selector name>: count, ...}` on the current page (`story_media` and `story_next` are 0 unless the page is a story) |

- Each call is one command, like `x.*`: other page commands wait until it
  has finished, and the whole flow has 120 s
  (`linkedin_flow_deadline` / `instagram_flow_deadline`). The flows that
  type text take `timeout_ms` (1 to 600000) for long texts. Opening the
  page may take up to 60 s on LinkedIn (a cold profile load took longer
  than 30 s on the live site) and 30 s on Instagram; past that the call
  fails with -32007 `navigation_timeout`.
- **Which step failed.** When a call fails on one of its own steps, the
  error's `data.step` names that step, with the same name the trace uses:
  the command, then the selector table entry it waited for or acted on.
  Examples: `navigate` (opening the page), `waitFor_signed_in` (the page
  never showed a signed-in account), `url` (reading where the page
  landed), `waitFor_story_media` (the story's video or picture never
  appeared), `query_story_next`, `click_follow_button`,
  `click_owner_more_button`, `waitFor_send_without_note_button` (the
  invite dialog never opened). An error the flow
  raises itself (such as `linkedin_profile_action_missing`), a platform
  stop sign (-32010), the flow deadline and a cancellation have no `step`.
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
- **LinkedIn profile actions click only the profile's own button.** A
  profile page also lists "People you may know", with buttons labelled the
  same way for other people ("Invite <Name> to connect", "Follow <Name>").
  So `linkedin.connect` and `linkedin.follow` first check the page, each
  check a -32001 `data.reason` when it fails:
  - `linkedin_not_a_profile`: the page is not a profile (`/in/...`) on
    LinkedIn, e.g. LinkedIn redirected elsewhere;
  - `linkedin_profile_name_missing`: the title ("<Name> | LinkedIn") names
    nobody.

  Then they look only inside the profile's own area, the one section of
  the page's `<main>` labelled "Primary content", which must be there
  exactly once (a page in another language has no such section, so the
  action stops). In it they click the control labelled exactly for that
  name, and only if exactly one such control is shown (LinkedIn also keeps
  a hidden copy of Connect there, and a copy outside `<main>`, which are
  never clicked). A card for another person, even one with the same name,
  is never looked at. Otherwise they fail with
  `linkedin_profile_action_missing` (never shown) or
  `linkedin_profile_action_ambiguous` (shown more than once, or the area
  more than once). Nothing is clicked in either case.
- **`linkedin.connect` also works when Connect is under the owner's "More"
  menu.** Many profiles show only Follow and More, with Connect inside the
  menu. When the owner's area has no Connect of its own, the call clicks
  the owner's one shown More button (the same rules as above: never a
  hidden copy, never a card's More), then the menu item whose text is
  exactly "Connect". The menu must be inside the owner's area or be a
  `role=menu`, and it must be the one the owner's More opened. If any
  `role=menu` or any such Connect item is already shown before More is
  clicked (another menu is open), the call fails with -32001
  `linkedin_profile_menu_already_open` and clicks nothing. When the More
  button names its menu (`aria-controls`, one id or several), only those
  elements are searched, and each must be on the page exactly once:
  otherwise Escape closes the menu and the call fails with
  `linkedin_profile_menu_unbound`. If the menu has no Connect (already connected or pending, or
  Follow only), Escape closes it and the call fails with -32001
  `linkedin_profile_connect_not_in_menu`; two Connect items fail with
  `linkedin_profile_action_ambiguous`. Not yet run live: where LinkedIn
  puts the open menu.
- **The invite dialog is awaited.** On the live site it opens 3 to 5 s
  after the Connect click, inside a shadow root (found with `pierce=`). The
  call waits up to 15 s for its "Send without a note" button (or "Add a
  note" with a note), then waits for the owner's own label "Pending, click
  to withdraw invitation sent to <Name>". `linkedin.follow` waits for
  "Following, click to unfollow <Name>" (both labels seen live on
  2026-10-11). The toast "Invitation sent to <first name>." is counted by
  `linkedin.selfcheck` (`invite_sent_toast`) but decides nothing.
- **`linkedin.message` with `profileUrl` is switched off for now.** The
  profile's own Message button has not been seen on a live profile yet,
  so it opens the profile, checks it as above, then stops before any click
  with -32001 `linkedin_profile_owner_unverified`. `linkedin.message` with
  `conversationUrl` works as before.
- **`instagram.story_view` never clicks "View story".** If a "View story"
  button stands in front of the viewer (viewing would need a click that
  marks the story seen), the call stops before it with -32001
  `instagram_story_view_needs_click`. That button has not been seen live.
- **`instagram.story_view` uses only the story viewer's own controls.**
  It opens `/stories/<username>/` and checks the page is that user's story
  on Instagram. Without active stories Instagram shows the profile
  instead: -32001 `instagram_no_story_viewer`. The viewer sits on top of
  another page, which has a "Next" of its own (as does a profile's
  highlights carousel); the call leaves everything inside that page's
  `<main>` alone and uses the viewer's Next button and its video or
  picture. That Next must be there exactly once, else -32001
  `instagram_story_next_ambiguous` and nothing is clicked. Viewing stops
  when the viewer closes or moves on to another person's stories.
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
| `x.post` | `text` (1-280 characters), `compose_url?`, `options?: {input?, humanize?, dry_run?}`, `timeout_ms?` | `{ok:true}` once X shows its confirmation |
| `x.schedule_post` | `text`, `date` (`YYYY-MM-DD`), `time` (`HH:MM`, 24-hour), `compose_url?`, `options?`, `timeout_ms?` | `{ok:true, scheduledFor:"YYYY-MM-DDTHH:MM"}` |
| `x.login_check` | — | `{loggedIn, platform:"x"}` (composer on the current page; does not navigate) |
| `x.selfcheck` | — | `{<selector name>: count, ...}` for every entry of the X selector table on the current page (read-only, not paced) |

- Each flow is one command: it opens the composer (`https://x.com/compose/post`
  unless `compose_url` names another page, e.g. a test fixture), clears any
  restored draft, types the text, picks the Post button that is actually
  clickable, clicks it and waits for X's confirmation toast. Other page
  commands wait until the whole flow has finished.
- An old toast still on screen would confirm a click that did nothing, so
  no toast may be showing when Post is clicked: an old one gets 10 s to
  go, otherwise the call fails with -32001 `x_toast_already_shown` and Post
  is never clicked. The toast that shows after the click is then new.
  X's error toasts (daily limit, "something went wrong") are reported as
  -32010 by the stop-sign scan. Not yet checked: the success toast's
  wording (it has not been recorded from the live site).
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
- When `/compose/post` opens as a dialog over the home timeline, the page
  has two composers and two schedule buttons. The flows use the dialog's.
- Leaving a compose page that holds an unsent draft makes X ask "Leave
  site?". The flow's `page.navigate` uses the default `onBeforeUnload:
  "fail"`, so the flow stops at once with -32013 `dialog_open` and the
  prompt stays open (see [Dialogs](#dialogs)). Answer it with
  `dialog.respond`, or post or discard the draft before the flow.
- Selectors live in one table at the top of `src/x.zig`; update it when X
  changes its markup. `x.selfcheck` on a logged-in x.com page shows which
  entries still match (a 0 for `composer` or both `post_button.*` means the
  table needs updating; `login_link` and `post_success` are normally 0).

### Dry run: `options: {dry_run: true}`

The ten acting flows `linkedin.connect`, `linkedin.follow`, `linkedin.like`,
`linkedin.comment`, `instagram.follow`, `instagram.like`,
`instagram.comment`, `instagram.story_view`, `x.post` and
`x.schedule_post` take `options: {dry_run: true}`. Use it to check a flow
on a real account without acting. A dry run does what the real flow does up
to the click that would act, then stops:

- It checks the params as the real call does (a comment or post text must
  still be valid), passes the session-cookie gate, opens the page, checks
  that it is signed in, and runs the challenge and limit checks (see
  below).
- It finds exactly the control the real flow would click, with the same
  checks (for LinkedIn profiles: the owner's own area and button), and runs
  a trial click on it: the browser checks that a click would land (attached,
  visible, steady, not covered, enabled), scrolls it into view, and sends no
  event.
- It sends no input at all: no click, typing, key, or option choice. A
  restored X draft stays as it is.
- It skips pacing entirely: it is not counted, does not pause, saves no
  pacing state, and is not refused at the daily cap. The check `daily_cap`
  says how many actions are left; at 0 its reason names the error the real
  call would give now (`social_daily_cap`, `x_daily_cap`).
- It fails exactly where the real flow would, with the same error (for
  example -32011 `logged_out`, -32010 `platform_rate_limited`, -32001
  `linkedin_profile_action_ambiguous`, `instagram_story_next_ambiguous`,
  `x_post_button_missing`).

It returns:

```json
{"dry_run": true, "would_act": "connect",
 "target": {"tag": "a", "label": "Invite <owner> to connect",
            "box": {"x": 56, "y": 513, "width": 97, "height": 48}},
 "checks": [{"name": "signed_in", "result": "pass"},
            {"name": "owner_area", "result": "pass", "count": 1},
            {"name": "invite_dialog", "result": "not_reached", "reason": "opens only after the Connect click"},
            {"name": "rate_limit_scans", "result": "pass", "count": 3},
            {"name": "daily_cap", "result": "note", "count": 97, "reason": "a dry run is not counted"}]}
```

- `target` is the control the real flow would click first to act. `label`
  is the label its selector requires, never text read from the page; the
  profile owner's name is written `<owner>`. `box` is where it is on the
  screen, in CSS pixels.
- In `checks`, a `result` of `pass` means the step ran and passed. `count`
  says how many matches were found. `not_reached` names a step that needs
  the real click first, with the reason. `note` is information.
  `rate_limit_scans` counts the challenge and limit checks that found
  nothing.

What each one stops at:

| Call | `target` | Not reached |
|---|---|---|
| `linkedin.connect` | the owner's Connect, or the owner's More when Connect is in its menu (`more_menu` is reported `not_reached`: opening the menu needs a click) | the menu, the invite dialog (Send without a note, Add a note, Send) |
| `linkedin.follow` | the owner's Follow | the Following state |
| `linkedin.like` | the first reaction button | the liked state |
| `linkedin.comment` | the Comment button (the comment box is counted) | typing and the submit button |
| `instagram.follow` | Follow | the Following / Requested state |
| `instagram.like` | the post's Like | the Unlike state |
| `instagram.comment` | the comment box (Post is counted; it stays disabled until there is text) | typing and Post |
| `instagram.story_view` | the viewer's Next, or `null` when there is none (one frame) | viewing frames and every Next |
| `x.post`, `x.schedule_post` | the composer (Post buttons are counted; Post stays disabled until there is text); `schedule_post` also tries the schedule button | typing, the schedule dialog, Post |

`instagram.story_view` needs care. Opening `/stories/<username>/` is the
real flow's own first step, and Instagram may count that first frame as
seen. The dry run says so with the `note` check `first_frame`. It opens
nothing else, does not wait on a frame, and never clicks Next. If a "View
story" button stands in front of the viewer, it stops before that click.
It returns `target: null` with the check `view_story_click`:
`not_reached`, reason `instagram_story_view_needs_click`. That button's
markup has not been seen live yet.

The SDKs take it as `dry_run=True` (Python) and `{ dryRun: true }` (Node).
For example, `zb.linkedin.connect(url, dry_run=True)` or
`zb.x.post(text, { dryRun: true })`.

### Challenge, CAPTCHA and limit pages

Every `x.*`, `linkedin.*` and `instagram.*` flow that navigates or acts
checks the page for the platform's own stop signs: after every navigation,
before its first action and before any action that follows an action (a
click can open a limit dialog), after a failed step, and once more before
it reports success. When one is showing, the flow stops at once with
-32010 `platform_rate_limited` and `data.signal` / `data.platform`, and
nothing more is clicked or typed. The flow does not count against the
daily cap. Signals:

| `data.signal` | What the page shows |
|---|---|
| `challenge` | A checkpoint or CAPTCHA (LinkedIn `/checkpoint/`, Instagram `/challenge/`, X's Arkose frame) |
| `authwall` | LinkedIn's sign-in wall |
| `invitation_limit` | LinkedIn's weekly invitation-limit dialog |
| `action_blocked` | Instagram's "Try Again Later" dialog |
| `toast` | X's error toast (daily post limit, "something went wrong") |
| `modal` | Another dialog about limits, restrictions or verification |

Stop and look at the page in the visible window before trying again.
`x.selfcheck`, `x.login_check` and `linkedin.selfcheck` /
`instagram.selfcheck` only read the current page and do not check.

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
| -32001 | element_not_found | No match (see `data.reason`: `strict_zero`, `strict_multiple`, `no_match`, `no_option`, `timeout`, `malformed_selector`, `document_changed`, `x_post_button_missing`, `x_toast_already_shown`, `linkedin_profile_owner_unverified`, `linkedin_not_a_profile`, `linkedin_profile_name_missing`, `linkedin_profile_action_missing`, `linkedin_profile_action_ambiguous`, `linkedin_profile_connect_not_in_menu`, `linkedin_profile_menu_already_open`, `linkedin_profile_menu_unbound`, `instagram_story_viewer_unverified`, `instagram_no_story_viewer`, `instagram_story_next_ambiguous`) |
| -32002 | element_not_visible | Matched but hidden or zero-size |
| -32003 | element_not_stable | Matched but still moving |
| -32004 | element_obscured | Another element covers the click point |
| -32005 | element_disabled | Matched but disabled |
| -32006 | element_not_editable | Fill/type target is not editable |
| -32007 | navigation_timeout | Navigation did not finish before the deadline |
| -32008 | navigation_failed | The load failed |
| -32009 | action_timeout | Deadline passed (`data.last_error` names the last actionability failure) |
| -32010 | platform_rate_limited | Pacing limit reached (`x_daily_cap` for `x.*`, `social_daily_cap` for `linkedin.*`/`instagram.*`), or the platform showed a challenge, CAPTCHA or limit page (`data.signal`, `data.platform`) |
| -32011 | session_invalid | No page or cookie store is available; `logged_out` for `x.*`, `linkedin.*`, `instagram.*`; `unsupported` when the build has no native input |
| -32012 | cancelled | The browser stopped, or `page.recover` ended the window's web process, while the command was queued or running |
| -32013 | dialog_open | A page dialog (alert, confirm, prompt, or beforeunload "Leave site?") is open on the window and blocks the command; see [Dialogs](#dialogs) |
| -32014 | recovering | `page.recover` is ending and reloading this window's web process; try again when it answers. See [Recovering a frozen page](#recovering-a-frozen-page-pagerecover) |
| -32015 | expectation_mismatch | An approved action's expectation (`options.expect`: the window's origin or load, the account, the recipient, or the element) no longer held when it ran, so nothing was sent. Not retryable: it needs a new approval. Used by the chat drawer's approvals. |

Errors -32001 to -32015 carry `data.trace_id` and `data.command_id`; the SDKs
raise them as `AutomationError` with those fields.

## Result

Your program drives the live page through the socket, keeps logins in a
profile directory, and can explain any failure with `telemetry.query`.
