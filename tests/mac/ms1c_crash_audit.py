#!/usr/bin/env python3
"""Fail-closed MS1c browser-process and macOS crash-report evidence audit."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
from typing import Optional, Union


ROWS = ("render", "render", "reply", "loadfail", "arch", "control")
SHIM_REF = "@executable_path/../Frameworks/libwkwebview_shim.dylib"


def field(value: Union[str, bytes]) -> str:
    raw = os.fsencode(value)
    return "b64:" + base64.urlsafe_b64encode(raw).decode("ascii")


def decode_field(value: str) -> bytes:
    if not value.startswith("b64:") or not value.isascii():
        raise ValueError("not a canonical evidence field")
    raw = base64.b64decode(value[4:].encode("ascii"), altchars=b"-_", validate=True)
    if field(raw) != value:
        raise ValueError("not a canonical evidence field")
    return raw


def read_ledger(path: Path) -> tuple[list[tuple[str, int, int, str]], Optional[str]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return [], "missing process record"
    records: list[tuple[str, int, int, str]] = []
    try:
        for line in lines:
            parts = line.split("\t")
            if len(parts) != 4 or not parts[0] or not parts[3]:
                return [], "conflict process record"
            pid, status = int(parts[1]), int(parts[2])
            if pid <= 1 or len(os.fsencode(parts[3])) > 512 or any(c in parts[3] for c in "\r\n"):
                return [], "conflict process record"
            records.append((parts[0], pid, status, parts[3]))
    except ValueError:
        return [], "conflict process record"
    return records, None


def row_records(args: argparse.Namespace) -> int:
    records, error = read_ledger(args.ledger)
    selected = [record for record in records if record[0] == args.row]
    expected = args.expected_count
    if error is None:
        if len(selected) < expected:
            error = "missing process record"
        elif len(selected) > expected:
            error = ("duplicate process record" if len(set(selected)) < len(selected)
                     else "conflict process record")
        elif any(record[3] != args.expected_exe for record in selected):
            error = "conflict process record"
    if error is not None:
        print(f"PROCESSAUDIT\tINCONCLUSIVE\t{error}")
        args.audit_marker.write_text(error + "\n", encoding="ascii")
        return 3
    abnormal = False
    for row, pid, status, executable in selected:
        print(f"PROCESS\t{row}\t{pid}\t{status}\t{field(executable)}")
        if status not in args.allow_status:
            print(f"PRODUCT-FAIL\tabnormal-exit\t{row}\t{pid}\t{status}")
            abnormal = True
    return 1 if abnormal else 0


def load_snapshot_rows(path: Path) -> Optional[dict[bytes, str]]:
    try:
        lines = path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError):
        return None
    if not lines or not lines[-1].startswith("END\t") or any(line.startswith("ERROR\t") for line in lines):
        return None
    rows: dict[bytes, str] = {}
    try:
        for line in lines[1:-1]:
            if line.startswith("SKIPPED-PROTECTED\t"):
                continue
            encoded, metadata = line.split("\t", 1)
            rows[decode_field(encoded)] = metadata
    except (ValueError, binascii.Error):
        return None
    return rows


def process_table(path: Path) -> tuple[list[tuple[str, int, int, str]], Optional[str]]:
    records, error = read_ledger(path)
    if error is not None:
        return records, error
    if len(records) < len(ROWS):
        return records, "missing process record"
    if len(records) > len(ROWS):
        return records, ("duplicate process record" if len(set(records)) < len(records)
                         else "conflict process record")
    if tuple(record[0] for record in records) != ROWS:
        return records, "conflict process record"
    if len({record[1] for record in records}) != len(records):
        return records, "conflict process record"
    product_exe = records[0][3]
    if any(record[3] != product_exe for record in records[:5]) or records[5][3] == product_exe:
        return records, "conflict process record"
    return records, None


def parse_incident(raw: bytes) -> tuple[dict, dict]:
    text = raw.decode("utf-8", "strict")
    decoder = json.JSONDecoder()
    metadata, end = decoder.raw_decode(text)
    if not isinstance(metadata, dict):
        raise ValueError("metadata is not an object")
    while end < len(text) and text[end].isspace():
        end += 1
    incident, end = decoder.raw_decode(text, end)
    if not isinstance(incident, dict) or text[end:].strip():
        raise ValueError("incident is not the sole second JSON value")
    meta_fields = ("app_name", "timestamp", "slice_uuid", "bundleID", "bug_type", "os_version", "name", "incident_id")
    if any(not isinstance(metadata.get(name), str) for name in meta_fields):
        raise ValueError("metadata has a missing or mistyped field")
    pid, proc_path = incident.get("pid"), incident.get("procPath")
    exception, termination = incident.get("exception"), incident.get("termination")
    if (isinstance(pid, bool) or not isinstance(pid, int) or pid <= 1 or not isinstance(proc_path, str)
            or not proc_path or not isinstance(exception, dict) or not isinstance(termination, dict)
            or not isinstance(exception.get("type"), str) or not isinstance(exception.get("signal"), str)
            or not isinstance(termination.get("namespace"), str)
            or not isinstance(termination.get("indicator"), str)):
        raise ValueError("incident has a missing or mistyped field")
    if termination["namespace"] == "DYLD":
        details = termination.get("details")
        if not isinstance(details, list) or any(not isinstance(item, str) for item in details):
            raise ValueError("DYLD incident details are mistyped")
    return metadata, incident


def observed_control_diagnostic(path: Path, control_exe: str) -> bool:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return False
    referenced = f"Referenced from: {control_exe}"
    referenced_uuid = f"> {control_exe}"
    return (f"Library not loaded: {SHIM_REF}" in text
            and (referenced in text or referenced_uuid in text))


def missing_shim_incident(incident: dict) -> bool:
    exception, termination = incident["exception"], incident["termination"]
    details = termination.get("details", [])
    return (exception.get("type") == "EXC_CRASH"
            and termination.get("namespace") == "DYLD"
            and termination.get("indicator") == "Library missing"
            and any(SHIM_REF in item for item in details))


def structured_zigbrowser(metadata: dict, incident: dict) -> bool:
    bundle = incident.get("bundleInfo")
    bundle_id = bundle.get("CFBundleIdentifier") if isinstance(bundle, dict) else None
    return (metadata.get("bundleID") == "com.cosmichq.zigBrowser"
            or bundle_id == "com.cosmichq.zigBrowser"
            or incident.get("procName") == "zigBrowser")


def report_records(args: argparse.Namespace) -> int:
    before = load_snapshot_rows(args.before)
    records, table_error = process_table(args.ledger)
    marker_error = None
    try:
        marker_error = args.audit_marker.read_text(encoding="ascii").strip()
    except FileNotFoundError:
        pass
    except (OSError, UnicodeError):
        marker_error = "conflict process record"
    if marker_error:
        table_error = marker_error

    diag_raw = os.fsencode(args.diag)
    try:
        entries = list(os.scandir(diag_raw))
    except OSError:
        entries = []
        scan_error = True
    else:
        scan_error = False
    diag_rel = os.fsencode(args.diag_rel)
    old = set()
    if before is not None:
        old = {rel for rel in before if os.path.dirname(rel) == diag_rel}
    else:
        scan_error = True
    new_entries = []
    for entry in entries:
        name = entry.name
        rel = os.path.join(diag_rel, name)
        if rel not in old and name.endswith(b".ips"):
            new_entries.append((name, rel, os.path.join(diag_raw, name)))
    new_entries.sort(key=lambda item: item[0])

    try:
        with args.ignore_out.open("w", encoding="ascii") as ignore:
            for _name, rel, _path in new_entries:
                ignore.write(field(rel) + "\n")
    except OSError:
        scan_error = True

    control_ok = observed_control_diagnostic(args.control_err, args.control_exe)
    exact_control_used = False
    product = False
    inconclusive = scan_error or table_error is not None
    launched = {(pid, executable) for _row, pid, _status, executable in records}
    control = records[-1] if table_error is None else None

    for name, _rel, path in new_entries:
        digest = "-"
        kind, pid, proc_path = "UNREADABLE", "-", "-"
        try:
            fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            try:
                st = os.fstat(fd)
                if not stat.S_ISREG(st.st_mode):
                    raise OSError("report is not a regular file")
                chunks = []
                total = 0
                while True:
                    chunk = os.read(fd, 1048576)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > 16 * 1024 * 1024:
                        raise OSError("report is too large")
                    chunks.append(chunk)
                raw = b"".join(chunks)
            finally:
                os.close(fd)
            digest = hashlib.sha256(raw).hexdigest()
        except OSError:
            raw = None
        if raw is None:
            inconclusive = True
        else:
            try:
                metadata, incident = parse_incident(raw)
            except (UnicodeError, ValueError, json.JSONDecodeError):
                kind = "MALFORMED"
                inconclusive = True
            else:
                pid, proc_path = incident["pid"], incident["procPath"]
                try:
                    path_too_large = len(os.fsencode(proc_path)) > 512
                except UnicodeError:
                    path_too_large = True
                if path_too_large:
                    kind, pid, proc_path = "MALFORMED", "-", "-"
                    inconclusive = True
                    print(f"CRASHREPORT\t{field(name)}\t{digest}\t{kind}\t{pid}\t{proc_path}")
                    continue
                if table_error is not None:
                    kind = "UNVERIFIED"
                    inconclusive = True
                else:
                    assert control is not None
                    exact_control = (pid == control[1] and proc_path == control[3] and control[2] == -6
                                     and missing_shim_incident(incident) and control_ok)
                    if exact_control and not exact_control_used:
                        kind = "CONTROL"
                        exact_control_used = True
                    elif (pid, proc_path) in launched or structured_zigbrowser(metadata, incident):
                        kind = "PRODUCT"
                        product = True
                    else:
                        kind = "OTHER"
        encoded_path = field(proc_path) if proc_path != "-" else "-"
        print(f"CRASHREPORT\t{field(name)}\t{digest}\t{kind}\t{pid}\t{encoded_path}")
        if kind == "PRODUCT":
            print(f"PRODUCT-FAIL\tcrash-report\t{field(name)}")

    if inconclusive:
        return 3
    return 2 if product else 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    sub = result.add_subparsers(dest="command", required=True)
    row = sub.add_parser("row")
    row.add_argument("--ledger", type=Path, required=True)
    row.add_argument("--audit-marker", type=Path, required=True)
    row.add_argument("--row", required=True)
    row.add_argument("--expected-count", type=int, required=True)
    row.add_argument("--expected-exe", required=True)
    row.add_argument("--allow-status", type=int, action="append", default=[])
    reports = sub.add_parser("reports")
    reports.add_argument("--ledger", type=Path, required=True)
    reports.add_argument("--audit-marker", type=Path, required=True)
    reports.add_argument("--before", type=Path, required=True)
    reports.add_argument("--diag", required=True)
    reports.add_argument("--diag-rel", required=True)
    reports.add_argument("--control-exe", required=True)
    reports.add_argument("--control-err", type=Path, required=True)
    reports.add_argument("--ignore-out", type=Path, required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    if args.command == "row":
        return row_records(args)
    return report_records(args)


if __name__ == "__main__":
    raise SystemExit(main())
