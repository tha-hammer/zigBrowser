# The Claude Agent drawer (Linux, opt-in)

zigBrowser can show a Claude Agent drawer in each browsing window. It is
**off by default** while it is being built (plan:
`thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md`).
So far it has the icon and the drawer shell. **No agent is connected yet**:
sending a message answers "Agent not available yet".

## Turning it on

```bash
./zig-out/bin/zigBrowser https://example.com --agent-drawer on
# or
ZIGBROWSER_AGENT_DRAWER=on ./zig-out/bin/zigBrowser https://example.com
```

The flag wins over the variable. A variable that is not `on` or `off` is
ignored, and stderr says so. Screenshot mode (`--screenshot`) does not take
the flag.

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

## What pages can and cannot do

The icon and drawer are native GTK widgets, with no web content and no
JavaScript. Pages, iframes and popups cannot see, script or cover them, and
the automation socket has no drawer, agent or secrets methods.
