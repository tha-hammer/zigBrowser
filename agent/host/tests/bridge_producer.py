"""S7.0.3 (chat-drawer plan section 10, S7, rev 16.20.30): the producer half of the producer
test. The real Bridge, with a provider at prompt 7, makes one browser tool call; the real
Emitter writes its frame to stdout, and tests/agent_bridge_frame_test.zig judges that line
with the app's real validator. The build runs this and hands its stdout to that test."""

import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from zb_agent_host.bridge import Bridge  # noqa: E402
from zb_agent_host.frames import Emitter  # noqa: E402


class Tap:
    """stdout, and the frames written to it."""

    def __init__(self):
        self.lines = []

    def write(self, text):
        self.lines.extend(line for line in text.splitlines() if line)
        sys.stdout.write(text)

    def flush(self):
        sys.stdout.flush()


async def main():
    tap = Tap()
    bridge = Bridge(Emitter(tap), "s-1-1", 5.0, prompt=lambda: 7)
    task = asyncio.ensure_future(bridge.call("get_text", {"selector": "#greeting"}))
    while not tap.lines and not task.done():
        await asyncio.sleep(0.01)
    frame = json.loads(tap.lines[-1])
    bridge.resolve({"type": "tool_result", "session": "s-1-1", "id": frame["id"], "ok": True,
                    "content": [{"type": "text", "text": "Hello from page 1"}]})
    await asyncio.wait_for(task, 5)


if __name__ == "__main__":
    asyncio.run(main())
