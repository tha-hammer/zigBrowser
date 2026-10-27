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
import time
import unittest
from pathlib import Path
from unittest import mock

HOST_DIR = Path(__file__).resolve().parents[1]
REPO = HOST_DIR.parents[1]
sys.path.insert(0, str(HOST_DIR))

from zb_agent_host import options, relay, setup  # noqa: E402

FIXTURE = REPO / "tests" / "fixtures" / "agent" / "sai_source"
sys.path.insert(0, str(REPO / "tests" / "e2e"))
from agent_escape import TcpDecoy, attempter_cli, host_lan_address  # noqa: E402


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
                    source_path=self.source_path, python="/usr/bin/python3", select_token_route=False)
        args.update(kw)
        return setup.provision(**args)


class TokenRouteTest(unittest.TestCase):
    """§3c.1: R3 (the token in the CLI's environment) is removed. Setup always
    probes R1, the descriptor route, and refuses when it does not work."""

    def setUp(self):
        self.runtime = Path(tempfile.mkdtemp(prefix="zb-route-"))
        self.addCleanup(shutil.rmtree, self.runtime, True)

    def test_setup_takes_no_route_option_any_more(self):
        required = ["--home", "/h", "--sai-source", "/s", "--source-home", "/u", "--source-path", "/usr/bin",
                    "--python", "/usr/bin/python3"]
        for route in ("env", "r1"):
            with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()):
                setup.main([*required, "--route", route])
            self.assertEqual(raised.exception.code, 2, route)

    def test_the_route_is_r1_when_the_descriptor_probe_works(self):
        with mock.patch.object(setup, "cli_version", return_value="9.9.9"):
            setup.select_route(self.runtime, "/cli", lambda wrapper, cli: True)
        record = json.loads((self.runtime / "token-route.json").read_text())
        self.assertEqual((record["route"], record["cli_path"]), ("R1", "/cli"))

    def test_setup_refuses_when_the_descriptor_probe_fails(self):
        with self.assertRaises(setup.SetupError):
            setup.select_route(self.runtime, "/cli", lambda wrapper, cli: False)
        self.assertFalse((self.runtime / "token-route.json").exists())

    def test_no_risk_line_and_no_env_route_remain(self):
        self.assertFalse(hasattr(setup, "RISK_LINE"))
        from zb_agent_host import token
        self.assertFalse(hasattr(token, "r3_env"))


