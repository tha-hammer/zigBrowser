"""S3.1 (chat-drawer plan): `--agent-setup` provisions an isolated agent home
from a SAI source. Unit and property tests of zb_agent_host.setup; the real
binary is driven by tests/e2e/agent_setup_test.py."""

import contextlib
import hashlib
import io
import json
import os
import random
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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
            self.assertEqual(setup.rewrite_text(ok, "/home/u", "/h", "a.md", commands={"create_tdd_plan"}), ok)
        with self.assertRaises(setup.SetupError) as cm:
            setup.rewrite_text("one\ntwo /tmp/evil/x\n", "/home/u", "/h", "dir/b.ts")
        self.assertEqual(str(cm.exception), "outside path in dir/b.ts:2")
        with self.assertRaises(setup.SetupError):
            setup.rewrite_text('{"p": "/home/other/x"}', "/home/u", "/h", "c.json")


class RewriteBlockerTest(unittest.TestCase):
    """RoseCat 5328 (2, 3): one-component paths and an empty source HOME."""

    def test_a_one_component_absolute_path_is_refused_unless_it_names_a_known_slash_command(self):
        for bad in ("read /secret now", "cd /tmp", '"/srv"'):
            with self.assertRaises(setup.SetupError):
                setup.rewrite_text(bad, "/home/u", "/h", "a.md", commands={"create_tdd_plan"})
        for ok in ("run /create_tdd_plan", "use /clear first", "/usr", "/etc"):  # .md prose
            self.assertEqual(setup.rewrite_text(ok, "/home/u", "/h", "a.md", commands={"create_tdd_plan"}), ok)

    def test_a_known_name_is_kept_only_as_a_slash_command_invocation_in_markdown_prose(self):
        """RoseCat 5338: the exception may not certify an OS path."""
        ok = ("First run /clear, then read.", "submits after /clear and", "you have been /clear'd", "shown in /help",
              "/clear", "- /compact now", "> /help", "1. /status", "type `/clear` here", "Use /create_tdd_plan.")
        for text in ok:
            self.assertEqual(setup.rewrite_text(text, "/home/u", "/h", "a.md", commands={"create_tdd_plan"}), text, text)
        bad = ("rm /clear", "open /help", "path=/status", "see /clear/x", "`rm /clear`")
        for text in bad:
            with self.assertRaises(setup.SetupError, msg=text):
                setup.rewrite_text(text, "/home/u", "/h", "a.md")
        for rel in ("hooks/x.ts", "a.py", "b.sh", "c.json"):
            with self.assertRaises(setup.SetupError, msg=rel):
                setup.rewrite_text("run /clear", "/home/u", "/h", rel)
        with self.assertRaises(setup.SetupError):
            setup.rewrite_text("text\n```\n/clear\n```\n", "/home/u", "/h", "a.md")

    def test_a_copied_command_or_skill_named_like_a_root_path_refuses_setup(self):
        """RoseCat 5352."""
        for make in (lambda s: (s / "skills" / "tmp").mkdir(), lambda s: (s / "commands" / "etc.md").write_text("x")):
            box = Sandbox(self)
            make(box.source)
            with self.assertRaises(setup.SetupError) as cm:
                box.provision()
            self.assertIn("collides with a root path", str(cm.exception))
            self.assertFalse(box.home.root.exists())
        with self.assertRaises(setup.SetupError):
            setup.rewrite_text("stored in /tmp", "/home/u", "/h", "a.md")

    def test_a_dot_segment_refuses_before_any_prefix_check_or_rewrite(self):
        """RoseCat 5340."""
        for text in ("cat /usr/../secret", "/proc/self/../../secret", "/agent/../secret", "/home/u/../other",
                     "/usr/./bin/x"):
            with self.assertRaises(setup.SetupError, msg=text) as cm:
                setup.rewrite_text(text, "/home/u", "/agent", "a.md")
            self.assertEqual(str(cm.exception), "path with a dot segment in a.md:1")

    def test_an_empty_or_relative_source_home_is_refused(self):
        for home in ("", "relative", "/"):
            with self.assertRaises(setup.SetupError):
                setup.rewrite_text("/srv/private/x", home, "/agent", "a.md")

    def test_setup_refuses_an_empty_source_home(self):
        box = Sandbox(self)
        with self.assertRaises(setup.SetupError):
            box.provision(source_home="")
        self.assertFalse(box.home.root.exists())


