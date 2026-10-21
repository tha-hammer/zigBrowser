"""MS5 dependency pin (the user's decision, relayed in JadeBeacon 7178; scoped by the orchestrator): the Mac app bundles
ONE fat universal2 runtime tree under python.org CPython 3.12, so on macOS cryptography is pinned to 48.0.1 for both
chips. 50.0.2 ships macOS wheels for arm64 only. Linux is NOT pinned: it keeps its own resolution.

agent/host/uv.lock must:
- record the pin in its manifest as a darwin-only constraint: cryptography==48.0.1; sys_platform == 'darwin';
- lock a cryptography 48.0.1 entry whose every resolution marker is a darwin one, carrying a macOS wheel that CPython
  3.12 loads on BOTH chips (a universal2 abi3 wheel, cp3X-abi3 with X <= 12, or abi3 x86_64 and arm64 wheels);
- keep a separate non-darwin cryptography entry, not 48.0.1: Linux is not dragged onto the Mac pin.
agent/host/pyproject.toml, the lock's source, must carry that exact constraint too (RoseCat on 15470e4), so deleting
it while a stale lock still holds the pin cannot pass.

Pure file checks, no network, no process, no signal.
Registered (build.zig: test-mac-census and the Linux test step).
Run like the gate: cd tests/e2e && python3 -X dev -m unittest -v mac_ms5_crypto_pin_test.
"""
import re
import tomllib
import unittest
from pathlib import Path

LOCK = Path(__file__).resolve().parents[2] / "agent" / "host" / "uv.lock"
PYPROJECT = LOCK.with_name("pyproject.toml")
PIN = "48.0.1"
DARWIN = "sys_platform == 'darwin'"


def wheel_tags(url):
    """(python tag, abi tag, platform tag) of a wheel URL."""
    name = url.rsplit("/", 1)[1][:-len(".whl")]
    parts = name.split("-")
    return parts[-3], parts[-2], parts[-1]


def loads_on_cp312(python_tag, abi_tag):
    m = re.fullmatch(r"cp3(\d+)", python_tag)
    return bool(m) and abi_tag == "abi3" and int(m.group(1)) <= 12


class CryptographyMacPin(unittest.TestCase):
    def setUp(self):
        with open(LOCK, "rb") as f:
            self.lock = tomllib.load(f)
        self.entries = [p for p in self.lock["package"] if p["name"] == "cryptography"]

    def mac_entry(self):
        pinned = [p for p in self.entries if p["version"] == PIN]
        self.assertEqual(len(pinned), 1, f"exactly one cryptography {PIN} entry")
        return pinned[0]

    def test_the_manifest_constrains_cryptography_on_darwin_only(self):
        constraints = self.lock.get("manifest", {}).get("constraints", [])
        self.assertIn({"name": "cryptography", "marker": DARWIN, "specifier": f"=={PIN}"}, constraints)

    def test_the_pyproject_carries_the_darwin_only_constraint(self):
        with open(PYPROJECT, "rb") as f:
            project = tomllib.load(f)
        constraints = project.get("tool", {}).get("uv", {}).get("constraint-dependencies", [])
        self.assertEqual([c for c in constraints if c.split("=")[0].split(";")[0].strip() == "cryptography"],
                         [f"cryptography=={PIN}; {DARWIN}"])
        self.assertNotIn("cryptography", " ".join(project["project"].get("dependencies", [])),
                         "a constraint, not a direct dependency")

    def test_the_48_0_1_entry_resolves_only_on_darwin(self):
        markers = self.mac_entry().get("resolution-markers", [])
        self.assertTrue(markers, "the Mac pin is a forked, marker-scoped resolution")
        self.assertTrue(all(DARWIN in m and "sys_platform != 'darwin'" not in m for m in markers), markers)

    def test_its_macos_wheel_loads_on_both_chips_under_cpython_3_12(self):
        archs = set()
        for wheel in self.mac_entry().get("wheels", []):
            py, abi, plat = wheel_tags(wheel["url"])
            if not plat.startswith("macosx_") or not loads_on_cp312(py, abi):
                continue
            for tag in plat.split("."):
                if tag.endswith("_universal2"):
                    archs |= {"x86_64", "arm64"}
                elif tag.endswith("_x86_64"):
                    archs.add("x86_64")
                elif tag.endswith("_arm64"):
                    archs.add("arm64")
        self.assertEqual(archs, {"x86_64", "arm64"}, "a CPython 3.12 macOS wheel for each chip (or one universal2)")

    def test_linux_keeps_its_own_resolution(self):
        others = [p for p in self.entries if p["version"] != PIN]
        self.assertEqual(len(others), 1, "one non-darwin cryptography entry besides the Mac pin")
        markers = others[0].get("resolution-markers", [])
        self.assertTrue(markers and all(DARWIN not in m for m in markers), markers)


if __name__ == "__main__":
    unittest.main()
