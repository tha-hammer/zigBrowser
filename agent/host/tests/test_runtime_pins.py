"""WS7.2 [L] — RED-FIRST for the Windows runtime pin contract (plan line 1661).

The bundled runtime pins an EXACT x64 Python build and the Agent SDK wheel by sha256 in the runtime manifest; setup
refuses an unpinned or mismatched artifact. This [L] test is OFFLINE with FAKE in-memory artifacts — no downloads,
no pip, no installs: it feeds a manifest {name: sha256} and an artifacts {name: bytes} map to the pure verifier.

UNREGISTERED, signal-free, no VM, no Macs. Only agent/host/tests/ touched (not zb_agent_host/), so no ms5 inventory
change. RED now: `setup.verify_pins` / `setup.PinError` absent (AttributeError). The green adds the verifier.

MUTANTS (committed as rows): an unpinned artifact (the "unpinned pip install"), a sha256 mismatch, a missing
required pin, and a DROP-COMPLETENESS mutant (a verifier that checks only the artifacts it is handed and never
requires every pinned artifact to be present) must each be REFUSED / caught.
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


def _mutant_drop_completeness(manifest, artifacts):
    """Committed DROP-COMPLETENESS mutant: it verifies every artifact it is HANDED against its pin, but never
    requires that every pinned artifact in the manifest is actually present. A complete two-pin manifest whose
    artifacts omit one pinned item therefore slips through. The real verify_pins must refuse that; this mutant
    proves the two completeness rows below exercise completeness, not just per-artifact sha."""
    for name, blob in artifacts.items():
        if name not in manifest:
            raise setup.PinError("unpinned artifact: %s" % name)
        if _sha(blob) != manifest[name]:
            raise setup.PinError("sha256 mismatch: %s" % name)


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

    def test_complete_manifest_with_only_the_python_artifact_is_refused(self):
        # the manifest pins BOTH, but the wheel artifact was never produced: the runtime is incomplete -> refuse.
        with self.assertRaises(setup.PinError):
            setup.verify_pins(_manifest(), {"python-x64": PY_X64})

    def test_complete_manifest_with_only_the_wheel_artifact_is_refused(self):
        # the manifest pins BOTH, but the python build is missing: the runtime is incomplete -> refuse.
        with self.assertRaises(setup.PinError):
            setup.verify_pins(_manifest(), {"claude_agent_sdk.whl": WHEEL})

    def test_drop_completeness_mutant_wrongly_accepts_a_missing_artifact(self):
        # The committed drop-completeness mutant: on a complete two-pin manifest whose artifacts omit one pinned
        # item, the real verify_pins REFUSES, but a verifier that drops the completeness check wrongly ACCEPTS.
        manifest = _manifest()
        python_only = {"python-x64": PY_X64}  # the wheel pin has no artifact
        with self.assertRaises(setup.PinError):
            setup.verify_pins(manifest, python_only)  # the real engine requires every pinned artifact present
        try:
            _mutant_drop_completeness(manifest, python_only)  # the mutant skips completeness -> no raise
        except setup.PinError:
            self.fail("the drop-completeness mutant must NOT raise here; otherwise it does not model the gap")


if __name__ == "__main__":
    unittest.main()
