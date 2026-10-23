"""4pa.80 slice 2 (SilverRidge 7f3b4c70): tests/mac/bundle_layout_spike_audit.py, the audit classifier.

It reads one leg's evidence/audit.roots, evidence/audit.before and evidence/audit.after itself (never pre-diffed text),
validates them, derives every delta, classifies each one by a closed, named rule, and writes a deterministic
<evidence dir>/audit.classified:
  AUDIT-CLASSIFIED v1
  ROOT<TAB><token><TAB><physical root>                        (TEMP, CACHE, CACHES, HOME, RUN, in that order)
  DELTA<TAB><token><TAB><relative path|.><TAB><before meta|-><TAB><after meta|-><TAB><rule id><TAB>AMBIENT|UNKNOWN
  COUNT<TAB>TS=<n><TAB>AR=<n><TAB>PU-PARENT=<n><TAB>PU-CHILD=<n><TAB>UNKNOWN=<n><TAB>TOTAL=<n>
  VERDICT<TAB>AUDIT-CLEAN|AUDIT-AMBIENT|AUDIT-UNKNOWN
where meta is type|mode|inode|size|mtime and DELTA lines are in (root order, relative path bytes) order. It prints
  AUDIT<TAB><verdict><TAB><sha256 of audit.classified><TAB>TS=..<TAB>AR=..<TAB>PU-PARENT=..<TAB>PU-CHILD=..<TAB>UNKNOWN=..<TAB>TOTAL=..
and, for AUDIT-UNKNOWN, FIRST-UNKNOWN<TAB><token><TAB><relative path><TAB><before meta><TAB><after meta> (the first
UNKNOWN delta in that order); exit 0. A structural error prints AUDIT-ERROR<TAB><why>, writes no audit.classified and
exits 2. Module API: audit(roots_text, before_text, after_text) -> Result(classified, verdict, counts, first_unknown),
raising AuditError.

Rules (closed, literal):
  TS  timestamp-only, an exact reviewed path (14 literal entries), same type/mode/inode/size, only mtime changed;
  AR  atomic replacement, an exact reviewed path (5 literal entries), regular file before and after, same mode and
      size, inode changed;
  PU  parsecd Usage additions: each child a new regular file CACHES/com.apple.parsecd/CustomFeedback/Usage/<UPPERCASE
      UUID>, mode 100600, size 102 or 115; the Usage directory keeps type, mode and inode and grows by exactly 32*N,
      1 <= N <= 5; no other change below Usage. Otherwise every Usage delta is UNKNOWN.
Roots: ROOT<TAB>token<TAB>given<TAB>physical<TAB>link=no|yes<TAB>id=<inode>|-, exactly one each of TEMP, CACHE, CACHES,
HOME, RUN; given and physical absolute and normalized; given may differ from physical (macOS resolves /var through
/private/var), but a bound root's id (the inode the leg's stat -L of the given path saw) must be its physical root
entry's inode in both snapshots, and HOME and RUN carry id=- with given == physical (SilverRidge 1950c0bb); link=yes
(the root entry itself a symlink) is refused;
CACHES == HOME/Library/Caches; RUN a direct child of HOME named zb-gate-<40 hex>-<16 hex>; RUN disjoint from TEMP,
CACHE, CACHES; TEMP and CACHE disjoint from HOME, CACHES and each other. Snapshots: path|type|mode|inode|size|mtime,
byte-sorted, unique, every path under exactly the most specific physical root (CACHES before HOME), HOME entries only
at depth 1, nothing at or under RUN, and each snapshot covers TEMP, CACHE and CACHES (their root entries) and at least
one HOME entry.
Rows: Q1 provenance (the fixtures give back the recorded Stage B diff lines and their bead hashes, and every line they
share is a declared synthetic one); Q2 Intel and Q3
arm64 real fixtures: AUDIT-AMBIENT with the pinned family counts; Q4 identical pairs: AUDIT-CLEAN; Q5 determinism,
output shape and the printed SHA-256; Q6 each family alone; Q7 every UNKNOWN shape; Q8 root refusals, the accepted
/var alias and the given/physical binding; Q9 snapshot refusals (every metadata column, a sibling-prefix path, a
missing surface root entry); Q10 FIRST-UNKNOWN.
Run: cd tests/e2e && python3 -X dev -m unittest -v mac_spike_audit_test
"""
import hashlib
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "tests" / "mac" / "bundle_layout_spike_audit.py"
FX = REPO / "tests" / "mac" / "fixtures" / "4pa80_audit"
USAGE = "com.apple.parsecd/CustomFeedback/Usage"
UUID1 = "29252333-E65A-4438-8102-6FCE33E45B58"


