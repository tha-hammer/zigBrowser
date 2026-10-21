"""The MS6 hard-gate driver (plan rev 18.1): runs every tests/mac/hard_gate/case_*.py under the staged runtime.

usage: hard_gate_driver.py <cases dir>

For each case_*.py (sorted) it loads the module, gives run(h) a fresh Harness and its own scratch directory, and
prints "SCRATCH\\t<NAME>\\t<path>", the case's own check lines, then "PASS\\t<NAME>" or "FAIL\\t<label>\\t<why>". The
last line is "PASS\\tms6-hard-gate\\t<n> cases" (exit 0) or "FAIL\\tms6-hard-gate\\t<why>" (exit 1). Fail closed: a
failed check, a raise, no check at all, a missing NAME or run, a duplicate NAME, a scratch left behind, and an empty
cases dir are each a FAIL."""
import importlib.util
import os
import re
import shutil
import sys
import tempfile
import traceback

sys.dont_write_bytecode = True  # never write into the cases dir (on a Mac it is the staged tree)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import Harness  # noqa: E402


def load(path):
    name = os.path.splitext(os.path.basename(path))[0]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(argv):
    if len(argv) != 1 or not os.path.isdir(argv[0]):
        print("FAIL\tms6-hard-gate\tusage: hard_gate_driver.py <cases dir>")
        return 1
    files = sorted(f for f in os.listdir(argv[0]) if re.fullmatch(r"case_[A-Za-z0-9_]+\.py", f))
    if not files:
        print("FAIL\tms6-hard-gate\tno cases")
        return 1
    root = tempfile.mkdtemp(prefix="zb-hardgate-run-")
    names, passed, failed = set(), 0, 0
    try:
        for f in files:
            modname = f[:-3]
            try:
                module = load(os.path.join(argv[0], f))
            except Exception as exc:  # noqa: BLE001 - a case that cannot load fails, it never vanishes
                print(f"FAIL\t{modname}\tdoes not load: {exc!r}")
                failed += 1
                continue
            name, run = getattr(module, "NAME", None), getattr(module, "run", None)
            if not isinstance(name, str) or not name:
                print(f"FAIL\t{modname}\tno NAME")
                failed += 1
                continue
            if not callable(run):
                print(f"FAIL\t{name}\tno run(h)")
                failed += 1
                continue
            if name in names:
                print(f"FAIL\t{name}\tduplicate NAME")
                failed += 1
                continue
            names.add(name)
            scratch = os.path.join(root, f"{len(names):02d}-{re.sub(r'[^A-Za-z0-9._-]', '_', name)}")
            os.mkdir(scratch, 0o700)
            print(f"SCRATCH\t{name}\t{scratch}", flush=True)
            h = Harness(scratch)
            error = None
            try:
                run(h)
            except Exception:  # noqa: BLE001 - a raise is a FAIL with its traceback's last line
                error = traceback.format_exc().strip().splitlines()[-1]
            finally:
                h.close()
                shutil.rmtree(scratch, ignore_errors=True)
            if error is not None:
                why = f"raised: {error}"
            elif h.failures:
                why = f"{len(h.failures)} check(s) failed: {h.failures[0]}"
            elif h.checks == 0:
                why = "no check() at all"
            elif os.path.lexists(scratch):
                why = "its scratch could not be removed"
            else:
                why = None
            if why is None:
                print(f"PASS\t{name}")
                passed += 1
            else:
                print(f"FAIL\t{name}\t{why}")
                failed += 1
    finally:
        shutil.rmtree(root, ignore_errors=True)
    if failed or not passed:
        print(f"FAIL\tms6-hard-gate\t{failed} failed, {passed} passed")
        return 1
    print(f"PASS\tms6-hard-gate\t{passed} cases")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
