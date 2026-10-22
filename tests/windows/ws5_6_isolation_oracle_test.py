"""WS5.6 drawer socket-isolation RED (UNREGISTERED, wired into no zig build step).

The existing WS5.6 oracle asserts isolation against a HARD-CODED `exposed` list, so it cannot catch a
real `drawer.*` automation method being added to production. Bind EXPECTED_ISOLATION to the ACTUAL
production registry instead: the socket surface exposes exactly `src/automation.zig`'s
`phase1_command_verbs`, and any method not in it falls through to the JSON-RPC not-found path
(-32601) — which is exactly what EXPECTED_ISOLATION requires for every `socket.drawer.*`.

Red now: `production_automation_verbs` does not exist yet. Green adds it (parsing the real registry),
adds a registered oracle that reachable_drawer_methods(real verbs) == [] and that each
EXPECTED_ISOLATION socket method is absent from the registry (→ -32601) with a planted-drawer mutant,
and removes this throwaway file.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import win_drawer_behaviors_test as whb  # noqa: E402


class Ws56IsolationOracleRed(unittest.TestCase):
    def test_production_registry_exposes_no_drawer_method(self):
        verbs = whb.production_automation_verbs()
        self.assertTrue(verbs, "the production automation verb registry must be read, not empty")
        self.assertEqual(whb.reachable_drawer_methods(verbs), [],
                         "no production automation method may mention the drawer")

    def test_expected_isolation_socket_methods_are_not_found(self):
        verbs = whb.production_automation_verbs()
        for key, code in whb.EXPECTED_ISOLATION.items():
            if key.startswith("socket.drawer."):
                method = key[len("socket."):]  # e.g. "drawer.state"
                self.assertNotIn(method, verbs, f"{method} must be absent from the registry so it is -32601")
                self.assertEqual(code, -32601, f"{key} must expect method-not-found")


if __name__ == "__main__":
    unittest.main()
