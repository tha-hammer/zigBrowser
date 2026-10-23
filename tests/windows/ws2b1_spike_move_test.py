#!/usr/bin/env python3
"""The WS2b.1 spike's move row measures its target back in the viewport and its hover trust row is non-vacuous
(NavyCanyon 0fc5f8b; a hostless TRIPWIRE, the real proof is the next approved Win11 matrix run).

The Win11 leg at 661ef67 failed "move: a trusted mousemove reaches the hover target": the spike's 600 px wheel row
leaves #menu (document y 40..80) above the viewport, and the spike moved to that negative point; its trust row
`hovers.every(...)` was also true for an empty log.

This takes the two JavaScript bodies the spike sends, kMoveTarget and kHoverTrust, out of
tests/windows/ws2b1_input_spike.c and runs them in node against a fake page whose #menu sits at document y 40..80
(scrollTo applies on the next frame, as a real scroll settles): the target must be restored and measured only after
the scroll settled, the hover log cleared, a centre outside the viewport answered "out" with its scroll/rect/viewport,
and an empty hover log must not count as trusted. It also pins, on the C side, that the move is sent only for an
"in" answer and that the driver's 37 required row names are unchanged and unique.

Run:  python3 -I tests/windows/ws2b1_spike_move_test.py
"""
import json
import pathlib
import re
import shutil
import subprocess
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
SPIKE = REPO / "tests" / "windows" / "ws2b1_input_spike.c"
DRIVER = REPO / "tests" / "e2e" / "win_trusted_input_matrix.py"
NODE = shutil.which("node") or shutil.which("nodejs")

# A fake page: window = the context; #menu is 160x40 at document (0, 40); scrollTo lands on the next frame.
HARNESS = r"""
const vm = require('vm');
const input = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const frames = [];
const ctx = {
  scrollY: input.scrollY, innerWidth: input.w, innerHeight: input.h, pending: null,
  requestAnimationFrame(cb) { frames.push(cb); },
  scrollTo(x, y) { ctx.pending = y; },
  __scroll: { hovers: input.hovers.slice(), wheels: [] },
  document: { getElementById(id) {
    if (id !== 'menu') throw new Error('unexpected id ' + id);
    return { getBoundingClientRect: () => ({ left: 0, top: input.menuTop - ctx.scrollY, width: 160, height: 40 }) };
  } },
};
ctx.window = ctx;
ctx.document.getElementById = ctx.document.getElementById.bind(ctx.document);
vm.createContext(ctx);
const run = vm.runInContext('(async function (arg) {\n' + input.body + '\n})(null)', ctx);
(function pump(n) {  // one frame per turn: a settled scroll first, then the callbacks queued for it
  if (ctx.pending !== null) { ctx.scrollY = ctx.pending; ctx.pending = null; }
  const now = frames.splice(0); now.forEach(cb => cb(n));
  if (n < 20) setImmediate(() => pump(n + 1));
})(0);
run.then(v => process.stdout.write(JSON.stringify({value: v, hovers: ctx.__scroll.hovers})),
         e => { process.stdout.write(JSON.stringify({error: String(e)})); });
"""


def c_string(source, name):
    """The concatenated C string literal `static const char <name>[] = "..." "...";` (simple escapes only)."""
    m = re.search(r"static const char " + re.escape(name) + r"\[\]\s*=\s*((?:\s*\"(?:[^\"\\]|\\.)*\")+)\s*;", source)
    if m is None:
        raise AssertionError(f"{SPIKE.name}: no `static const char {name}[] = \"...\";`")
    parts = re.findall(r"\"((?:[^\"\\]|\\.)*)\"", m.group(1))
    return "".join(re.sub(r"\\(.)", lambda e: {"n": "\n", "t": "\t"}.get(e.group(1), e.group(1)), p) for p in parts)