def load():
    if not SCRIPT.is_file():
        raise AssertionError("tests/mac/bundle_layout_spike_audit.py is missing (4pa.80 slice 2)")
    spec = importlib.util.spec_from_file_location("bundle_layout_spike_audit", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def fx(name):
    return (FX / name).read_text()


def roots_of(text):
    return {l.split("\t")[1]: l.split("\t")[3] for l in text.splitlines()}


def edit(text, old_prefix, new_line=None):
    """Replace (or, with new_line None, drop) the one snapshot line that starts with old_prefix + '|'."""
    lines = text.splitlines()
    hits = [i for i, l in enumerate(lines) if l.startswith(old_prefix + "|")]
    assert len(hits) == 1, (old_prefix, hits)
    if new_line is None:
        del lines[hits[0]]
    else:
        lines[hits[0]] = new_line
    return "".join(l + "\n" for l in sorted(lines, key=lambda x: x.encode()))


def add(text, *new_lines):
    lines = text.splitlines() + list(new_lines)
    return "".join(l + "\n" for l in sorted(lines, key=lambda x: x.encode()))


def meta(text, path):
    l = [x for x in text.splitlines() if x.startswith(path + "|")]
    assert len(l) == 1, path
    return l[0][len(path) + 1:].split("|")


class Base(unittest.TestCase):
    def setUp(self):
        self.mod = load()
        self.ir, self.ib, self.ia = fx("intel.roots"), fx("intel.before"), fx("intel.after")
        self.ar, self.ab, self.aa = fx("arm.roots"), fx("arm.before"), fx("arm.after")
        self.I, self.A = roots_of(self.ir), roots_of(self.ar)

    def run_audit(self, roots, before, after):
        return self.mod.audit(roots, before, after)

    def assertUnknown(self, roots, before, after, token, rel):
        r = self.run_audit(roots, before, after)
        self.assertEqual(r.verdict, "AUDIT-UNKNOWN")
        rows = [l.split("\t") for l in r.classified.splitlines() if l.startswith("DELTA\t")]
        hit = [x for x in rows if x[1] == token and x[2] == rel]
        self.assertTrue(hit, f"no DELTA for {token} {rel}: {rows}")
        self.assertEqual(hit[0][6], "UNKNOWN", hit[0])
        return r

    def assertError(self, roots, before, after, reason):
        """A structural error, for the stated reason (so a row cannot pass on a later, unrelated refusal)."""
        with self.assertRaises(self.mod.AuditError) as cm:
            self.run_audit(roots, before, after)
        self.assertIn(reason, str(cm.exception))


class Provenance(unittest.TestCase):
    def test_q1_provenance(self):
        prov = fx("provenance.txt").splitlines()
        sets = {l.split("\t")[1]: (int(l.split("\t")[2]), l.split("\t")[3]) for l in prov if l.startswith("SET\t")}
        subst = [l.split("\t")[1:3] for l in prov if l.startswith("SUBST\t")]
        self.assertEqual(sorted(sets), ["arm", "intel"])
        self.assertEqual(subst, [["/private/var/folders/", "/var/folders/"]], "exactly one declared substitution")
        with tempfile.TemporaryDirectory() as d:
            for arch, (n, sha) in sets.items():
                for side in ("before", "after"):
                    Path(d, side).write_text(fx(f"{arch}.{side}").replace(*subst[0]))
                out = subprocess.run(["diff", f"{d}/before", f"{d}/after"], capture_output=True, text=True,
                                     env=dict(os.environ, LC_ALL="C")).stdout
                got = "".join(l + "\n" for l in out.splitlines() if l[:2] in ("< ", "> "))
                self.assertEqual((len(got.splitlines()), hashlib.sha256(got.encode()).hexdigest()), (n, sha), arch)
                syn = fx(f"{arch}.synthetic").splitlines()
                shared = set(fx(f"{arch}.before").splitlines()) & set(fx(f"{arch}.after").splitlines())
                self.assertEqual(len(syn), len(set(syn)), arch)
                self.assertEqual(shared, set(syn), f"{arch}: the lines both snapshots share must be exactly the declared synthetic ones")


class RealFixtures(Base):
    def counts(self, r):
        return {k: r.counts[k] for k in ("TS", "AR", "PU-PARENT", "PU-CHILD", "UNKNOWN", "TOTAL")}

    def test_q2_intel(self):
        r = self.run_audit(self.ir, self.ib, self.ia)
        self.assertEqual(r.verdict, "AUDIT-AMBIENT")
        self.assertEqual(self.counts(r), {"TS": 6, "AR": 5, "PU-PARENT": 0, "PU-CHILD": 0, "UNKNOWN": 0, "TOTAL": 11})

    def test_q3_arm(self):
        r = self.run_audit(self.ar, self.ab, self.aa)
        self.assertEqual(r.verdict, "AUDIT-AMBIENT")
        self.assertEqual(self.counts(r), {"TS": 11, "AR": 1, "PU-PARENT": 1, "PU-CHILD": 5, "UNKNOWN": 0, "TOTAL": 18})

    def test_q4_identical_is_clean(self):
        for roots, snap in ((self.ir, self.ib), (self.ir, self.ia), (self.ar, self.ab), (self.ar, self.aa)):
            r = self.run_audit(roots, snap, snap)
            self.assertEqual((r.verdict, r.counts["TOTAL"]), ("AUDIT-CLEAN", 0))


class Cli(Base):
    def evdir(self, root, roots, before, after):
        e = Path(root) / "evidence"
        e.mkdir(parents=True)
        (e / "audit.roots").write_text(roots)
        (e / "audit.before").write_text(before)
        (e / "audit.after").write_text(after)
        return Path(root)

    def cli(self, d):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), str(d)], capture_output=True, text=True)

    def test_q5_determinism_shape_sha(self):
        with tempfile.TemporaryDirectory() as t1, tempfile.TemporaryDirectory() as t2:
            d1, d2 = self.evdir(t1, self.ar, self.ab, self.aa), self.evdir(t2 + "/x/y", self.ar, self.ab, self.aa)
            r1, r1b, r2 = self.cli(d1), self.cli(d1), self.cli(d2)
            self.assertEqual((r1.returncode, r2.returncode), (0, 0), r1.stdout + r1.stderr)
            c1 = (d1 / "audit.classified").read_bytes()
            self.assertEqual(c1, (d2 / "audit.classified").read_bytes())
            self.assertEqual(r1.stdout, r1b.stdout)
            self.assertEqual(r1.stdout, r2.stdout)
            sha = hashlib.sha256(c1).hexdigest()
            self.assertEqual(r1.stdout.splitlines()[0],
                             f"AUDIT\tAUDIT-AMBIENT\t{sha}\tTS=11\tAR=1\tPU-PARENT=1\tPU-CHILD=5\tUNKNOWN=0\tTOTAL=18")
            lines = c1.decode().splitlines()
            self.assertEqual(lines[0], "AUDIT-CLASSIFIED v1")
            self.assertEqual([l.split("\t")[1] for l in lines[1:6]], ["TEMP", "CACHE", "CACHES", "HOME", "RUN"])
            self.assertEqual(lines[1].split("\t")[2], self.A["TEMP"])
            deltas = [l.split("\t") for l in lines if l.startswith("DELTA\t")]
            self.assertEqual(len(deltas), 18)
            order = {t: i for i, t in enumerate(["TEMP", "CACHE", "CACHES", "HOME", "RUN"])}
            self.assertEqual(deltas, sorted(deltas, key=lambda x: (order[x[1]], x[2].encode())))
            usage = [x for x in deltas if x[2] == USAGE][0]
            self.assertEqual(usage[3:7], ["Directory|40700|29492899|64|1792668446",
                                          "Directory|40700|29492899|224|1792744060", "PU-PARENT", "AMBIENT"])
            child = [x for x in deltas if x[2] == f"{USAGE}/{UUID1}"][0]
            self.assertEqual(child[3:7], ["-", "Regular File|100600|31195747|102|1792744060", "PU-CHILD", "AMBIENT"])
            self.assertTrue(all(x[5] != "NONE" for x in deltas))
            self.assertEqual(lines[-2], "COUNT\tTS=11\tAR=1\tPU-PARENT=1\tPU-CHILD=5\tUNKNOWN=0\tTOTAL=18")
            self.assertEqual(lines[-1], "VERDICT\tAUDIT-AMBIENT")

    def test_q8_error_cli(self):
        with tempfile.TemporaryDirectory() as t:
            d = self.evdir(t, self.ir.replace("link=no", "link=yes", 1), self.ib, self.ia)
            r = self.cli(d)
            self.assertEqual(r.returncode, 2)
            self.assertTrue(r.stdout.startswith("AUDIT-ERROR\t"), r.stdout)
            self.assertFalse((d / "audit.classified").exists())

    def test_q10_first_unknown(self):
        T, C = self.I["TEMP"], self.I["CACHES"]
        after = edit(self.ia, f"{C}/com.apple.nsservicescache.plist")                 # deletion (CACHES)
        after = add(after, f"{T}/zb-new|Regular File|100644|1|1|1792743964")           # addition (TEMP): first
        with tempfile.TemporaryDirectory() as t:
            r = self.cli(self.evdir(t, self.ir, self.ib, after))
            self.assertEqual(r.returncode, 0)
            self.assertEqual(r.stdout.splitlines()[0].split("\t")[1], "AUDIT-UNKNOWN")
            self.assertEqual(r.stdout.splitlines()[1], "FIRST-UNKNOWN\tTEMP\tzb-new\t-\tRegular File|100644|1|1|1792743964")


