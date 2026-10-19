#!/usr/bin/env python3
"""Off-Mac unit test for the MS1.1 component census (plan rev 6; RoseCat 5968).

The census in mac_universal_test.py runs on the Mac against a real bundle, but its
LOGIC — "every bundled Mach-O must be fat, every required role present, a declared
resource present, and an empty inventory or empty bundle fails closed" — is a pure
function, so it is pinned here with fixtures (no Mac, no build, no display needed).

The load-bearing case is the MUTANT RoseCat requires: omit one required component
(or ship one single-arch) and the census MUST fail. A census that passed with only
the browser fat is exactly the false-green this guards against.
"""
import unittest

import mac_universal_test as mu

BOTH = mu.BOTH
INVENTORY = {
    "components": [
        {"role": "browser", "match": "zigBrowser"},
        {"role": "python-runtime", "match": "python3"},
        {"role": "claude-cli", "match": "claude"},
        {"role": "helper-launcher", "match": "zb-claude"},
    ],
    "resources": [{"role": "agent-runtime-manifest", "path": "lib/zigbrowser/agent-host/runtime.json"}],
}

# A complete, all-fat bundle (the green shape): every required role as a fat Mach-O.
COMPLETE = {
    "bin/zigBrowser": set(BOTH),
    "lib/zigbrowser/agent-host/venv/bin/python3": set(BOTH),
    "lib/zigbrowser/agent-host/venv/lib/site-packages/claude_agent_sdk/_bundled/claude": set(BOTH),
    "lib/zigbrowser/agent-host/venv/bin/zb-claude": set(BOTH),
}
ALL_RESOURCES_PRESENT = lambda rel: True  # noqa: E731


def census(macho, inventory=INVENTORY, resource_present=ALL_RESOURCES_PRESENT):
    c = mu.Checks()
    mu.component_census(macho, inventory, resource_present, c)
    return c


class CensusTest(unittest.TestCase):
    def test_complete_all_fat_passes(self):
        c = census(COMPLETE)
        self.assertEqual(c.failures, [], "a complete, all-fat bundle must pass the census")
        self.assertGreater(c.ran, 0)

    def test_omitting_a_required_component_fails(self):
        # MUTANT (RoseCat 5968): drop the Claude CLI; only zigBrowser+python+launcher remain.
        mutant = {k: v for k, v in COMPLETE.items() if "claude" not in k.rsplit("/", 1)[-1]}
        c = census(mutant)
        self.assertTrue(any("claude-cli" in f for f in c.failures),
                        f"omitting the claude-cli component must fail the census; got {c.failures}")

    def test_one_single_arch_component_fails(self):
        # An unlisted/mislabelled single-arch binary must be caught by the whole-bundle scan.
        mutant = dict(COMPLETE)
        mutant["lib/zigbrowser/agent-host/venv/bin/python3"] = {"x86_64"}
        c = census(mutant)
        self.assertTrue(any("not fat" in f and "python3" in f for f in c.failures),
                        f"a single-arch component must fail the census; got {c.failures}")

    def test_empty_bundle_fails_closed(self):
        c = census({})
        self.assertTrue(any("no Mach-O" in f for f in c.failures),
                        "an empty bundle scan must fail closed, never pass")

    def test_missing_resource_fails(self):
        c = census(COMPLETE, resource_present=lambda rel: False)
        self.assertTrue(any("agent-runtime-manifest" in f for f in c.failures),
                        "a missing declared resource must fail the census")

    def test_empty_inventory_is_rejected_at_load(self):
        import json
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "empty.json"
            p.write_text(json.dumps({"components": [], "resources": []}))
            with self.assertRaises(mu.FailClosed):
                mu.load_inventory(p)


if __name__ == "__main__":
    unittest.main()
