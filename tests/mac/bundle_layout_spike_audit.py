#!/usr/bin/env python3
"""Classify one 4pa.80 spike leg's outside-the-root audit (SilverRidge a365949c, 7f3b4c70).

usage: bundle_layout_spike_audit.py <leg evidence dir>
Reads <dir>/evidence/audit.roots, audit.before and audit.after (the raw snapshots, never pre-diffed text), writes a
deterministic <dir>/audit.classified, prints AUDIT<TAB><verdict><TAB><sha256><TAB><counts> (and FIRST-UNKNOWN for
AUDIT-UNKNOWN), exit 0. A structural error prints AUDIT-ERROR<TAB><why>, writes nothing, exit 2.

AUDIT-AMBIENT means only that every delta matches a reviewed pathname/metadata shape below; it says nothing about which
process wrote it. Every other delta is AUDIT-UNKNOWN. The rules are literal: no prefix, basename, name or regex family
beyond the Usage UUID grammar.
"""
import hashlib
import posixpath
import re
import sys
from collections import namedtuple
from pathlib import Path

TOKENS = ("TEMP", "CACHE", "CACHES", "HOME", "RUN")
TYPES = frozenset(("Regular File", "Directory", "Symbolic Link", "Fifo File", "Socket", "Character Device", "Block Device"))
RUN_NAME = re.compile(r"zb-gate-[0-9a-f]{40}-[0-9a-f]{16}")
MODE = re.compile(r"[0-7]{1,7}")
UUID = re.compile(r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")
# timestamp-only: the reviewed paths, exactly as both Stage B legs showed them
TS = {
    ("CACHES", "."): "TS-CACHES-ROOT",
    ("TEMP", "TemporaryItems"): "TS-TEMP-ITEMS",
    ("TEMP", "com.apple.chrono/TemporaryItems"): "TS-TEMP-CHRONO-ITEMS",
    ("TEMP", "duetexpertd/TemporaryItems"): "TS-TEMP-DUETEXPERTD-ITEMS",
    ("TEMP", "assistantd/TemporaryItems"): "TS-TEMP-ASSISTANTD-ITEMS",
    ("TEMP", "com.apple.parsec-fbf/TemporaryItems"): "TS-TEMP-PARSEC-FBF-ITEMS",
    ("CACHE", "com.apple.trustd/mds"): "TS-CACHE-TRUSTD-MDS",
    ("CACHE", "mds"): "TS-CACHE-MDS",
    ("CACHES", "com.apple.cache_delete/CacheDeleteAnalytics.plist"): "TS-CACHEDELETE-ANALYTICS",
    ("CACHES", "com.apple.cache_delete/CacheDeleteDaemonRecentInfo_v2"): "TS-CACHEDELETE-RECENT",
    ("CACHES", "com.apple.feedbacklogger/com.apple.assistantd/data.sqlite-shm"): "TS-FEEDBACKLOGGER-SHM",
    ("CACHES", "com.apple.parsecd/Cohorts/cohorts.sqlite"): "TS-PARSECD-COHORTS",
    ("CACHES", "com.apple.parsecd/Cohorts/cohorts.sqlite-shm"): "TS-PARSECD-COHORTS-SHM",
    ("CACHES", "com.apple.parsecd/Cohorts/cohorts.sqlite-wal"): "TS-PARSECD-COHORTS-WAL",
}
# atomic replacement: the reviewed regular files
AR = {
    ("CACHES", "com.apple.nsservicescache.plist"): "AR-NSSERVICESCACHE",
    ("CACHE", "com.apple.trustd/mds/mdsDirectory.db"): "AR-TRUSTD-MDSDIRECTORY",
    ("CACHE", "com.apple.trustd/mds/mdsObject.db"): "AR-TRUSTD-MDSOBJECT",
    ("CACHE", "mds/mdsDirectory.db"): "AR-MDS-MDSDIRECTORY",
    ("CACHE", "mds/mdsObject.db"): "AR-MDS-MDSOBJECT",
}
PU_PARENT = ("CACHES", "com.apple.parsecd/CustomFeedback/Usage")
PU_CHILD_MODE, PU_CHILD_SIZES, PU_DIR_STEP, PU_MAX = "100600", frozenset(("102", "115")), 32, 5

Meta = namedtuple("Meta", "type mode inode size mtime")
Delta = namedtuple("Delta", "token rel before after")
Result = namedtuple("Result", "classified verdict counts first_unknown")


class AuditError(Exception):
    pass


def normalized_abs(p):
    return p.startswith("/") and p != "/" and posixpath.normpath(p) == p and "//" not in p


def within(path, root):
    return path == root or path.startswith(root + "/")


BOUND = ("TEMP", "CACHE", "CACHES")   # resolved from a given path; HOME and RUN are physical by construction
ROOT_ID = re.compile(r"id=([0-9]+|-)")


def parse_roots(text):
    """ROOT<TAB>token<TAB>given<TAB>physical<TAB>link=no|yes<TAB>id=<inode the given path resolves to>|-"""
    roots, given, ids = {}, {}, {}
    for line in text.splitlines():
        f = line.split("\t")
        if (len(f) != 6 or f[0] != "ROOT" or f[1] not in TOKENS or f[4] not in ("link=no", "link=yes")
                or not ROOT_ID.fullmatch(f[5])):
            raise AuditError(f"malformed root line: {line!r}")
        if f[1] in roots:
            raise AuditError(f"duplicate root {f[1]}")
        if not (normalized_abs(f[2]) and normalized_abs(f[3])):
            raise AuditError(f"root {f[1]} is not absolute and normalized: {f[2]!r} {f[3]!r}")
        if f[4] == "link=yes":
            raise AuditError(f"root {f[1]} is itself a symlink: {f[2]}")
        rid = f[5][3:]
        if (f[1] in BOUND) != (rid != "-"):
            raise AuditError(f"root {f[1]} has id={rid}, want {'an inode' if f[1] in BOUND else '-'}")
        if f[1] not in BOUND and f[2] != f[3]:
            raise AuditError(f"root {f[1]} is not given by its physical path: {f[2]} {f[3]}")
        roots[f[1]], given[f[1]], ids[f[1]] = f[3], f[2], rid
    missing = [t for t in TOKENS if t not in roots]
    if missing:
        raise AuditError(f"missing roots: {' '.join(missing)}")
    return roots, given, ids


def check_bound(ids, entries, label):
    """The given path's inode must be the physical root's own entry: physical == pwd -P(given), as the leg saw it."""
    for token in BOUND:
        got = entries[(token, ".")].inode
        if got != ids[token]:
            raise AuditError(f"{label}: root {token} is given by a path that resolves to inode {ids[token]}, "
                             f"not to the physical root's {got}")


def check_containment(r):
    if r["CACHES"] != r["HOME"] + "/Library/Caches":
        raise AuditError("CACHES is not HOME/Library/Caches")
    parent, name = posixpath.split(r["RUN"])
    if parent != r["HOME"] or not RUN_NAME.fullmatch(name):
        raise AuditError("RUN is not HOME/zb-gate-<40 hex>-<16 hex>")
    disjoint = [("RUN", "TEMP"), ("RUN", "CACHE"), ("RUN", "CACHES"), ("TEMP", "CACHE"),
                ("TEMP", "HOME"), ("TEMP", "CACHES"), ("CACHE", "HOME"), ("CACHE", "CACHES")]
    for a, b in disjoint:
        if within(r[a], r[b]) or within(r[b], r[a]):
            raise AuditError(f"roots {a} and {b} overlap")


def owner(path, r):
    """(token, relative path) of the most specific physical root holding path."""
    if within(path, r["RUN"]):
        raise AuditError(f"a path at or under the run root: {path}")
    for token in ("TEMP", "CACHE", "CACHES"):
        if within(path, r[token]):
            return token, "." if path == r[token] else path[len(r[token]) + 1:]
    if path.startswith(r["HOME"] + "/") and "/" not in path[len(r["HOME"]) + 1:]:
        return "HOME", path[len(r["HOME"]) + 1:]
    raise AuditError(f"a path under no physical surface root: {path}")


def parse_snapshot(text, r, label):
    entries, prev = {}, None
    for line in text.splitlines():
        f = line.rsplit("|", 5)
        if len(f) != 6:
            raise AuditError(f"{label}: malformed line {line!r}")
        path, m = f[0], Meta(*f[1:])
        if m.type not in TYPES or not MODE.fullmatch(m.mode) or not all(x.isdigit() for x in (m.inode, m.size, m.mtime)):
            raise AuditError(f"{label}: malformed metadata {line!r}")
        if prev is not None and line.encode() <= prev.encode():
            raise AuditError(f"{label}: not sorted or duplicated at {line!r}")
        try:
            key = owner(path, r)
        except AuditError as e:
            raise AuditError(f"{label}: {e}") from None
        if key in entries:
            raise AuditError(f"{label}: duplicate path {path}")
        entries[key], prev = m, line
    covered = {t for t, rel in entries if rel == "." or t == "HOME"}
    if covered != {"TEMP", "CACHE", "CACHES", "HOME"}:
        raise AuditError(f"{label}: does not cover {' '.join(sorted({'TEMP', 'CACHE', 'CACHES', 'HOME'} - covered))}")
    return entries


def derive(before, after):
    order = {t: i for i, t in enumerate(TOKENS)}
    keys = sorted(set(before) | set(after), key=lambda k: (order[k[0]], k[1].encode()))
    return [Delta(k[0], k[1], before.get(k), after.get(k)) for k in keys if before.get(k) != after.get(k)]


def same(b, a, *fields):
    return all(getattr(b, f) == getattr(a, f) for f in fields)


def rule_of(d):
    """The candidate rule of one delta on its own, or None."""
    key, b, a = (d.token, d.rel), d.before, d.after
    if b and a and key in TS and same(b, a, "type", "mode", "inode", "size") and b.mtime != a.mtime:
        return TS[key]
    if b and a and key in AR and b.type == a.type == "Regular File" and same(b, a, "mode", "size") and b.inode != a.inode:
        return AR[key]
    if b and a and key == PU_PARENT and b.type == a.type == "Directory" and same(b, a, "mode", "inode"):
        return "PU-PARENT"
    parent, name = posixpath.split(d.rel)
    if (not b and a and (d.token, parent) == PU_PARENT and UUID.fullmatch(name) and a.type == "Regular File"
            and a.mode == PU_CHILD_MODE and a.size in PU_CHILD_SIZES):
        return "PU-CHILD"
    return None


def pu_coupled(deltas, rules):
    """The Usage additions hold only as one bounded shape: the parent grows by 32 per child, 1 to 5 children."""
    usage = [i for i, d in enumerate(deltas) if (d.token, d.rel) == PU_PARENT
             or (d.token == PU_PARENT[0] and d.rel.startswith(PU_PARENT[1] + "/"))]
    if not usage:
        return True
    children = [i for i in usage if rules[i] == "PU-CHILD"]
    parents = [i for i in usage if rules[i] == "PU-PARENT"]
    if len(parents) != 1 or len(children) + 1 != len(usage) or not 1 <= len(children) <= PU_MAX:
        return False
    p = deltas[parents[0]]
    return int(p.after.size) == int(p.before.size) + PU_DIR_STEP * len(children)


def classify(deltas):
    rules = [rule_of(d) for d in deltas]
    if not pu_coupled(deltas, rules):
        rules = [None if r in ("PU-PARENT", "PU-CHILD") else r for r in rules]
    return [(d, r or "NONE", "AMBIENT" if r else "UNKNOWN") for d, r in zip(deltas, rules)]


def family(rule):
    return rule if rule.startswith("PU-") else rule.split("-", 1)[0] if rule != "NONE" else "UNKNOWN"


def render(r, classified):
    fmt = lambda m: "|".join(m) if m else "-"
    counts = {k: 0 for k in ("TS", "AR", "PU-PARENT", "PU-CHILD", "UNKNOWN")}
    for _, rule, _ in classified:
        counts[family(rule)] += 1
    counts["TOTAL"] = len(classified)
    verdict = ("AUDIT-CLEAN" if not classified else "AUDIT-UNKNOWN" if counts["UNKNOWN"] else "AUDIT-AMBIENT")
    lines = ["AUDIT-CLASSIFIED v1"] + [f"ROOT\t{t}\t{r[t]}" for t in TOKENS]
    lines += [f"DELTA\t{d.token}\t{d.rel}\t{fmt(d.before)}\t{fmt(d.after)}\t{rule}\t{cls}" for d, rule, cls in classified]
    lines += ["COUNT\t" + "\t".join(f"{k}={v}" for k, v in counts.items()), f"VERDICT\t{verdict}"]
    first = next(((d, fmt(d.before), fmt(d.after)) for d, _, cls in classified if cls == "UNKNOWN"), None)
    return "".join(l + "\n" for l in lines), verdict, counts, first


def audit(roots_text, before_text, after_text):
    r, _, ids = parse_roots(roots_text)
    check_containment(r)
    before = parse_snapshot(before_text, r, "audit.before")
    after = parse_snapshot(after_text, r, "audit.after")
    check_bound(ids, before, "audit.before")
    check_bound(ids, after, "audit.after")
    return Result(*render(r, classify(derive(before, after))))


def main(argv):
    if len(argv) != 2:
        print("usage: bundle_layout_spike_audit.py <leg evidence dir>", file=sys.stderr)
        return 2
    d = Path(argv[1])
    try:
        texts = [(d / "evidence" / n).read_text() for n in ("audit.roots", "audit.before", "audit.after")]
        res = audit(*texts)
    except (AuditError, OSError, UnicodeDecodeError) as e:
        print(f"AUDIT-ERROR\t{e}")
        return 2
    (d / "audit.classified").write_text(res.classified)
    sha = hashlib.sha256(res.classified.encode()).hexdigest()
    print(f"AUDIT\t{res.verdict}\t{sha}\t" + "\t".join(f"{k}={v}" for k, v in res.counts.items()))
    if res.first_unknown:
        dl, b, a = res.first_unknown
        print(f"FIRST-UNKNOWN\t{dl.token}\t{dl.rel}\t{b}\t{a}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
