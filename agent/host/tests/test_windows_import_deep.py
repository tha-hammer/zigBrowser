"""WS7.5, deepened (RoseCat 6324 on bb0b4b3; Windows plan WS7.5): zb_agent_host imports on Windows.

1. A static scan of everything that runs at import time, in every module of the package
   (recursively, __init__ and __main__ included): module bodies and the bodies of nested
   if/elif/else, for, while, with, try and class statements, but not function or lambda bodies.
   A POSIX-only module imported there is a failure unless it sits under exactly
   `if sys.platform != "win32":` (or in the else of `if sys.platform == "win32":`), or inside a
   `try` one of whose handlers catches ImportError or ModuleNotFoundError. `if True:`,
   `while True:`, `if sys.platform == "linux":` and `except RuntimeError:` do not count.
   The scanner is tested on small sources first, so a weak oracle cannot pass.
2. The plan's controlled import: in a child of the agent-host Python, the standard-library and
   SDK modules the package imports are loaded first under the real platform (several pick a
   backend at import time: asyncio, subprocess, ctypes...), then `sys.platform` becomes "win32",
   every POSIX-only module is removed from sys.modules and blocked by a meta-path finder,
   os.fork, os.forkpty, os.exec* and os.spawn*p are deleted, and every zb_agent_host module is
   imported afresh. None may fail.
Run the module alone, as the gate does."""

import ast
import json
import os
import pathlib
import subprocess
import sys
import textwrap
import unittest

HOST_DIR = pathlib.Path(__file__).resolve().parents[1]           # agent/host
PKG = HOST_DIR / "zb_agent_host"

# CPython modules that exist only on POSIX (absent from the Windows standard library).
POSIX_ONLY = {"fcntl", "pty", "termios", "tty", "resource", "grp", "pwd", "spwd", "syslog", "posix",
              "crypt", "nis", "_posixsubprocess", "_posixshmem"}
GONE_FROM_OS = ("fork", "forkpty", "execv", "execve", "execvp", "execvpe", "execl", "execle", "execlp",
                "execlpe", "spawnvp", "spawnvpe", "spawnlp", "spawnlpe")


def _platform_guard(test) -> str | None:
    """'posix' for exactly `sys.platform != "win32"`, 'win32' for `sys.platform == "win32"`."""
    if not (isinstance(test, ast.Compare) and len(test.ops) == 1 and len(test.comparators) == 1):
        return None
    left, right = test.left, test.comparators[0]
    if not (isinstance(left, ast.Attribute) and left.attr == "platform" and isinstance(left.value, ast.Name)
            and left.value.id == "sys" and isinstance(right, ast.Constant) and right.value == "win32"):
        return None
    return {ast.NotEq: "posix", ast.Eq: "win32"}.get(type(test.ops[0]))


def _catches_import_error(handlers) -> bool:
    names = []
    for h in handlers:
        t = h.type
        for e in (t.elts if isinstance(t, ast.Tuple) else [t]):
            if isinstance(e, ast.Name):
                names.append(e.id)
    return any(n in ("ImportError", "ModuleNotFoundError") for n in names)


def import_time_posix_imports(source: str, filename: str = "<src>"):
    """(module, line) for each POSIX-only import that runs at import time and is not guarded."""
    hits = []

    def visit(stmts):
        for node in stmts:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                continue  # runs only when called
            if isinstance(node, ast.Import):
                hits.extend((a.name, node.lineno) for a in node.names if a.name.split(".")[0] in POSIX_ONLY)
            elif isinstance(node, ast.ImportFrom):
                if node.level == 0 and node.module and node.module.split(".")[0] in POSIX_ONLY:
                    hits.append((node.module, node.lineno))
            elif isinstance(node, ast.If):
                guard = _platform_guard(node.test)
                if guard != "posix":
                    visit(node.body)
                if guard != "win32":
                    visit(node.orelse)
            elif isinstance(node, ast.Try) or (hasattr(ast, "TryStar") and isinstance(node, ast.TryStar)):
                if not _catches_import_error(node.handlers):
                    visit(node.body)
                for h in node.handlers:
                    visit(h.body)
                visit(node.orelse)
                visit(node.finalbody)
            elif isinstance(node, (ast.For, ast.AsyncFor, ast.While)):
                visit(node.body)
                visit(node.orelse)
            elif isinstance(node, (ast.With, ast.AsyncWith, ast.ClassDef)):
                visit(node.body)
            elif hasattr(ast, "Match") and isinstance(node, ast.Match):
                for case in node.cases:
                    visit(case.body)

    visit(ast.parse(source, filename=filename).body)
    return hits


def package_modules():
    for p in sorted(PKG.rglob("*.py")):
        rel = p.relative_to(HOST_DIR).with_suffix("")
        parts = list(rel.parts)
        if parts[-1] == "__init__":
            parts = parts[:-1]
        yield p, ".".join(parts)