class Families(Base):
    def test_q6_ts_alone(self):
        T = self.I["TEMP"]
        p = f"{T}/TemporaryItems"
        m = meta(self.ib, p)
        r = self.run_audit(self.ir, self.ib, edit(self.ib, p, f"{p}|{'|'.join(m[:4])}|1799999999"))
        self.assertEqual((r.verdict, r.counts["TS"], r.counts["TOTAL"]), ("AUDIT-AMBIENT", 1, 1))

    def test_q6_ar_alone(self):
        p = f"{self.I['CACHES']}/com.apple.nsservicescache.plist"
        m = meta(self.ib, p)
        r = self.run_audit(self.ir, self.ib, edit(self.ib, p, f"{p}|{m[0]}|{m[1]}|7777777|{m[3]}|{m[4]}"))
        self.assertEqual((r.verdict, r.counts["AR"], r.counts["TOTAL"]), ("AUDIT-AMBIENT", 1, 1))

    def test_q6_pu_alone(self):
        C = self.A["CACHES"]
        after = self.ab
        for l in self.aa.splitlines():
            if l.startswith(f"{C}/{USAGE}"):
                after = edit(after, f"{C}/{USAGE}", l) if l.startswith(f"{C}/{USAGE}|") else add(after, l)
        r = self.run_audit(self.ar, self.ab, after)
        self.assertEqual((r.verdict, r.counts["PU-PARENT"], r.counts["PU-CHILD"], r.counts["TOTAL"]),
                         ("AUDIT-AMBIENT", 1, 5, 6))


