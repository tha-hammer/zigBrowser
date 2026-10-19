#!/usr/bin/env python3
"""Off-Mac unit test for the MS1.1 census + resource oracle (plan rev 6; RoseCat 5968/5974).

The census and the resource-compat oracle in mac_universal_test.py run on the Mac
against a real bundle, but their LOGIC is pure, so it is pinned here with fixtures
(no Mac, no build, no display). The load-bearing mutants RoseCat required:
  - omit a required component, or ship one single-arch -> census FAILS (5968);
  - a file `file` cannot probe -> the bundle is REJECTED, never dropped (5974.1);
  - a mismatched non-exec resource across the two arch trees -> FAILS (5974.2);
  - a same-named Mach-O in the WRONG location -> does NOT satisfy the role (5974 SHOULD).
"""
import unittest

import mac_universal_test as mu

BOTH = mu.BOTH

INVENTORY = {
    "components": [
        {"role": "browser", "path_glob": "bin/zigBrowser"},
        {"role": "python-runtime", "path_glob": "lib/zigbrowser/agent-host/venv/bin/python3"},
        {"role": "claude-cli",
         "path_glob": "lib/zigbrowser/agent-host/venv/lib/*/site-packages/claude_agent_sdk/_bundled/claude"},
        {"role": "helper-launcher", "path_glob": "lib/zigbrowser/agent-host/venv/bin/zb-claude"},
    ],
    "resources": [{"role": "agent-runtime-manifest", "path": "lib/zigbrowser/agent-host/runtime.json"}],
}

# A complete, all-fat bundle (the green shape): every required role as a fat Mach-O
# AT ITS EXACT expected location.
COMPLETE = {
    "bin/zigBrowser": set(BOTH),
    "lib/zigbrowser/agent-host/venv/bin/python3": set(BOTH),
    "lib/zigbrowser/agent-host/venv/lib/python3.9/site-packages/claude_agent_sdk/_bundled/claude": set(BOTH),
    "lib/zigbrowser/agent-host/venv/bin/zb-claude": set(BOTH),
}
ALL_PRESENT = lambda rel: True  # noqa: E731


def census(macho, inventory=INVENTORY, resource_present=ALL_PRESENT):
    c = mu.Checks()
    mu.component_census(macho, inventory, resource_present, c)
    return c


class CensusTest(unittest.TestCase):
    def test_complete_all_fat_passes(self):
        c = census(COMPLETE)
        self.assertEqual(c.failures, [], "a complete, all-fat bundle must pass the census")
        self.assertGreater(c.ran, 0)

    def test_omitting_a_required_component_fails(self):
        # MUTANT (5968): drop the Claude CLI; only browser+python+launcher remain.
        mutant = {k: v for k, v in COMPLETE.items() if "claude_agent_sdk" not in k}
        c = census(mutant)
        self.assertTrue(any("claude-cli" in f for f in c.failures),
                        f"omitting the claude-cli component must fail the census; got {c.failures}")

    def test_one_single_arch_component_fails(self):
        mutant = dict(COMPLETE)
        mutant["lib/zigbrowser/agent-host/venv/bin/python3"] = {"x86_64"}
        c = census(mutant)
        self.assertTrue(any("not fat" in f and "python3" in f for f in c.failures),
                        f"a single-arch component must fail the census; got {c.failures}")

    def test_wrong_location_decoy_does_not_satisfy_role(self):
        # SHOULD (5974): a fat Mach-O named python3 in the WRONG place must not satisfy
        # the python-runtime role; the real venv python3 is absent here.
        mutant = {k: v for k, v in COMPLETE.items()
                  if k != "lib/zigbrowser/agent-host/venv/bin/python3"}
        mutant["lib/zigbrowser/agent-host/decoy/bin/python3"] = set(BOTH)
        c = census(mutant)
        self.assertTrue(any("python-runtime" in f for f in c.failures),
                        f"a wrong-located python3 must not satisfy the role; got {c.failures}")

    def test_wrong_depth_decoy_does_not_satisfy_role(self):
        # SHOULD (5977.1): a claude binary at the WRONG DEPTH (an extra path segment)
        # must not satisfy the role; segment-wise matching rejects it even though a
        # `*`-crosses-`/` fnmatch would have accepted it.
        mutant = {k: v for k, v in COMPLETE.items() if "claude_agent_sdk" not in k}
        mutant["lib/zigbrowser/agent-host/venv/lib/python3.9/extra/site-packages/"
               "claude_agent_sdk/_bundled/claude"] = set(BOTH)
        c = census(mutant)
        self.assertTrue(any("claude-cli" in f for f in c.failures),
                        f"a wrong-depth claude must not satisfy the role; got {c.failures}")

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


