"""pidns_guard arms a real-signal test only on KERNEL proof that it runs in a PID namespace below the launcher's
(RoseCat 7433: fb13f88's guard trusted a forgeable ZB_OUTER_PIDNS string, and a PID 1 named sh is a legitimate host
shape).

The launcher opens its own /proc/self/ns/pid as an inherited fd before unshare and names it in ZB_OUTER_PIDNS_FD. The
guard arms only when that fd is a PID namespace (NS_GET_NSTYPE), is not this process's own (dev/ino), and this
process's pid translates INTO it (NS_GET_TGID_IN_PIDNS), which holds only for a strict ancestor; plus, as defense in
depth, pid 1 is this process or its parent. Each forgery below runs the guard in a fresh interpreter on this host and
must NOT arm:
- the old string ZB_OUTER_PIDNS=pid:[forged] with no fd;
- an fd to this host process's own PID namespace;
- an fd to a file that is not a namespace;
- a closed or non-numeric fd;
- an fd to a DESCENDANT PID namespace (another process's).
- inside a namespace whose pid 1 IS a sh, a forged string with no held fd (RoseCat's own probe shape).
And the reviewed launcher form (fd held before unshare, then unshare --user --map-root-user --pid --fork --mount-proc)
DOES arm. These rows signal nothing (the descendant namespace's own sleeper ends by itself in 5 s).
Run: cd agent/host/tests && python -X dev -m unittest -v test_pidns_guard. Unregistered until the green.
"""
import os
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = ("import sys; sys.path.insert(0, %r); import pidns_guard; ok, why = pidns_guard.private_pid_namespace(); "
         "print('ARMED' if ok else 'SKIP:' + why)" % HERE)


def guard(env_extra, pass_fds=()):
    env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", **env_extra}
    out = subprocess.run([sys.executable, "-I", "-c", CHECK], env=env, pass_fds=pass_fds, capture_output=True,
                         text=True, timeout=30)
    return out.stdout.strip() or out.stderr.strip()


class Forgeries(unittest.TestCase):
    def assert_not_armed(self, result, why):
        self.assertTrue(result.startswith("SKIP:"), f"{why} armed the guard: {result}")

    def test_the_old_string_alone_does_not_arm(self):
        self.assert_not_armed(guard({"ZB_OUTER_PIDNS": "pid:[forged]"}), "a forged string")

    def test_an_fd_to_our_own_pid_namespace_does_not_arm(self):
        fd = os.open("/proc/self/ns/pid", os.O_RDONLY)
        self.addCleanup(os.close, fd)
        self.assert_not_armed(guard({"ZB_OUTER_PIDNS_FD": str(fd)}, (fd,)), "our own namespace")

    def test_an_fd_that_is_not_a_namespace_does_not_arm(self):
        f = tempfile.TemporaryFile()
        self.addCleanup(f.close)
        self.assert_not_armed(guard({"ZB_OUTER_PIDNS_FD": str(f.fileno())}, (f.fileno(),)), "a plain file")

    def test_a_closed_or_malformed_fd_does_not_arm(self):
        for value in ("99", "x", "", "-1", "3 "):
            with self.subTest(fd=value):
                self.assert_not_armed(guard({"ZB_OUTER_PIDNS_FD": value}), f"fd {value!r}")

    def test_a_descendant_pid_namespace_does_not_arm(self):
        child = subprocess.Popen(["unshare", "--user", "--map-root-user", "--pid", "--fork", "sleep", "5"])
        self.addCleanup(child.wait)
        deadline = time.monotonic() + 5
        sleeper = None
        while sleeper is None and time.monotonic() < deadline:
            for p in os.listdir("/proc"):
                if p.isdigit():
                    try:
                        with open(f"/proc/{p}/stat") as f:
                            fields = f.read().rsplit(")", 1)[1].split()
                        with open(f"/proc/{p}/comm") as f:
                            comm = f.read().strip()
                    except OSError:
                        continue
                    if comm == "sleep" and int(fields[1]) == child.pid:
                        sleeper = int(p)
            time.sleep(0.05)
        self.assertIsNotNone(sleeper, "the descendant namespace started")
        fd = os.open(f"/proc/{sleeper}/ns/pid", os.O_RDONLY)
        self.addCleanup(os.close, fd)
        self.assert_not_armed(guard({"ZB_OUTER_PIDNS_FD": str(fd)}, (fd,)), "a descendant namespace")


class ForgedInsideANamespace(unittest.TestCase):
    def test_a_sh_pid_1_and_a_forged_string_without_the_held_fd_does_not_arm(self):
        """RoseCat 7433's probe: pid 1 is a sh and ZB_OUTER_PIDNS names some other namespace, but no launcher held
        the outer namespace: a string is not proof."""
        out = subprocess.run(
            ["unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc", "sh", "-c",
             f'env -i PATH=/usr/bin:/bin ZB_OUTER_PIDNS="pid:[forged]" {sys.executable} -I -c "$1"; :', "pid1-sh",
             CHECK], capture_output=True, text=True, timeout=30)
        self.assertTrue(out.stdout.strip().startswith("SKIP:"), f"a forged string armed the guard: {out.stdout!r}")


class Launcher(unittest.TestCase):
    def test_the_reviewed_launcher_form_arms(self):
        out = subprocess.run(
            ["sh", "-c", 'exec 9</proc/self/ns/pid; exec unshare --user --map-root-user --pid --fork --mount-proc '
             f'env -i PATH=/usr/bin:/bin ZB_OUTER_PIDNS_FD=9 {sys.executable} -I -c "$1"', "launcher", CHECK],
            capture_output=True, text=True, timeout=30)
        self.assertEqual(out.stdout.strip(), "ARMED", out.stderr)


if __name__ == "__main__":
    unittest.main()
