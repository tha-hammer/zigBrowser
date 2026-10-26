#!/usr/bin/env python3
"""Failing-first oracle for one exact, retained macOS run-root cleanup.

The green sibling must expose:

* run_cleanup(argv, *, account_lookup, uid_getter, process_probe, output,
  operation_hook=None) -> int
* reconcile_processes(before, open_pids, after, root, ancestors) -> tuple
* require_same_device(root_device, candidate_device) -> None
* CleanupRefusal

The immutable release specializes EXPECTED_BASENAME, EXPECTED_REPORT_SHA256,
and EXPECTED_REPORT_B64.  The remote entry accepts only that basename and
derives its home from the authenticated uid.  This oracle is intentionally
unregistered until its red has been reviewed.
"""

import base64
import contextlib
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
from types import SimpleNamespace


HERE = Path(__file__).resolve().parent
IMPL = HERE / "mac_exact_root_cleanup.py"
BASENAME = "zb-gate-cleanup-red-exact-79b6e6e140a02422"
MAX_OUTPUT = 8 * 1024 * 1024
CASE_NAMES = (
    "static-remote-boundary",
    "exact-success-a",
    "exact-success-b",
    "wrong-basename",
    "home-not-environment",
    "sealed-report-digest",
    "sealed-report-base64",
    "root-path",
    "root-device",
    "root-inode",
    "root-type",
    "root-mode",
    "root-uid",
    "root-gid",
    "root-size",
    "root-mtime",
    "inventory-mode-drift",
    "inventory-content-drift",
    "inventory-missing-entry",
    "inventory-added-entry",
    "marker-present",
    "relevant-process",
    "late-process-final-boundary",
    "process-probe-error",
    "main-real-process-probe",
    "process-open-missing-before",
    "process-open-missing-after",
    "process-open-changed-start",
    "process-open-changed-command",
    "process-stable-control",
    "mount-boundary",
    "mount-boundary-traversal",
    "root-symlink-substitution",
    "root-replacement-after-process",
    "unsupported-entry",
    "failure-before-first-mutation",
    "descendant-symlink-final-boundary",
    "output-bound-before-mutation",
    "partial-after-first-mutation",
    "bounded-evidence",
)


problems = []


def problem(case, detail):
    problems.append("%s: %s" % (case, detail))


def b64(raw):
    return b"b64:" + base64.urlsafe_b64encode(raw)


def entry_kind(mode):
    if stat.S_ISREG(mode):
        return b"f"
    if stat.S_ISDIR(mode):
        return b"d"
    if stat.S_ISLNK(mode):
        return b"l"
    if stat.S_ISFIFO(mode):
        return b"p"
    if stat.S_ISSOCK(mode):
        return b"s"
    return b"?"


def lstat_row(path, rel):
    info = os.lstat(path)
    target = os.readlink(path) if stat.S_ISLNK(info.st_mode) else b"-"
    return (
        rel,
        entry_kind(info.st_mode),
        stat.S_IMODE(info.st_mode),
        info.st_uid,
        info.st_gid,
        info.st_size,
        info.st_mtime_ns,
        target,
        info.st_dev,
        info.st_ino,
    )


def scan_tree(root):
    rows = []

    def visit(directory, prefix):
        with os.scandir(directory) as stream:
            entries = sorted(stream, key=lambda entry: os.fsencode(entry.name))
        for entry in entries:
            raw_name = os.fsencode(entry.name)
            rel = raw_name if not prefix else prefix + b"/" + raw_name
            path = os.path.join(directory, raw_name)
            row = lstat_row(path, rel)
            rows.append(row)
            if row[1] == b"d":
                visit(path, rel)

    visit(os.fsencode(root), b"")
    return tuple(sorted(rows, key=lambda row: row[0]))


def regular_sha(path):
    digest = hashlib.sha256()
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        while True:
            block = os.read(fd, 65536)
            if not block:
                break
            digest.update(block)
    finally:
        os.close(fd)
    return digest.hexdigest().encode("ascii")