class Unknown(Base):
    """Every shape outside the closed rules is AUDIT-UNKNOWN (SilverRidge a365949c, 7f3b4c70)."""

    def set_line(self, text, path, *, typ=None, mode=None, ino=None, size=None, mtime=None):
        m = meta(text, path)
        new = [typ or m[0], mode or m[1], ino or m[2], size or m[3], mtime or m[4]]
        return edit(text, path, f"{path}|{'|'.join(new)}")

    def test_q7_deletion(self):
        p = f"{self.I['TEMP']}/TemporaryItems"
        self.assertUnknown(self.ir, self.ib, edit(self.ib, p), "TEMP", "TemporaryItems")

    def test_q7_addition_elsewhere(self):
        self.assertUnknown(self.ir, self.ib, add(self.ib, f"{self.I['CACHES']}/com.apple.zz/new|Regular File|100644|5|5|5"),
                           "CACHES", "com.apple.zz/new")

    def test_q7_broader_prefix(self):
        T = self.I["TEMP"]
        b = add(self.ib, f"{T}/com.apple.other/TemporaryItems|Directory|40700|11|64|1790000000")
        a = self.set_line(b, f"{T}/com.apple.other/TemporaryItems", mtime="1799999999")
        self.assertUnknown(self.ir, b, a, "TEMP", "com.apple.other/TemporaryItems")

    def test_q7_other_com_apple_replacement(self):
        C = self.I["CACHES"]
        b = add(self.ib, f"{C}/com.apple.othercache.plist|Regular File|100644|12|100|1790000000")
        self.assertUnknown(self.ir, b, self.set_line(b, f"{C}/com.apple.othercache.plist", ino="13"),
                           "CACHES", "com.apple.othercache.plist")

    def test_q7_ts_mismatches(self):
        p = f"{self.I['TEMP']}/TemporaryItems"
        for kw in ({"size": "999", "mtime": "1799999999"}, {"mode": "40755", "mtime": "1799999999"},
                   {"ino": "424242", "mtime": "1799999999"}, {"typ": "Regular File", "mtime": "1799999999"}):
            with self.subTest(**kw):
                self.assertUnknown(self.ir, self.ib, self.set_line(self.ib, p, **kw), "TEMP", "TemporaryItems")

    def test_q7_ar_mismatches(self):
        p = f"{self.I['CACHES']}/com.apple.nsservicescache.plist"
        for kw in ({"ino": "7777777", "size": "1"}, {"ino": "7777777", "mode": "100600"}, {"mtime": "1799999999"}):
            with self.subTest(**kw):
                self.assertUnknown(self.ir, self.ib, self.set_line(self.ib, p, **kw), "CACHES", "com.apple.nsservicescache.plist")

    def test_q7_ar_needs_a_regular_file(self):
        C = self.I["CACHES"]
        p = f"{C}/com.apple.nsservicescache.plist"
        b = self.set_line(self.ib, p, typ="Directory", mode="40700")
        self.assertUnknown(self.ir, b, self.set_line(b, p, ino="7777777"), "CACHES", "com.apple.nsservicescache.plist")

    def pu(self, children, parent_size=None, parent_ino=None, parent_touched=False, parent_typ=None, parent_mode=None):
        """arm before -> after with the given Usage children and parent size growth."""
        C = self.A["CACHES"]
        after = add(self.ab, *[f"{C}/{USAGE}/{name}|{rest}" for name, rest in children])
        if parent_size is not None or parent_ino is not None or parent_touched or parent_typ or parent_mode:
            after = self.set_line(after, f"{C}/{USAGE}", size=parent_size, ino=parent_ino, mtime="1792744060",
                                  typ=parent_typ, mode=parent_mode)
        return after

    def test_q7_pu_parent_type_and_mode(self):
        """With one valid child and the right growth, a parent that stops being a directory, changes mode, or is not a
        directory on either side, is UNKNOWN."""
        ok = "Regular File|100600|1|102|1792744060"
        for name, kw in (("parent type", {"parent_typ": "Regular File"}), ("parent mode", {"parent_mode": "40755"})):
            with self.subTest(name):
                r = self.run_audit(self.ar, self.ab, self.pu([(UUID1, ok)], "96", **kw))
                self.assertEqual(r.verdict, "AUDIT-UNKNOWN")
                rows = [l.split("\t") for l in r.classified.splitlines() if l.startswith("DELTA\t") and USAGE in l]
                self.assertEqual(len(rows), 2, rows)
                self.assertTrue(all(x[6] == "UNKNOWN" for x in rows), rows)
        # Field-isolated: the parent is the same non-Directory type on both sides, with the same mode and inode, the exact
        # +32 growth and one valid child, so only the parent's Directory requirement can make it UNKNOWN (SilverRidge ceaf2f23).
        with self.subTest("parent not a directory on both sides"):
            parent = f"{self.A['CACHES']}/{USAGE}"
            before = self.set_line(self.ab, parent, typ="Regular File")
            b = meta(before, parent)
            after = self.set_line(add(before, f"{parent}/{UUID1}|{ok}"), parent, size=str(int(b[3]) + 32), mtime="1792744060")
            self.assertEqual((meta(after, parent)[0], meta(after, parent)[1], meta(after, parent)[2]), (b[0], b[1], b[2]))
            r = self.run_audit(self.ar, before, after)
            self.assertEqual(r.verdict, "AUDIT-UNKNOWN")
            rows = [l.split("\t") for l in r.classified.splitlines() if l.startswith("DELTA\t") and USAGE in l]
            self.assertEqual(len(rows), 2, rows)
            self.assertTrue(all(x[6] == "UNKNOWN" for x in rows), rows)

    def test_q7_pu_shapes(self):
        ok = "Regular File|100600|1|102|1792744060"
        cases = {
            "lowercase uuid": ([(UUID1.lower(), ok)], "96"),
            "size 103": ([(UUID1, "Regular File|100600|1|103|1792744060")], "96"),
            "mode 100644": ([(UUID1, "Regular File|100644|1|102|1792744060")], "96"),
            "a directory child": ([(UUID1, "Directory|40700|1|64|1792744060")], "96"),
            "not a uuid": ([("zb-not-a-uuid", ok)], "96"),
            "parent only": ([], "96"),
            "parent mtime only": ([], None),
            "child only": ([(UUID1, ok)], None),
            "wrong growth": ([(UUID1, ok)], "95"),
            "parent inode": ([(UUID1, ok)], "96"),
            "six children": ([(f"{UUID1[:-1]}{i}", ok) for i in range(6)], str(64 + 32 * 6)),
        }
        for name, (children, size) in cases.items():
            with self.subTest(name):
                after = self.pu(children, size, "1" if name == "parent inode" else None, name == "parent mtime only")
                r = self.run_audit(self.ar, self.ab, after)
                self.assertEqual(r.verdict, "AUDIT-UNKNOWN")
                rows = [l.split("\t") for l in r.classified.splitlines() if l.startswith("DELTA\t") and USAGE in l]
                self.assertTrue(rows)
                self.assertTrue(all(x[6] == "UNKNOWN" for x in rows), rows)

    def test_q7_pu_extra_usage_delta(self):
        C = self.A["CACHES"]
        b = add(self.ab, f"{C}/{USAGE}/B7D609EA-1316-457E-9464-E0F8C1C744D0|Regular File|100600|9|102|1792668446")
        a = add(self.set_line(b, f"{C}/{USAGE}/B7D609EA-1316-457E-9464-E0F8C1C744D0", mtime="1792744060"),
                f"{C}/{USAGE}/{UUID1}|Regular File|100600|1|102|1792744060")
        a = self.set_line(a, f"{C}/{USAGE}", size="96", mtime="1792744060")
        self.assertUnknown(self.ar, b, a, "CACHES", f"{USAGE}/{UUID1}")

    def test_q7_k10_shapes(self):
        T, C, H = self.I["TEMP"], self.I["CACHES"], self.I["HOME"]
        self.assertUnknown(self.ir, self.ib, add(self.ib, f"{T}/zb-audit-added|Regular File|100644|3|6|1"), "TEMP", "zb-audit-added")
        self.assertUnknown(self.ir, self.ib, self.set_line(self.ib, f"{H}/.profile", size="999", mtime="1799999999"),
                           "HOME", ".profile")
        self.assertUnknown(self.ir, self.ib, self.set_line(self.ib, f"{H}/.profile", mode="100600"), "HOME", ".profile")
        self.assertUnknown(self.ir, self.ib, self.set_line(self.ib, f"{C}/zb-fixture-unchanged", size="99"),
                           "CACHES", "zb-fixture-unchanged")