def run_body(body, scrollY=600, w=1024, h=768, hovers=(), menu_top=40):
    if NODE is None:
        raise AssertionError("node is not installed: this check runs the spike's JavaScript in node")
    payload = json.dumps({"body": body, "scrollY": scrollY, "w": w, "h": h, "hovers": list(hovers), "menuTop": menu_top})
    proc = subprocess.run([NODE, "-e", HARNESS], input=payload, capture_output=True, text=True, timeout=60)
    if proc.returncode != 0 or not proc.stdout:
        raise AssertionError(f"node failed rc={proc.returncode}: {proc.stderr[-2000:]}")
    out = json.loads(proc.stdout)
    if "error" in out:
        raise AssertionError(f"the spike body threw: {out['error']}")
    return out


def code_only(text):
    """`text` with C comments and string literals blanked (lengths kept)."""
    return re.sub(r'/\*.*?\*/|//[^\n]*|"(?:[^"\\\n]|\\.)*"',
                  lambda m: m.group(0)[0] + " " * (len(m.group(0)) - 2) + m.group(0)[-1]
                  if m.group(0).startswith('"') else " " * len(m.group(0)), text, flags=re.S)


class SpikeMoveTarget(unittest.TestCase):
    def setUp(self):
        self.source = SPIKE.read_text(encoding="utf-8")
        self.move = c_string(self.source, "kMoveTarget")
        self.trust = c_string(self.source, "kHoverTrust")

    def test_the_target_is_restored_into_the_viewport_after_the_wheel(self):
        out = run_body(self.move, scrollY=600, hovers=["mousemove:false"])
        self.assertTrue(out["value"].startswith("in 80,60 "), f"after the 600 px wheel: {out['value']!r}")
        self.assertIn("scrollY=0", out["value"])

    def test_the_hover_log_is_cleared_before_the_measurement(self):
        out = run_body(self.move, scrollY=600, hovers=["mousemove:false", "mouseover:false"])
        self.assertEqual(out["hovers"], [], "the stale hover events must be cleared before the move")

    def test_a_centre_outside_the_viewport_is_refused_with_diagnostics(self):
        out = run_body(self.move, scrollY=600, h=50)  # #menu centre y=60 below a 50 px viewport
        self.assertTrue(out["value"].startswith("out 80,60 "), out["value"])
        for part in ("scrollY=0", "rect=0,40,160x40", "viewport=1024x50"):
            self.assertIn(part, out["value"])
        out = run_body(self.move, scrollY=600, menu_top=-200)  # still above the viewport after the restore
        self.assertTrue(out["value"].startswith("out "), out["value"])

    def test_an_empty_hover_log_is_not_trusted(self):
        self.assertEqual(run_body(self.trust, hovers=[])["value"], "false")
        self.assertEqual(run_body(self.trust, hovers=["pointerover:true", "mousemove:true"])["value"], "true")
        self.assertEqual(run_body(self.trust, hovers=["mousemove:true", "mouseover:false"])["value"], "false")

    def test_the_move_is_sent_only_for_an_in_answer(self):
        body = code_only(self.source)
        start = body.index("static void scroll_page_checks(void)")
        fn = body[start:body.index("int main(", start)]
        evals = fn.find("eval(NULL, kMoveTarget,")
        parse = fn.find("sscanf(target, ")
        guard = fn.find("if (inside) {")
        move = fn.find("zb_native_move(")
        self.assertTrue(0 <= evals < parse < guard < move,
                        f"order eval kMoveTarget / sscanf 'in' / if (inside) / zb_native_move: {evals, parse, guard, move}")
        self.assertEqual(fn.count("zb_native_move("), 1, "exactly one move, inside the guard")
        self.assertIn('"in %lf,%lf"', self.source, "only an `in <cx>,<cy>` answer gives a move point")
        self.assertIn('eval_is(NULL, kHoverTrust, NULL, "true", "move: every hover event is trusted");', self.source)

    def test_the_required_rows_are_unchanged(self):
        names = re.findall(r'^    "([^"\n]+)",$', DRIVER.read_text(encoding="utf-8"), re.M)
        self.assertEqual(len(names), 37, f"the driver's REQUIRED rows: {len(names)}")
        self.assertEqual(len(set(names)), 37, "a REQUIRED row name appears twice")
        for name in ("move: zb_native_move returns OK", "move: a trusted mousemove reaches the hover target",
                     "move: every hover event is trusted", "move: zb_native_pointer reports the move point"):
            self.assertIn(name, names)


if __name__ == "__main__":
    unittest.main()