def make_report(root, marker=b"ABSENT", process_count=0):
    root_raw = os.fsencode(root)
    root_info = os.lstat(root_raw)
    inventory = scan_tree(root_raw)
    lines = [
        b"ROOT\t" + b64(root_raw) + b"\td\t" + ("%o" % stat.S_IMODE(root_info.st_mode)).encode("ascii")
        + b"\t" + str(root_info.st_uid).encode("ascii") + b"\t" + str(root_info.st_gid).encode("ascii")
        + b"\t" + str(root_info.st_size).encode("ascii") + b"\t" + str(root_info.st_mtime_ns).encode("ascii")
        + b"\t" + str(root_info.st_dev).encode("ascii") + b"\t" + str(root_info.st_ino).encode("ascii"),
        b"ROOT_INVENTORY_COUNT\t" + str(len(inventory)).encode("ascii"),
    ]
    for row in inventory:
        rel, kind, mode, uid, gid, size, mtime, target, _dev, _ino = row
        lines.append(
            b"INVENTORY\t" + b64(rel) + b"\t" + kind + b"\t" + ("%o" % mode).encode("ascii")
            + b"\t" + str(uid).encode("ascii") + b"\t" + str(gid).encode("ascii")
            + b"\t" + str(size).encode("ascii") + b"\t" + str(mtime).encode("ascii")
            + b"\t" + (b64(target) if kind == b"l" else b"-")
        )
    lines.append(b"MARKER\tLEAKED\t" + marker)
    lines.append(b"PROCESS_COUNT\t" + str(process_count).encode("ascii"))

    selfaudit = root_raw + b"/evidence/selfaudit"
    items = (lstat_row(selfaudit, b"."),) + scan_tree(selfaudit)
    lines.append(b"SELFAUDIT_ENTRY_COUNT\t" + str(len(items)).encode("ascii"))
    for row in items:
        rel, kind, mode, _uid, _gid, size, _mtime, target, _dev, _ino = row
        if kind == b"f":
            path = selfaudit if rel == b"." else selfaudit + b"/" + rel
            payload = regular_sha(path)
        elif kind == b"l":
            payload = b64(target)
        else:
            payload = b"-"
        lines.append(
            b"SELFAUDIT_ENTRY\t" + b64(rel) + b"\t" + kind + b"\t" + ("%o" % mode).encode("ascii")
            + b"\t" + str(size).encode("ascii") + b"\t" + payload
        )
    lines.append(b"SELFAUDIT_ARCHIVE\t" + b"0" * 64 + b"\t10240")
    return b"\n".join(lines) + b"\n"


def install_seal(module, report):
    module.EXPECTED_BASENAME = os.fsencode(BASENAME)
    module.EXPECTED_REPORT_SHA256 = hashlib.sha256(report).hexdigest()
    module.EXPECTED_REPORT_B64 = base64.urlsafe_b64encode(report)


def tree_fingerprint(path):
    raw = os.fsencode(path)
    if not os.path.lexists(raw):
        return None
    first = lstat_row(raw, b".")
    if first[1] != b"d":
        return (first,)
    rows = [first]
    for row in scan_tree(raw):
        rel = row[0]
        digest = b"-"
        if row[1] == b"f":
            digest = regular_sha(raw + b"/" + rel)
        rows.append(row + (digest,))
    return tuple(rows)


def fingerprint_by_rel(path):
    value = tree_fingerprint(path)
    if value is None:
        return None
    return {row[0]: row[1:] for row in value}


def sealed_inventory(report):
    inventory = {}
    for line in report.splitlines():
        fields = line.split(b"\t")
        if fields[0] != b"INVENTORY":
            continue
        rel = base64.b64decode(fields[1][4:], altchars=b"-_", validate=True)
        inventory[rel] = fields[2]
    return inventory