class SetupSandboxTest(unittest.TestCase):
    """§3c.7: setup's own executions (`cli --version` and the R1 probe) run in the
    same kind of sandbox as the helper, never under `--dev-bind / /`: a private
    network, read-only /usr, the few /etc files and what they need, a throwaway
    home, and no X11, XDG_RUNTIME_DIR, user home or repository."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="zb-setup-sandbox-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.decoys = [TcpDecoy("127.0.0.1")]
        lan = host_lan_address()
        self.assertIsNotNone(lan, "the host has no global IPv4 address for the LAN decoy")
        self.decoys.append(TcpDecoy(lan))
        for decoy in self.decoys:
            self.addCleanup(decoy.close)
        self.user = self.tmp / "user-home"
        (self.user / "src" / "repo").mkdir(parents=True)
        self.canaries = [self.user / "canary", self.user / "src" / "repo" / "canary"]
        for canary in self.canaries:
            canary.write_text("canary\n")

    def attempter(self, path=None, real=None):
        return attempter_cli(path or self.tmp / "attempter-claude", tcp=[d.address for d in self.decoys],
                             files=self.canaries, real=real)

    def assert_nothing_reached(self, opened):
        self.assertEqual([d.accepted for d in self.decoys], [0, 0], "a decoy was reached (loopback, LAN)")
        self.assertEqual(sorted(p for p in opened if "canary" in p), [], "a canary was opened")

    def test_the_sandbox_has_its_own_network_and_only_the_binds_it_needs(self):
        scratch = self.tmp / "scratch"
        argv = setup.setup_sandbox(scratch, ["/v", "/pkg", "/r/runtime", "/c/claude"], ["/c/claude", "--version"])
        self.assertNotIn("--dev-bind", argv)
        for flag in ("--unshare-net", "--unshare-pid", "--unshare-ipc", "--die-with-parent", "--new-session"):
            self.assertIn(flag, argv[:argv.index("--")])
        binds = [(argv[i], argv[i + 1]) for i in range(len(argv) - 1) if argv[i] in ("--bind", "--ro-bind", "--dev-bind")]
        self.assertEqual([b for b in binds if b[0] == "--bind"], [("--bind", str(scratch))], "only the throwaway home is writable")
        ro = {path for flag, path in binds if flag == "--ro-bind"}
        allowed = {"/usr", "/v", "/pkg", "/r/runtime", "/c/claude", *(f for f in setup.sandbox.ETC_FILES)}
        self.assertLessEqual(ro, allowed)
        self.assertEqual(argv[argv.index("--") + 1:], ["/c/claude", "--version"])

    def test_cli_version_reaches_no_decoy_and_reads_no_canary(self):
        cli = self.attempter()
        watch = support_inotify(self.user)
        version = setup.cli_version(cli)
        self.assert_nothing_reached(watch.close())
        self.assertEqual(version, "0.0.0", "the sandboxed CLI still answers --version")

    def test_the_r1_probe_still_passes_and_reaches_no_decoy_or_canary(self):
        # The wrapper starts the attempter (in the runtime, which the probe sees), which
        # then execs the real CLI: the probe still finds and checks the real CLI.
        from zb_agent_host import token
        real = token.bundled_cli()
        wrapper = self.tmp / "runtime" / "bin" / "zb-claude"
        wrapper.parent.mkdir(parents=True)
        token.write_wrapper(wrapper, self.attempter(wrapper.parent / "escape-claude", real=real))
        watch = support_inotify(self.user)
        r1 = setup.probe_r1(wrapper, real)
        self.assert_nothing_reached(watch.close())
        self.assertTrue(r1, "the real CLI behind the attempter must still pass the R1 probe")


def support_inotify(root):
    import support
    return support.Inotify(root, extra_mask=support.Inotify.IN_OPEN | support.Inotify.IN_ACCESS)


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
    """Plan rev 15.6 (the user's decision): copied text only gets the source
    HOME moved to the agent home; no path in it refuses setup."""

    def test_only_the_source_home_prefix_is_rewritten(self):
        out = setup.rewrite_text("see /home/u/.claude/x and /usr/share/y\n", "/home/u", "/data/agent-home")
        self.assertEqual(out, "see /data/agent-home/.claude/x and /usr/share/y\n")
        for same in ("run /create_tdd_plan", "https://example.com/a/b", "`${home}/.claude/hooks`", "$(pwd)/a/b",
                     "relative/a/b", "~/.claude/hooks/a", "/tmp/evil/x", "/home/other/x", "/home/user2/x",
                     "rm /clear", "Bash(dd if=/dev/zero:*)", "/srv/../x"):
            self.assertEqual(setup.rewrite_text(same, "/home/u", "/h"), same, same)

    def test_an_empty_relative_or_root_source_home_is_refused(self):
        for home in ("", "relative", "/"):
            with self.assertRaises(setup.SetupError):
                setup.rewrite_text("/srv/private/x", home, "/agent")

    def test_setup_refuses_an_empty_source_home(self):
        box = Sandbox(self)
        with self.assertRaises(setup.SetupError):
            box.provision(source_home="")
        self.assertFalse(box.home.root.exists())


class SourceLinkTest(unittest.TestCase):
    """RoseCat 5428, 5430: top-level items that are links."""

    def bundle_layout(self):
        """The user's real layout: every item is a link into one SAI bundle
        directory outside ~/.claude."""
        box = Sandbox(self)
        bundle = box.tmp / "Dev" / "sai-bundle" / "SAI"
        bundle.parent.mkdir(parents=True)
        shutil.move(str(box.source / "SAI"), bundle)
        os.symlink(bundle, box.source / "SAI")
        for name in ("settings.json", "hooks", "commands", "skills", "agents"):
            shutil.move(str(box.source / name), bundle / name)
            os.symlink(bundle / name, box.source / name)
        return box, bundle

    def test_the_real_layout_of_links_into_the_sai_bundle_is_followed(self):
        box, _bundle = self.bundle_layout()
        box.provision()
        for kept in ("hooks/X.hook.ts", "commands/hello.md", "skills/demo/SKILL.md", "SAI/README.md", "settings.json"):
            self.assertTrue((box.home.root / ".claude" / kept).is_file(), kept)

    def test_a_top_level_link_is_followed_once_and_logged_a_chain_is_skipped(self):
        """RoseCat 5438: the user chose each top-level link by choosing the
        SAI source; a chain of links, or another user's target, is skipped."""
        box = Sandbox(self)
        elsewhere = box.tmp / "elsewhere"
        elsewhere.mkdir()
        (elsewhere / "CLAUDE.md").write_text("ZB-LINKED-CLAUDE\n")
        (box.source / "CLAUDE.md").unlink()
        (box.source / "CLAUDE.md").symlink_to(elsewhere / "CLAUDE.md")
        with contextlib.redirect_stderr(io.StringIO()) as err:
            box.provision()
        self.assertIn(f"CLAUDE.md comes from {elsewhere / 'CLAUDE.md'}", err.getvalue())
        self.assertEqual((box.home.root / ".claude/CLAUDE.md").read_text(), "ZB-LINKED-CLAUDE\n")

        box = Sandbox(self)
        (box.tmp / "secret").write_text("ZB-SECRET-CANARY")
        os.symlink(box.tmp / "secret", box.tmp / "hop")
        (box.source / "CLAUDE.md").unlink()
        (box.source / "CLAUDE.md").symlink_to(box.tmp / "hop")  # a link to a link
        with contextlib.redirect_stderr(io.StringIO()) as err:
            box.provision()
        self.assertIn("skipped CLAUDE.md: its link is a chain", err.getvalue())
        text = "".join(p.read_text(errors="replace") for p in (box.home.root / "current").rglob("*") if p.is_file())
        self.assertNotIn("ZB-SECRET-CANARY", text)

    def test_a_top_level_link_through_a_link_in_a_parent_component_is_skipped(self):
        """RoseCat 833767e: `CLAUDE.md -> hop/CLAUDE.md` with `hop -> /outside`."""
        box = Sandbox(self)
        outside = box.tmp / "outside"
        outside.mkdir()
        (outside / "CLAUDE.md").write_text("CHAIN_CANARY\n")
        (box.tmp / "hop").symlink_to(outside)
        (box.source / "CLAUDE.md").unlink()
        (box.source / "CLAUDE.md").symlink_to(box.tmp / "hop" / "CLAUDE.md")
        with contextlib.redirect_stderr(io.StringIO()) as err:
            box.provision()
        self.assertIn("skipped CLAUDE.md: its link is a chain", err.getvalue())
        text = "".join(p.read_text(errors="replace") for p in (box.home.root / "current").rglob("*") if p.is_file())
        self.assertNotIn("CHAIN_CANARY", text)

    def test_an_internal_alias_keeps_both_names_and_a_real_cycle_is_bounded(self):
        """RoseCat 833767e: a global seen set dropped one of two names."""
        for alias in ("alias", "zzz-alias"):  # before and after the real name
            with self.subTest(alias):
                box = Sandbox(self)
                real = box.source / "skills" / "real"
                real.mkdir()
                (real / "payload.txt").write_text("payload\n")
                (box.source / "skills" / alias).symlink_to("real")
                (real / "loop").symlink_to("..")  # a real cycle: back to an ancestor
                started = time.monotonic()
                with contextlib.redirect_stderr(io.StringIO()) as err:
                    box.provision()
                self.assertLess(time.monotonic() - started, 30)
                claude = box.home.root / ".claude"
                for name in ("real", alias):
                    self.assertEqual((claude / "skills" / name / "payload.txt").read_text(), "payload\n", name)
                self.assertIn("a link cycle", err.getvalue())

    def test_a_source_or_item_overlapping_the_agent_home_refuses_before_copying(self):
        """RoseCat 5439: `SAI -> an ancestor of the agent home` would copy its own output."""
        box = Sandbox(self)
        shutil.rmtree(box.source / "SAI")
        (box.source / "SAI").symlink_to(box.tmp)  # an ancestor of the agent home
        started = time.monotonic()
        with self.assertRaises(setup.SetupError) as cm:
            box.provision()
        self.assertIn("SAI overlaps the agent home", str(cm.exception))
        self.assertLess(time.monotonic() - started, 10)
        self.assertFalse(box.home.root.exists())
        box = Sandbox(self)
        with self.assertRaises(setup.SetupError) as cm:
            setup.provision(home=box.home, source=box.tmp, source_home=box.source_home, source_path=box.source_path,
                            python="/usr/bin/python3", select_token_route=False)
        self.assertIn("the SAI source overlaps the agent home", str(cm.exception))

    def test_each_item_must_have_its_type(self):
        """RoseCat 5445: CLAUDE.md and settings.json are files, the rest directories."""
        for name, make in (("CLAUDE.md", lambda p: p.mkdir()), ("hooks", lambda p: p.write_text("x"))):
            with self.subTest(name):
                box = Sandbox(self)
                path = box.source / name
                shutil.rmtree(path) if path.is_dir() else path.unlink()
                make(path)
                with self.assertRaises(setup.SetupError) as cm:
                    box.provision()
                self.assertIn(f"{name} in the SAI source is not a", str(cm.exception))

    def test_a_nested_fifo_or_socket_refuses_without_blocking(self):
        """RoseCat 5445: nothing inside an item vanishes silently, and nothing is opened."""
        import socket
        for kind in ("fifo", "socket"):
            with self.subTest(kind):
                box = Sandbox(self)
                path = box.source / "skills" / "demo" / f"special-{kind}"
                if kind == "fifo":
                    os.mkfifo(path)
                else:
                    sock = socket.socket(socket.AF_UNIX)
                    self.addCleanup(sock.close)
                    sock.bind(str(path))
                started = time.monotonic()
                with self.assertRaises(setup.SetupError) as cm:
                    box.provision()
                self.assertIn(f"skills/demo/special-{kind} in the SAI source is not a regular file", str(cm.exception))
                self.assertLess(time.monotonic() - started, 10)

    def test_a_top_level_fifo_refuses_without_blocking(self):
        box = Sandbox(self)
        (box.source / "CLAUDE.md").unlink()
        os.mkfifo(box.source / "CLAUDE.md")
        with self.assertRaises(setup.SetupError) as cm:
            box.provision()
        self.assertIn("is not a regular file or a directory", str(cm.exception))


class PinnedReadTest(unittest.TestCase):
    """RoseCat db02324 SHOULD: a leaf swapped after classification is never
    followed or blocked on (a reversion to Path.read_bytes() fails this)."""

    def test_a_leaf_swapped_to_a_link_or_a_fifo_refuses_and_a_regular_file_reads(self):
        tmp = Path(tempfile.mkdtemp(prefix="zb-pinned-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "secret").write_text("ZB-SWAP-CANARY")
        (tmp / "plain").write_text("plain")
        self.assertEqual(setup._read_regular(tmp / "plain"), b"plain")
        (tmp / "swapped-link").symlink_to(tmp / "secret")
        os.mkfifo(tmp / "swapped-fifo")
        for name in ("swapped-link", "swapped-fifo"):
            started = time.monotonic()
            with self.assertRaises(setup.SetupError, msg=name):
                setup._read_regular(tmp / name)
            self.assertLess(time.monotonic() - started, 5, name)

    def test_a_swap_between_classification_and_read_is_caught_in_the_copy(self):
        box = Sandbox(self)
        target = box.source / "SAI" / "README.md"
        (box.tmp / "secret").write_text("ZB-SWAP-CANARY")
        real_stat = os.stat

        def swap_after_classify(path, *args, **kw):
            st = real_stat(path, *args, **kw)
            if str(path) == str(target) and not os.path.islink(target):
                target.unlink()
                target.symlink_to(box.tmp / "secret")  # the swap lands after classification
            return st

        with mock.patch.object(setup.os, "stat", side_effect=swap_after_classify):
            with self.assertRaises(setup.SetupError) as cm:
                box.provision()
        self.assertIn("changed while setup read it", str(cm.exception))
        self.assertFalse(box.home.root.exists())


class StateModeTest(unittest.TestCase):
    """RoseCat 5431: existing state is never changed, so a wrong mode refuses."""

    def test_a_loose_root_state_directory_or_state_file_refuses_and_nothing_changes(self):
        for rel, mode in ((".", 0o755), ("state/projects", 0o755), ("workspace", 0o777), ("secrets", 0o750),
                          ("state/.claude.json", 0o644)):
            with self.subTest(rel):
                box = Sandbox(self)
                box.provision()
                path = box.home.root / rel
                os.chmod(path, mode)
                before = tree_digest(box.home.root)
                with self.assertRaises(setup.SetupError):
                    box.provision()
                self.assertEqual(tree_digest(box.home.root), before)
                os.chmod(path, 0o600 if rel.endswith(".json") else 0o700)


class RuntimeRecordTest(unittest.TestCase):
    """RoseCat 5331: host.json records which installed runtime set this home up."""

    def test_host_json_records_the_runtime_identity_beside_the_package(self):
        box = Sandbox(self)
        runtime = box.tmp / "prefix" / "lib" / "zigbrowser" / "agent-host"
        shutil.copytree(HOST_DIR / "zb_agent_host", runtime / "zb_agent_host")
        (runtime / "runtime.json").write_text(json.dumps({"lock_sha256": "ab" * 32,
                                                           "host_sha256": "cd" * 32}))
        box.provision(package_dir=runtime)
        host = json.loads((box.home.runtime / "host.json").read_text())
        self.assertEqual(host, {"python": "/usr/bin/python3", "runtime_lock": "ab" * 32,
                                "host_sha256": "cd" * 32})

    def test_a_development_checkout_has_no_lock_record(self):
        box = Sandbox(self)
        box.provision()
        host = json.loads((box.home.runtime / "host.json").read_text())
        self.assertIsNone(host["runtime_lock"])
        self.assertIsNone(host["host_sha256"])


class RuntimeRelayTest(unittest.TestCase):
    """§3c.2 and §3c.8b: setup's published runtime holds zb-net-relay, the outer relay
    (the helper sandbox's command) and each sealed hook's bridge-only relay. Until
    S3b only the P0 provision path installed it, so a real setup home had none."""

    def test_setup_installs_the_relay_read_only_and_executable(self):
        box = Sandbox(self)
        box.provision()
        path = box.home.runtime / "bin" / "zb-net-relay"
        self.assertEqual(stat.S_IMODE(path.lstat().st_mode), 0o555)
        self.assertTrue(stat.S_ISREG(path.lstat().st_mode))
        self.assertEqual(path.read_bytes(), Path(relay.BRIDGE_RELAY_FILE).read_bytes())


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

    def test_a_fixed_link_made_by_someone_else_in_a_race_is_checked_after_creation(self):
        """RoseCat 5405: the link must be the exact one after create-or-exists."""
        (self.root / "runtime").unlink()
        real_symlink = os.symlink

        def racer(target, name, *args, **kw):
            if name == "runtime":
                real_symlink("/tmp/elsewhere", name, *args, **kw)  # another process won the race
            real_symlink(target, name, *args, **kw)

        with mock.patch.object(setup.os, "symlink", side_effect=racer):
            with self.assertRaises(setup.SetupError) as cm:
                self.box.provision()
        self.assertIn("is not the link setup made", str(cm.exception))
        self.assertEqual(os.readlink(self.root / "current"), self.current_before)
        self.assert_state_untouched()

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

    def test_a_link_outside_its_item_that_no_hook_runs_is_skipped_with_a_warning(self):
        """Plan rev 15.6: never followed (it could name any user file), but
        it no longer refuses setup (the user's real SAI has such skills)."""
        secret = self.box.tmp / "secret"
        secret.mkdir()
        (secret / "key").write_text("ZB-SECRET-CANARY")
        (self.box.source / "skills" / "elsewhere").symlink_to(secret)
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.box.provision()
        self.assertIn("skipped skills/elsewhere: it links outside skills", err.getvalue())
        self.assertFalse((self.box.home.root / ".claude/skills/elsewhere").exists())
        text = "".join(p.read_text(errors="replace") for p in (self.box.home.root / "current").rglob("*") if p.is_file())
        self.assertNotIn("ZB-SECRET-CANARY", text)

    def test_a_hook_naming_a_file_below_a_skipped_link_refuses(self):
        """RoseCat 5416: the skipped link or any of its descendants."""
        foreign = self.box.tmp / "foreign"
        foreign.mkdir()
        (foreign / "run.ts").write_text("// foreign\n")
        (self.box.source / "skills" / "outside").symlink_to(foreign)
        settings = json.loads((self.box.source / "settings.json").read_text())
        settings["hooks"]["Stop"][0]["hooks"].append({"type": "command", "command": "bun ~/.claude/skills/outside/run.ts"})
        (self.box.source / "settings.json").write_text(json.dumps(settings))
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(setup.SetupError) as cm:
                self.box.provision()
        self.assertEqual(str(cm.exception), "hook script links outside its item: skills/outside/run.ts")
        self.assertFalse(self.box.home.root.exists())

    def test_a_path_embedded_in_an_option_is_checked_like_any_other(self):
        """RoseCat 5416: `--preload=/x` names an executed file."""
        for command, refused in (("bun --preload=/srv/evil.ts ~/.claude/hooks/X.hook.ts", True),
                                 ("bun --preload=~/.claude/hooks/X.hook.ts ~/.claude/hooks/X.hook.ts", False)):
            with self.subTest(command):
                box = Sandbox(self)
                settings = json.loads((box.source / "settings.json").read_text())
                settings["hooks"]["Stop"][0]["hooks"].append({"type": "command", "command": command})
                (box.source / "settings.json").write_text(json.dumps(settings))
                if refused:
                    with self.assertRaises(setup.SetupError) as cm:
                        box.provision()
                    self.assertIn("hook path outside agent home: Stop/0", str(cm.exception))
                else:
                    box.provision()

    def test_hook_commands_outside_the_supported_grammar_refuse(self):
        """RoseCat 5431: opaque forms could carry code or paths unchecked."""
        cases = {
            "sh -c 'cat /etc/passwd'": "has shell syntax",
            "bash -lc ~/.claude/hooks/X.hook.ts": "evaluates code",
            "node -e ~/.claude/hooks/X.hook.ts": "evaluates code",
            "bun --eval=x ~/.claude/hooks/X.hook.ts": "evaluates code",
            "python3 -m http.server": "evaluates code",
            "~root/x.sh": "names another user's home",
            "bun file:///srv/x.ts": "has a non-http URL",
            "curl http://localhost:51091/notify": "launcher is not supported (curl)",
            "bun --watch": "runs no script path",
            "bun --preload=/srv/evil.ts ~/.claude/hooks/X.hook.ts": "hook path outside agent home",
            # RoseCat 5438: shell syntax anywhere, and attached eval flags.
            "bun ~/.claude/hooks/X.hook.ts; id": "has shell syntax",
            "bun ~/.claude/hooks/X.hook.ts && curl http://127.0.0.1:51091/x": "has shell syntax",
            "bun ~/.claude/hooks/X.hook.ts | sh": "has shell syntax",
            "bun ~/.claude/hooks/X.hook.ts > /tmp/x": "has shell syntax",
            "bun ~/.claude/hooks/X.hook.ts $(cat</etc/passwd)": "has shell syntax",
            "bun ~/.claude/hooks/X.hook.ts `id`": "has shell syntax",
            "bun ~/.claude/hooks/X.hook.ts $HOME": "has shell syntax",
            "bun ~/.claude/hooks/X.hook.ts\nid": "has shell syntax",
            "node -eCODE ~/.claude/hooks/X.hook.ts": "evaluates code",
            'python3 "unterminated': "has shell syntax",  # RoseCat 833767e: a refusal, not a parser crash
            "bun -pCODE ~/.claude/hooks/X.hook.ts": "evaluates code",
        }
        for command, want in cases.items():
            with self.subTest(command):
                box = Sandbox(self)
                settings = json.loads((box.source / "settings.json").read_text())
                settings["hooks"]["Stop"][0]["hooks"].append({"type": "command", "command": command})
                (box.source / "settings.json").write_text(json.dumps(settings))
                with self.assertRaises(setup.SetupError) as cm:
                    box.provision()
                self.assertIn(want, str(cm.exception))
                self.assertFalse(box.home.root.exists())
        for command in ("~/.claude/hooks/X.hook.ts", "bun ~/.claude/hooks/X.hook.ts",
                        "bun --smol ~/.claude/hooks/X.hook.ts arg", "python3 ~/.claude/hooks/notify.py stop"):
            with self.subTest(ok=command):
                box = Sandbox(self)
                settings = json.loads((box.source / "settings.json").read_text())
                settings["hooks"]["Stop"][0]["hooks"].append({"type": "command", "command": command})
                (box.source / "settings.json").write_text(json.dumps(settings))
                box.provision()

    def test_a_hook_path_must_name_an_existing_file_of_the_published_copy(self):
        """RoseCat 5444: never the workspace, scratchpad or state, whose bytes
        the agent can change after setup checked them; never missing or
        relative (relative resolves against the writable workspace)."""
        for command in ("bun ~/scratchpad/run.ts", "bun ~/workspace/run.ts", "bun ~/state/MEMORY/run.ts",
                        "bun ~/secrets/run.ts", "bun workspace/run.ts", "bun ~/.claude/hooks/missing.ts",
                        "~/.claude/hooks/X.hook.ts --preload=~/scratchpad/pre.ts"):
            with self.subTest(command):
                box = Sandbox(self)
                settings = json.loads((box.source / "settings.json").read_text())
                settings["hooks"]["Stop"][0]["hooks"].append({"type": "command", "command": command})
                (box.source / "settings.json").write_text(json.dumps(settings))
                with self.assertRaises(setup.SetupError) as cm:
                    box.provision()
                self.assertIn("hook path is not in the copied SAI: Stop/0", str(cm.exception))
                self.assertFalse(box.home.root.exists())

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

    def test_only_what_runs_is_checked_strictly_other_text_is_rewritten_only(self):
        """Plan rev 15.6: documentation may mention any path."""
        readme = self.box.source / "SAI" / "README.md"
        with open(readme, "a") as f:
            f.write(f"Pipe to /dev/null, write /tmp/x.png, see {self.box.source_home}/notes and /usr/../odd.\n")
        self.box.provision()
        copied = (self.box.home.root / ".claude/SAI/README.md").read_text()
        self.assertIn("/dev/null", copied)
        self.assertIn(f"{self.box.home.root}/notes", copied)
        self.assertNotIn(str(self.box.source_home), copied)

    def test_a_hook_scripts_text_may_hold_any_path_its_command_line_is_what_is_checked(self):
        """Plan rev 15.6: hook scripts are source code (regex literals and
        comments read as paths); the hook command line is checked instead
        (test_an_absolute_hook_outside_the_agent_home_is_refused...)."""
        hook = self.box.source / "hooks" / "X.hook.ts"
        hook.write_text(hook.read_text() + "const out = '/srv/elsewhere/x'; s.replace(/[^a-z]/g, '');\n")
        self.box.provision()
        self.assertIn("/srv/elsewhere/x", (self.box.home.root / ".claude/hooks/X.hook.ts").read_text())

    def test_version_control_and_build_output_are_copied_byte_for_byte(self):
        """RoseCat 5443: copied, not dropped and not rewritten."""
        named = [f"skills/demo/{d}/x" for d in setup.DEPENDENCY_DIRS]
        for rel in named:
            path = self.box.source / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(f"{self.box.source_home}/kept\n".encode())
        self.box.provision()
        for rel in named:
            self.assertEqual((self.box.home.root / ".claude" / rel).read_bytes(), f"{self.box.source_home}/kept\n".encode())

    def test_dependency_trees_are_copied_byte_for_byte(self):
        module = self.box.source / "skills" / "demo" / "node_modules" / "pkg" / "index.js"
        module.parent.mkdir(parents=True)
        body = f"require('/usr/../x'); const home = '{self.box.source_home}/y'; // /srv/z\n".encode()
        module.write_bytes(body)
        self.box.provision()
        self.assertEqual((self.box.home.root / ".claude/skills/demo/node_modules/pkg/index.js").read_bytes(), body)


if __name__ == "__main__":
    unittest.main()