class ScannerSelfTest(unittest.TestCase):
    """RoseCat 6324: the oracle must see imports that run on Windows, wherever they sit."""

    FLAGGED = {
        "plain": "import fcntl\n",
        "aliased": "import fcntl as f\n",
        "listed": "import os, termios\n",
        "from": "from pty import fork\n",
        "dotted": "import posix.path\n",
        "if-true": "if True:\n    import fcntl\n",
        "while-true": "while True:\n    import pty\n    break\n",
        "for": "for _ in [1]:\n    import tty\n",
        "with": "import contextlib\nwith contextlib.suppress(Exception):\n    import resource\n",
        "class-body": "class C:\n    import grp\n",
        "wrong-except": "try:\n    import termios\nexcept RuntimeError:\n    pass\n",
        "else-of-try": "try:\n    pass\nexcept ImportError:\n    pass\nelse:\n    import pwd\n",
        "linux-guard": "import sys\nif sys.platform == 'linux':\n    import fcntl\n",
        "win32-branch": "import sys\nif sys.platform == 'win32':\n    import syslog\n",
        "inverted-else": "import sys\nif sys.platform != 'win32':\n    pass\nelse:\n    import fcntl\n",
        "elif": "import sys\nif sys.platform == 'darwin':\n    pass\nelif True:\n    import fcntl\n",
        "nested-if": "import sys\nif sys.platform != 'win32':\n    pass\nif 1:\n    if 1:\n        import spwd\n",
    }
    CLEAN = {
        "guarded": "import sys\nif sys.platform != 'win32':\n    import fcntl\n    import pty, termios\n",
        "else-of-win32": "import sys\nif sys.platform == 'win32':\n    pass\nelse:\n    import fcntl\n",
        "try-importerror": "try:\n    import fcntl\nexcept ImportError:\n    fcntl = None\n",
        "try-modulenotfound": "try:\n    import pty\nexcept (ValueError, ModuleNotFoundError):\n    pty = None\n",
        "in-function": "def f():\n    import fcntl\n    return fcntl\n",
        "in-method": "class C:\n    def m(self):\n        import termios\n",
        "relative": "from . import pty\n",
        "not-posix": "import os, json, socket\n",
    }

    def test_flags_every_import_that_runs_on_windows(self):
        missed = [name for name, src in self.FLAGGED.items() if not import_time_posix_imports(src)]
        self.assertEqual(missed, [])

    def test_does_not_flag_the_exact_guards(self):
        wrong = {name: import_time_posix_imports(src) for name, src in self.CLEAN.items()}
        self.assertEqual({k: v for k, v in wrong.items() if v}, {})


class DeepScan(unittest.TestCase):
    def test_every_module_including_init_and_main(self):
        modules = dict((name, p) for p, name in package_modules())
        self.assertIn("zb_agent_host", modules)            # __init__.py
        self.assertIn("zb_agent_host.__main__", modules)
        failures = {}
        for p, name in package_modules():
            hits = import_time_posix_imports(p.read_text(encoding="utf-8"), str(p))
            if hits:
                failures[name] = hits
        self.assertEqual(failures, {})


CHILD = r'''
import ast, importlib, json, os, pathlib, sys
host, pkg_names, posix_only, gone = sys.argv[1], json.loads(sys.argv[2]), set(json.loads(sys.argv[3])), json.loads(sys.argv[4])
sys.path.insert(0, host)
# 1. what the package imports from outside it, loaded under the real platform
outside = set()
for p in pathlib.Path(host, "zb_agent_host").rglob("*.py"):
    for node in ast.walk(ast.parse(p.read_text(encoding="utf-8"))):
        if isinstance(node, ast.Import):
            outside.update(a.name for a in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            outside.add(node.module)
preloaded = []
for name in sorted(outside):
    if name.split(".")[0] in posix_only or name.split(".")[0] == "zb_agent_host":
        continue
    try:
        importlib.import_module(name)
        preloaded.append(name)
    except Exception:
        pass
# 2. Windows-shaped from here on
for name in list(sys.modules):
    if name.split(".")[0] in posix_only:
        del sys.modules[name]
class Blocked:
    def find_spec(self, name, path=None, target=None):
        if name.split(".")[0] in posix_only:
            raise ModuleNotFoundError(f"No module named {name!r} (Windows)", name=name)
        return None
sys.meta_path.insert(0, Blocked())
for attr in gone:
    if hasattr(os, attr):
        delattr(os, attr)
sys.platform = "win32"
# 3. every zb_agent_host module, afresh
failures = {}
for name in pkg_names:
    try:
        importlib.import_module(name)
    except BaseException as e:
        failures[name] = f"{type(e).__name__}: {e}"
print(json.dumps({"failures": failures, "preloaded": len(preloaded), "imported": len(pkg_names)}))
'''


class ControlledWindowsImport(unittest.TestCase):
    def test_every_module_imports_with_win32_and_posix_blocked(self):
        python = os.environ.get("ZB_AGENT_HOST_PYTHON", sys.executable)
        names = [name for _, name in package_modules()]
        done = subprocess.run([python, "-I", "-c", CHILD, str(HOST_DIR), json.dumps(names),
                               json.dumps(sorted(POSIX_ONLY)), json.dumps(GONE_FROM_OS)],
                              capture_output=True, text=True, timeout=120,
                              env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"})
        self.assertEqual(done.returncode, 0, done.stderr[-2000:])
        report = json.loads(done.stdout.strip().splitlines()[-1])
        self.assertEqual(report["imported"], len(names))
        self.assertGreater(report["preloaded"], 10)
        self.assertEqual(report["failures"], {})


if __name__ == "__main__":
    unittest.main()
