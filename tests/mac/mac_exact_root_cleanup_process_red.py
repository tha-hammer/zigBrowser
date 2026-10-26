#!/usr/bin/env python3
"""Failing-first oracle for the cleanup's real final process boundary.

The success case deliberately enters ``main()`` with real ``process_rows`` and
real ``lsof``.  At the second process probe the cleanup itself holds the sealed
root directory open.  Only that exact, stable current pid may be ignored.
External holders, an ancestor holder, unstable self identity, and a separate
zigBrowser-named process must all refuse before ``BEGIN``.

This oracle is intentionally unregistered until its red is reviewed.
"""

import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
IMPL = Path(os.environ.get("ZB_EXACT_ROOT_CLEANUP_IMPL", HERE / "mac_exact_root_cleanup.py")).resolve()
BASENAME = "zb-cleanup-process-boundary-root"
CASES = (
    "self-holder-main-success",
    "self-holder-reconcile",
    "self-missing-before",
    "self-missing-after",
    "self-changed-start",
    "self-changed-command",
    "external-root-holder",
    "ancestor-root-holder",
    "separate-root-command-process",
    "separate-zigbrowser-process",
)
problems = []


def problem(case, detail):
    problems.append("%s: %s" % (case, detail))


def b64(raw):
    return b"b64:" + base64.urlsafe_b64encode(raw)


def kind(mode):
    if stat.S_ISDIR(mode):
        return b"d"
    if stat.S_ISREG(mode):
        return b"f"
    if stat.S_ISLNK(mode):
        return b"l"
    return b"?"


def sha256_file(path):
    digest = hashlib.sha256()
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        while True:
            block = os.read(fd, 65536)
            if not block:
                return digest.hexdigest().encode("ascii")
            digest.update(block)
    finally:
        os.close(fd)


def row(path, rel):
    info = os.lstat(path)
    target = os.fsencode(os.readlink(path)) if stat.S_ISLNK(info.st_mode) else b"-"
    return (
        rel,
        kind(info.st_mode),
        stat.S_IMODE(info.st_mode),
        info.st_uid,
        info.st_gid,
        info.st_size,
        info.st_mtime_ns,
        target,
        info.st_dev,
        info.st_ino,
    )


def scan(root):
    rows = []

    def visit(directory, prefix):
        with os.scandir(directory) as stream:
            entries = sorted(stream, key=lambda entry: os.fsencode(entry.name))
        for entry in entries:
            name = os.fsencode(entry.name)
            rel = name if not prefix else prefix + b"/" + name
            item = os.path.join(directory, name)
            current = row(item, rel)
            rows.append(current)
            if current[1] == b"d":
                visit(item, rel)

    visit(os.fsencode(root), b"")
    return tuple(sorted(rows, key=lambda current: current[0]))