class ProbeFailClosedTest(unittest.TestCase):
    """5974.1: a file that `file` cannot classify must REJECT the bundle, not drop out."""

    def test_probe_failure_rejects_the_bundle(self):
        entries = [("bin/zigBrowser", "/b/bin/zigBrowser"),
                   ("lib/weird.bin", "/b/lib/weird.bin")]

        def bad_probe(ab):
            if ab.endswith("weird.bin"):
                raise mu.FailClosed(f"could not probe file type of {ab}")
            return set(BOTH)

        with self.assertRaises(mu.FailClosed):
            mu.census_scan(entries, bad_probe)

    def test_real_probe_rejects_unreadable_file(self):
        # The production probe treats nonzero rc / stderr / 'cannot open' as fail-closed.
        class R:
            def __init__(self, rc, out, err):
                self.returncode, self.stdout, self.stderr = rc, out, err

        with self.assertRaises(mu.FailClosed):
            mu.probe_archs("/nope", run=lambda cmd: R(1, "", "cannot open `/nope' (No such file)"))
        # rc 0 but a 'cannot open' body (BSD `file` can do this) is still fail-closed.
        with self.assertRaises(mu.FailClosed):
            mu.probe_archs("/nope", run=lambda cmd: R(0, "cannot open `/nope' (Permission denied)", ""))
        # A clean non-Mach-O classification is simply skipped (None), not an error.
        self.assertIsNone(mu.probe_archs("/x", run=lambda cmd: R(0, "ASCII text", "")))

    def test_probe_timeout_fails_closed(self):
        # SHOULD (5977.2): a wedged `file` must not hang MS1.4 — a timeout is fail-closed.
        import subprocess

        def hang(cmd):
            raise subprocess.TimeoutExpired(cmd, 30)

        with self.assertRaises(mu.FailClosed):
            mu.probe_archs("/wedged", run=hang)


class ResourceCompatTest(unittest.TestCase):
    """5974.2: the pure two-tree resource oracle refuses a cross-arch mismatch before lipo."""

    REQ = INVENTORY["resources"]
    PATH = "lib/zigbrowser/agent-host/runtime.json"

    def compat(self, a, b):
        c = mu.Checks()
        mu.resource_compat(a, b, self.REQ, c)
        return c

    def test_identical_resources_pass(self):
        c = self.compat({self.PATH: "deadbeef"}, {self.PATH: "deadbeef"})
        self.assertEqual(c.failures, [], "byte-identical resources must be compatible")

    def test_mismatched_resource_fails(self):
        c = self.compat({self.PATH: "deadbeef"}, {self.PATH: "feedface"})
        self.assertTrue(any("differs across arches" in f for f in c.failures),
                        f"a mismatched resource must refuse before lipo; got {c.failures}")

    def test_resource_missing_from_one_tree_fails(self):
        c = self.compat({self.PATH: "deadbeef"}, {})
        self.assertTrue(any("missing from the second arch tree" in f for f in c.failures),
                        f"a resource present in only one arch tree must fail; got {c.failures}")


class ResourcePhaseTest(unittest.TestCase):
    """5995/6002: the empty-resource exception is a typed, shape-checked, fail-closed phase gate.
    Empty is accepted ONLY for the EXACT browser-only MS1 bundle (one component at the fixed
    browser path, no resources); the MS1 label alone is not enough (RoseCat's bypass)."""

    PATH = "lib/zigbrowser/agent-host/runtime.json"
    RES = [{"role": "agent-runtime-manifest", "path": PATH}]
    BROWSER = {"role": "browser", "path_glob": "bin/zigBrowser"}
    PY = {"role": "python-runtime", "path_glob": "lib/zigbrowser/agent-host/venv/bin/python3"}
    CLI = {"role": "claude-cli", "path_glob": "lib/.../_bundled/claude"}

    def phase(self, milestone, inventory, a=None, b=None):
        c = mu.Checks()
        mu.resource_phase(milestone, inventory, a or {}, b or {}, c)
        return c

    def inv(self, components, resources):
        return {"components": components, "resources": resources}

    def test_ms1_browser_only_empty_passes(self):
        c = self.phase("MS1", self.inv([self.BROWSER], []))
        self.assertEqual(c.failures, [], "exact browser-only MS1 with no resource must pass")
        self.assertGreater(c.ran, 0, "the gate must actually assert for MS1 (called, not skipped)")

    def test_ms5_empty_resources_fails(self):
        c = self.phase("MS5", self.inv([self.BROWSER], []))
        self.assertTrue(c.failures, "MS5 with no resource must fail closed")

    def test_unqualified_empty_fails(self):
        for milestone in ("", "unknown", "ms1"):
            c = self.phase(milestone, self.inv([self.BROWSER], []))
            self.assertTrue(c.failures, f"unqualified empty ({milestone!r}) must fail closed")

    def test_ms1_extra_component_fails(self):
        # Browser + an extra component is not the exact browser-only shape.
        c = self.phase("MS1", self.inv([self.BROWSER, self.PY], []))
        self.assertTrue(c.failures, "MS1 with an extra component must fail closed")

    def test_ms1_non_browser_component_fails(self):
        # RoseCat 6002's exact bypass: one non-browser component, empty resources, labeled MS1.
        c = self.phase("MS1", self.inv([self.PY], []))
        self.assertTrue(c.failures, "MS1 with a single non-browser component must fail closed")

    def test_ms5_shaped_empty_relabeled_ms1_fails(self):
        # An MS5-shaped manifest (python + CLI, no resources) relabeled MS1 must not pass.
        c = self.phase("MS1", self.inv([self.PY, self.CLI], []))
        self.assertTrue(c.failures, "an MS5-shaped empty manifest relabeled MS1 must fail closed")

    def test_ms5_nonempty_mismatch_still_fails(self):
        c = self.phase("MS5", self.inv([self.BROWSER, self.PY], self.RES),
                       {self.PATH: "aa"}, {self.PATH: "bb"})
        self.assertTrue(any("differs across arches" in f for f in c.failures),
                        f"a nonempty MS5 mismatch must still fail; got {c.failures}")

    def test_ms5_nonempty_identical_passes(self):
        c = self.phase("MS5", self.inv([self.BROWSER, self.PY], self.RES),
                       {self.PATH: "aa"}, {self.PATH: "aa"})
        self.assertEqual(c.failures, [], "a nonempty MS5 match must pass the phase gate")


if __name__ == "__main__":
    unittest.main()
