"""WS7.2 [L] — RED-FIRST for the Windows runtime pin contract (plan line 1661).

The bundled runtime pins an EXACT x64 Python build and the Agent SDK wheel by sha256 in the runtime manifest; setup
refuses an unpinned or mismatched artifact. This [L] test is OFFLINE with FAKE in-memory artifacts — no downloads,
no pip, no installs: it feeds a manifest {name: sha256} and an artifacts {name: bytes} map to the pure verifier.

UNREGISTERED, signal-free, no VM, no Macs. Only agent/host/tests/ touched (not zb_agent_host/), so no ms5 inventory
change. RED now: `setup.verify_pins` / `setup.PinError` absent (AttributeError). The green adds the verifier.

MUTANTS (committed as rows): an unpinned artifact (the "unpinned pip install"), a sha256 mismatch, and a missing
required pin must each be REFUSED.
"""

import hashlib
import unittest

import support  # noqa: F401  (puts agent/host on sys.path)

from zb_agent_host import setup

PY_X64 = b"python-build-standalone x64 install_only bytes (fake)"
WHEEL = b"claude_agent_sdk-*.whl bytes with bundled claude.exe (fake)"


def _sha(b):
    return hashlib.sha256(b).hexdigest()


def _manifest():
    return {"python-x64": _sha(PY_X64), "claude_agent_sdk.whl": _sha(WHEEL)}


def _artifacts():
    return {"python-x64": PY_X64, "claude_agent_sdk.whl": WHEEL}


class RuntimePinContract(unittest.TestCase):
    def test_matching_pinned_artifacts_verify(self):
        setup.verify_pins(_manifest(), _artifacts())  # exact x64 python + SDK wheel, sha256 pinned -> no raise

    def test_a_sha256_mismatch_is_refused(self):
        bad = _artifacts()
        bad["claude_agent_sdk.whl"] = b"a tampered / different wheel"
        with self.assertRaises(setup.PinError):
            setup.verify_pins(_manifest(), bad)

    def test_an_unpinned_artifact_is_refused(self):
        # the unpinned pip-install mutant: an artifact with no manifest pin slipped in and must be refused.
        extra = _artifacts()
        extra["unpinned_dep.whl"] = b"installed by an unpinned pip, no sha256 pin"
        with self.assertRaises(setup.PinError):
            setup.verify_pins(_manifest(), extra)

    def test_a_missing_required_pin_is_refused(self):
        # the manifest MUST pin both the x64 python build and the SDK wheel.
        with self.assertRaises(setup.PinError):
            setup.verify_pins({"python-x64": _sha(PY_X64)}, {"python-x64": PY_X64})  # wheel pin missing
        with self.assertRaises(setup.PinError):
            setup.verify_pins({"claude_agent_sdk.whl": _sha(WHEEL)}, {"claude_agent_sdk.whl": WHEEL})  # python pin missing


if __name__ == "__main__":
    unittest.main()