class Roots(Base):
    def roots(self, **change):
        out = []
        for l in self.ir.splitlines():
            f = l.split("\t")
            if f[1] in change:
                if change[f[1]] is None:
                    continue
                f = change[f[1]]
            out.append("\t".join(f))
        return "".join(l + "\n" for l in out)

    def test_q8_binding(self):
        """given/physical are bound by the inode the given path resolves to (SilverRidge 1950c0bb)."""
        I = self.I
        T, new = I["TEMP"], "/private/not-the-real-alias-target/T"
        root_line = [l for l in self.ib.splitlines() if l.startswith(T + "|")][0]
        # an unrelated physical root reported for the same given path: its own root entry is another directory
        moved = lambda text: "".join(
            l.replace(T, new, 1) + "\n" if l.startswith(T + "|") or l.startswith(T + "/") else l + "\n"
            for l in text.splitlines())
        unrelated_b = edit(moved(self.ib), new, (new + root_line[len(T):]).replace("|900009|", "|4242|"))
        unrelated_a = edit(moved(self.ia), new, (new + root_line[len(T):]).replace("|900009|", "|4242|"))
        roots = self.ir.replace("\t" + T + "\t", "\t" + new + "\t")
        self.assertError(roots, "".join(sorted(unrelated_b.splitlines(True), key=lambda x: x.encode())),
                         "".join(sorted(unrelated_a.splitlines(True), key=lambda x: x.encode())),
                         "audit.before: root TEMP is given by a path that resolves to inode 900009, not to the physical root's 4242")
        # the same physical root, a recorded id that is not its inode
        self.assertError(self.ir.replace("id=900009", "id=1"), self.ib, self.ia,
                         "audit.before: root TEMP is given by a path that resolves to inode 1, not to the physical root's 900009")
        # the after snapshot's root entry is another inode
        a = edit(self.ia, T, root_line.replace("|900009|", "|7|"))
        self.assertError(self.ir, self.ib, a, "audit.after: root TEMP is given by a path that resolves to inode 900009, not to the physical root's 7")

    def test_q8_var_alias_accepted(self):
        r = self.ir.splitlines()[0].split("\t")
        self.assertTrue(r[2].startswith("/var/folders/") and r[3] == "/private" + r[2])
        self.assertEqual(self.run_audit(self.ir, self.ib, self.ia).verdict, "AUDIT-AMBIENT")

    def test_q8_root_refusals(self):
        I = self.I
        H, T = I["HOME"], I["TEMP"]
        run = I["RUN"].rsplit("/", 1)[1]
        ids = {l.split("\t")[1]: l.split("\t")[5] for l in self.ir.splitlines()}
        R = lambda tok, g, p=None: ["ROOT", tok, g, g if p is None else p, "link=no", ids[tok]]
        bad = {
            "missing CACHE": (self.roots(CACHE=None), "missing roots: CACHE"),
            "duplicate TEMP": (self.ir + self.ir.splitlines()[0] + "\n", "duplicate root TEMP"),
            "malformed line": (self.ir + "ROOT\tTEMP\n", "malformed root line"),
            "unknown token": (self.ir + f"ROOT\tOTHER\t{T}x\t{T}x\tlink=no\tid=-\n", "malformed root line"),
            "no id field": (self.roots(TEMP=["ROOT", "TEMP", I["TEMP"].replace("/private", ""), T, "link=no"]), "malformed root line"),
            "malformed id": (self.roots(TEMP=["ROOT", "TEMP", T, T, "link=no", "id=x9"]), "malformed root line"),
            "bound root without an id": (self.roots(TEMP=["ROOT", "TEMP", T, T, "link=no", "id=-"]), "root TEMP has id=-, want an inode"),
            "HOME with an id": (self.roots(HOME=["ROOT", "HOME", H, H, "link=no", "id=5"]), "root HOME has id=5, want -"),
            "HOME given elsewhere": (self.roots(HOME=["ROOT", "HOME", "/Users/elsewhere", H, "link=no", "id=-"]),
                                     "root HOME is not given by its physical path"),
            "RUN given elsewhere": (self.roots(RUN=["ROOT", "RUN", f"/Users/elsewhere/{run}", I["RUN"], "link=no", "id=-"]),
                                    "root RUN is not given by its physical path"),
            "CACHE inside HOME": (self.roots(CACHE=R("CACHE", f"{H}/C")), "roots CACHE and HOME overlap"),
            "relative physical": (self.roots(TEMP=R("TEMP", "var/T", "private/var/T")), "not absolute and normalized"),
            "trailing slash": (self.roots(TEMP=R("TEMP", T + "/")), "not absolute and normalized"),
            "dot segment": (self.roots(TEMP=R("TEMP", T, T + "/./x")), "not absolute and normalized"),
            "link=yes": (self.roots(TEMP=["ROOT", "TEMP", T, T, "link=yes", ids["TEMP"]]), "itself a symlink"),
            "CACHES not HOME/Library/Caches": (self.roots(CACHES=R("CACHES", H + "/Caches")), "CACHES is not HOME/Library/Caches"),
            "RUN 15-hex nonce": (self.roots(RUN=R("RUN", f"{H}/{run[:-1]}")), "RUN is not HOME/zb-gate"),
            "RUN uppercase": (self.roots(RUN=R("RUN", f"{H}/{run.upper()}")), "RUN is not HOME/zb-gate"),
            "RUN not a direct child": (self.roots(RUN=R("RUN", f"{H}/x/{run}")), "RUN is not HOME/zb-gate"),
            "TEMP inside HOME": (self.roots(TEMP=R("TEMP", f"{H}/T")), "roots TEMP and HOME overlap"),
            "TEMP equals CACHE": (self.roots(TEMP=R("TEMP", I["CACHE"])), "roots TEMP and CACHE overlap"),
            "CACHE inside TEMP": (self.roots(CACHE=R("CACHE", T + "/C")), "roots TEMP and CACHE overlap"),
            "TEMP inside RUN": (self.roots(TEMP=R("TEMP", I["RUN"] + "/T")), "roots RUN and TEMP overlap"),
            "TEMP inside CACHES": (self.roots(TEMP=R("TEMP", I["CACHES"] + "/T")), "roots TEMP and HOME overlap"),
            "HOME inside TEMP": (self.roots(HOME=R("HOME", T + "/h"), CACHES=R("CACHES", T + "/h/Library/Caches"),
                                            RUN=R("RUN", f"{T}/h/{run}")), "roots RUN and TEMP overlap"),
        }
        for name, (roots, reason) in bad.items():
            with self.subTest(name):
                self.assertError(roots, self.ib, self.ia, reason)