def expected_delete_lines(report):
    inventory = sealed_inventory(report)
    children = {}
    for rel in inventory:
        parent = rel.rsplit(b"/", 1)[0] if b"/" in rel else b""
        children.setdefault(parent, []).append(rel)
    for values in children.values():
        values.sort(key=lambda rel: rel.rsplit(b"/", 1)[-1])

    ordered = []

    def visit(parent):
        for rel in children.get(parent, ()):
            if inventory[rel] == b"d":
                visit(rel)
            ordered.append(
                "DELETE\t%s\t%s"
                % (inventory[rel].decode("ascii"), b64(rel).decode("ascii"))
            )

    visit(b"")
    ordered.append("DELETE\td\t" + b64(b".").decode("ascii"))
    return ordered


def fixture():
    base = Path(tempfile.mkdtemp(prefix="zb-cleanup-red-", dir=os.environ["TMPDIR"]))
    home = base / "account-home"
    root = home / BASENAME
    outside = base / "outside"
    (root / "evidence" / "selfaudit" / "nested").mkdir(parents=True, mode=0o700)
    (root / "payload" / "inner").mkdir(parents=True, mode=0o700)
    outside.mkdir(mode=0o700)
    (root / "payload" / "alpha").write_bytes(b"alpha\n")
    (root / "payload" / "inner" / "beta").write_bytes(b"beta\n")
    (root / "evidence" / "selfaudit" / "audit.log").write_bytes(b"audit\n")
    (root / "evidence" / "selfaudit" / "nested" / "row").write_bytes(b"row\n")
    (outside / "sentinel").write_bytes(b"outside-must-survive\n")
    os.symlink(os.fsencode(outside), os.fsencode(root / "outside-link"))
    os.chmod(root, 0o755)
    report = make_report(root)
    return SimpleNamespace(base=base, home=home, root=root, outside=outside, report=report)


def remove_fixture(item):
    shutil.rmtree(item.base, ignore_errors=True)


def load_impl():
    spec = importlib.util.spec_from_file_location("mac_exact_root_cleanup", IMPL)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot create module spec")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def call_cleanup(module, item, *, argv=None, probe=None, hook=None):
    output = []
    calls = []

    def default_probe(root):
        calls.append(os.fsencode(root))
        return ()

    selected_probe = probe if probe is not None else default_probe
    status = module.run_cleanup(
        [BASENAME] if argv is None else argv,
        account_lookup=lambda uid: SimpleNamespace(pw_dir=str(item.home)),
        uid_getter=lambda: 502,
        process_probe=selected_probe,
        output=output.append,
        operation_hook=hook,
    )
    return status, output, calls


def output_bounded(case, output):
    encoded = "\n".join(output).encode("utf-8", "strict")
    if len(encoded) > MAX_OUTPUT or any(len(line.encode("utf-8")) > 4096 for line in output):
        problem(case, "deletion evidence is not bounded")


def expect_refusal(module, case, item, reason, *, argv=None, probe=None, hook=None):
    install_seal(module, item.report)
    before = tree_fingerprint(item.home)
    try:
        status, output, _calls = call_cleanup(module, item, argv=argv, probe=probe, hook=hook)
    except Exception as error:
        problem(case, "raised %s" % (type(error).__name__,))
        return
    after = tree_fingerprint(item.home)
    expected = "CLEANUP\tINCONCLUSIVE\t%s\tdeleted=0" % reason
    if status != 3 or output != [expected]:
        problem(case, "got rc=%r output=%r" % (status, output))
    if before != after:
        problem(case, "refusal mutated the fixture")
    output_bounded(case, output)


def mutate_root_field(report, index, value):
    lines = report.splitlines()
    fields = lines[0].split(b"\t")
    fields[index] = value
    lines[0] = b"\t".join(fields)
    return b"\n".join(lines) + b"\n"


