"""WS5.5b-2 finding #2 proof (UNREGISTERED). RoseCat 35ff63f / 8126: the four WINDOWS-seam behaviour methods
must settle on the TERMINAL `live` row, so the harness waits for the clean-shutdown row the shim's primary
WM_CLOSE now produces (9132e93) instead of being torn down at the first `open`.

This is an AST proof, NOT a substring/.count scan (RoseCat proved source substrings leak). It BINDS the settle
to the one relevant call, not merely "a keyword somewhere under the method": a method passes iff it has exactly
ONE top-level `self._run_drawer(...)` statement (dead `if` branches and nested `def` bodies are excluded,
because only the method's DIRECT body statements are inspected), whose `extra_env=` is a `self._env(...)` call,
and that `_env` call carries exactly one `ZB_SETTLE_KINDS` keyword whose value is the constant 'live'.

Durable-row mutants below (all false greens RoseCat reproduced): the kind on an unrelated `decoy(...)` or
`self.other(...)` call, under a dead `if False`, inside an unused nested function, or passed to `_run_drawer`
itself rather than its `_env` — every one is rejected while the real `_run_drawer(extra_env=self._env())` lacks
the kind. Also rejected: two top-level `_run_drawer` calls, a wrong value, a non-constant value, and missing.
"""
import ast
import pathlib
import textwrap
import unittest

BEH = pathlib.Path(__file__).resolve().parent / "win_drawer_behaviors_test.py"

METHODS = (
    "test_ws5_5_live_count_peak_then_zero",
    "test_ws5_5b2_closing_one_extra_drops_the_live_count_by_exactly_one",
    "test_ws5_5b2_extra_fail_panel_drives_partial_cleanup",
    "test_ws5_5b2_extra_fail_icon_drives_partial_cleanup",
)


def _is_self_call(node, name):
    """node is EXACTLY `self.<name>(...)` — an attribute call whose receiver is the Name `self` (so a
    `evil._run_drawer(...)` / `evil._env(...)` on a different receiver is rejected), not merely any `.<name>`."""
    return (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == name
            and isinstance(node.func.value, ast.Name) and node.func.value.id == "self")


def live_settle_bound(method):
    """True iff the method's ONE REACHABLE top-level self._run_drawer(...) passes extra_env=self._env(... with
    exactly one ZB_SETTLE_KINDS='live' ...). Only the method's direct body statements are considered (dead
    branches and nested defs cannot contribute), both receivers must be `self`, and a self._run_drawer that
    follows a top-level return/raise is unreachable and does not count."""
    runs, terminated = [], False
    for s in method.body:
        if isinstance(s, (ast.Return, ast.Raise)):
            terminated = True  # anything after an unconditional top-level return/raise is dead
        elif isinstance(s, ast.Expr) and _is_self_call(s.value, "_run_drawer") and not terminated:
            runs.append(s.value)
    if len(runs) != 1:
        return False  # zero, unreachable, or an ambiguous second top-level _run_drawer
    env = next((kw.value for kw in runs[0].keywords if kw.arg == "extra_env"), None)
    if not _is_self_call(env, "_env"):
        return False  # extra_env must be the real self._env(...) call
    vals = [kw.value.value if isinstance(kw.value, ast.Constant) else object()
            for kw in env.keywords if kw.arg == "ZB_SETTLE_KINDS"]
    return len(vals) == 1 and vals[0] == "live"


def method_node(tree, name):
    for n in ast.walk(tree):
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    raise AssertionError(f"method {name} not found")


def _m(src):
    """Parse a synthetic `def m(self): ...` and return its FunctionDef."""
    return method_node(ast.parse(textwrap.dedent(src)), "m")