class Snapshots(Base):
    def test_q9_snapshot_refusals(self):
        I = self.I
        H, T = I["HOME"], I["TEMP"]
        given_temp = self.ir.splitlines()[0].split("\t")[2]
        first = self.ib.splitlines()[0]
        bad = {
            "five fields": (add(self.ib, f"{T}/x|Regular File|100644|1|1"), "malformed line"),
            "unknown type": (add(self.ib, f"{T}/x|Weird|100644|1|1|1"), "malformed metadata"),
            "bad mode": (add(self.ib, f"{T}/x|Regular File|644x|1|1|1"), "malformed metadata"),
            "bad inode": (add(self.ib, f"{T}/x|Regular File|100644|one|1|1"), "malformed metadata"),
            "bad size": (add(self.ib, f"{T}/x|Regular File|100644|1|1x|1"), "malformed metadata"),
            "bad mtime": (add(self.ib, f"{T}/x|Regular File|100644|1|1|-5"), "malformed metadata"),
            "sibling prefix": (add(self.ib, f"{T}-other/x|Regular File|100644|1|1|1"), "a path under no physical surface root"),
            "unsorted": ("".join(l + "\n" for l in reversed(self.ib.splitlines())), "not sorted or duplicated"),
            "duplicate path": (add(self.ib, first.rsplit("|", 1)[0] + "|1"), "duplicate path"),
            "unowned path": (add(self.ib, "/opt/zb|Directory|40755|1|1|1"), "a path under no physical surface root"),
            "nonphysical path": (add(self.ib, f"{given_temp}/x|Regular File|100644|1|1|1"), "a path under no physical surface root"),
            "HOME depth 2": (add(self.ib, f"{H}/Library/Other|Directory|40700|1|1|1"), "a path under no physical surface root"),
            "HOME root itself": (add(self.ib, f"{H}|Directory|40755|1|1|1"), "a path under no physical surface root"),
            "RUN itself": (add(self.ib, f"{I['RUN']}|Directory|40755|1|1|1"), "a path at or under the run root"),
            "under RUN": (add(self.ib, f"{I['RUN']}/x|Regular File|100644|1|1|1"), "a path at or under the run root"),
        }
        for name, (snap, reason) in bad.items():
            with self.subTest(name, side="before"):
                self.assertError(self.ir, snap, self.ia, "audit.before: " + reason)
            with self.subTest(name, side="after"):
                self.assertError(self.ir, self.ib, snap, "audit.after: " + reason)

    def test_q9_root_entry_required(self):
        """Children alone do not cover a surface: dropping only its root entry is a structural error."""
        for token in ("TEMP", "CACHE", "CACHES"):
            root = self.I[token]
            self.assertTrue(any(l.startswith(root + "/") for l in self.ib.splitlines()), token)
            drop = lambda text: edit(text, root)
            with self.subTest(token, side="before"):
                self.assertError(self.ir, drop(self.ib), self.ia, f"audit.before: does not cover {token}")
            with self.subTest(token, side="after"):
                self.assertError(self.ir, self.ib, drop(self.ia), f"audit.after: does not cover {token}")

    def test_q9_coverage(self):
        """Each snapshot must cover every surface: an identical omission is never AUDIT-CLEAN."""
        I = self.I
        for token, prefix in (("TEMP", I["TEMP"]), ("CACHE", I["CACHE"]), ("CACHES", I["CACHES"]), ("HOME", I["HOME"] + "/")):
            def omit(text):
                keep = []
                for l in text.splitlines():
                    p = l.rsplit("|", 5)[0]
                    if token == "HOME":
                        inside = p.startswith(prefix) and "/" not in p[len(prefix):]
                    else:
                        inside = p == prefix or p.startswith(prefix + "/")
                    if not inside:
                        keep.append(l)
                return "".join(l + "\n" for l in keep)
            with self.subTest(token, both=True):
                self.assertError(self.ir, omit(self.ib), omit(self.ib), f"audit.before: does not cover {token}")
            with self.subTest(token, both=False):
                self.assertError(self.ir, self.ib, omit(self.ib), f"audit.after: does not cover {token}")


if __name__ == "__main__":
    unittest.main()
