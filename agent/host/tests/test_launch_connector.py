"""bd zigBrowser-4pa.21, plan MS6.8 slice 1 (SilverRidge a365949c ruling; fix-forward of red 2b84e825 for the
4420d805 block): the production launch connector.

RED, UNREGISTERED: the green registers it in aggregate ``test`` (no skip-to-green).

One function over the backend Protocol, ``launch.build_launch(backend, request)``, composes the helper's launch for
LinuxBwrapBackend and MacSeatbeltBackend alike. The private ``sandbox._LINUX_BACKEND`` is POISONED in every row that
builds a launch, so neither the builder, the Linux compatibility wrapper, ``launch.main`` nor the inner helpers may
reach it.

Rows (each its own test; a failure names it):
- Q request: ``launch.LaunchRequest`` is frozen; its realization fields (seccomp_fd, net_dir, bwrap) default to None.
- B builder:
  - B1-B3: ``launch.build_argv``'s chat, test-CA and login variants stay byte-for-byte the frozen references (the
    independent ``reference_build_argv`` of test_backend_contract; the login one below).
  - B4: Linux refuses a request without its seccomp fd or socket dir (a SandboxError).
  - B5: macOS: ``sandbox-exec -f <profile> -D SCRATCHPAD=<scratch>`` then the inner chat with
    ``--egress-port 51234``; no relay.
  - B6: macOS refuses a seccomp fd, a socket dir and a bwrap override, each with UnsupportedLaunchInput and ZERO
    profile materializations (the bwrap refusal also before any lease call).
- R relay, chosen only from ``LaunchSpec.network.egress.dir`` (a synthetic backend drives both values):
  - R1: a dir adds exactly one ``zb-net-relay --egress <dir>``;
  - R2: None adds none, and the inner helper gets ``--egress-port`` from the spec's endpoint (two ports, so neither
    is hard-coded).
- E lease: ``launch`` is a context-managed operation on the Protocol and both backends, shaped like ``launch_spec``.
  - E1: the shape.
  - E2: Linux is a no-op lease that yields its whole ``launch_spec`` value (argv, mounts, workdir, seccomp fd,
    network, lifetime, channel).
  - E3: macOS: the profile is absent before, present (0400, the rendered port) inside, and gone after a normal exit.
  - E4: gone after an exception.
- P proxy, through the real inner parsers with the global poisoned:
  - P1, P2: chat with ``--egress-port`` holds ``http://127.0.0.1:<port>`` (two ports); P3: without it, Linux's
    ``:3128``.
  - P4: ``chat.session_options`` puts the given proxy in HTTPS_PROXY and HTTP_PROXY.
  - P5-P7: the same for login (``login.main`` -> ``Login.proxy`` -> ``login.cli_env``).
  - P8, P9: the real call sites (``chat.Session``'s options, ``Login.spawn``'s CLI environment) carry that proxy.
- M ``launch.main`` through injected seams:
  - M1: Linux execs bwrap in place with the frozen argv.
  - M2: Linux without ``--net-dir`` is a usage error.
  - M3: Darwin still refuses "not ready" under the real BROAD derivation, needs no ``--net-dir``, and makes no
    lease call and no profile. M3b: the refusal comes from ``sandbox_macos.LAUNCH_SPEC_CONSUMABLE()`` itself: patched
    to False while the curation says CURATED, main still refuses and the function was called.
  - M4: with ``LAUNCH_SPEC_CONSUMABLE()`` patched to True (the curation left BROAD, so no copy of it can pass), Darwin
    calls ``launch.spawn_helper`` inside the lease (the profile present, 0400, with the port) with
    ``options.helper_environ(home, os.environ)``. It never calls execve or seccomp, and returns the child's status;
    no profile is left.
  - M5: a spawn failure returns EXIT_NO_SANDBOX and leaves no profile.
  - M6: ``--net-dir`` or ``--bwrap`` on Darwin is a usage error naming the flag, with no lease call and no profile.
  - M7: Darwin login spawns the inner login with the port.
  - M8, M9: ``launch.main`` down to the real spawn seam, over a recording ``subprocess.Popen``. The child is waited for
    while the profile is still present, with the helper environment; main returns its status (M8), and a Popen
    OSError gives EXIT_NO_SANDBOX with no profile left (M9).
- S the real ``launch.spawn_helper`` over a recording ``subprocess.Popen``:
  - S1: the exact argv, no shell, the given env, a wait before it returns, and the child's exit status (not its
    pid, not a constant).
  - S2: a Popen OSError propagates.

Run:
    cd agent/host/tests && python3 -m unittest -v test_launch_connector
"""