def make_report(root):
    root_raw = os.fsencode(root)
    root_info = os.lstat(root_raw)
    inventory = scan(root_raw)
    lines = [
        b"\t".join(
            (
                b"ROOT",
                b64(root_raw),
                b"d",
                ("%o" % stat.S_IMODE(root_info.st_mode)).encode("ascii"),
                str(root_info.st_uid).encode("ascii"),
                str(root_info.st_gid).encode("ascii"),
                str(root_info.st_size).encode("ascii"),
                str(root_info.st_mtime_ns).encode("ascii"),
                str(root_info.st_dev).encode("ascii"),
                str(root_info.st_ino).encode("ascii"),
            )
        ),
        b"ROOT_INVENTORY_COUNT\t" + str(len(inventory)).encode("ascii"),
    ]
    for rel, entry_kind, mode, uid, gid, size, mtime, target, _dev, _ino in inventory:
        lines.append(
            b"\t".join(
                (
                    b"INVENTORY",
                    b64(rel),
                    entry_kind,
                    ("%o" % mode).encode("ascii"),
                    str(uid).encode("ascii"),
                    str(gid).encode("ascii"),
                    str(size).encode("ascii"),
                    str(mtime).encode("ascii"),
                    b64(target) if entry_kind == b"l" else b"-",
                )
            )
        )
    lines.extend((b"MARKER\tLEAKED\tABSENT", b"PROCESS_COUNT\t0"))

    selfaudit = root_raw + b"/evidence/selfaudit"
    selfaudit_rows = (row(selfaudit, b"."),) + scan(selfaudit)
    lines.append(b"SELFAUDIT_ENTRY_COUNT\t" + str(len(selfaudit_rows)).encode("ascii"))
    for rel, entry_kind, mode, _uid, _gid, size, _mtime, target, _dev, _ino in selfaudit_rows:
        if entry_kind == b"f":
            path = selfaudit if rel == b"." else selfaudit + b"/" + rel
            payload = sha256_file(path)
        elif entry_kind == b"l":
            payload = b64(target)
        else:
            payload = b"-"
        lines.append(
            b"\t".join(
                (
                    b"SELFAUDIT_ENTRY",
                    b64(rel),
                    entry_kind,
                    ("%o" % mode).encode("ascii"),
                    str(size).encode("ascii"),
                    payload,
                )
            )
        )
    lines.append(b"SELFAUDIT_ARCHIVE\t" + b"0" * 64 + b"\t10240")
    return b"\n".join(lines) + b"\n"


def fixture():
    base = Path(tempfile.mkdtemp(prefix="zb-cleanup-process-red-", dir=os.environ["TMPDIR"]))
    home = base / "account-home"
    root = home / BASENAME
    (root / "evidence" / "selfaudit").mkdir(parents=True, mode=0o700)
    (root / "payload").mkdir(mode=0o700)
    (root / "evidence" / "selfaudit" / "audit.log").write_bytes(b"audit\n")
    (root / "payload" / "item").write_bytes(b"payload\n")
    os.chmod(root, 0o755)
    return base, home, root, make_report(root)


def fingerprint(root):
    if not os.path.lexists(root):
        return None
    result = []
    for current in (row(root, b"."),) + scan(root):
        digest = sha256_file(os.fsencode(root) + b"/" + current[0]) if current[1] == b"f" else b"-"
        result.append(current + (digest,))
    return tuple(result)


