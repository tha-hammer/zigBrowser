"""S3.1 (chat-drawer plan): `--agent-setup` provisions an isolated agent home
from a SAI source. Unit and property tests of zb_agent_host.setup; the real
binary is driven by tests/e2e/agent_setup_test.py."""

import hashlib
import json
import os
import random
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parents[1]
REPO = HOST_DIR.parents[1]
sys.path.insert(0, str(HOST_DIR))

from zb_agent_host import options, setup  # noqa: E402

FIXTURE = REPO / "tests" / "fixtures" / "agent" / "sai_source"


def tree_digest(root):
    """Every path, mode, and file content under `root` (symlinks by target)."""
    h = hashlib.sha256()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(dirnames + filenames):
            p = Path(dirpath, name)
            st = p.lstat()
            h.update(f"{p.relative_to(root)}:{stat.S_IMODE(st.st_mode)}:{stat.S_IFMT(st.st_mode)}".encode())
            if p.is_symlink():
                h.update(os.readlink(p).encode())
            elif p.is_file():
                h.update(p.read_bytes())
    return h.hexdigest()


class Sandbox:
    """A temp source HOME holding the fixture as ~/.claude, a fake `bun` on its
    PATH, and a target agent home."""

    def __init__(self, tc):
        self.tmp = Path(tempfile.mkdtemp(prefix="zb-provision-"))
        tc.addCleanup(shutil.rmtree, self.tmp, True)
        self.source_home = self.tmp / "user"
        self.source = self.source_home / ".claude"
        shutil.copytree(FIXTURE, self.source, symlinks=True)
        for path in self.source.rglob("*"):
            if path.is_file() and not path.is_symlink():
                text = path.read_bytes()
                if b"@SOURCE_HOME@" in text:
                    path.write_bytes(text.replace(b"@SOURCE_HOME@", str(self.source_home).encode()))
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        bun = self.bin / "bun"
        bun.write_text("#!/bin/sh\nexit 0\n")
        bun.chmod(0o755)
        self.home = options.AgentHome(self.tmp / "data" / "agent-home")
        self.source_path = f"{self.bin}:/usr/bin:/bin"

    def provision(self, **kw):
        args = dict(home=self.home, source=self.source, source_home=self.source_home,
                    source_path=self.source_path, python="/usr/bin/python3", route=None)
        args.update(kw)
        return setup.provision(**args)


class SanitizeTest(unittest.TestCase):
    def test_removed_keys_are_gone_at_every_depth_and_others_stay(self):
        settings = json.loads((FIXTURE / "settings.json").read_text())
        clean = setup.sanitize_settings(settings)
        text = json.dumps(clean)
        for key in setup.REMOVED_KEYS:
            self.assertNotIn(f'"{key}"', text, key)
        self.assertNotIn("bypassPermissions", text)
        self.assertNotIn('"allow"', text)
        self.assertEqual(clean["model"], "fixture-model")
        self.assertEqual(clean["permissions"]["deny"], ["Read(/etc/shadow)"])
        self.assertEqual(set(clean["hooks"]), {"SessionStart", "UserPromptSubmit", "Stop"})

    def test_property_no_removed_key_survives_any_generated_tree(self):
        rng = random.Random(0x5E7_0001)
        vocab = list(setup.REMOVED_KEYS) + ["permissions", "allow", "defaultMode", "deny", "hooks", "a", "b", "model"]

        def gen(depth):
            if depth > 3 or rng.random() < 0.3:
                return rng.choice(["x", 1, True, None, "~/.claude/a", "/usr/bin/x"])
            if rng.random() < 0.3:
                return [gen(depth + 1) for _ in range(rng.randint(0, 3))]
            return {rng.choice(vocab): gen(depth + 1) for _ in range(rng.randint(0, 4))}

        def keys(node, path=()):
            if isinstance(node, dict):
                for k, v in node.items():
                    yield path + (k,)
                    yield from keys(v, path + (k,))
            elif isinstance(node, list):
                for v in node:
                    yield from keys(v, path + ("[]",))

        for _ in range(500):
            clean = setup.sanitize_settings(gen(0))
            for key_path in keys(clean):
                self.assertNotIn(key_path[-1], setup.REMOVED_KEYS, key_path)
                if key_path[-2:] in (("permissions", "allow"), ("permissions", "defaultMode")):
                    self.fail(key_path)


