"""j76's production entrypoints (RoseCat 6564): every browser command that renders reaches the
native settings only through the startup's flag step, backend_flag.startup, never around it.

Read from the sources (standard library only), because on Linux every value cli.zig accepts is
supported, so a bypass is invisible from outside the binary there; the refusal itself on macOS
and Windows is their arms' e2e (MS3.2, WS3.2: `--renderer=shm is not supported on Windows`).
- src/main.zig makes no native rendering call of its own: no webkit.runScreenshot,
  webkit.applyRender, webkit.applyMediaSource or render_config.resolve; its `.open` and
  `.screenshot` arms both go to app.runWithIo.
- src/app.zig calls webkit.applyRender and webkit.applyMediaSource only in a sink's
  applyResolved, and webkit.runScreenshot only in a function that called backend_flag.startup
  before it; runOpen and runScreenshot each call backend_flag.startup.
Run alone: python3 -I tests/startup_entrypoint_test.py"""

import re
import sys
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "src"
NATIVE = ("webkit.runScreenshot(", "webkit.applyRender(", "webkit.applyMediaSource(")


def code(text: str) -> str:
    """The source without // comments (string literals here never hold `//`)."""
    return "\n".join(line.split("//", 1)[0] for line in text.splitlines())


def bodies(text: str) -> dict[str, str]:
    """Every `fn name(...) ... { body }`, by brace matching (later duplicates get a suffix)."""
    out: dict[str, str] = {}
    for m in re.finditer(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", text):
        start = text.find("{", m.end())
        if start < 0:
            continue
        depth, i = 0, start
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        name = m.group(1)
        while name in out:
            name += "'"
        out[name] = text[start:i + 1]
    return out


def arm(text: str, tag: str) -> str:
    """The `.tag => ...` arm of main's command switch, up to the next arm."""
    m = re.search(r"\n\s*\." + tag + r"\b[^=\n]*=>", text)
    if m is None:
        return ""
    nxt = re.search(r"\n\s*\.[a-z_]+\b[^=\n]*=>", text[m.end():])
    return text[m.end():m.end() + (nxt.start() if nxt else len(text))]


class Entrypoints(unittest.TestCase):
    def test_main_makes_no_native_rendering_call(self):
        main = code((SRC / "main.zig").read_text())
        for call in NATIVE + ("render_config.resolve(",):
            self.assertFalse(call in main, f"src/main.zig calls {call}..) around the startup's flag step")

    def test_main_sends_open_and_screenshot_to_app(self):
        main = code((SRC / "main.zig").read_text())
        for tag in ("open", "screenshot"):
            self.assertTrue("app.runWithIo(" in arm(main, tag), f"main's .{tag} arm does not go to app.runWithIo")

    def test_app_applies_only_after_the_flag_step(self):
        app = code((SRC / "app.zig").read_text())
        fns = bodies(app)
        for name, body in fns.items():
            for call in ("webkit.applyRender(", "webkit.applyMediaSource("):
                if call in body:
                    self.assertTrue(name.startswith("applyResolved"), f"app.zig {name} calls {call}..) outside a sink")
            if "webkit.runScreenshot(" in body:
                step = body.find("backend_flag.startup(")
                self.assertTrue(0 <= step < body.find("webkit.runScreenshot("),
                                f"app.zig {name} calls webkit.runScreenshot without backend_flag.startup before it")
        for runner in ("runOpen", "runScreenshot"):
            self.assertTrue("backend_flag.startup(" in fns.get(runner, ""), f"app.zig {runner} skips backend_flag.startup")


if __name__ == "__main__":
    sys.exit(unittest.main())
