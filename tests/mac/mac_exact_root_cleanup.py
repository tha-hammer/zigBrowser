#!/usr/bin/env python3
"""Exact, sealed, no-follow cleanup for one reviewed retained run root."""

import base64
import binascii
import errno
import hashlib
import os
import pwd
import re
import stat
import subprocess
import sys


EXPECTED_BASENAME = b""
EXPECTED_REPORT_SHA256 = ""
EXPECTED_REPORT_B64 = b""
MAX_REPORT = 64 * 1024 * 1024
MAX_ENTRIES = 200000
MAX_OUTPUT = 8 * 1024 * 1024


class CleanupRefusal(Exception):
    pass


class CleanupPartial(Exception):
    pass


def refuse(reason):
    raise CleanupRefusal(reason)


def canonical_decode(value):
    if not isinstance(value, bytes) or not value.startswith(b"b64:"):
        refuse("sealed-report")
    try:
        raw = base64.b64decode(value[4:], altchars=b"-_", validate=True)
    except (ValueError, binascii.Error):
        refuse("sealed-report")
    if b"b64:" + base64.urlsafe_b64encode(raw) != value:
        refuse("sealed-report")
    return raw


def field(raw):
    return "b64:" + base64.urlsafe_b64encode(raw).decode("ascii")


def kind(mode):
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
    if stat.S_ISCHR(mode):
        return b"c"
    if stat.S_ISBLK(mode):
        return b"b"
    return b"?"


def root_identity(info):
    return (
        info.st_dev,
        info.st_ino,
        stat.S_IFMT(info.st_mode),
        stat.S_IMODE(info.st_mode),
        info.st_uid,
        info.st_gid,
        info.st_size,
        info.st_mtime_ns,
    )


def report_identity(fields):
    if len(fields) != 10:
        refuse("sealed-report")
    try:
        if fields[2] != b"d":
            refuse("root-identity")
        return (
            int(fields[8]),
            int(fields[9]),
            stat.S_IFDIR,
            int(fields[3], 8),
            int(fields[4]),
            int(fields[5]),
            int(fields[6]),
            int(fields[7]),
        )
    except (ValueError, OverflowError):
        refuse("sealed-report")


def safe_rel(raw):
    if not raw or raw.startswith(b"/") or b"\0" in raw:
        refuse("sealed-report")
    parts = raw.split(b"/")
    if any(part in (b"", b".", b"..") for part in parts):
        refuse("sealed-report")
    return tuple(parts)