class RuntimeRecordTest(unittest.TestCase):
    """RoseCat 5331: host.json records which installed runtime set this home up."""

    def test_host_json_records_the_runtime_lock_beside_the_package(self):
        box = Sandbox(self)
        runtime = box.tmp / "prefix" / "lib" / "zigbrowser" / "agent-host"
        shutil.copytree(HOST_DIR / "zb_agent_host", runtime / "zb_agent_host")
        (runtime / "runtime.json").write_text(json.dumps({"lock_sha256": "ab" * 32}))
        box.provision(package_dir=runtime)
        host = json.loads((box.home.runtime / "host.json").read_text())
        self.assertEqual(host, {"python": "/usr/bin/python3", "runtime_lock": "ab" * 32})

    def test_a_development_checkout_has_no_lock_record(self):
        box = Sandbox(self)
        box.provision()
        self.assertIsNone(json.loads((box.home.runtime / "host.json").read_text())["runtime_lock"])


def inode_and_bytes(path):
    st = path.stat()
    return st.st_ino, path.read_bytes()


class PublishTest(unittest.TestCase):
    """Plan rev 15.4: a complete build is published by one swap of `current`;
    a failure or a kill anywhere leaves the old or the new `current`, never a
    mix, and the state is never touched."""

    def setUp(self):
        self.box = Sandbox(self)
        self.box.provision()
        self.root = root = self.box.home.root
        (root / "state" / "projects" / "keep.jsonl").write_text("transcript")
        (root / "state" / "MEMORY" / "note.md").write_text("memory")
        (root / "workspace" / "keep.txt").write_text("mine")
        self.state_files = [root / "state/projects/keep.jsonl", root / "state/MEMORY/note.md", root / "workspace/keep.txt",
                            root / "state/.claude.json"]
        self.state_before = [inode_and_bytes(p) for p in self.state_files]
        self.current_before = os.readlink(root / "current")
        self.dist_before = tree_digest(root / self.current_before)

    def assert_state_untouched(self):
        self.assertEqual([inode_and_bytes(p) for p in self.state_files], self.state_before)

    def assert_old_current(self):
        self.assertEqual(os.readlink(self.root / "current"), self.current_before)
        self.assertEqual(tree_digest(self.root / self.current_before), self.dist_before)
        self.assert_state_untouched()

    def assert_clean(self):
        names = sorted(p.name for p in self.root.iterdir())
        self.assertEqual([n for n in names if n.startswith(("dist-", ".dist-tmp-", ".current.tmp-"))],
                         [os.readlink(self.root / "current")], names)

    def test_the_layout_is_fixed_links_into_current_and_state_outside_it(self):
        self.assertEqual(self.current_before, "dist-1")
        self.assertEqual(os.readlink(self.root / ".claude"), "current/.claude")
        self.assertEqual(os.readlink(self.root / "runtime"), "current/runtime")
        for name in ("workspace", "scratchpad", "scratchpad/tmp", "secrets", "state", "state/backups",
                     *(f"state/{d}" for d in setup.sandbox.STATE_DIRS)):
            path = self.root / name
            self.assertTrue(path.is_dir() and not path.is_symlink(), name)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700, name)
        self.assertEqual(json.loads((self.root / "state/.claude.json").read_text()), {})
        self.assertEqual(stat.S_IMODE((self.root / "state/.claude.json").stat().st_mode), 0o600)
        for d in ("backups", *setup.sandbox.STATE_DIRS):
            self.assertEqual(list((self.root / "dist-1/.claude" / d).iterdir()), [], f"{d} is an empty mount point")
        self.assertEqual((self.root / "dist-1/.claude/.claude.json").read_bytes(), b"{}\n", "a placeholder mount point")
        self.assert_clean()

    def test_a_second_run_publishes_a_new_build_and_keeps_the_state(self):
        self.box.provision()
        self.assertEqual(os.readlink(self.root / "current"), "dist-2")
        self.assertEqual(tree_digest(self.root / "dist-2"), self.dist_before)
        self.assert_state_untouched()
        self.assert_clean()

    def test_a_failure_at_any_build_step_keeps_the_old_current_and_the_state(self):
        for target in ("copy_sai", "stage", "fsync_tree"):
            with self.subTest(target=target):
                with mock.patch.object(setup, target, side_effect=OSError("injected")):
                    with self.assertRaises(OSError):
                        self.box.provision()
                self.assert_old_current()
                self.assert_clean()

    def test_a_failure_at_either_rename_of_the_publish_keeps_the_old_current(self):
        for failing in (1, 2):  # the build to dist-<n>, then the temp link over current
            with self.subTest(failing=failing):
                real, calls = os.rename, []

                def flaky(a, b):
                    calls.append(b)
                    if len(calls) == failing:
                        raise OSError("injected")
                    real(a, b)

                with mock.patch.object(setup.os, "rename", side_effect=flaky):
                    with self.assertRaises(OSError):
                        self.box.provision()
                self.assert_old_current()
        self.box.provision()  # the next run publishes and removes the leftovers
        self.assertNotEqual(os.readlink(self.root / "current"), self.current_before)
        self.assert_state_untouched()
        self.assert_clean()

    def test_killed_at_either_cut_the_disk_holds_one_whole_current_and_a_rerun_recovers(self):
        class Killed(BaseException):
            pass

        for cut, live in (("swap:before", self.current_before), ("swap:after", None)):
            with self.subTest(cut=cut):
                old = os.readlink(self.root / "current")
                with mock.patch.object(setup, "_PAUSE_AT", cut), mock.patch.object(setup.time, "sleep"), \
                        mock.patch.object(setup.os, "_exit", side_effect=Killed), \
                        contextlib.redirect_stdout(io.StringIO()) as out:
                    with self.assertRaises(Killed):
                        self.box.provision()
                self.assertEqual(out.getvalue(), f"SETUP\tpaused\t{cut}\n")
                now = os.readlink(self.root / "current")
                self.assertEqual(now, old if cut == "swap:before" else f"dist-{int(old[5:]) + 1}")
                self.assertEqual(tree_digest(self.root / now), self.dist_before)
                self.assert_state_untouched()
                self.box.provision()
                self.assert_state_untouched()
                self.assert_clean()

    def test_a_failure_at_either_fsync_of_root_keeps_one_whole_current_and_the_state(self):
        """Plan rev 15.5, steps 4 and 7 of the publish order."""
        real = setup.fsync_dir
        for failing, current_may_be in ((1, "old"), (2, "either")):
            with self.subTest(failing=failing):
                old = os.readlink(self.root / "current")
                calls = []

                def flaky(path):
                    if Path(path) == self.root:
                        calls.append(path)
                        if len(calls) == failing:
                            raise OSError("injected")
                    real(path)

                with mock.patch.object(setup, "ensure_home"), mock.patch.object(setup, "fsync_dir", side_effect=flaky):
                    with self.assertRaises(OSError):
                        self.box.provision()
                now = os.readlink(self.root / "current")
                if current_may_be == "old":
                    self.assertEqual(now, old)
                else:
                    self.assertIn(now, (old, f"dist-{int(old[5:]) + 1}"))
                self.assertEqual(tree_digest(self.root / now), self.dist_before)
                self.assert_state_untouched()
                self.box.provision()
                self.assert_state_untouched()
                self.assert_clean()

    def test_an_entry_setup_did_not_make_refuses_before_building_and_is_left_alone(self):
        """Plan rev 15.5: garbage is deleted only once validated; nothing is followed."""
        outside = self.box.tmp / "outside"
        outside.mkdir()
        (outside / "precious").write_text("keep")
        cases = {
            "dist-9 -> outside": lambda: os.symlink(outside, self.root / "dist-9"),
            "dist-01": lambda: (self.root / "dist-01").mkdir(mode=0o700),
            "dist-x": lambda: (self.root / "dist-x").mkdir(mode=0o700),
            "dist-9 mode 0755": lambda: (self.root / "dist-9").mkdir(mode=0o755),
            ".dist-tmp-a file": lambda: (self.root / ".dist-tmp-a").write_text("x"),
            ".current.tmp-a dir": lambda: (self.root / ".current.tmp-a").mkdir(mode=0o700),
        }
        for label, plant in cases.items():
            with self.subTest(label):
                plant()
                with self.assertRaises(setup.SetupError) as cm:
                    self.box.provision()
                self.assertIn("is not something setup made", str(cm.exception))
                self.assertEqual((outside / "precious").read_text(), "keep")
                self.assert_old_current()
                name = label.split()[0]
                path = self.root / name
                (path.unlink if path.is_symlink() or path.is_file() else path.rmdir)()
        for target in ("../x", "/tmp/x", "dist-1/.claude", "dist-01"):
            with self.subTest(current=target):
                (self.root / "current").unlink()
                os.symlink(target, self.root / "current")
                with self.assertRaises(setup.SetupError):
                    self.box.provision()
                (self.root / "current").unlink()
                os.symlink(self.current_before, self.root / "current")
        self.assert_old_current()

    def test_a_missing_fixed_link_is_made_again_and_a_wrong_one_refuses(self):
        (self.root / "runtime").unlink()
        self.box.provision()
        self.assertEqual(os.readlink(self.root / "runtime"), "current/runtime")
        self.assert_state_untouched()
        before = os.readlink(self.root / "current")
        (self.root / "runtime").unlink()
        (self.root / "runtime").mkdir()
        with self.assertRaises(setup.SetupError):
            self.box.provision()
        self.assertEqual(os.readlink(self.root / "current"), before)

    def test_a_failed_removal_of_an_old_build_is_reported_and_setup_succeeds(self):
        with mock.patch.object(setup.shutil, "rmtree", side_effect=OSError("injected")), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            self.box.provision()
        self.assertEqual(os.readlink(self.root / "current"), "dist-2")
        self.assertIn(f"zigBrowser: agent-setup: old build left at {self.root / 'dist-1'}", err.getvalue())
        self.assert_state_untouched()

    def test_an_old_layout_home_or_a_changed_link_refuses_and_nothing_changes(self):
        other = Sandbox(self)
        other.home.root.mkdir(parents=True)
        (other.home.root / ".claude").mkdir()
        (other.home.root / ".claude" / "projects").mkdir()
        before = tree_digest(other.home.root)
        with self.assertRaises(setup.SetupError) as cm:
            other.provision()
        self.assertEqual(str(cm.exception), f"{other.home.root} has the old layout; move it aside and run again")
        self.assertEqual(tree_digest(other.home.root), before)
        (self.root / "runtime").unlink()
        os.symlink("dist-1/runtime", self.root / "runtime")
        with self.assertRaises(setup.SetupError):
            self.box.provision()
        self.assert_old_current()


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
        self.assertEqual(json.loads((root / "state/.claude.json").read_text()), {})
        for name in ("bin/zb-hook-run", "bin/zb-claude", "hook-env.json", "writable.json", "path.json",
                     "config-manifest.json", "host.json", "host/zb_agent_host/__main__.py"):
            self.assertTrue((root / "runtime" / name).exists(), name)
        self.assertEqual(json.loads((root / "runtime/host.json").read_text())["python"], "/usr/bin/python3")
        self.assertEqual(json.loads((root / "runtime/writable.json").read_text()),
                         ["projects", "sessions", "session-env", "todos", "statsig", "debug", "MEMORY"])
        manifest = json.loads((root / "runtime/config-manifest.json").read_text())
        self.assertIn("settings.json", manifest)
        self.assertEqual(manifest["settings.json"], hashlib.sha256((root / ".claude/settings.json").read_bytes()).hexdigest())
        self.assertEqual(json.loads((root / "current/.zb-agent-home").read_text()), {"layout": 2})
        text = "\n".join(p.read_text(errors="replace") for p in (root / ".claude").rglob("*") if p.is_file())
        for canary in ("ZB-FIXTURE-CREDENTIAL-CANARY", "ZB-FIXTURE-PROJECT-CANARY", "ZB-FIXTURE-MEMORY-CANARY",
                       "ZB-FIXTURE-HISTORY-CANARY", "zb-fixture-should-not-survive"):
            self.assertNotIn(canary, text)

    def test_a_second_run_is_idempotent_and_keeps_the_agents_own_files(self):
        self.box.provision()
        root = self.box.home.root
        (root / "workspace" / "keep.txt").write_text("mine")
        (root / "state" / "projects" / "t.jsonl").write_text("transcript")
        claude_before = tree_digest(root / ".claude")
        self.box.provision()
        self.assertEqual(tree_digest(root / ".claude"), claude_before)
        self.assertEqual((root / "workspace" / "keep.txt").read_text(), "mine")
        self.assertEqual((root / "state" / "projects" / "t.jsonl").read_text(), "transcript")
        self.assertEqual(sorted(p.name for p in root.iterdir() if p.name.startswith(("dist-", ".dist-tmp"))), ["dist-2"])

    def test_a_home_holding_only_the_owner_lock_is_a_first_install(self):
        self.box.home.root.mkdir(parents=True, mode=0o700)
        (self.box.home.root / ".zb-owner.lock").write_text("")
        self.box.provision()
        self.assertTrue((self.box.home.root / "current" / ".zb-agent-home").is_file())
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
