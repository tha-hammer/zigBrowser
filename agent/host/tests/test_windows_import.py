"""WS7.5 [L] (UNREGISTERED red): no zb_agent_host module imports a POSIX-only module at top level.

On Windows the helper's Python package must at least IMPORT: `--agent-setup`, the launcher and the
chat/login helpers all import these modules, and an UNGUARDED top-level `import fcntl`/`pty`/`termios`/
`resource` (POSIX-only; absent on Windows) crashes the import before any platform guard can run.

This is a static AST check — deterministic and free of the false positives a runtime "simulate Windows on
Linux" would hit (forcing sys.platform="win32" breaks asyncio's proactor imports `_overlapped`/`_winapi`,
which DO exist on real Windows, and the Agent SDK is absent from a bare interpreter). It flags only a
POSIX-only import that sits DIRECTLY at module scope (an import nested under `if sys.platform != "win32":`,
a `try/except ImportError`, or inside a function is fine — that is exactly the green).

RED today (confirmed): `seccomp.py` (`import fcntl`), `hook_run.py` (`import fcntl`), `login.py`
(`import fcntl`/`pty`/`termios`). GREEN is guarding those imports (and keeping the POSIX
`os.fork`/`os.execv` paths unreachable on Windows) in those modules — another agent's lane, tracked as a
bead; this file is the executable spec. Mutant: re-add an unconditional top-level `import fcntl` ⇒ red.

Intentionally NOT registered in build.zig until green. Run alone:
  cd agent/host/tests && python3 test_windows_import.py -v
"""
import ast
import pathlib
import unittest

HOST_DIR = pathlib.Path(__file__).resolve().parents[1]           # agent/host
PKG = HOST_DIR / "zb_agent_host"

# Modules the CPython standard library provides only on POSIX; importing one at top level aborts the import
# on Windows. (grp/pwd join the plan's fcntl/pty/termios/resource — all POSIX-only.)
POSIX_ONLY = {"fcntl", "pty", "termios", "resource", "grp", "pwd"}


def _top_level_posix_imports(path: pathlib.Path):
    """POSIX-only modules imported DIRECTLY at module scope (not under if/try or inside a function)."""
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    hits = []
    for node in tree.body:  # only module-scope statements; nested imports live in their parent's body
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name.split(".")[0] in POSIX_ONLY:
                    hits.append((alias.name, node.lineno))
        elif isinstance(node, ast.ImportFrom):
            if node.module and node.module.split(".")[0] in POSIX_ONLY:
                hits.append((node.module, node.lineno))
    return hits


class WindowsImportTest(unittest.TestCase):
    def test_no_module_imports_posix_only_at_top_level(self):
        failures = {}
        for p in sorted(PKG.glob("*.py")):
            if p.stem in ("__init__", "__main__"):
                continue
            hits = _top_level_posix_imports(p)
            if hits:
                failures[p.name] = hits
        self.assertEqual(failures, {}, "modules with an unguarded top-level POSIX-only import:\n" +
                         "\n".join(f"  {m}: {h}" for m, h in failures.items()))


if __name__ == "__main__":
    unittest.main()