def parse_sealed_report(expected_root):
    if not isinstance(EXPECTED_BASENAME, bytes) or not EXPECTED_BASENAME:
        refuse("sealed-report")
    if not isinstance(EXPECTED_REPORT_SHA256, str) or not re.fullmatch(r"[0-9a-f]{64}", EXPECTED_REPORT_SHA256):
        refuse("sealed-report")
    if not isinstance(EXPECTED_REPORT_B64, bytes):
        refuse("sealed-report")
    try:
        report = base64.b64decode(EXPECTED_REPORT_B64, altchars=b"-_", validate=True)
    except (ValueError, binascii.Error):
        refuse("sealed-report")
    if base64.urlsafe_b64encode(report) != EXPECTED_REPORT_B64 or len(report) > MAX_REPORT:
        refuse("sealed-report")
    if hashlib.sha256(report).hexdigest() != EXPECTED_REPORT_SHA256:
        refuse("sealed-report")

    root_fields = None
    declared_inventory = None
    inventory = {}
    inventory_order = []
    marker = None
    process_count = None
    declared_selfaudit = None
    selfaudit = {}
    archive_count = 0
    for line in report.splitlines():
        fields = line.split(b"\t")
        if not fields:
            refuse("sealed-report")
        tag = fields[0]
        if tag == b"ROOT":
            if root_fields is not None:
                refuse("sealed-report")
            root_fields = fields
        elif tag == b"ROOT_INVENTORY_COUNT":
            if len(fields) != 2 or declared_inventory is not None or not fields[1].isdigit():
                refuse("sealed-report")
            declared_inventory = int(fields[1])
        elif tag == b"INVENTORY":
            if len(fields) != 9:
                refuse("sealed-report")
            rel = canonical_decode(fields[1])
            safe_rel(rel)
            if rel in inventory or fields[2] not in (b"d", b"f", b"l"):
                if fields[2] not in (b"d", b"f", b"l"):
                    refuse("unsupported-entry")
                refuse("sealed-report")
            try:
                mode = int(fields[3], 8)
                uid, gid, size, mtime = (int(value) for value in fields[4:8])
            except (ValueError, OverflowError):
                refuse("sealed-report")
            target = canonical_decode(fields[8]) if fields[2] == b"l" else b"-"
            if fields[2] != b"l" and fields[8] != b"-":
                refuse("sealed-report")
            inventory[rel] = (fields[2], mode, uid, gid, size, mtime, target)
            inventory_order.append(rel)
            if len(inventory) > MAX_ENTRIES:
                refuse("sealed-report")
        elif tag == b"MARKER":
            if marker is not None or fields != [b"MARKER", b"LEAKED", b"ABSENT"]:
                refuse("sealed-report")
            marker = b"ABSENT"
        elif tag == b"PROCESS_COUNT":
            if len(fields) != 2 or process_count is not None or not fields[1].isdigit():
                refuse("sealed-report")
            process_count = int(fields[1])
        elif tag == b"PROCESS":
            refuse("sealed-report")
        elif tag == b"SELFAUDIT_ENTRY_COUNT":
            if len(fields) != 2 or declared_selfaudit is not None or not fields[1].isdigit():
                refuse("sealed-report")
            declared_selfaudit = int(fields[1])
        elif tag == b"SELFAUDIT_ENTRY":
            if len(fields) != 6:
                refuse("sealed-report")
            rel = canonical_decode(fields[1])
            if rel != b".":
                safe_rel(rel)
            if rel in selfaudit or fields[2] not in (b"d", b"f", b"l"):
                refuse("sealed-report")
            try:
                mode = int(fields[3], 8)
                size = int(fields[4])
            except (ValueError, OverflowError):
                refuse("sealed-report")
            payload = fields[5]
            if fields[2] == b"f" and not re.fullmatch(rb"[0-9a-f]{64}", payload):
                refuse("sealed-report")
            if fields[2] == b"l":
                canonical_decode(payload)
            if fields[2] == b"d" and payload != b"-":
                refuse("sealed-report")
            selfaudit[rel] = (fields[2], mode, size, payload)
        elif tag == b"SELFAUDIT_ARCHIVE":
            if len(fields) != 3 or archive_count or not re.fullmatch(rb"[0-9a-f]{64}", fields[1]) or not fields[2].isdigit():
                refuse("sealed-report")
            archive_count += 1
        else:
            refuse("sealed-report")
    if root_fields is None or canonical_decode(root_fields[1]) != expected_root:
        refuse("root-identity")
    identity = report_identity(root_fields)
    if declared_inventory != len(inventory) or inventory_order != sorted(inventory_order):
        refuse("sealed-report")
    if marker != b"ABSENT" or process_count != 0:
        refuse("sealed-report")
    if declared_selfaudit != len(selfaudit) or archive_count != 1:
        refuse("sealed-report")
    return identity, inventory, selfaudit


PS_PATTERN = re.compile(
    rb"^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\d+\s+\d\d:\d\d:\d\d\s+\d{4})\s+(.*)$"
)


def parse_ps(raw):
    table = {}
    for line in raw.splitlines():
        match = PS_PATTERN.match(line)
        if not match:
            refuse("process")
        pid, pgid, ppid = (int(match.group(index)) for index in (1, 2, 3))
        if pid <= 0 or pid in table:
            refuse("process")
        table[pid] = (pgid, ppid, match.group(4), match.group(5))
    return table


def ps_snapshot():
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,pgid=,ppid=,lstart=,command="],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
        check=False,
    )
    if result.returncode != 0 or result.stderr:
        refuse("process")
    return parse_ps(result.stdout)