def static_boundary(source):
    forbidden = (
        "glob(",
        "shutil.rmtree",
        "rm -rf",
        "os.kill",
        "subprocess.kill",
        "/var/folders",
        "tempfile",
        "mkstemp",
        "mkdtemp",
        "NamedTemporaryFile",
        "TemporaryDirectory",
        "<<",
    )
    for token in forbidden:
        if token in source:
            problem("static-remote-boundary", "forbidden token %r" % token)
    required = (
        "pwd.getpwuid(os.getuid()).pw_dir",
        "O_NOFOLLOW",
        "dir_fd=",
        "os.unlink(",
        "os.rmdir(",
        "before = ps_snapshot()",
        "open_pids = lsof_open_pids(root)",
        "after = ps_snapshot()",
    )
    for token in required:
        if token not in source:
            problem("static-remote-boundary", "missing %r" % token)


def success_case(module, case):
    item = fixture()
    try:
        install_seal(module, item.report)
        root_raw = os.fsencode(item.root)
        report_sha = hashlib.sha256(item.report).hexdigest()
        planned_delete = expected_delete_lines(item.report)
        planned_digest = hashlib.sha256(("\n".join(planned_delete) + "\n").encode("utf-8")).hexdigest()
        planned_count = len(planned_delete)
        inventory_count = planned_count - 1
        expected_output = [
            "CLEANUP\tBEGIN\t%s\treport_sha256=%s\tentries=%d"
            % (b64(root_raw).decode("ascii"), report_sha, inventory_count),
            *planned_delete,
            "CLEANUP\tABSENT\t%s\tdeleted=%d\tevidence_sha256=%s"
            % (b64(root_raw).decode("ascii"), planned_count, planned_digest),
        ]
        poison = item.base / "poison-home"
        poison.mkdir()
        old_home = os.environ.get("HOME")
        os.environ["HOME"] = str(poison)
        try:
            status, output, calls = call_cleanup(module, item)
        finally:
            if old_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = old_home
        if status != 0 or item.root.exists() or item.root.is_symlink():
            problem(case, "rc=%r root_exists=%r output_tail=%r" % (status, os.path.lexists(item.root), output[-3:]))
        if not (item.outside / "sentinel").is_file() or (item.outside / "sentinel").read_bytes() != b"outside-must-survive\n":
            problem(case, "symlink target outside the exact root changed")
        if not poison.is_dir():
            problem("home-not-environment", "HOME environment path was touched")
        if calls != [root_raw, root_raw]:
            problem(case, "process probe calls were %r" % (calls,))
        if output != expected_output:
            problem(case, "complete ordered deletion transcript differs: %r" % output)
        output_bounded(case, output)
        return tuple(planned_delete)
    finally:
        remove_fixture(item)


if not IMPL.is_file():
    for missing_case in CASE_NAMES:
        problem(missing_case, "implementation is absent")