import contextlib
import inspect
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

HOST_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from zb_agent_host import chat, launch, login, options, sandbox, sandbox_macos  # noqa: E402
from test_backend_contract import REF_BWRAP, REF_NET_DIR, reference_build_argv, reference_launch  # noqa: E402

MAC_PORT = 51234
OTHER_PORT = 40001
PYTHON = "/opt/zb-venv/bin/python3"


class PoisonedGlobal(AssertionError):
    pass


class _Poison:
    def __getattr__(self, name):
        raise PoisonedGlobal(f"sandbox._LINUX_BACKEND.{name} was used")


def poisoned():
    return mock.patch.object(sandbox, "_LINUX_BACKEND", _Poison())


def reference_login_argv(home, seccomp_fd, python, *, net_dir, claude_cli=None):
    """The frozen login variant of launch.build_argv: the login spec binds netd's egress/ only (no bridges/), the
    CLI's directory is read-only, and the relay runs `login`."""
    venv = os.path.dirname(os.path.dirname(python))
    path_json = json.loads((home.runtime / "path.json").read_text())
    extra = [venv] + [d for d in path_json if d != "/usr" and not d.startswith("/usr/")]
    if claude_cli is not None:
        extra.append(os.path.dirname(claude_cli))
    argv, *_ = reference_launch(home, seccomp_fd=seccomp_fd, ro_paths=extra, net_dir=net_dir)
    argv = list(argv)
    i = argv.index(f"{REF_NET_DIR}/bridges")
    del argv[i - 2:i + 1]  # the --ro-bind <net_dir>/bridges /run/zb-net/bridges triple
    runtime = str(home.runtime)
    inner = [python, "-I", "-c", launch.CHAT_BOOT, f"{runtime}/host", "login", "--home", str(home.root)]
    if claude_cli is not None:
        inner += ["--e2e-claude-cli", claude_cli]
    relay = ["/usr/bin/python3", "-I", "-S", f"{runtime}/bin/zb-net-relay", "--egress", f"{REF_NET_DIR}/egress"]
    return argv + relay + ["--", *inner]


class FakeBackend:
    """A synthetic backend whose spec carries a chosen egress dir and port, so the relay choice can only come from
    the spec."""

    def __init__(self, egress_dir, port):
        self.egress_dir_value, self.port = egress_dir, port

    def network(self, session=None):
        return sandbox.Network(egress=sandbox.Egress(sandbox.Endpoint("127.0.0.1", self.port), (), self.egress_dir_value),
                               bridges=sandbox.BridgePolicy(ports=(), hooks_get_egress=False))

    def login_network(self):
        return self.network()

    @contextlib.contextmanager
    def launch(self, home, *, seccomp_fd=None, ro_paths=(), state_dirs=None, claude_writable=False, net_dir=None,
               network=None):
        yield sandbox.LaunchSpec(argv=("fake-sandbox", "--"), workdir=str(home.workspace),
                                 network=network if network is not None else self.network())


class RecordingPopen:
    """A stand-in for subprocess.Popen that records how it was called and whether it was waited for. Its pid (4242)
    differs from the exit status it reports, so a seam that returns the pid is caught."""

    def __init__(self, status, on_wait=None, fail=False):
        self.status, self.on_wait, self.fail = status, on_wait, fail
        self.calls = []

    def __call__(self, args, **kwargs):
        if self.fail:
            raise OSError("cannot spawn")
        proc = _Proc(self, args, kwargs)
        self.calls.append(proc)
        return proc


class _Proc:
    def __init__(self, owner, args, kwargs):
        self.owner, self.args, self.kwargs = owner, args, kwargs
        self.pid, self.returncode, self.waited = 4242, None, False

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def _finish(self):
        if not self.waited and self.owner.on_wait is not None:
            self.owner.on_wait(self)
        self.waited = True
        self.returncode = self.owner.status
        return self.returncode

    def wait(self, timeout=None):
        return self._finish()

    def communicate(self, input=None, timeout=None):
        self._finish()
        return None, None

    def poll(self):
        return self.returncode

    def kill(self):
        pass