# --- synthetic method sources for the mutant rows ---
REAL = """
    def m(self):
        def body(r):
            pass
        self._run_drawer(extra_env=self._env(ZIGBROWSER_AGENT_DRAWER_WINDOWS='2', ZB_SETTLE_KINDS='live'), body=body)
"""
DECOY_CALL = """
    def m(self):
        decoy(ZB_SETTLE_KINDS='live')
        self._run_drawer(extra_env=self._env(ZIGBROWSER_AGENT_DRAWER_WINDOWS='2'), body=body)
"""
OTHER_CALL = """
    def m(self):
        self.other(ZB_SETTLE_KINDS='live')
        self._run_drawer(extra_env=self._env(), body=body)
"""
DEAD_BRANCH = """
    def m(self):
        if False:
            self._run_drawer(extra_env=self._env(ZB_SETTLE_KINDS='live'))
        self._run_drawer(extra_env=self._env(), body=body)
"""
NESTED_DEF = """
    def m(self):
        def inner():
            self._run_drawer(extra_env=self._env(ZB_SETTLE_KINDS='live'))
        self._run_drawer(extra_env=self._env(), body=body)
"""
KIND_ON_RUN_DRAWER = """
    def m(self):
        self._run_drawer(extra_env=self._env(), ZB_SETTLE_KINDS='live')
"""
TWO_RUN_DRAWER = """
    def m(self):
        self._run_drawer(extra_env=self._env(ZB_SETTLE_KINDS='live'))
        self._run_drawer(extra_env=self._env())
"""
WRONG_VALUE = """
    def m(self):
        self._run_drawer(extra_env=self._env(ZB_SETTLE_KINDS='open'))
"""
NON_CONSTANT = """
    def m(self):
        k = 'live'
        self._run_drawer(extra_env=self._env(ZB_SETTLE_KINDS=k))
"""
MISSING = """
    def m(self):
        self._run_drawer(extra_env=self._env(ZIGBROWSER_AGENT_DRAWER_WINDOWS='2'))
"""
WRONG_RECEIVER = """
    def m(self):
        evil._run_drawer(extra_env=evil._env(ZB_SETTLE_KINDS='live'))
"""
WRONG_ENV_RECEIVER = """
    def m(self):
        self._run_drawer(extra_env=evil._env(ZB_SETTLE_KINDS='live'))
"""
PRIOR_RETURN = """
    def m(self):
        return
        self._run_drawer(extra_env=self._env(ZB_SETTLE_KINDS='live'))
"""
PRIOR_RAISE = """
    def m(self):
        raise RuntimeError('x')
        self._run_drawer(extra_env=self._env(ZB_SETTLE_KINDS='live'))
"""


class Ws55b2SettleAstTest(unittest.TestCase):
    def setUp(self):
        self.tree = ast.parse(BEH.read_text(encoding="utf-8"))

    def test_each_windows_seam_method_settles_on_live(self):
        for name in METHODS:
            with self.subTest(method=name):
                self.assertTrue(live_settle_bound(method_node(self.tree, name)),
                                f"{name}'s top-level _run_drawer must pass extra_env=self._env(... ZB_SETTLE_KINDS='live' ...)")

    def test_predicate_binds_the_relevant_call_only(self):
        self.assertTrue(live_settle_bound(_m(REAL)), "the real bound shape passes")
        for label, src in (("unrelated decoy() call", DECOY_CALL), ("unrelated self.other() call", OTHER_CALL),
                           ("dead if-False branch", DEAD_BRANCH), ("unused nested def", NESTED_DEF),
                           ("kind on _run_drawer not _env", KIND_ON_RUN_DRAWER), ("two top-level _run_drawer", TWO_RUN_DRAWER),
                           ("wrong value 'open'", WRONG_VALUE), ("non-constant value", NON_CONSTANT),
                           ("missing kind", MISSING), ("wrong receiver (evil._run_drawer)", WRONG_RECEIVER),
                           ("wrong _env receiver (evil._env)", WRONG_ENV_RECEIVER),
                           ("unreachable after return", PRIOR_RETURN), ("unreachable after raise", PRIOR_RAISE)):
            with self.subTest(mutant=label):
                self.assertFalse(live_settle_bound(_m(src)), f"{label} must be rejected")


if __name__ == "__main__":
    unittest.main()