class RewriteTest(unittest.TestCase):
    def test_source_home_is_rewritten_allowed_roots_pass_and_others_fail_with_file_and_line(self):
        out = setup.rewrite_text("see /home/u/.claude/x and /usr/share/y\n", "/home/u", "/data/agent-home", "a.md")
        self.assertEqual(out, "see /data/agent-home/.claude/x and /usr/share/y\n")
        for ok in ("run /create_tdd_plan", "https://example.com/a/b", "/etc/ssl/certs", "/proc/self/fd/3",
                   "`${home}/.claude/hooks`", "$(pwd)/a/b",
                   "/opt/x/y", "/bin/sh -c", "/lib/x/y", "relative/a/b", "~/.claude/hooks/a"):
            self.assertEqual(setup.rewrite_text(ok, "/home/u", "/h", "a.md"), ok)
        with self.assertRaises(setup.SetupError) as cm:
            setup.rewrite_text("one\ntwo /tmp/evil/x\n", "/home/u", "/h", "dir/b.ts")
        self.assertEqual(str(cm.exception), "outside path in dir/b.ts:2")
        with self.assertRaises(setup.SetupError):
            setup.rewrite_text('{"p": "/home/other/x"}', "/home/u", "/h", "c.json")


class HookTest(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox(self)

    def test_path_hooks_and_bare_commands_resolve_inside_and_record_their_dirs(self):
        self.box.provision()
        settings = json.loads((self.box.home.claude_dir / "settings.json").read_text())
        prefix = f"{self.box.home.runtime}/bin/zb-hook-run -- "
        commands = [h["command"] for entries in settings["hooks"].values() for e in entries for h in e["hooks"]]
        self.assertEqual(len(commands), 3)
        self.assertTrue(all(c.startswith(prefix) for c in commands), commands)
        self.assertIn("~/.claude/hooks/X.hook.ts", commands[0])
        self.assertIn(f"python3 {self.box.home.root}/.claude/hooks/notify.py stop", commands[2])
        paths = json.loads((self.box.home.runtime / "path.json").read_text())
        self.assertIn(str(self.box.bin), paths)
        self.assertIn("/usr/bin", paths)

    def test_an_absolute_hook_outside_the_agent_home_is_refused_and_nothing_changes(self):
        self.box.provision()
        before = tree_digest(self.box.home.root)
        settings = json.loads((self.box.source / "settings.json").read_text())
        settings["hooks"]["Stop"][0]["hooks"].append({"type": "command", "command": "/home/u/evil.sh"})
        (self.box.source / "settings.json").write_text(json.dumps(settings))
        with self.assertRaises(setup.SetupError) as cm:
            self.box.provision()
        self.assertEqual(str(cm.exception), "hook path outside agent home: Stop/0")
        self.assertEqual(tree_digest(self.box.home.root), before)

    def test_a_hook_script_symlinked_outside_is_refused(self):
        outside = self.box.tmp / "outside.ts"
        outside.write_text("// outside\n")
        (self.box.source / "hooks" / "X.hook.ts").unlink()
        (self.box.source / "hooks" / "X.hook.ts").symlink_to(outside)
        with self.assertRaises(setup.SetupError) as cm:
            self.box.provision()
        self.assertIn("outside", str(cm.exception))
        self.assertFalse(self.box.home.root.exists())

    def test_a_non_command_hook_cannot_be_wrapped(self):
        settings = json.loads((self.box.source / "settings.json").read_text())
        settings["hooks"]["Stop"][0]["hooks"].append({"type": "prompt", "prompt": "x"})
        (self.box.source / "settings.json").write_text(json.dumps(settings))
        with self.assertRaises(setup.SetupError):
            self.box.provision()

    def test_property_every_path_like_token_in_the_provisioned_hooks_is_inside_the_agent_home(self):
        rng = random.Random(0x5E7_0002)
        for _ in range(40):
            box = Sandbox(self)
            settings = json.loads((box.source / "settings.json").read_text())
            hooks = []
            for _ in range(rng.randint(1, 4)):
                script = rng.choice(["~/.claude/hooks/X.hook.ts", f"{box.source_home}/.claude/hooks/notify.py"])
                command = rng.choice([script, f"bun {script}", f"python3 {script} --x"])
                hooks.append({"type": "command", "command": command})
            settings["hooks"] = {"Stop": [{"hooks": hooks}]}
            (box.source / "settings.json").write_text(json.dumps(settings))
            box.provision()
            final = json.loads((box.home.claude_dir / "settings.json").read_text())
            for hook in final["hooks"]["Stop"][0]["hooks"]:
                tokens = hook["command"].split()
                self.assertEqual(tokens[1], "--")
                for token in tokens[2:]:
                    if "/" in token or token.startswith("~"):
                        expanded = str(box.home.root) + token[1:] if token.startswith("~") else token
                        resolved = os.path.realpath(expanded)
                        self.assertTrue(resolved.startswith(str(box.home.root) + "/"), token)


class LayoutTest(unittest.TestCase):
    def setUp(self):
        self.box = Sandbox(self)

    def test_layout_modes_copy_exclusions_and_runtime(self):
        self.box.provision()
        root = self.box.home.root
        for sub in (".", ".claude", "workspace", "scratchpad", "secrets", "runtime"):
            self.assertEqual(stat.S_IMODE((root / sub).stat().st_mode), 0o700, sub)
        self.assertEqual((root / ".claude/CLAUDE.md").read_text().splitlines()[:3],
                         (FIXTURE / "CLAUDE.md").read_text().splitlines()[:3])
        self.assertIn(f"{root}/.claude/SAI/README.md", (root / ".claude/CLAUDE.md").read_text())
        for gone in (".credentials.json", "history.jsonl", "projects/p1", "todos/t.json", "MEMORY/notes.md"):
            self.assertFalse((root / ".claude" / gone).exists(), gone)
        self.assertTrue((root / ".claude/MEMORY").is_dir())
        for kept in ("hooks/X.hook.ts", "commands/hello.md", "skills/demo/SKILL.md", "agents/helper.md", "SAI/README.md"):
            self.assertTrue((root / ".claude" / kept).is_file(), kept)
        self.assertTrue(os.access(root / ".claude/hooks/X.hook.ts", os.X_OK))
        self.assertEqual(json.loads((root / ".claude/.claude.json").read_text()), {})
        for name in ("bin/zb-hook-run", "bin/zb-claude", "hook-env.json", "writable.json", "path.json",
                     "config-manifest.json", "host.json", "host/zb_agent_host/__main__.py"):
            self.assertTrue((root / "runtime" / name).exists(), name)
        self.assertEqual(json.loads((root / "runtime/host.json").read_text())["python"], "/usr/bin/python3")
        self.assertEqual(json.loads((root / "runtime/writable.json").read_text()),
                         ["projects", "sessions", "session-env", "todos", "statsig", "debug", "MEMORY"])
        manifest = json.loads((root / "runtime/config-manifest.json").read_text())
        self.assertIn("settings.json", manifest)
        self.assertEqual(manifest["settings.json"], hashlib.sha256((root / ".claude/settings.json").read_bytes()).hexdigest())
        self.assertTrue((root / ".zb-agent-home").is_file())
        text = "\n".join(p.read_text(errors="replace") for p in (root / ".claude").rglob("*") if p.is_file())
        for canary in ("ZB-FIXTURE-CREDENTIAL-CANARY", "ZB-FIXTURE-PROJECT-CANARY", "ZB-FIXTURE-MEMORY-CANARY",
                       "ZB-FIXTURE-HISTORY-CANARY", "zb-fixture-should-not-survive"):
            self.assertNotIn(canary, text)

    def test_a_second_run_is_idempotent_and_keeps_the_agents_own_files(self):
        self.box.provision()
        root = self.box.home.root
        (root / "workspace" / "keep.txt").write_text("mine")
        (root / ".claude" / "projects").mkdir(exist_ok=True)
        (root / ".claude" / "projects" / "t.jsonl").write_text("transcript")
        claude_before = tree_digest(root / ".claude")
        self.box.provision()
        self.assertEqual(tree_digest(root / ".claude"), claude_before)
        self.assertEqual((root / "workspace" / "keep.txt").read_text(), "mine")
        self.assertEqual(sorted(p.name for p in root.iterdir() if ".staging" in p.name), [])

    def test_a_home_holding_only_the_owner_lock_is_a_first_install(self):
        self.box.home.root.mkdir(parents=True, mode=0o700)
        (self.box.home.root / ".zb-owner.lock").write_text("")
        self.box.provision()
        self.assertTrue((self.box.home.root / ".zb-agent-home").is_file())
        self.assertTrue((self.box.home.root / ".zb-owner.lock").exists())
        self.assertTrue((self.box.home.root / ".claude" / "CLAUDE.md").is_file())

    def test_an_outside_path_in_a_copied_text_file_refuses_setup(self):
        with open(self.box.source / "SAI" / "README.md", "a") as f:
            f.write("And /srv/elsewhere/x.\n")
        with self.assertRaises(setup.SetupError) as cm:
            self.box.provision()
        self.assertEqual(str(cm.exception), "outside path in SAI/README.md:3")
        self.assertFalse(self.box.home.root.exists())


if __name__ == "__main__":
    unittest.main()
