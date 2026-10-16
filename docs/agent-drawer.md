# The Claude Agent drawer (Linux)

Every browsing window has a Claude Agent drawer: you type a message, and
Claude answers in that window (plan:
`thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md`).
It is **on by default**.

## Turning it off

```bash
./zig-out/bin/zigBrowser https://example.com --agent-drawer off
# or
ZIGBROWSER_AGENT_DRAWER=off ./zig-out/bin/zigBrowser https://example.com
```

The flag wins over the variable. A variable that is not `on` or `off` is
ignored, and stderr says so. Screenshot mode (`--screenshot`) does not take
the flag, and its window has no drawer.

## Setting it up

1. Run `zigBrowser --agent-setup` once. It builds the agent's own home under
   `$XDG_DATA_HOME/zigbrowser/agent-home` (or
   `~/.local/share/zigbrowser/agent-home`), with its own copy of the Claude
   configuration, made once by setup. The running agent never reads or
   writes your own `~/.claude`.
   Until then, Send answers "Agent runtime not set up: run zigBrowser
   --agent-setup".
2. When no token is stored, Send opens the Secrets window (the drawer's
   **Account** button opens it at any time). Paste a long-lived token from
   `claude setup-token` and click Save. It is kept in the Secret Service, or in
   a 0600 file in the agent home when you choose that.

## The icon

- Every browsing window, popups included, gets a round orange **S** icon
  floating over the page. It starts at the bottom right.
- **Click** it to open the drawer.
- **Drag** it (more than 6 px) to move it away from anything it covers.
  Clicks anywhere outside the icon still reach the page.
- **Keyboard:** Tab reaches the icon. The arrow keys move it 16 px, or 64 px
  with Shift. Enter or Space opens the drawer.
- The position is remembered in the profile (`agent-drawer.json`) and is
  where new windows and the next launch start. An unreadable file means the
  default position.

## The drawer

- It floats over the bottom of the page: the full width, and 40% of the
  height (at least 220 px, at most 70%). The page is not resized.
- From top to bottom it has a header ("Claude Agent", the status, and **-**),
  the message list, and the input row (text, Send, Stop).
- **Enter** sends the message. **Shift+Enter** starts a new line.
- The list scrolls. While you are scrolled up, new messages do not move the
  view; a "↓ New messages" button appears instead.
- **-**, **Escape** (inside the drawer) or **Ctrl+Shift+Space** fold the
  drawer back into the icon's last position. Ctrl+Shift+Space also opens it.

## The conversation

- Each window has its own conversation (its own session), popups included.
  Closing the window ends it. The agent keeps its transcripts in its own home
  (`agent-home/.claude/projects/`).
- The reply streams into one bubble that grows as it arrives. The header shows
  "Working…" while it runs.
- **Stop** is live while a reply runs. It stops the reply, which ends with
  "(stopped)", and the next message continues the same conversation.
- A message sent while a reply runs waits its turn.
- Errors are plain sentences, never the server's own text:
  - "Claude rejected the saved token. Open Account to replace it."
  - "Claude is busy; try again shortly."
  - "Agent error" for anything else.
- Every bubble and the status text can be selected with the mouse and copied
  with Ctrl+C.

## What pages can and cannot do

The icon and drawer are native GTK widgets, with no web content and no
JavaScript. Pages, iframes and popups cannot see, script or cover them, and
the automation socket has no drawer, agent or secrets methods.