def lsof_open_pids(root):
    executable = next((path for path in ("/usr/sbin/lsof", "/usr/bin/lsof") if os.path.isfile(path)), None)
    if executable is None:
        refuse("process")
    result = subprocess.run(
        [executable, "-n", "-P", "-w", "-F", "p", "+D", os.fsdecode(root)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
        check=False,
    )
    if result.returncode not in (0, 1) or result.stderr:
        refuse("process")
    pids = set()
    for line in result.stdout.splitlines():
        if line.startswith(b"p"):
            if not line[1:].isdigit() or int(line[1:]) <= 1:
                refuse("process")
            pids.add(int(line[1:]))
    return pids


def command_reasons(root, command):
    reasons = []
    if root in command or os.path.basename(root) in command:
        reasons.append(b"root-command")
    if b"zigbrowser" in command.lower():
        reasons.append(b"zigBrowser-command")
    return reasons


def reconcile_processes(before, open_pids, after, root, ancestors):
    relevant = set(open_pids)
    for table in (before, after):
        for pid, row in table.items():
            if command_reasons(root, row[3]):
                relevant.add(pid)
    result = []
    for pid in sorted(relevant):
        left = before.get(pid)
        right = after.get(pid)
        if left is None or right is None or (left[2], left[3]) != (right[2], right[3]):
            refuse("process")
        reasons = command_reasons(root, right[3])
        if pid in open_pids:
            reasons.append(b"root-open")
        if pid == os.getpid():
            continue
        if pid in ancestors and pid not in open_pids:
            continue
        if reasons:
            result.append((pid, right[0], right[1], right[2], right[3], b",".join(reasons)))
    return tuple(result)


def process_rows(root):
    before = ps_snapshot()
    open_pids = lsof_open_pids(root)
    after = ps_snapshot()
    ancestors = set()
    cursor = os.getpid()
    while cursor > 1 and cursor in after and cursor not in ancestors:
        ancestors.add(cursor)
        cursor = after[cursor][1]
    ancestors.add(cursor)
    return reconcile_processes(before, open_pids, after, root, ancestors)


def require_same_device(root_device, candidate_device):
    if root_device != candidate_device:
        refuse("mount-boundary")


def stat_record(info, target=b"-"):
    return (
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


def scan_anchored(root_fd, root_device):
    rows = {}

    def visit(directory_fd, prefix):
        try:
            names = sorted((os.fsencode(name) for name in os.listdir(directory_fd)))
        except OSError:
            refuse("inventory")
        for name in names:
            if name in (b"", b".", b"..") or b"/" in name or b"\0" in name:
                refuse("inventory")
            rel = name if not prefix else prefix + b"/" + name
            try:
                info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                target = os.readlink(name, dir_fd=directory_fd) if stat.S_ISLNK(info.st_mode) else b"-"
                target = os.fsencode(target)
            except OSError:
                refuse("inventory")
            require_same_device(root_device, info.st_dev)
            record = stat_record(info, target)
            if record[0] not in (b"d", b"f", b"l"):
                refuse("unsupported-entry")
            rows[rel] = record
            if len(rows) > MAX_ENTRIES:
                refuse("inventory")
            if record[0] == b"d":
                flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
                try:
                    child_fd = os.open(name, flags, dir_fd=directory_fd)
                    opened = os.fstat(child_fd)
                except OSError:
                    refuse("inventory")
                if (opened.st_dev, opened.st_ino, stat.S_IFMT(opened.st_mode)) != (
                    info.st_dev,
                    info.st_ino,
                    stat.S_IFMT(info.st_mode),
                ):
                    os.close(child_fd)
                    refuse("inventory")
                try:
                    visit(child_fd, rel)
                finally:
                    os.close(child_fd)

    visit(root_fd, b"")
    return rows


def comparable_inventory(rows):
    return {
        rel: (record[0], record[1], record[2], record[3], record[4], record[5], record[6])
        for rel, record in rows.items()
    }


def open_directory_path(root_fd, components, root_device):
    fd = os.dup(root_fd)
    try:
        for component in components:
            flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
            next_fd = os.open(component, flags, dir_fd=fd)
            info = os.fstat(next_fd)
            require_same_device(root_device, info.st_dev)
            os.close(fd)
            fd = next_fd
        return fd
    except Exception:
        os.close(fd)
        raise


def hash_anchored_file(root_fd, rel, expected_record, root_device):
    parts = safe_rel(rel)
    parent_fd = open_directory_path(root_fd, parts[:-1], root_device)
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(parts[-1], flags, dir_fd=parent_fd)
        try:
            info = os.fstat(fd)
            require_same_device(root_device, info.st_dev)
            if stat_record(info)[:6] != expected_record[:6] or not stat.S_ISREG(info.st_mode):
                refuse("inventory")
            digest = hashlib.sha256()
            while True:
                block = os.read(fd, 65536)
                if not block:
                    break
                digest.update(block)
            return digest.hexdigest().encode("ascii")
        finally:
            os.close(fd)
    except OSError:
        refuse("inventory")
    finally:
        os.close(parent_fd)


def verify_selfaudit(root_fd, rows, expected, root_device):
    prefix = b"evidence/selfaudit"
    current_rels = {b"."}
    for rel in rows:
        if rel == prefix:
            continue
        if rel.startswith(prefix + b"/"):
            current_rels.add(rel[len(prefix) + 1 :])
    if set(expected) != current_rels or prefix not in rows:
        refuse("inventory")
    for rel, record in expected.items():
        full = prefix if rel == b"." else prefix + b"/" + rel
        current = rows.get(full)
        if current is None:
            refuse("inventory")
        expected_kind, expected_mode, expected_size, payload = record
        if (current[0], current[1], current[4]) != (expected_kind, expected_mode, expected_size):
            refuse("inventory")
        if expected_kind == b"f":
            if hash_anchored_file(root_fd, full, current, root_device) != payload:
                refuse("inventory")
        elif expected_kind == b"l":
            if field(current[6]).encode("ascii") != payload:
                refuse("inventory")


def marker_absent(root_fd):
    try:
        os.stat(b"LEAKED", dir_fd=root_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError:
        refuse("marker")
    refuse("marker")


def require_current_root(home_fd, root_fd, basename, expected_identity):
    try:
        named = os.stat(basename, dir_fd=home_fd, follow_symlinks=False)
        opened = os.fstat(root_fd)
    except OSError:
        refuse("root-identity")
    if stat.S_ISLNK(named.st_mode):
        refuse("symlink-root")
    if root_identity(named) != expected_identity or root_identity(opened) != expected_identity:
        refuse("root-identity")


def full_preflight(home_fd, root_fd, basename, expected_identity, expected_inventory, expected_selfaudit):
    marker_absent(root_fd)
    require_current_root(home_fd, root_fd, basename, expected_identity)
    rows = scan_anchored(root_fd, expected_identity[0])
    if comparable_inventory(rows) != expected_inventory:
        refuse("inventory")
    verify_selfaudit(root_fd, rows, expected_selfaudit, expected_identity[0])
    require_current_root(home_fd, root_fd, basename, expected_identity)
    marker_absent(root_fd)
    return rows


def identity_matches(info, record):
    target = b"-"
    return stat_record(info, target)[:6] == record[:6] and info.st_dev == record[7] and info.st_ino == record[8]


def planned_delete_lines(plan):
    children = {}
    for rel in plan:
        parent = rel.rsplit(b"/", 1)[0] if b"/" in rel else b""
        children.setdefault(parent, []).append(rel)
    for values in children.values():
        values.sort(key=lambda rel: rel.rsplit(b"/", 1)[-1])
    lines = []

    def visit(parent):
        for rel in children.get(parent, ()):
            if plan[rel][0] == b"d":
                visit(rel)
            lines.append("DELETE\t%s\t%s" % (plan[rel][0].decode("ascii"), field(rel)))

    visit(b"")
    lines.append("DELETE\td\t" + field(b"."))
    return lines


def require_output_bound(root, plan):
    delete_lines = planned_delete_lines(plan)
    evidence = hashlib.sha256(("\n".join(delete_lines) + "\n").encode("utf-8")).hexdigest()
    transcript = [
        "CLEANUP\tBEGIN\t%s\treport_sha256=%s\tentries=%d"
        % (field(root), EXPECTED_REPORT_SHA256, len(plan)),
        *delete_lines,
        "CLEANUP\tABSENT\t%s\tdeleted=%d\tevidence_sha256=%s"
        % (field(root), len(delete_lines), evidence),
    ]
    if any(len(line.encode("utf-8")) > 4096 for line in transcript):
        refuse("output-bound")
    if sum(len(line.encode("utf-8")) + 1 for line in transcript) > MAX_OUTPUT:
        refuse("output-bound")


def delete_anchored(root_fd, home_fd, basename, root_identity_expected, plan, emit_delete, hook):
    deleted = 0

    def walk(directory_fd, prefix):
        nonlocal deleted
        try:
            names = sorted((os.fsencode(name) for name in os.listdir(directory_fd)))
        except OSError as error:
            raise CleanupPartial("cannot-list: %s" % error)
        expected_names = {
            rel[len(prefix) + 1 :].split(b"/", 1)[0] if prefix else rel.split(b"/", 1)[0]
            for rel in plan
            if (rel.startswith(prefix + b"/") if prefix else True)
        }
        if set(names) != expected_names:
            raise CleanupPartial("inventory-race")
        for name in names:
            rel = name if not prefix else prefix + b"/" + name
            record = plan.get(rel)
            if record is None:
                raise CleanupPartial("inventory-race")
            hook("before-entry-identity", rel, deleted)
            try:
                info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                target = os.fsencode(os.readlink(name, dir_fd=directory_fd)) if stat.S_ISLNK(info.st_mode) else b"-"
            except OSError as error:
                raise CleanupPartial("identity-race: %s" % error)
            current = stat_record(info, target)
            if current != record:
                raise CleanupPartial("identity-race")
            if record[0] == b"d":
                flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
                try:
                    child_fd = os.open(name, flags, dir_fd=directory_fd)
                    opened = os.fstat(child_fd)
                except OSError as error:
                    raise CleanupPartial("directory-race: %s" % error)
                if (opened.st_dev, opened.st_ino, stat.S_IFMT(opened.st_mode)) != (
                    record[7],
                    record[8],
                    stat.S_IFDIR,
                ):
                    os.close(child_fd)
                    raise CleanupPartial("directory-race")
                try:
                    walk(child_fd, rel)
                finally:
                    os.close(child_fd)
                try:
                    final = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                    if (final.st_dev, final.st_ino, stat.S_IFMT(final.st_mode)) != (
                        record[7],
                        record[8],
                        stat.S_IFDIR,
                    ):
                        raise CleanupPartial("directory-race")
                    os.rmdir(name, dir_fd=directory_fd)
                except OSError as error:
                    raise CleanupPartial("rmdir-failed: %s" % error)
            else:
                try:
                    os.unlink(name, dir_fd=directory_fd)
                except OSError as error:
                    raise CleanupPartial("unlink-failed: %s" % error)
            deleted += 1
            emit_delete(record[0], rel)
            hook("after-delete", rel, deleted)

    walk(root_fd, b"")
    hook("before-entry-identity", b".", deleted)
    try:
        opened = os.fstat(root_fd)
        named = os.stat(basename, dir_fd=home_fd, follow_symlinks=False)
        if (opened.st_dev, opened.st_ino, stat.S_IFMT(opened.st_mode)) != (
            root_identity_expected[0],
            root_identity_expected[1],
            stat.S_IFDIR,
        ) or (named.st_dev, named.st_ino, stat.S_IFMT(named.st_mode)) != (
            root_identity_expected[0],
            root_identity_expected[1],
            stat.S_IFDIR,
        ):
            raise CleanupPartial("root-race")
        if os.listdir(root_fd):
            raise CleanupPartial("root-not-empty")
        os.rmdir(basename, dir_fd=home_fd)
    except OSError as error:
        raise CleanupPartial("root-rmdir-failed: %s" % error)
    deleted += 1
    emit_delete(b"d", b".")
    hook("after-delete", b".", deleted)
    try:
        os.stat(basename, dir_fd=home_fd, follow_symlinks=False)
    except FileNotFoundError:
        return deleted
    except OSError as error:
        raise CleanupPartial("absence-unconfirmed: %s" % error)
    raise CleanupPartial("absence-unconfirmed")


def sanitize_reason(reason):
    return str(reason).replace("\t", " ").replace("\r", " ").replace("\n", " ")[:512]


def run_cleanup(
    argv,
    *,
    account_lookup,
    uid_getter,
    process_probe,
    output,
    operation_hook=None,
    account_home_override=None
):
    deleted = 0
    delete_lines = []
    started = False
    hook = operation_hook if operation_hook is not None else (lambda _event, _rel, _deleted: None)

    def emit(line):
        if len(line.encode("utf-8")) > 4096:
            raise CleanupPartial("output-line-bound")
        output(line)

    def emit_delete(entry_kind, rel):
        line = "DELETE\t%s\t%s" % (entry_kind.decode("ascii"), field(rel))
        delete_lines.append(line)
        if sum(len(item) + 1 for item in delete_lines) > MAX_OUTPUT:
            raise CleanupPartial("output-bound")
        emit(line)

    home_fd = None
    root_fd = None
    try:
        if len(argv) != 1 or not isinstance(argv[0], str) or os.fsencode(argv[0]) != EXPECTED_BASENAME:
            refuse("basename")
        if b"/" in EXPECTED_BASENAME or EXPECTED_BASENAME in (b".", b".."):
            refuse("basename")
        if account_home_override is None:
            account = account_lookup(uid_getter())
            home_value = account.pw_dir
        else:
            home_value = account_home_override
        home = os.fsencode(home_value)
        if not os.path.isabs(home):
            refuse("root-identity")
        root = home.rstrip(b"/") + b"/" + EXPECTED_BASENAME
        expected_identity, expected_inventory, expected_selfaudit = parse_sealed_report(root)
        try:
            live = process_probe(root)
        except CleanupRefusal:
            raise
        except Exception:
            refuse("process")
        if live:
            refuse("process")

        home_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            home_fd = os.open(home, home_flags)
        except OSError:
            refuse("root-identity")
        root_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            root_fd = os.open(EXPECTED_BASENAME, root_flags, dir_fd=home_fd)
        except OSError as error:
            try:
                candidate = os.stat(EXPECTED_BASENAME, dir_fd=home_fd, follow_symlinks=False)
            except OSError:
                refuse("root-identity")
            if stat.S_ISLNK(candidate.st_mode):
                refuse("symlink-root")
            raise CleanupRefusal("root-identity") from error
        plan = full_preflight(
            home_fd,
            root_fd,
            EXPECTED_BASENAME,
            expected_identity,
            expected_inventory,
            expected_selfaudit,
        )
        hook("before-first-mutation", b".", 0)
        try:
            live = process_probe(root)
        except CleanupRefusal:
            raise
        except Exception:
            refuse("process")
        if live:
            refuse("process")
        plan = full_preflight(
            home_fd,
            root_fd,
            EXPECTED_BASENAME,
            expected_identity,
            expected_inventory,
            expected_selfaudit,
        )
        require_output_bound(root, plan)
        emit(
            "CLEANUP\tBEGIN\t%s\treport_sha256=%s\tentries=%d"
            % (field(root), EXPECTED_REPORT_SHA256, len(plan))
        )
        started = True
        deleted = delete_anchored(
            root_fd,
            home_fd,
            EXPECTED_BASENAME,
            expected_identity,
            plan,
            emit_delete,
            hook,
        )
        evidence = hashlib.sha256(("\n".join(delete_lines) + "\n").encode("utf-8")).hexdigest()
        emit(
            "CLEANUP\tABSENT\t%s\tdeleted=%d\tevidence_sha256=%s"
            % (field(root), deleted, evidence)
        )
        return 0
    except CleanupRefusal as error:
        reason = sanitize_reason(error)
        if deleted or started:
            emit("CLEANUP\tPARTIAL\t%s\tdeleted=%d" % (reason, deleted))
            return 4
        emit("CLEANUP\tINCONCLUSIVE\t%s\tdeleted=0" % reason)
        return 3
    except CleanupPartial as error:
        emit("CLEANUP\tPARTIAL\t%s\tdeleted=%d" % (sanitize_reason(error), len(delete_lines)))
        return 4
    except Exception as error:
        if delete_lines or started:
            emit("CLEANUP\tPARTIAL\t%s\tdeleted=%d" % (sanitize_reason(error), len(delete_lines)))
            return 4
        reason = "pre-mutation" if operation_hook is not None else "internal"
        emit("CLEANUP\tINCONCLUSIVE\t%s\tdeleted=0" % reason)
        return 3
    finally:
        if root_fd is not None:
            os.close(root_fd)
        if home_fd is not None:
            os.close(home_fd)


def main():
    home = pwd.getpwuid(os.getuid()).pw_dir
    return run_cleanup(
        sys.argv[1:],
        account_lookup=pwd.getpwuid,
        uid_getter=os.getuid,
        process_probe=process_rows,
        output=print,
        account_home_override=home,
    )


if __name__ == "__main__":
    raise SystemExit(main())
