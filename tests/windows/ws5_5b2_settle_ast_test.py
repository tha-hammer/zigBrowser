"""WS5.5b-2 finding #2 proof (UNREGISTERED). RoseCat 35ff63f: the four WINDOWS-seam behaviour methods must
settle on the TERMINAL `live` row, so the harness waits for the clean-shutdown row the shim's primary WM_CLOSE
now produces (9132e93) instead of being torn down at the first `open`.

This is an AST proof, NOT a substring/.count scan (RoseCat proved source substrings leak): each method is
parsed, and every `ast.keyword` named ZB_SETTLE_KINDS reaching a call in that method is collected. A method
passes iff it has EXACTLY ONE such keyword and its value is the constant 'live'. Consequences, each a durable
row below: a value only in a COMMENT contributes no keyword node (caught); a DUPLICATE keyword across two calls
makes the count 2 (caught); the WRONG value ('open'/'fold') is one node but not 'live' (caught); a MISSING
keyword is zero nodes (caught). Red until the four methods each add one real ZB_SETTLE_KINDS='live'.
"""
import ast
import pathlib
import unittest

BEH = pathlib.Path(__file__).resolve().parent / "win_drawer_behaviors_test.py"

# The four WINDOWS-seam (ZIGBROWSER_AGENT_DRAWER_WINDOWS) methods whose terminal row is the global `live` count.
METHODS = (
    "test_ws5_5_live_count_peak_then_zero",
    "test_ws5_5b2_closing_one_extra_drops_the_live_count_by_exactly_one",
    "test_ws5_5b2_extra_fail_panel_drives_partial_cleanup",
    "test_ws5_5b2_extra_fail_icon_drives_partial_cleanup",
)


def settle_kind_values(node):
    """The value of every `ZB_SETTLE_KINDS=<...>` keyword argument at any call within `node`.

    A plain-constant value becomes its string; a non-constant (name/expr) becomes a sentinel object so the
    'exactly one constant "live"' predicate still rejects it. Comment text is invisible to the AST, so a decoy
    in a comment contributes nothing."""
    values = []
    for n in ast.walk(node):
        if isinstance(n, ast.keyword) and n.arg == "ZB_SETTLE_KINDS":
            values.append(n.value.value if isinstance(n.value, ast.Constant) else object())
    return values


def settles_on_live(node):
    vals = settle_kind_values(node)
    return len(vals) == 1 and vals[0] == "live"


def method_node(tree, name):
    for n in ast.walk(tree):
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    raise AssertionError(f"method {name} not found")


def _one(src_body):
    """Parse a one-method source and return its FunctionDef (for the synthetic mutants)."""
    return method_node(ast.parse(src_body), "m")


class Ws55b2SettleAstTest(unittest.TestCase):
    def setUp(self):
        self.tree = ast.parse(BEH.read_text(encoding="utf-8"))

    def test_each_windows_seam_method_settles_on_live(self):
        for name in METHODS:
            with self.subTest(method=name):
                self.assertTrue(settles_on_live(method_node(self.tree, name)),
                                f"{name} must set exactly one real ZB_SETTLE_KINDS='live' at its _env/_run_drawer call")

    def test_predicate_is_not_vacuous(self):
        # the real, correct shape
        self.assertTrue(settles_on_live(_one(
            "def m(self):\n    self._run_drawer(extra_env=self._env(ZIGBROWSER_AGENT_DRAWER_WINDOWS='2', ZB_SETTLE_KINDS='live'))\n")))
        # a value only in a COMMENT is not an AST keyword -> zero nodes -> rejected
        self.assertFalse(settles_on_live(_one(
            "def m(self):\n    # ZB_SETTLE_KINDS='live'\n    self._run_drawer(extra_env=self._env(ZIGBROWSER_AGENT_DRAWER_WINDOWS='2'))\n")),
            "a commented ZB_SETTLE_KINDS must not count")
        # a DUPLICATE keyword across two calls -> two nodes -> rejected
        self.assertFalse(settles_on_live(_one(
            "def m(self):\n    e = self._env(ZB_SETTLE_KINDS='live')\n    self._run_drawer(extra_env=e, ZB_SETTLE_KINDS='live')\n")),
            "a duplicated ZB_SETTLE_KINDS must be caught")
        # the WRONG value -> one node, not 'live' -> rejected
        self.assertFalse(settles_on_live(_one(
            "def m(self):\n    self._run_drawer(extra_env=self._env(ZB_SETTLE_KINDS='open'))\n")),
            "a non-'live' settle kind must be caught")
        # a NON-constant value (a variable) -> rejected (cannot prove it is 'live')
        self.assertFalse(settles_on_live(_one(
            "def m(self):\n    k = 'live'\n    self._run_drawer(extra_env=self._env(ZB_SETTLE_KINDS=k))\n")),
            "a non-constant settle value must be caught")
        # MISSING entirely -> zero nodes -> rejected
        self.assertFalse(settles_on_live(_one(
            "def m(self):\n    self._run_drawer(extra_env=self._env(ZIGBROWSER_AGENT_DRAWER_WINDOWS='2'))\n")),
            "a missing ZB_SETTLE_KINDS must be caught")


if __name__ == "__main__":
    unittest.main()