def load_impl():
    spec = importlib.util.spec_from_file_location("mac_exact_root_cleanup_process_red_impl", IMPL)
    if spec is None or spec.loader is None:
        raise RuntimeError("implementation cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def install_seal(module, report):
    module.EXPECTED_BASENAME = os.fsencode(BASENAME)
    module.EXPECTED_REPORT_SHA256 = hashlib.sha256(report).hexdigest()
    module.EXPECTED_REPORT_B64 = base64.urlsafe_b64encode(report)


def expected_delete_lines(report):
    inventory = {}
    for line in report.splitlines():
        fields = line.split(b"\t")
        if fields[0] == b"INVENTORY":
            rel = base64.b64decode(fields[1][4:], altchars=b"-_", validate=True)
            inventory[rel] = fields[2]
    children = {}
    for rel in inventory:
        parent = rel.rsplit(b"/", 1)[0] if b"/" in rel else b""
        children.setdefault(parent, []).append(rel)
    for values in children.values():
        values.sort(key=lambda rel: rel.rsplit(b"/", 1)[-1])
    result = []

    def visit(parent):
        for rel in children.get(parent, ()):
            if inventory[rel] == b"d":
                visit(rel)
            result.append("DELETE\t%s\t%s" % (inventory[rel].decode("ascii"), b64(rel).decode("ascii")))

    visit(b"")
    result.append("DELETE\td\t" + b64(b".").decode("ascii"))
    return result


def expected_success(root, report):
    deletes = expected_delete_lines(report)
    digest = hashlib.sha256(("\n".join(deletes) + "\n").encode("utf-8")).hexdigest()
    root_field = b64(os.fsencode(root)).decode("ascii")
    return [
        "CLEANUP\tBEGIN\t%s\treport_sha256=%s\tentries=%d"
        % (root_field, hashlib.sha256(report).hexdigest(), len(deletes) - 1),
        *deletes,
        "CLEANUP\tABSENT\t%s\tdeleted=%d\tevidence_sha256=%s" % (root_field, len(deletes), digest),
    ]


def call_main(module, home):
    old_argv = module.sys.argv
    old_getpwuid = module.pwd.getpwuid
    module.sys.argv = [str(IMPL), BASENAME]
    module.pwd.getpwuid = lambda _uid: type("Account", (), {"pw_dir": str(home)})()
    captured = io.StringIO()
    try:
        with contextlib.redirect_stdout(captured):
            status = module.main()
    finally:
        module.sys.argv = old_argv
        module.pwd.getpwuid = old_getpwuid
    return status, captured.getvalue().splitlines()


def assert_refusal(case, status, output, before, root):
    expected = ["CLEANUP\tINCONCLUSIVE\tprocess\tdeleted=0"]
    if status != 3 or output != expected:
        problem(case, "rc=%r output=%r" % (status, output))
    if fingerprint(root) != before:
        problem(case, "process refusal changed the sealed fixture")
    if any(line.startswith(("CLEANUP\tBEGIN\t", "DELETE\t", "CLEANUP\tABSENT\t")) for line in output):
        problem(case, "mutation transcript appeared before refusal")


def main_success_case(module):
    base, home, root, report = fixture()
    try:
        install_seal(module, report)
        status, output = call_main(module, home)
        expected = expected_success(root, report)
        if status != 0 or output != expected or os.path.lexists(root):
            problem(
                "self-holder-main-success",
                "rc=%r root_exists=%r output=%r" % (status, os.path.lexists(root), output),
            )
    finally:
        shutil.rmtree(base, ignore_errors=True)


HOLDER = r'''import os, sys
fd = os.open(os.environ["ZB_HELD_ROOT"], os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    print("READY", flush=True)
    sys.stdin.buffer.read()
finally:
    os.close(fd)
'''


def stop_waiter(proc):
    if proc.stdin is not None:
        proc.stdin.close()
        proc.stdin = None
    stdout, stderr = proc.communicate(timeout=5)
    if proc.returncode != 0 or stderr:
        raise RuntimeError("holder rc=%r stdout=%r stderr=%r" % (proc.returncode, stdout, stderr))


def external_holder_case(module):
    base, home, root, report = fixture()
    proc = None
    try:
        install_seal(module, report)
        before = fingerprint(root)
        env = dict(os.environ)
        env["ZB_HELD_ROOT"] = str(root)
        proc = subprocess.Popen(
            [sys.executable, "-I", "-X", "dev", "-W", "error", "-B", "-c", HOLDER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        if proc.stdout is None or proc.stdout.readline() != b"READY\n":
            raise RuntimeError("holder did not become ready")
        status, output = call_main(module, home)
        assert_refusal("external-root-holder", status, output, before, root)
    except Exception as error:
        problem("external-root-holder", "raised %s: %s" % (type(error).__name__, error))
    finally:
        if proc is not None:
            try:
                stop_waiter(proc)
            except Exception as error:
                problem("external-root-holder", "holder shutdown failed: %s" % error)
        shutil.rmtree(base, ignore_errors=True)


PARENT_SHELL = r'''set -eu
if [ "$ZB_PARENT_HOLD" = 1 ]; then
    exec 9<"$ZB_PARENT_MEMBER"
fi
"$ZB_PARENT_PYTHON" -I -X dev -W error -B "$ZB_PARENT_ORACLE" --parent-shell-child &
child=$!
wait "$child"
'''


def call_through_parent_shell(home, root, report, hold):
    env = dict(os.environ)
    env.update(
        {
            "PYTHONDONTWRITEBYTECODE": "1",
            "ZB_PARENT_HOLD": "1" if hold else "0",
            "ZB_PARENT_MEMBER": str(root / "payload" / "item"),
            "ZB_PARENT_PYTHON": sys.executable,
            "ZB_PARENT_ORACLE": str(Path(__file__).resolve()),
            "ZB_PARENT_HOME": str(home),
            "ZB_PARENT_REPORT": base64.urlsafe_b64encode(report).decode("ascii"),
        }
    )
    completed = subprocess.run(
        ["/bin/sh", "-c", PARENT_SHELL, BASENAME],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        check=False,
    )
    if completed.returncode != 0 or completed.stderr:
        raise RuntimeError(
            "parent shell rc=%r stdout=%r stderr=%r"
            % (completed.returncode, completed.stdout, completed.stderr)
        )
    return json.loads(completed.stdout.decode("utf-8"))


def ancestor_holder_case(_module):
    base, home, root, report = fixture()
    try:
        decoded = call_through_parent_shell(home, root, report, False)
        expected = expected_success(root, report)
        if decoded.get("status") != 0 or decoded.get("output") != expected or os.path.lexists(root):
            problem(
                "ancestor-root-holder",
                "non-holding parent blocked cleanup: rc=%r root_exists=%r output=%r"
                % (decoded.get("status"), os.path.lexists(root), decoded.get("output")),
            )
    except Exception as error:
        problem("ancestor-root-holder", "non-holding parent raised %s: %s" % (type(error).__name__, error))
    finally:
        shutil.rmtree(base, ignore_errors=True)

    base, home, root, report = fixture()
    try:
        before = fingerprint(root)
        decoded = call_through_parent_shell(home, root, report, True)
        assert_refusal("ancestor-root-holder", decoded.get("status"), decoded.get("output"), before, root)
    except Exception as error:
        problem("ancestor-root-holder", "holding parent raised %s: %s" % (type(error).__name__, error))
    finally:
        shutil.rmtree(base, ignore_errors=True)


def zigbrowser_case(module):
    base, home, root, report = fixture()
    proc = None
    try:
        install_seal(module, report)
        before = fingerprint(root)
        executable = base / "zigBrowser"
        proc = subprocess.Popen(
            [
                str(executable),
                "-I",
                "-X",
                "dev",
                "-W",
                "error",
                "-B",
                "-c",
                "import sys; print('READY', flush=True); sys.stdin.buffer.read()",
            ],
            executable=sys.executable,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if proc.stdout is None or proc.stdout.readline() != b"READY\n":
            raise RuntimeError("zigBrowser process did not become ready")
        status, output = call_main(module, home)
        assert_refusal("separate-zigbrowser-process", status, output, before, root)
    except Exception as error:
        problem("separate-zigbrowser-process", "raised %s: %s" % (type(error).__name__, error))
    finally:
        if proc is not None:
            try:
                stop_waiter(proc)
            except Exception as error:
                problem("separate-zigbrowser-process", "process shutdown failed: %s" % error)
        shutil.rmtree(base, ignore_errors=True)


def root_command_case(module):
    base, home, root, report = fixture()
    proc = None
    try:
        install_seal(module, report)
        before = fingerprint(root)
        proc = subprocess.Popen(
            [
                sys.executable,
                "-I",
                "-X",
                "dev",
                "-W",
                "error",
                "-B",
                "-c",
                "import sys; print('READY', flush=True); sys.stdin.buffer.read()",
                str(root),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if proc.stdout is None or proc.stdout.readline() != b"READY\n":
            raise RuntimeError("root-command process did not become ready")
        status, output = call_main(module, home)
        assert_refusal("separate-root-command-process", status, output, before, root)
    except Exception as error:
        problem("separate-root-command-process", "raised %s: %s" % (type(error).__name__, error))
    finally:
        if proc is not None:
            try:
                stop_waiter(proc)
            except Exception as error:
                problem("separate-root-command-process", "process shutdown failed: %s" % error)
        shutil.rmtree(base, ignore_errors=True)


def unstable_identity_case(module, case, second_before, second_after):
    base, home, root, report = fixture()
    original_ps = module.ps_snapshot
    original_lsof = module.lsof_open_pids
    try:
        install_seal(module, report)
        before_tree = fingerprint(root)
        pid = os.getpid()
        ppid = os.getppid()
        stable = {
            pid: (
                pid,
                ppid,
                b"Sat Oct 25 12:34:56 2026",
                b"/usr/bin/python3 -I -B cleanup.py",
            )
        }
        snapshots = iter((stable, stable, second_before, second_after))
        open_sets = iter((set(), {pid}))
        snapshot_calls = []
        lsof_calls = []

        def ps_snapshot():
            snapshot_calls.append(True)
            return next(snapshots)

        def lsof_open_pids(got_root):
            lsof_calls.append(os.fsencode(got_root))
            return next(open_sets)

        module.ps_snapshot = ps_snapshot
        module.lsof_open_pids = lsof_open_pids
        status, output = call_main(module, home)
        assert_refusal(case, status, output, before_tree, root)
        if len(snapshot_calls) != 4 or lsof_calls != [os.fsencode(root), os.fsencode(root)]:
            problem(case, "main bypassed the two production process_rows boundaries")
    except Exception as error:
        problem(case, "raised %s: %s" % (type(error).__name__, error))
    finally:
        module.ps_snapshot = original_ps
        module.lsof_open_pids = original_lsof
        shutil.rmtree(base, ignore_errors=True)


def reconcile_cases(module):
    pid = os.getpid()
    ppid = os.getppid()
    root = b"/private/tmp/" + os.fsencode(BASENAME)
    start = b"Sat Oct 25 12:34:56 2026"
    command = b"/usr/bin/python3 -I -B cleanup.py"
    stable = {pid: (pid, ppid, start, command)}
    try:
        rows = module.reconcile_processes(stable, {pid}, stable, root, {pid, ppid})
        if rows:
            problem("self-holder-reconcile", "stable current pid remained live: %r" % (rows,))
    except Exception as error:
        problem("self-holder-reconcile", "raised %s" % type(error).__name__)

    unstable_identity_case(module, "self-missing-before", {}, stable)
    unstable_identity_case(module, "self-missing-after", stable, {})
    unstable_identity_case(
        module,
        "self-changed-start",
        stable,
        {pid: (pid, ppid, b"Sat Oct 25 12:34:57 2026", command)},
    )
    unstable_identity_case(
        module,
        "self-changed-command",
        stable,
        {pid: (pid, ppid, start, command + b" --changed")},
    )


def parent_shell_child():
    report = base64.b64decode(os.environ["ZB_PARENT_REPORT"], altchars=b"-_", validate=True)
    module = load_impl()
    install_seal(module, report)
    status, output = call_main(module, Path(os.environ["ZB_PARENT_HOME"]))
    print(json.dumps({"status": status, "output": output}, separators=(",", ":")))


def run():
    if not IMPL.is_file():
        for case in CASES:
            problem(case, "implementation is absent")
        return
    try:
        module = load_impl()
    except Exception as error:
        for case in CASES:
            problem(case, "implementation load failed: %s" % type(error).__name__)
        return
    main_success_case(module)
    reconcile_cases(module)
    external_holder_case(module)
    ancestor_holder_case(module)
    root_command_case(module)
    zigbrowser_case(module)


if sys.argv[1:] == ["--parent-shell-child"]:
    parent_shell_child()
else:
    run()
    if problems:
        for item in problems:
            print("PROBLEM\t" + item)
        print("FAIL\tmac-exact-root-cleanup-process-red\t%d problems" % len(problems))
        raise SystemExit(1)

    print("PASS\tmac-exact-root-cleanup-process-red\t%d cases" % len(CASES))