class Connector(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="zb-connector-")
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name) / "home"
        self.home = options.AgentHome(root)
        for d in (".claude", "workspace", "scratchpad", "runtime"):
            (root / d).mkdir(parents=True, exist_ok=True)
        for base in (root / "state", root / ".claude"):
            base.mkdir(parents=True, exist_ok=True)
            for name in ("backups", *sandbox.STATE_DIRS):
                (base / name).mkdir(mode=0o700, exist_ok=True)
            (base / ".claude.json").write_text("{}\n")
        (root / "runtime" / "path.json").write_text(json.dumps(["/usr", "/usr/bin", "/opt/hookdir"]))
        self.net_dir = Path(self._tmp.name) / "zb-net"
        for sub in ("egress", "bridges"):
            (self.net_dir / sub).mkdir(parents=True)
        self.temp_root = Path(self._tmp.name) / "temp"
        self.temp_root.mkdir()
        saved = tempfile.tempdir
        tempfile.tempdir = str(self.temp_root)
        self.addCleanup(setattr, tempfile, "tempdir", saved)
        self.runtime = str(self.home.runtime)

    # --- helpers -------------------------------------------------------------------------------------------------
    def need(self, name):
        if not hasattr(launch, name):
            self.fail(f"launch.{name} does not exist (MS6.8 slice 1)")
        return getattr(launch, name)

    def request(self, **kw):
        fields = {"home": self.home, "python": PYTHON, "command": "chat", "read_paths": ("/opt/zb-venv", "/opt/hookdir"),
                  "test_ca": None, "claude_cli": None}
        fields.update(kw)
        return self.need("LaunchRequest")(**fields)

    def profile_dirs(self):
        return sorted(p.name for p in self.temp_root.iterdir() if p.name.startswith("zb-seatbelt-"))

    def inner(self, command="chat", *extra):
        return [PYTHON, "-I", "-c", launch.CHAT_BOOT, f"{self.runtime}/host", command, "--home", str(self.home.root),
                *extra]

    def relay(self, egress_dir):
        return ["/usr/bin/python3", "-I", "-S", f"{self.runtime}/bin/zb-net-relay", "--egress", egress_dir]

    def run_main(self, argv):
        err = io.StringIO()
        with redirect_stderr(err):
            try:
                rc = launch.main(argv)
            except SystemExit as exc:  # argparse's own usage error
                rc = exc.code
        return rc, err.getvalue()

    # --- Q: the request ------------------------------------------------------------------------------------------
    def test_q1_request_is_frozen_with_optional_realization_fields(self):
        req = self.request()
        for name in ("seccomp_fd", "net_dir", "bwrap"):
            self.assertIsNone(getattr(req, name), f"Q1: LaunchRequest.{name} must default to None")
        with self.assertRaises(Exception):
            req.python = "/other"

    # --- B: the builder and the frozen Linux wrapper ----------------------------------------------------------------
    def test_b1_build_argv_chat_is_frozen(self):
        with poisoned():
            got = launch.build_argv(self.home, 17, PYTHON, net_dir=str(self.net_dir))
        self.assertEqual(got, reference_build_argv(self.home, 17, PYTHON, net_dir=str(self.net_dir)))

    def test_b2_build_argv_test_ca_is_frozen(self):
        with poisoned():
            got = launch.build_argv(self.home, 17, PYTHON, net_dir=str(self.net_dir), test_ca="/some/ca.pem")
        self.assertEqual(got, reference_build_argv(self.home, 17, PYTHON, net_dir=str(self.net_dir),
                                                   test_ca="/some/ca.pem"))

    def test_b3_build_argv_login_is_frozen(self):
        with poisoned():
            got = launch.build_argv(self.home, 17, PYTHON, net_dir=str(self.net_dir), command="login",
                                    claude_cli="/opt/fake/claude")
        self.assertEqual(got, reference_login_argv(self.home, 17, PYTHON, net_dir=str(self.net_dir),
                                                   claude_cli="/opt/fake/claude"))

    def test_b4_linux_refuses_a_request_without_its_fd_or_dir(self):
        build = self.need("build_launch")
        for kw in ({"net_dir": str(self.net_dir)}, {"seccomp_fd": 17}):
            with self.subTest(given=kw), poisoned():
                with self.assertRaises(sandbox.SandboxError):
                    with build(sandbox.LinuxBwrapBackend(), self.request(**kw)):
                        pass

    def test_b5_mac_launch_is_the_profile_prefix_then_the_inner_chat_with_the_port(self):
        build = self.need("build_launch")
        with poisoned(), build(sandbox_macos.MacSeatbeltBackend(MAC_PORT), self.request()) as plan:
            argv = list(plan.argv)
            self.assertEqual(argv[:2], ["/usr/bin/sandbox-exec", "-f"])
            self.assertTrue(os.path.isfile(argv[2]), "B5: the profile exists while the launch is held")
            self.assertEqual(argv[3], "-D")
            self.assertEqual(argv[4], f"SCRATCHPAD={os.path.realpath(str(self.home.scratchpad))}")
            self.assertEqual(argv[5:], self.inner("chat", "--egress-port", str(MAC_PORT)))
            self.assertEqual(plan.spec.network.egress.endpoint.port, MAC_PORT)
        self.assertEqual(self.profile_dirs(), [])

    @contextlib.contextmanager
    def instrumented(self):
        """Counts profile materializations and Mac lease calls (both still run for real)."""
        counts = {"materialize": mock.MagicMock(side_effect=sandbox_macos._materialize_profile),
                  "lease": mock.MagicMock()}
        real_launch = sandbox_macos.MacSeatbeltBackend.launch

        def lease(backend, *args, **kwargs):
            counts["lease"](*args, **kwargs)
            return real_launch(backend, *args, **kwargs)

        with mock.patch.object(sandbox_macos, "_materialize_profile", counts["materialize"]), \
                mock.patch.object(sandbox_macos.MacSeatbeltBackend, "launch", lease):
            yield counts

    def test_b6_mac_refuses_linux_realization_inputs_before_any_profile(self):
        build = self.need("build_launch")
        for kw in ({"seccomp_fd": 17}, {"net_dir": str(self.net_dir)}, {"bwrap": REF_BWRAP}):
            with self.subTest(given=kw), poisoned(), self.instrumented() as counts:
                with self.assertRaises(sandbox.UnsupportedLaunchInput):
                    with build(sandbox_macos.MacSeatbeltBackend(MAC_PORT), self.request(**kw)):
                        pass
                self.assertEqual(counts["materialize"].call_count, 0, f"B6: {kw} materialized a profile")
                if "bwrap" in kw:
                    self.assertEqual(counts["lease"].call_count, 0, "B6: the bwrap refusal must come before the lease")
                self.assertEqual(self.profile_dirs(), [], f"B6: {kw} left a profile")

    # --- R: the relay comes from the spec ---------------------------------------------------------------------------
    def test_r1_a_relay_dir_adds_exactly_one_relay(self):
        build = self.need("build_launch")
        with poisoned(), build(FakeBackend("/zb/egress", OTHER_PORT), self.request()) as plan:
            argv = list(plan.argv)
        self.assertEqual(argv, ["fake-sandbox", "--", *self.relay("/zb/egress"), "--", *self.inner("chat")])

    def test_r2_no_relay_dir_adds_no_relay_and_passes_the_spec_port(self):
        build = self.need("build_launch")
        for port in (MAC_PORT, OTHER_PORT):
            with self.subTest(port=port), poisoned(), build(FakeBackend(None, port), self.request()) as plan:
                self.assertEqual(list(plan.argv), ["fake-sandbox", "--", *self.inner("chat", "--egress-port", str(port))])

    # --- E: the lease ---------------------------------------------------------------------------------------------
    def test_e1_launch_lease_is_on_the_protocol_and_both_backends_shaped_like_launch_spec(self):
        self.assertTrue(hasattr(sandbox.SandboxBackend, "launch"), "E1: SandboxBackend.launch is missing")

        def shape(fn):
            return [(p.name, p.kind, p.default) for p in inspect.signature(fn).parameters.values()]

        want = shape(sandbox.SandboxBackend.launch_spec)
        for cls in (sandbox.SandboxBackend, sandbox.LinuxBwrapBackend, sandbox_macos.MacSeatbeltBackend):
            with self.subTest(cls=cls.__name__):
                self.assertTrue(hasattr(cls, "launch"), f"E1: {cls.__name__}.launch is missing")
                self.assertEqual(shape(cls.launch), want, f"E1: {cls.__name__}.launch differs from launch_spec")

    def test_e2_linux_lease_is_a_no_op_over_its_spec(self):
        backend = sandbox.LinuxBwrapBackend()
        if not hasattr(backend, "launch"):
            self.fail("E2: LinuxBwrapBackend.launch is missing")
        want = backend.launch_spec(self.home, seccomp_fd=17, net_dir=str(self.net_dir))
        with poisoned(), backend.launch(self.home, seccomp_fd=17, net_dir=str(self.net_dir)) as spec:
            self.assertEqual(spec, want, "E2: the Linux lease must yield launch_spec's whole value")
            for field in ("argv", "unshare", "mounts", "workdir", "seccomp_fd", "network", "lifetime", "channel"):
                self.assertEqual(getattr(spec, field), getattr(want, field), f"E2: LaunchSpec.{field}")
        self.assertEqual(list(self.temp_root.iterdir()), [])

    def test_e3_mac_lease_owns_the_profile_for_exactly_its_extent(self):
        backend = sandbox_macos.MacSeatbeltBackend(MAC_PORT)
        self.assertEqual(self.profile_dirs(), [])
        with backend.launch(self.home) as spec:
            st = os.lstat(spec.argv[2])
            self.assertTrue(stat.S_ISREG(st.st_mode))
            self.assertEqual(stat.S_IMODE(st.st_mode), 0o400)
            self.assertIn(str(MAC_PORT), Path(spec.argv[2]).read_text())
            self.assertEqual(len(self.profile_dirs()), 1)
        self.assertEqual(self.profile_dirs(), [])

    def test_e4_mac_lease_removes_the_profile_on_an_exception(self):
        with self.assertRaises(RuntimeError):
            with sandbox_macos.MacSeatbeltBackend(MAC_PORT).launch(self.home):
                raise RuntimeError("the spawn failed")
        self.assertEqual(self.profile_dirs(), [])

    # --- P: the inner helpers' proxy --------------------------------------------------------------------------------
    def chat_main(self, *extra):
        with poisoned(), mock.patch.object(chat, "recorded_route", return_value="R1"), \
                mock.patch.object(chat.token, "read_token", return_value="tok"), \
                mock.patch.object(chat.asyncio, "run") as run:
            try:
                rc = chat.main(["--home", str(self.home.root), *extra])
            except SystemExit as exc:
                self.fail(f"chat refuses {list(extra)} (exit {exc.code}): its parser must take --egress-port")
        self.assertEqual(rc, 0)
        coro = run.call_args.args[0]
        obj = coro.cr_frame.f_locals["self"]
        coro.close()
        return obj

    def assert_chat_proxy(self, row, extra, want):
        obj = self.chat_main(*extra)
        self.assertEqual(getattr(obj, "proxy", None), want, f"{row}: the Chat's proxy")

    def test_p1_chat_takes_the_mac_port(self):
        self.assert_chat_proxy("P1", ("--egress-port", str(MAC_PORT)), f"http://127.0.0.1:{MAC_PORT}")

    def test_p2_chat_takes_another_port(self):
        self.assert_chat_proxy("P2", ("--egress-port", str(OTHER_PORT)), f"http://127.0.0.1:{OTHER_PORT}")

    def test_p3_chat_without_a_port_keeps_linux_3128(self):
        self.assert_chat_proxy("P3", (), "http://127.0.0.1:3128")

    def test_p4_chat_session_options_use_the_given_proxy(self):
        proxy = f"http://127.0.0.1:{MAC_PORT}"
        with poisoned():
            try:
                opts = chat.session_options(self.home, route_env={}, cli_path=None, e2e=None, test_ca=None, proxy=proxy)
            except TypeError as exc:
                self.fail(f"P4: chat.session_options takes no proxy ({exc}); it must use the one it is given")
        self.assertEqual(opts.env.get("HTTPS_PROXY"), proxy)
        self.assertEqual(opts.env.get("HTTP_PROXY"), proxy)

    def test_p8_chat_sessions_use_the_chat_proxy_at_the_real_call_site(self):
        obj = self.chat_main("--egress-port", str(MAC_PORT))
        route = mock.MagicMock(env={}, cli_path=None)
        with poisoned(), mock.patch.object(chat, "Route", return_value=route), \
                mock.patch.object(chat, "ClaudeSDKClient"):
            session = chat.Session(obj, "s1")
        want = f"http://127.0.0.1:{MAC_PORT}"
        self.assertEqual((session.opts.env.get("HTTPS_PROXY"), session.opts.env.get("HTTP_PROXY")), (want, want),
                         "P8: chat.Session's CLI options must carry the Chat's proxy")

    def login_main(self, *extra):
        with poisoned(), mock.patch.object(login.os, "fstat"), \
                mock.patch.object(login.Login, "run", autospec=True, return_value=0) as run:
            try:
                rc = login.main(["--home", str(self.home.root), "--e2e-claude-cli", "/bin/true", *extra])
            except SystemExit as exc:
                self.fail(f"login refuses {list(extra)} (exit {exc.code}): its parser must take --egress-port")
        self.assertEqual(rc, 0)
        return run.call_args.args[0]

    def test_p5_login_takes_the_port(self):
        for port in (MAC_PORT, OTHER_PORT):
            with self.subTest(port=port):
                obj = self.login_main("--egress-port", str(port))
                self.assertEqual(getattr(obj, "proxy", None), f"http://127.0.0.1:{port}", "P5: the Login's proxy")

    def test_p6_login_without_a_port_keeps_linux_3128(self):
        obj = self.login_main()
        self.assertEqual(getattr(obj, "proxy", None), "http://127.0.0.1:3128", "P6: the Login's proxy")

    def test_p7_login_cli_env_uses_the_given_proxy(self):
        proxy = f"http://127.0.0.1:{MAC_PORT}"
        with poisoned():
            try:
                env = login.cli_env(str(self.home.root), proxy)
            except TypeError as exc:
                self.fail(f"P7: login.cli_env takes no proxy ({exc}); it must use the one it is given")
        self.assertEqual(env.get("HTTPS_PROXY"), proxy)
        self.assertEqual(env.get("HTTP_PROXY"), proxy)

    def test_p9_login_spawns_the_cli_with_the_login_proxy_at_the_real_call_site(self):
        obj = self.login_main("--egress-port", str(MAC_PORT))
        seen = {}

        def popen(*_args, **kwargs):
            seen["env"] = kwargs.get("env")
            raise OSError("stop before the CLI starts")

        with poisoned(), mock.patch.object(login, "ensure_private_tmp"), \
                mock.patch.object(login.subprocess, "Popen", side_effect=popen):
            with self.assertRaises(OSError):
                obj.spawn()
        want = f"http://127.0.0.1:{MAC_PORT}"
        env = seen.get("env") or {}
        self.assertEqual((env.get("HTTPS_PROXY"), env.get("HTTP_PROXY")), (want, want),
                         "P9: Login.spawn must give the CLI the Login's proxy")

    # --- M: launch.main ---------------------------------------------------------------------------------------------
    def base(self, *extra):
        return ["--home", str(self.home.root), "--python", PYTHON, *extra]

    def test_m1_linux_main_execs_bwrap_in_place_with_the_frozen_argv(self):
        with poisoned(), mock.patch.object(launch, "PLATFORM", "linux"), \
                mock.patch.object(launch.os, "access", return_value=True), \
                mock.patch.object(launch.seccomp, "seccomp_fd", return_value=9), \
                mock.patch.object(launch.os, "set_inheritable"), \
                mock.patch.object(launch.os, "execve") as ex:
            rc, err = self.run_main(self.base("--net-dir", str(self.net_dir)))
        self.assertEqual(ex.call_count, 1, f"M1: execve once (rc={rc}, stderr={err!r})")
        path, argv, _env = ex.call_args.args
        self.assertEqual(path, REF_BWRAP)
        self.assertEqual(list(argv), reference_build_argv(self.home, 9, PYTHON, net_dir=str(self.net_dir)))

    def test_m2_linux_main_needs_a_net_dir(self):
        with mock.patch.object(launch, "PLATFORM", "linux"), mock.patch.object(launch.os, "execve") as ex:
            rc, _err = self.run_main(self.base())
        self.assertEqual(rc, launch.EXIT_USAGE)
        ex.assert_not_called()

    def darwin(self, argv, *, ready, spawn=None, popen=None, curation=None):
        """launch.main on Darwin. `ready` None keeps the real LAUNCH_SPEC_CONSUMABLE derivation; True/False replace
        that function (and only it) with a recording mock. Returns rc, stderr, execve, seccomp, readiness, counts."""
        seccomp_fd = mock.MagicMock(side_effect=AssertionError("seccomp on Darwin"))
        consumable = None if ready is None else mock.MagicMock(return_value=ready)
        with contextlib.ExitStack() as stack:
            stack.enter_context(poisoned())
            stack.enter_context(mock.patch.object(launch, "PLATFORM", "darwin"))
            stack.enter_context(mock.patch.object(launch.seccomp, "seccomp_fd", seccomp_fd))
            stack.enter_context(mock.patch.object(launch.os, "access", return_value=False))
            execve = stack.enter_context(mock.patch.object(launch.os, "execve"))
            counts = stack.enter_context(self.instrumented())
            if consumable is not None:
                stack.enter_context(mock.patch.object(sandbox_macos, "LAUNCH_SPEC_CONSUMABLE", consumable))
            if curation is not None:
                stack.enter_context(mock.patch.object(sandbox_macos, "PROFILE_CURATION", curation))
            if spawn is not None:
                stack.enter_context(mock.patch.object(launch, "spawn_helper", spawn, create=True))
            if popen is not None:
                stack.enter_context(mock.patch.object(subprocess, "Popen", popen))
            rc, err = self.run_main(argv)
        return rc, err, execve, seccomp_fd, consumable, counts

    def test_m3_darwin_main_still_refuses_while_broad(self):
        rc, err, ex, _, _, counts = self.darwin(self.base("--egress-port", str(MAC_PORT)), ready=None)
        self.assertEqual(rc, launch.EXIT_USAGE)
        self.assertIn("macOS launch is not ready", err, "M3: the BROAD refusal (and no --net-dir needed)")
        ex.assert_not_called()
        self.assertEqual(counts["lease"].call_count, 0, "M3: no lease call before the refusal")
        self.assertEqual(counts["materialize"].call_count, 0, "M3: no profile before the refusal")
        self.assertEqual(self.profile_dirs(), [])

    def test_m3b_darwin_readiness_is_launch_spec_consumable_itself(self):
        rc, err, ex, _, consumable, counts = self.darwin(self.base("--egress-port", str(MAC_PORT)), ready=False,
                                                         curation=sandbox_macos.Curation.CURATED)
        self.assertGreaterEqual(consumable.call_count, 1, "M3b: main must consult LAUNCH_SPEC_CONSUMABLE()")
        self.assertEqual(rc, launch.EXIT_USAGE)
        self.assertIn("macOS launch is not ready", err, "M3b: its False refuses, whatever PROFILE_CURATION says")
        ex.assert_not_called()
        self.assertEqual(counts["lease"].call_count, 0)
        self.assertEqual(counts["materialize"].call_count, 0)

    def spawn_recorder(self, rc=7, fail=False):
        seen = {}

        def spawn(argv, env):
            argv = list(argv)
            seen["argv"] = argv
            seen["env"] = dict(env)
            st = os.lstat(argv[2])
            seen["mode"] = stat.S_IMODE(st.st_mode)
            seen["profile"] = Path(argv[2]).read_text()
            seen["dirs"] = self.profile_dirs()
            if fail:
                raise OSError("spawn failed")
            return rc
        return spawn, seen

    def test_m4_darwin_main_spawns_inside_the_lease_and_returns_the_child_status(self):
        spawn, seen = self.spawn_recorder(rc=7)
        rc, err, ex, seccomp_fd, _, _ = self.darwin(self.base("--egress-port", str(MAC_PORT)), ready=True, spawn=spawn)
        self.assertIn("argv", seen, f"M4: launch.spawn_helper was never called (rc={rc}, stderr={err!r})")
        self.assertEqual(seen["env"], options.helper_environ(self.home, os.environ),
                         "M4: the helper environment at the spawn boundary")
        self.assertEqual(rc, 7, "M4: main returns the child's status")
        self.assertEqual(seen["argv"][:2], ["/usr/bin/sandbox-exec", "-f"])
        self.assertEqual(seen["argv"][5:], self.inner("chat", "--egress-port", str(MAC_PORT)))
        self.assertEqual(seen["mode"], 0o400)
        self.assertIn(str(MAC_PORT), seen["profile"])
        self.assertEqual(len(seen["dirs"]), 1, "M4: exactly one live profile during the spawn")
        ex.assert_not_called()
        seccomp_fd.assert_not_called()
        self.assertEqual(self.profile_dirs(), [], "M4: the profile is gone after main returns")

    def test_m5_darwin_spawn_failure_cleans_and_fails(self):
        spawn, seen = self.spawn_recorder(fail=True)
        rc, err, ex, _, _, _ = self.darwin(self.base("--egress-port", str(MAC_PORT)), ready=True, spawn=spawn)
        self.assertIn("argv", seen, f"M5: launch.spawn_helper was never called (rc={rc}, stderr={err!r})")
        self.assertEqual(rc, launch.EXIT_NO_SANDBOX)
        ex.assert_not_called()
        self.assertEqual(self.profile_dirs(), [])

    def test_m6_darwin_refuses_linux_flags_before_any_profile(self):
        for extra in (("--net-dir", str(self.net_dir)), ("--bwrap", REF_BWRAP)):
            with self.subTest(flag=extra[0]):
                spawn, seen = self.spawn_recorder()
                rc, err, ex, _, _, counts = self.darwin(self.base("--egress-port", str(MAC_PORT), *extra), ready=True,
                                                        spawn=spawn)
                self.assertEqual(rc, launch.EXIT_USAGE, f"M6: {extra[0]} on Darwin (stderr={err!r})")
                self.assertIn(extra[0], err, f"M6: the usage error must name {extra[0]} (stderr={err!r})")
                self.assertNotIn("argv", seen)
                ex.assert_not_called()
                self.assertEqual(counts["lease"].call_count, 0, f"M6: {extra[0]}: no lease call")
                self.assertEqual(counts["materialize"].call_count, 0, f"M6: {extra[0]}: no profile")
                self.assertEqual(self.profile_dirs(), [])

    def test_m7_darwin_login_spawns_the_inner_login_with_the_port(self):
        spawn, seen = self.spawn_recorder(rc=0)
        rc, err, _ex, _, _, _ = self.darwin(self.base("--egress-port", str(MAC_PORT), "--command", "login"),
                                            ready=True, spawn=spawn)
        self.assertIn("argv", seen, f"M7: launch.spawn_helper was never called (rc={rc}, stderr={err!r})")
        self.assertEqual(seen["argv"][5:], self.inner("login", "--egress-port", str(MAC_PORT)))
        self.assertIn(str(MAC_PORT), seen["profile"])


    def test_m8_darwin_main_waits_for_the_real_child_inside_the_lease(self):
        want_env = options.helper_environ(self.home, os.environ)
        seen = {}

        def on_wait(proc):
            argv = list(proc.args)
            seen["argv"], seen["env"] = argv, proc.kwargs.get("env")
            seen["live"] = os.path.isfile(argv[2]) and len(self.profile_dirs()) == 1

        popen = RecordingPopen(status=7, on_wait=on_wait)
        rc, err, ex, _, _, _ = self.darwin(self.base("--egress-port", str(MAC_PORT)), ready=True, popen=popen)
        self.assertEqual(len(popen.calls), 1, f"M8: one child (rc={rc}, stderr={err!r})")
        self.assertTrue(popen.calls[0].waited, "M8: the child must be waited for")
        self.assertTrue(seen.get("live"), "M8: the profile must still be present while the child is waited for")
        self.assertEqual(seen["argv"][5:], self.inner("chat", "--egress-port", str(MAC_PORT)))
        self.assertEqual(seen["env"], want_env, "M8: the child gets options.helper_environ(home, os.environ)")
        self.assertEqual(rc, 7, "M8: main returns the child's exit status")
        ex.assert_not_called()
        self.assertEqual(self.profile_dirs(), [])

    def test_m9_darwin_main_popen_failure_is_no_sandbox_and_cleans(self):
        popen = RecordingPopen(status=0, fail=True)
        rc, err, ex, _, _, counts = self.darwin(self.base("--egress-port", str(MAC_PORT)), ready=True, popen=popen)
        self.assertEqual(counts["materialize"].call_count, 1, f"M9: the lease was taken (rc={rc}, stderr={err!r})")
        self.assertEqual(rc, launch.EXIT_NO_SANDBOX)
        ex.assert_not_called()
        self.assertEqual(self.profile_dirs(), [])

    # --- S: the real spawn seam -----------------------------------------------------------------------------------
    def test_s1_spawn_helper_runs_the_argv_with_the_env_and_returns_the_waited_status(self):
        spawn_helper = self.need("spawn_helper")
        argv = ("/usr/bin/sandbox-exec", "-f", "/zb/profile.sb", "-D", "SCRATCHPAD=/zb/s", PYTHON, "-I")
        env = {"PATH": "/usr/bin:/bin", "ZB_CONNECTOR_ENV": "exactly-this"}
        popen = RecordingPopen(status=7)
        with mock.patch.object(subprocess, "Popen", popen):
            rc = spawn_helper(argv, env)
        self.assertEqual(len(popen.calls), 1, "S1: exactly one child")
        proc = popen.calls[0]
        self.assertEqual(list(proc.args), list(argv), "S1: the exact argv")
        self.assertFalse(proc.kwargs.get("shell", False), "S1: no shell")
        self.assertNotIn("executable", proc.kwargs, "S1: argv[0] is the program")
        self.assertEqual(proc.kwargs.get("env"), env, "S1: exactly the given environment")
        self.assertTrue(proc.waited, "S1: the child is waited for before the seam returns")
        self.assertEqual(rc, 7, "S1: the child's exit status (its pid is 4242)")

    def test_s2_spawn_helper_lets_a_popen_failure_through(self):
        spawn_helper = self.need("spawn_helper")
        with mock.patch.object(subprocess, "Popen", RecordingPopen(status=0, fail=True)):
            with self.assertRaises(OSError):
                spawn_helper(("/usr/bin/sandbox-exec",), {"PATH": "/usr/bin:/bin"})


if __name__ == "__main__":
    unittest.main()