else:
    try:
        source_text = IMPL.read_text(encoding="utf-8")
        static_boundary(source_text)
        module = load_impl()
    except Exception as error:
        for missing_case in CASE_NAMES:
            problem(missing_case, "implementation load failed: %s" % type(error).__name__)
    else:
        required_api = ("run_cleanup", "reconcile_processes", "require_same_device", "CleanupRefusal")
        if any(not hasattr(module, name) for name in required_api):
            for missing_case in CASE_NAMES:
                problem(missing_case, "required cleanup API is incomplete")
        else:
            order_a = success_case(module, "exact-success-a")
            order_b = success_case(module, "exact-success-b")
            if order_a != order_b:
                problem("exact-success-b", "deletion evidence order is nondeterministic")

            item = fixture()
            try:
                expect_refusal(module, "wrong-basename", item, "basename", argv=["another-root"])
            finally:
                remove_fixture(item)

            item = fixture()
            try:
                install_seal(module, item.report)
                module.EXPECTED_REPORT_SHA256 = "f" * 64
                before = tree_fingerprint(item.home)
                status, output, _calls = call_cleanup(module, item)
                if status != 3 or output != ["CLEANUP\tINCONCLUSIVE\tsealed-report\tdeleted=0"] or before != tree_fingerprint(item.home):
                    problem("sealed-report-digest", "bad seal was not a mutation-free refusal")
            finally:
                remove_fixture(item)

            item = fixture()
            try:
                install_seal(module, item.report)
                module.EXPECTED_REPORT_B64 = b"@@not-base64@@"
                before = tree_fingerprint(item.home)
                status, output, _calls = call_cleanup(module, item)
                if status != 3 or output != ["CLEANUP\tINCONCLUSIVE\tsealed-report\tdeleted=0"] or before != tree_fingerprint(item.home):
                    problem("sealed-report-base64", "noncanonical seal was not a mutation-free refusal")
            finally:
                remove_fixture(item)

            root_fields = (
                ("root-path", 1, b64(b"/wrong/root")),
                ("root-type", 2, b"f"),
                ("root-mode", 3, b"700"),
                ("root-uid", 4, b"9999"),
                ("root-gid", 5, b"9999"),
            )
            for case, index, value in root_fields:
                item = fixture()
                try:
                    item.report = mutate_root_field(item.report, index, value)
                    expect_refusal(module, case, item, "root-identity")
                finally:
                    remove_fixture(item)
            for case, index in (("root-size", 6), ("root-mtime", 7), ("root-device", 8), ("root-inode", 9)):
                item = fixture()
                try:
                    fields = item.report.splitlines()[0].split(b"\t")
                    item.report = mutate_root_field(item.report, index, str(int(fields[index]) + 1).encode("ascii"))
                    expect_refusal(module, case, item, "root-identity")
                finally:
                    remove_fixture(item)

            item = fixture()
            try:
                os.chmod(item.root / "payload" / "alpha", 0o640)
                expect_refusal(module, "inventory-mode-drift", item, "inventory")
            finally:
                remove_fixture(item)

            item = fixture()
            try:
                target = item.root / "evidence" / "selfaudit" / "audit.log"
                before_stat = target.stat()
                target.write_bytes(b"AUDIT\n")
                os.utime(target, ns=(before_stat.st_atime_ns, before_stat.st_mtime_ns))
                expect_refusal(module, "inventory-content-drift", item, "inventory")
            finally:
                remove_fixture(item)

            item = fixture()
            try:
                target = item.root / "payload" / "inner" / "beta"
                parent_stat = target.parent.stat()
                target.unlink()
                os.utime(target.parent, ns=(parent_stat.st_atime_ns, parent_stat.st_mtime_ns))
                expect_refusal(module, "inventory-missing-entry", item, "inventory")
            finally:
                remove_fixture(item)

            item = fixture()
            try:
                root_stat = item.root.stat()
                (item.root / "added").write_bytes(b"added\n")
                os.utime(item.root, ns=(root_stat.st_atime_ns, root_stat.st_mtime_ns))
                expect_refusal(module, "inventory-added-entry", item, "root-identity")
            finally:
                remove_fixture(item)

            item = fixture()
            try:
                root_stat = item.root.stat()
                (item.root / "LEAKED").write_bytes(b"LEAKED\n")
                os.utime(item.root, ns=(root_stat.st_atime_ns, root_stat.st_mtime_ns))
                expect_refusal(module, "marker-present", item, "marker")
            finally:
                remove_fixture(item)

            item = fixture()
            try:
                def live_probe(_root):
                    return ((7001, 7001, 1, b"Sat Oct 25 12:34:56 2026", b"/Applications/zigBrowser", b"zigBrowser-command"),)

                expect_refusal(module, "relevant-process", item, "process", probe=live_probe)
            finally:
                remove_fixture(item)

            item = fixture()
            try:
                install_seal(module, item.report)
                before = tree_fingerprint(item.home)
                late = {"live": False}
                calls = []

                def boundary_probe(root):
                    calls.append(os.fsencode(root))
                    if late["live"]:
                        return ((7002, 7002, 1, b"Sat Oct 25 12:34:57 2026", b"/Applications/zigBrowser", b"zigBrowser-command"),)
                    return ()

                def start_at_boundary(event, _rel, deleted):
                    if event == "before-first-mutation" and deleted == 0:
                        late["live"] = True

                status, output, _calls = call_cleanup(module, item, probe=boundary_probe, hook=start_at_boundary)
                expected = ["CLEANUP\tINCONCLUSIVE\tprocess\tdeleted=0"]
                if status != 3 or output != expected or calls != [os.fsencode(item.root), os.fsencode(item.root)]:
                    problem("late-process-final-boundary", "rc=%r calls=%r output=%r" % (status, calls, output))
                if before != tree_fingerprint(item.home):
                    problem("late-process-final-boundary", "late process refusal changed the tree")
                if any(line.startswith(("CLEANUP\tBEGIN\t", "DELETE\t", "CLEANUP\tABSENT\t")) for line in output):
                    problem("late-process-final-boundary", "mutation evidence appeared before process refusal")
            except Exception as error:
                problem("late-process-final-boundary", "raised %s" % type(error).__name__)
            finally:
                remove_fixture(item)

            item = fixture()
            try:
                def broken_probe(_root):
                    raise module.CleanupRefusal("process")

                expect_refusal(module, "process-probe-error", item, "process", probe=broken_probe)
            finally:
                remove_fixture(item)

            item = fixture()
            try:
                install_seal(module, item.report)
                before = tree_fingerprint(item.home)
                entry_calls = []
                uid_calls = []
                old_argv = module.sys.argv
                old_process_rows = module.process_rows
                old_getpwuid = module.pwd.getpwuid
                old_getuid = module.os.getuid
                old_home = os.environ.get("HOME")
                poison = item.base / "entry-poison-home"
                poison.mkdir()

                def entry_process_rows(root):
                    entry_calls.append(os.fsencode(root))
                    return ((7003, 7003, 1, b"Sat Oct 25 12:34:58 2026", b"/Applications/zigBrowser", b"zigBrowser-command"),)

                def entry_getuid():
                    uid_calls.append(True)
                    return 502

                module.sys.argv = ["mac_exact_root_cleanup.py", BASENAME]
                module.process_rows = entry_process_rows
                module.pwd.getpwuid = lambda uid: SimpleNamespace(pw_dir=str(item.home)) if uid == 502 else None
                module.os.getuid = entry_getuid
                os.environ["HOME"] = str(poison)
                captured = io.StringIO()
                try:
                    with contextlib.redirect_stdout(captured):
                        status = module.main()
                finally:
                    module.sys.argv = old_argv
                    module.process_rows = old_process_rows
                    module.pwd.getpwuid = old_getpwuid
                    module.os.getuid = old_getuid
                    if old_home is None:
                        os.environ.pop("HOME", None)
                    else:
                        os.environ["HOME"] = old_home
                output = captured.getvalue().splitlines()
                if status != 3 or output != ["CLEANUP\tINCONCLUSIVE\tprocess\tdeleted=0"]:
                    problem("main-real-process-probe", "main rc=%r output=%r" % (status, output))
                if entry_calls != [os.fsencode(item.root)] or uid_calls != [True]:
                    problem("main-real-process-probe", "entry calls=%r uid calls=%r" % (entry_calls, uid_calls))
                if before != tree_fingerprint(item.home) or not poison.is_dir():
                    problem("main-real-process-probe", "main bypassed uid home or mutated the tree")
            except Exception as error:
                problem("main-real-process-probe", "raised %s" % type(error).__name__)
            finally:
                remove_fixture(item)

            process_root = b"/Users/test/" + os.fsencode(BASENAME)
            stable = {7001: (7001, 1, b"Sat Oct 25 12:34:56 2026", b"/Applications/zigBrowser")}
            process_cases = (
                ("process-open-missing-before", {}, stable),
                ("process-open-missing-after", stable, {}),
                ("process-open-changed-start", stable, {7001: (7001, 1, b"Sat Oct 25 12:34:57 2026", b"/Applications/zigBrowser")}),
                ("process-open-changed-command", stable, {7001: (7001, 1, b"Sat Oct 25 12:34:56 2026", b"/Applications/other")}),
            )
            for case, before, after in process_cases:
                try:
                    module.reconcile_processes(before, {7001}, after, process_root, set())
                except module.CleanupRefusal:
                    pass
                except Exception as error:
                    problem(case, "wrong exception %s" % type(error).__name__)
                else:
                    problem(case, "unmatched or changed root-open pid was accepted")
            try:
                stable_rows = module.reconcile_processes(stable, {7001}, stable, process_root, set())
                if len(stable_rows) != 1 or stable_rows[0][0] != 7001:
                    problem("process-stable-control", "stable root-open pid was not retained exactly once")
            except Exception as error:
                problem("process-stable-control", "stable control raised %s" % type(error).__name__)

            try:
                module.require_same_device(10, 11)
            except module.CleanupRefusal:
                pass
            except Exception as error:
                problem("mount-boundary", "wrong exception %s" % type(error).__name__)
            else:
                problem("mount-boundary", "cross-device entry was accepted")
            try:
                module.require_same_device(10, 10)
            except Exception as error:
                problem("mount-boundary", "same-device control raised %s" % type(error).__name__)

            item = fixture()
            original_same_device = module.require_same_device
            traversal_calls = []
            try:
                def poison_traversal(root_device, candidate_device):
                    traversal_calls.append((root_device, candidate_device))
                    raise module.CleanupRefusal("mount-boundary")

                module.require_same_device = poison_traversal
                expect_refusal(module, "mount-boundary-traversal", item, "mount-boundary")
                if not traversal_calls:
                    problem("mount-boundary-traversal", "run_cleanup never consulted the mount boundary")
            finally:
                module.require_same_device = original_same_device
                remove_fixture(item)

            item = fixture()
            try:
                original = item.home / (BASENAME + "-original")
                item.root.rename(original)
                os.symlink(os.fsencode(original), os.fsencode(item.root))
                expect_refusal(module, "root-symlink-substitution", item, "symlink-root")
                if not (original / "payload" / "alpha").is_file():
                    problem("root-symlink-substitution", "symlink target was changed")
            finally:
                remove_fixture(item)

            item = fixture()
            try:
                original = item.home / (BASENAME + "-original")

                def replace_during_probe(_root):
                    item.root.rename(original)
                    item.root.mkdir(mode=0o755)
                    return ()

                install_seal(module, item.report)
                status, output, _calls = call_cleanup(module, item, probe=replace_during_probe)
                if status != 3 or output != ["CLEANUP\tINCONCLUSIVE\troot-identity\tdeleted=0"]:
                    problem("root-replacement-after-process", "replacement was not refused before mutation")
                if not (original / "payload" / "alpha").is_file():
                    problem("root-replacement-after-process", "original root was changed")
            finally:
                remove_fixture(item)

            item = fixture()
            try:
                fifo = item.root / "unsupported"
                os.mkfifo(fifo, 0o600)
                item.report = make_report(item.root)
                expect_refusal(module, "unsupported-entry", item, "unsupported-entry")
            finally:
                remove_fixture(item)

            item = fixture()
            try:
                def stop_before(event, _rel, deleted):
                    if event == "before-first-mutation" and deleted == 0:
                        raise OSError("injected pre-mutation stop")

                expect_refusal(module, "failure-before-first-mutation", item, "pre-mutation", hook=stop_before)
            finally:
                remove_fixture(item)

            item = fixture()
            try:
                install_seal(module, item.report)
                before_root = fingerprint_by_rel(item.root)
                before_outside = tree_fingerprint(item.outside)
                target = item.root / "payload" / "alpha"
                parent = target.parent
                parent_stat = parent.stat()

                def swap_descendant(event, _rel, deleted):
                    if event == "before-first-mutation" and deleted == 0:
                        target.unlink()
                        os.symlink(os.fsencode(item.outside / "sentinel"), os.fsencode(target))
                        os.utime(parent, ns=(parent_stat.st_atime_ns, parent_stat.st_mtime_ns))

                status, output, _calls = call_cleanup(module, item, hook=swap_descendant)
                if status != 3 or output != ["CLEANUP\tINCONCLUSIVE\tinventory\tdeleted=0"]:
                    problem("descendant-symlink-final-boundary", "rc=%r output=%r" % (status, output))
                if not target.is_symlink() or tree_fingerprint(item.outside) != before_outside:
                    problem("descendant-symlink-final-boundary", "outside symlink target changed or link was followed")
                after_root = fingerprint_by_rel(item.root)
                if before_root is None or after_root is None:
                    problem("descendant-symlink-final-boundary", "exact root disappeared")
                else:
                    before_root.pop(b"payload/alpha", None)
                    after_root.pop(b"payload/alpha", None)
                    if before_root != after_root:
                        problem("descendant-symlink-final-boundary", "an unrelated planned entry changed")
                if any(line.startswith(("CLEANUP\tBEGIN\t", "DELETE\t", "CLEANUP\tABSENT\t")) for line in output):
                    problem("descendant-symlink-final-boundary", "mutation evidence appeared after descendant substitution")
            except Exception as error:
                problem("descendant-symlink-final-boundary", "raised %s" % type(error).__name__)
            finally:
                remove_fixture(item)

            item = fixture()
            original_bound = module.MAX_OUTPUT
            try:
                install_seal(module, item.report)
                before = tree_fingerprint(item.home)
                module.MAX_OUTPUT = 128
                status, output, _calls = call_cleanup(module, item)
                expected = ["CLEANUP\tINCONCLUSIVE\toutput-bound\tdeleted=0"]
                if status != 3 or output != expected:
                    problem("output-bound-before-mutation", "rc=%r output=%r" % (status, output))
                if before != tree_fingerprint(item.home):
                    problem("output-bound-before-mutation", "low output bound allowed mutation")
                if any(line.startswith(("CLEANUP\tBEGIN\t", "DELETE\t", "CLEANUP\tABSENT\t")) for line in output):
                    problem("output-bound-before-mutation", "output refusal occurred after mutation evidence")
            except Exception as error:
                problem("output-bound-before-mutation", "raised %s" % type(error).__name__)
            finally:
                module.MAX_OUTPUT = original_bound
                remove_fixture(item)

            item = fixture()
            try:
                install_seal(module, item.report)

                def stop_after(event, _rel, deleted):
                    if event == "after-delete" and deleted == 1:
                        raise OSError("injected partial stop")

                status, output, _calls = call_cleanup(module, item, hook=stop_after)
                partials = [line for line in output if line.startswith("CLEANUP\tPARTIAL\t")]
                deletes = [line for line in output if line.startswith("DELETE\t")]
                if status != 4 or len(partials) != 1 or len(deletes) != 1 or "deleted=1" not in partials[0]:
                    problem("partial-after-first-mutation", "partial result was rc=%r output=%r" % (status, output))
                if any(line.startswith("CLEANUP\tABSENT\t") for line in output):
                    problem("partial-after-first-mutation", "partial deletion claimed absence")
                output_bounded("partial-after-first-mutation", output)
            except Exception as error:
                problem("partial-after-first-mutation", "raised %s" % type(error).__name__)
            finally:
                remove_fixture(item)

if problems:
    for item in problems:
        print("FAIL mac-exact-root-cleanup-red " + item, file=sys.stderr)
    raise SystemExit(1)

print("PASS mac-exact-root-cleanup-red")
