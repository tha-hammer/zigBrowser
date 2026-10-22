"""MS7.6 / MS7.8 (macOS plan line 2158; RoseCat 8079 / 2796d94 on 1e35862, orchestrator's recommendation): the card's
one-minter rule proven on the REAL cross-compiled Darwin objects, by symbol and relocation, so a reference made by
@field, @extern, an alias, a function-pointer table or a substituted file is seen by construction (source lexing is
the secondary layer: mac_drawer_card_authority_test.py).
The objects: build step `check-card-authority-mac` compiles the shipped executable's own root module (build.zig's
`root_module.root_source_file`, its build_options import) to an object for aarch64-macos and for x86_64-macos, both
Debug, so no inlining hides a call: every function keeps its own symbol and every call or address-take its own
relocation. This checker reads each 64-bit Mach-O object (no SDK, no external tool): every relocation in code and data
(debug info, __LD and __eh_frame excluded) is attributed to the function or data symbol holding it, and resolved to
the symbol it reaches (an extern relocation by its symbol; a local relocation into __TEXT,__text by its decoded
target address; one it cannot decode fails closed). Over that reference graph, on both arches:
- R1 the chain exists: agent_approval's Cards.approve / Cards.deny, agent_tools' zb_agent_tools_approve /
  zb_agent_tools_deny, agent_drawer's toolsApprove / toolsDeny and zb_drawer_card_press are each DEFINED in the object,
  under exactly those repo-relative module names (a same-named file elsewhere, an inlined minter or a minter outside
  the object fails), and the two minters and the bridge are exported under their own C names, at the same address.
- R2 exactly one referrer each, by exactly ONE reference site (RoseCat 8097 / 4124a1b: multiplicity is kept, so an
  alias called twice is two sites): Cards.approve <- zb_agent_tools_approve; Cards.deny <- zb_agent_tools_deny;
  zb_agent_tools_approve <- toolsApprove; zb_agent_tools_deny <- toolsDeny; toolsApprove and toolsDeny <-
  zb_drawer_card_press; zb_drawer_card_press <- nothing in Zig (the AppKit buttons call it from the dylib). A site is
  one call or address-take (an arm64 PAGE21/PAGEOFF12 pair counts once). One site run twice, a loop, is the lexical
  layer's to see: it binds the minters' and the bridge's exact bodies.
- R3 no other symbol in the object is named for a minter, a Cards method or the bridge (no second definition, no
  undefined reference to a minter name).
Not covered here, and named: a re-implementation of Cards.approve's state change on the cards' fields, and native
event ingress (the ObjC rules of mac_drawer_card_authority_test.py, and the owner-run real-screen click).
Self-checking: an honest fixture graph compiled for both Darwin arches passes; each dishonest graph (RoseCat's
@field and @extern callers, an alias, files substituted under src/evil/, a function-pointer table, a second
Cards.approve caller, an inlined Cards.approve, a minter outside the object, and RoseCat 8097's Cards.approve /
Cards.deny alias called twice) compiled the same way fails, each with its own reason. One compiler runs at a time,
each in its own process group under a COMPILE_DEADLINE_S deadline, past which the group is killed (SIGKILL), and
the drain and the reap are bounded by REAP_S each; rows prove the group kill on a real `sleep` grandchild and that a
`setsid` escapee holding the output pipe cannot wedge the drain.
The self-check spawns and signals, so it runs only through its launcher (RoseCat 8107): `--self-check` holds the
outer /proc/self/ns/pid fd and re-runs the module under `unshare --map-current-user --pid --fork --kill-child
--mount-proc`. Before any spawn or signal, pidns_problem() requires that held namespace to differ from the current
one, and it refuses on an absent, unreadable or equal state (rows cover each, and that nothing is spawned or
signalled then).
Run (self-check, the only supported way): python3 tests/e2e/mac_card_authority_objects_test.py --self-check
Run (real objects): zig build check-card-authority-mac (unregistered; RED until the macOS build defines the minters
and the bridge)."""
import bisect
import collections
import os
import signal
import struct
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

CPU_X86_64, CPU_ARM64 = 0x01000007, 0x0100000C
# arm64 relocations that are not a site of their own: SUBTRACTOR (1), the PAGEOFF12 halves (4, 6, 9), ADDEND (10).
ARM64_NOT_A_SITE = (1, 4, 6, 9, 10)
COMPILE_DEADLINE_S = 240  # one fixture compile; past it the compiler's whole process group is killed
COMPILE_JOBS = 1  # one compiler at a time: the gate host's memory is tight
REAP_S = 5  # after the deadline kill: the drain, then the reap, each at most this long
PIDNS_ENV = "ZB_CARD_OUTER_PIDNS_FD"  # the launcher's held /proc/self/ns/pid fd (RoseCat 8107)
ARCHES = {"aarch64": CPU_ARM64, "x86_64": CPU_X86_64}
APPROVE, DENY = "_agent_approval.Cards.approve", "_agent_approval.Cards.deny"
MINT_A, MINT_D = "_agent_tools.zb_agent_tools_approve", "_agent_tools.zb_agent_tools_deny"
TOOLS_A, TOOLS_D = "_agent_drawer.toolsApprove", "_agent_drawer.toolsDeny"
BRIDGE = "_agent_drawer.zb_drawer_card_press"
REFERRERS = {APPROVE: {MINT_A}, DENY: {MINT_D}, MINT_A: {TOOLS_A}, MINT_D: {TOOLS_D},
             TOOLS_A: {BRIDGE}, TOOLS_D: {BRIDGE}, BRIDGE: set()}
EXPORTS = {"_zb_agent_tools_approve": MINT_A, "_zb_agent_tools_deny": MINT_D, "_zb_drawer_card_press": BRIDGE}
NAMED = ("zb_agent_tools_approve", "zb_agent_tools_deny", "zb_drawer_card_press", "Cards.approve", "Cards.deny",
         "toolsApprove", "toolsDeny")


def parse(data):
    """A 64-bit Mach-O object -> (cpu type, sections, symbols)."""
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        raise ValueError("not a 64-bit Mach-O object")
    _, cpu, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
    off, sects, symtab = 32, [], None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x19:  # LC_SEGMENT_64
            for k in range(struct.unpack_from("<I", data, off + 64)[0]):
                s = off + 72 + 80 * k
                addr, sz, foff, _, reloff, nreloc = struct.unpack_from("<QQIIII", data, s + 32)
                sects.append(dict(seg=data[s + 16:s + 32].rstrip(b"\0").decode(), name=data[s:s + 16].rstrip(b"\0").decode(),
                                  addr=addr, size=sz, foff=foff, reloff=reloff, nreloc=nreloc))
        elif cmd == 0x2:  # LC_SYMTAB
            symtab = struct.unpack_from("<IIII", data, off + 8)
        off += size
    if symtab is None:
        raise ValueError("no symbol table")
    symoff, nsyms, stroff, _ = symtab
    syms = []
    for i in range(nsyms):
        strx, typ, sect, _, value = struct.unpack_from("<IBBHQ", data, symoff + 16 * i)
        end = data.index(b"\0", stroff + strx)
        syms.append(dict(name=data[stroff + strx:end].decode(), type=typ, sect=sect, value=value))
    return cpu, sects, syms


def is_defined(sym):
    return sym["type"] & 0x0E == 0x0E and not sym["type"] & 0xE0  # N_SECT, not a stab


class Obj:
    def __init__(self, data):
        self.data = data
        self.cpu, self.sects, self.syms = parse(data)
        text = [i for i, s in enumerate(self.sects, 1) if (s["seg"], s["name"]) == ("__TEXT", "__text")]
        if len(text) != 1:
            raise ValueError("want exactly one __TEXT,__text section")
        self.text = text[0]
        by_sect = collections.defaultdict(list)
        for s in self.syms:
            if is_defined(s):
                by_sect[s["sect"]].append(s)
        # At one address the local (module-qualified) name is the canonical one, an export's C name its alias.
        self.at = {k: sorted(v, key=lambda s: (s["value"], s["type"] & 1, s["name"])) for k, v in by_sect.items()}
        self.keys = {k: [s["value"] for s in v] for k, v in self.at.items()}

    def owner(self, sect, addr):
        i = bisect.bisect_right(self.keys.get(sect, []), addr) - 1
        if i < 0:
            return f"<{self.sects[sect - 1]['name']}+{addr:#x}>"
        v = self.at[sect]
        return v[bisect.bisect_left(self.keys[sect], v[i]["value"])]["name"]

    def references(self):
        """{referrer: Counter(target: reference SITES)} over every code and data relocation. A site is one call or
        address-take: an arm64 address load is a PAGE21 + PAGEOFF12 pair, counted once at its PAGE21; a SUBTRACTOR
        names the base of a pair, not a target."""
        refs = collections.defaultdict(collections.Counter)
        for si, s in enumerate(self.sects, 1):
            if s["seg"] in ("__DWARF", "__LD") or s["name"] == "__eh_frame":
                continue
            for k in range(s["nreloc"]):
                r_addr, info = struct.unpack_from("<iI", self.data, s["reloff"] + 8 * k)
                num, pcrel, length, ext, typ = (info & 0xFFFFFF, (info >> 24) & 1, (info >> 25) & 3, (info >> 27) & 1,
                                                info >> 28)
                if r_addr < 0:
                    raise ValueError("a scattered relocation")
                if self.cpu == CPU_ARM64 and typ in ARM64_NOT_A_SITE:
                    continue
                if self.cpu == CPU_X86_64 and typ == 5:
                    continue  # X86_64_RELOC_SUBTRACTOR: the base of the pair that follows
                src = self.owner(si, s["addr"] + r_addr)
                if ext:
                    t = self.syms[num]
                    refs[src][self.owner(t["sect"], t["value"]) if is_defined(t) else t["name"]] += 1
                elif num == self.text:
                    loc = s["foff"] + r_addr
                    if self.cpu == CPU_X86_64 and pcrel and length == 2:
                        target = s["addr"] + r_addr + 4 + struct.unpack_from("<i", self.data, loc)[0] + {6: 1, 7: 2, 8: 4}.get(typ, 0)
                    elif not pcrel and length == 3:
                        target = struct.unpack_from("<Q", self.data, loc)[0]
                    else:
                        raise ValueError(f"an undecodable local relocation into code (type {typ}) in {src}")
                    refs[src][self.owner(self.text, target)] += 1
        return refs


def problems(data, arch):
    """One Darwin object's bytes -> the one-minter rule's violations (empty: holds)."""
    try:
        obj = Obj(data)
        refs = obj.references()
    except (ValueError, struct.error, IndexError) as e:
        return [f"{arch}: unreadable object: {e}"]
    found = []
    if obj.cpu != ARCHES[arch]:
        found.append(f"{arch}: the object's cpu type is {obj.cpu:#x}")
    defined = {s["name"]: s for s in obj.syms if is_defined(s)}
    for name in REFERRERS:
        if name not in defined:
            found.append(f"R1 {arch}: {name} is not defined in the object")
    for c_name, local in EXPORTS.items():
        g = defined.get(c_name)
        if g is None or not g["type"] & 1 or local not in defined or g["value"] != defined[local]["value"]:
            found.append(f"R1 {arch}: {c_name} must be the exported name of {local}")
    by_target = collections.defaultdict(collections.Counter)
    for src, targets in refs.items():
        for t, sites in targets.items():
            by_target[t][src] += sites
    for target, want in REFERRERS.items():
        got = dict(sorted(by_target.get(target, {}).items()))
        if got != {src: 1 for src in want}:
            found.append(f"R2 {arch}: {target} is referenced by {got}, want {dict.fromkeys(sorted(want), 1)}")
    allowed = set(REFERRERS) | set(EXPORTS)
    for s in obj.syms:
        if any(w in s["name"] for w in NAMED) and s["name"] not in allowed and not s["type"] & 0xE0:
            found.append(f"R3 {arch}: unexpected symbol {s['name']}")
    return found


# --- self-check: fixture graphs compiled by the real compiler ----------------------------------------------------
FIXTURE = {
    "main.zig": 'const app = @import("app.zig");\ncomptime {\n    _ = app;\n}\npub fn main() void {}\n',
    "app.zig": 'pub const drawer = @import("agent_drawer.zig");\npub const tools = @import("agent_tools.zig");\n'
               "comptime {\n    _ = drawer;\n    _ = tools;\n}\n",
    "agent_approval.zig": "pub const Cards = struct {\n    n: u64 = 0,\n"
                          "    pub fn approve(self: *Cards, id: u64) bool {\n        self.n +%= id;\n        return self.n & 1 == 0;\n    }\n"
                          "    pub fn deny(self: *Cards, id: u64) bool {\n        self.n -%= id;\n        return self.n & 1 == 0;\n    }\n};\n",
    "agent_tools.zig": 'const approval = @import("agent_approval.zig");\nvar cards: approval.Cards = .{};\n'
                       "export fn zb_agent_tools_approve(card: u64) c_int {\n    return @intFromBool(cards.approve(card));\n}\n"
                       "export fn zb_agent_tools_deny(card: u64) c_int {\n    return @intFromBool(cards.deny(card));\n}\n",
    "agent_drawer.zig": "pub const Approver = struct { ctx: *anyopaque, approve: *const fn (*anyopaque, u64) bool, "
                        "deny: *const fn (*anyopaque, u64) bool };\n"
                        "pub fn cardPress(card: u64, control: c_int, own: bool, approver: Approver) c_int {\n"
                        "    if (!own) return 0;\n    return switch (control) {\n"
                        "        1 => if (approver.approve(approver.ctx, card)) 1 else 3,\n"
                        "        2 => if (approver.deny(approver.ctx, card)) 2 else 3,\n        else => 0,\n    };\n}\n"
                        "extern fn zb_agent_tools_approve(card: u64) c_int;\nextern fn zb_agent_tools_deny(card: u64) c_int;\n"
                        "fn toolsApprove(_: *anyopaque, card: u64) bool {\n    return zb_agent_tools_approve(card) != 0;\n}\n"
                        "fn toolsDeny(_: *anyopaque, card: u64) bool {\n    return zb_agent_tools_deny(card) != 0;\n}\n"
                        "pub fn zb_drawer_card_press(card: u64, control: c_int, own: c_int) callconv(.c) c_int {\n"
                        "    var unused: u8 = 0;\n"
                        "    return cardPress(card, control, own != 0, .{ .ctx = &unused, .approve = toolsApprove, .deny = toolsDeny });\n}\n"
                        'comptime {\n    @export(&zb_drawer_card_press, .{ .name = "zb_drawer_card_press" });\n}\n',
}


def fixture(path, old, new):
    assert FIXTURE[path].count(old) == 1, old
    return dict(FIXTURE, **{path: FIXTURE[path].replace(old, new)})


def substituted():
    files = {k: v for k, v in FIXTURE.items() if k not in ("agent_tools.zig", "agent_approval.zig")}
    files["evil/agent_tools.zig"] = FIXTURE["agent_tools.zig"]
    files["evil/agent_approval.zig"] = FIXTURE["agent_approval.zig"]
    files["app.zig"] = FIXTURE["app.zig"].replace('"agent_tools.zig"', '"evil/agent_tools.zig"')
    files["agent_drawer.zig"] = FIXTURE["agent_drawer.zig"]
    return files


MUTANTS = {
    # RoseCat 2796d94's bypasses of the lexical census
    "an @field caller": (fixture("agent_tools.zig", "export fn zb_agent_tools_deny",
                                 'export fn zb_auto(c: u64) c_int {\n    return @field(@This(), "zb_agent_tools_approve")(c);\n}\n'
                                 "export fn zb_agent_tools_deny"), "'_agent_tools.zb_auto'"),
    "an @extern caller": (fixture("app.zig", "comptime {",
                                  "export fn zb_auto(c: u64) c_int {\n"
                                  '    const f = @extern(*const fn (u64) callconv(.c) c_int, .{ .name = "zb_agent_tools_approve" });\n'
                                  "    return f(c);\n}\ncomptime {"), "'_app.zb_auto'"),
    "files substituted under src/evil/": (substituted(), f"R1 {{arch}}: {MINT_A} is not defined"),
    # the same graph reached other ways
    "an alias of the minter": (fixture("agent_drawer.zig", "fn toolsDeny",
                                       "const mint = zb_agent_tools_approve;\nexport fn zb_auto(c: u64) c_int {\n    return mint(c);\n}\n"
                                       "fn toolsDeny"), "'_agent_drawer.zb_auto'"),
    "a function-pointer table": (fixture("app.zig", "comptime {",
                                         'const mint = @import("agent_tools.zig");\n'
                                         'pub const table = [_]*const fn (u64) callconv(.c) c_int{@extern(*const fn (u64) callconv(.c) c_int, .{ .name = "zb_agent_tools_approve" })};\n'
                                         "export fn zb_auto(i: usize, c: u64) c_int {\n    return table[i](c);\n}\ncomptime {"),
                                 "'_app.table'"),
    "a second Cards.approve caller": (fixture("agent_tools.zig", "export fn zb_agent_tools_deny",
                                              "export fn zb_auto(card: u64) c_int {\n    return @intFromBool(cards.approve(card));\n}\n"
                                              "export fn zb_agent_tools_deny"), "'_agent_tools.zb_auto'"),
    "an inlined Cards.approve": (fixture("agent_approval.zig", "pub fn approve(", "pub inline fn approve("),
                                 f"R1 {{arch}}: {APPROVE} is not defined"),
    # RoseCat 8097 / 4124a1b: one alias of the Cards method, called twice (a double consume)
    "Cards.approve called twice through an alias": (fixture("agent_tools.zig", "    return @intFromBool(cards.approve(card));\n",
                                                             "    const mint = approval.Cards.approve;\n"
                                                             "    return @intFromBool(mint(&cards, card)) + @intFromBool(mint(&cards, card));\n"),
                                                     f"R2 {{arch}}: {APPROVE} is referenced by {{'{MINT_A}': 2}}"),
    "Cards.deny called twice through an alias": (fixture("agent_tools.zig", "    return @intFromBool(cards.deny(card));\n",
                                                          "    const mint = approval.Cards.deny;\n"
                                                          "    return @intFromBool(mint(&cards, card)) + @intFromBool(mint(&cards, card));\n"),
                                                  f"R2 {{arch}}: {DENY} is referenced by {{'{MINT_D}': 2}}"),
    "a minter outside the object": (fixture("app.zig", 'pub const tools = @import("agent_tools.zig");\n',
                                            "const tools = struct {};\n"), f"R1 {{arch}}: {MINT_A} is not defined"),
}


def compile_graph(files, arch, work):
    """Compiles the fixture graph `files` for `arch`-macos (Debug) -> the object's bytes, or the compiler's error."""
    root = Path(work) / "src"
    for rel, text in files.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text)
    out = Path(work) / f"{arch}.o"
    code, err = run_bounded(["zig", "build-obj", "-target", f"{arch}-macos", "-O", "Debug", "-lc", str(root / "main.zig"),
                             f"-femit-bin={out}", "--cache-dir", str(Path(work) / "zc"), "--global-cache-dir",
                             str(Path(work) / "zgc")], COMPILE_DEADLINE_S)
    if code != 0:
        raise AssertionError(f"zig build-obj failed for {arch}: {err[-2000:]}")
    return out.read_bytes()


def pidns_problem(env=None, readlink=os.readlink):
    """None when this process provably runs in a PID namespace other than its launcher's: the launcher's held
    /proc/self/ns/pid fd (number in PIDNS_ENV) names a different namespace than this process's own. Otherwise why
    not (absent, unreadable, not a PID namespace, or the same one), and nothing may be spawned or signalled."""
    raw = (os.environ if env is None else env).get(PIDNS_ENV)
    if raw is None or not raw.isdigit():
        return f"no launcher PID-namespace fd ({PIDNS_ENV}): run `python3 {Path(__file__).name} --self-check`"
    try:
        outer, inner = readlink(f"/proc/self/fd/{raw}"), readlink("/proc/self/ns/pid")
    except OSError as e:
        return f"the PID-namespace sentinel is unreadable: {e}"
    if not (outer.startswith("pid:[") and inner.startswith("pid:[")):
        return f"the sentinel is not a PID namespace ({outer!r}, {inner!r})"
    if outer == inner:
        return f"this process shares its launcher's PID namespace {inner}: refusing to spawn or signal"
    return None


def run_bounded(argv, deadline_s, reap_s=REAP_S):
    """Runs `argv` in its own process group -> (exit code, stderr). Refuses (RuntimeError) before spawning outside
    a proven private PID namespace. Past `deadline_s` the whole group is killed; the drain and the reap are bounded by
    `reap_s` each, so an escaped holder of the output pipe cannot wedge it; the result is then (None, what happened)."""
    why = pidns_problem()
    if why:
        raise RuntimeError(why)
    proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        _, err = proc.communicate(timeout=deadline_s)
        return proc.returncode, err
    except subprocess.TimeoutExpired:
        pass
    notes = [f"{argv[0]} exceeded its {deadline_s} s deadline"]
    pid, why = proc.pid, pidns_problem()
    if why or not (isinstance(pid, int) and pid > 1):  # never a placeholder pid: killpg(0/1) reaches far beyond it
        notes.append(f"its group was NOT signalled ({why or f'pid {pid!r}'})")
    else:
        try:
            os.killpg(pid, signal.SIGKILL)
            notes.append("its process group was killed")
        except OSError as e:
            notes.append(f"killing its process group failed: {e!r}")
    try:
        proc.communicate(timeout=reap_s)
    except subprocess.TimeoutExpired:
        notes.append(f"its output stayed open past {reap_s} s (an escaped holder): drain abandoned")
        proc.stderr.close()
        try:
            proc.wait(timeout=reap_s)
        except subprocess.TimeoutExpired:
            notes.append(f"it was not reaped within {reap_s} s")
    return None, "; ".join(notes)


def compiled(cases):
    """{name: files} -> {(name, arch): object bytes}, each compiled in its own directory."""
    with tempfile.TemporaryDirectory() as tmp:
        jobs = {(name, arch): Path(tmp) / f"{i}-{arch}" for i, name in enumerate(cases) for arch in ARCHES}
        with ThreadPoolExecutor(max_workers=COMPILE_JOBS) as pool:
            futures = {key: pool.submit(compile_graph, cases[key[0]], key[1], str(work)) for key, work in jobs.items()}
            return {key: f.result() for key, f in futures.items()}


def gone(pid, wait_s=5.0):
    """True once `pid` no longer runs (absent, or a zombie its new parent has not reaped), within `wait_s`."""
    import time
    end = time.monotonic() + wait_s
    while True:
        try:
            state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
        except (FileNotFoundError, ProcessLookupError):
            return True
        if state == "Z":
            return True
        if time.monotonic() > end:
            return False
        time.sleep(0.05)


class CardAuthorityObjects(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cases = {"honest": FIXTURE, **{name: files for name, (files, _) in MUTANTS.items()}}
        cls.objects = compiled(cases)

    def test_the_honest_graph_passes_on_both_arches(self):
        for arch in ARCHES:
            with self.subTest(arch=arch):
                self.assertEqual(problems(self.objects[("honest", arch)], arch), [])

    def test_each_dishonest_graph_fails_for_its_reason(self):
        for name, (_, reason) in MUTANTS.items():
            for arch in ARCHES:
                with self.subTest(mutant=name, arch=arch):
                    found = problems(self.objects[(name, arch)], arch)
                    self.assertTrue(any(reason.replace("{arch}", arch) in f for f in found), (name, found))

    def test_this_run_is_in_a_private_pid_namespace(self):
        self.assertIsNone(pidns_problem())

    def test_the_sentinel_refuses_every_unproven_state(self):
        ns = {"/proc/self/fd/9": "pid:[1]", "/proc/self/ns/pid": "pid:[2]"}
        def reader(table):
            def readlink(path):
                if path not in table:
                    raise FileNotFoundError(path)
                return table[path]
            return readlink
        self.assertIsNone(pidns_problem({PIDNS_ENV: "9"}, reader(ns)))
        for name, env, table, want in (
                ("absent", {}, ns, "no launcher"),
                ("not a number", {PIDNS_ENV: "x"}, ns, "no launcher"),
                ("unreadable", {PIDNS_ENV: "8"}, ns, "unreadable"),
                ("not a PID namespace", {PIDNS_ENV: "9"}, dict(ns, **{"/proc/self/fd/9": "/dev/null"}), "not a PID namespace"),
                ("the same namespace", {PIDNS_ENV: "9"}, dict(ns, **{"/proc/self/fd/9": "pid:[2]"}), "shares")):
            with self.subTest(state=name):
                self.assertIn(want, pidns_problem(env, reader(table)) or "")

    def test_outside_a_proven_namespace_nothing_is_spawned_or_signalled(self):
        from unittest import mock
        def never(*a, **k):
            raise AssertionError("spawned or signalled outside a proven namespace")
        env = {k: v for k, v in os.environ.items() if k != PIDNS_ENV}
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(subprocess, "Popen", never), \
                mock.patch.object(os, "kill", never), mock.patch.object(os, "killpg", never):
            with self.assertRaises(RuntimeError):
                run_bounded(["sleep", "30"], 1)

    def test_an_escaped_output_holder_cannot_wedge_the_drain(self):
        import time
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "escaped"
            start = time.monotonic()
            code, err = run_bounded(["sh", "-c", f"setsid sleep 8 & echo $! > {marker}; wait"], 1, reap_s=1)
            elapsed = time.monotonic() - start
            escaped = int(marker.read_text())
            try:
                self.assertIsNone(code)
                self.assertIn("drain abandoned", err)
                self.assertLess(elapsed, 5, "the drain waited on the escaped holder")
            finally:
                if escaped > 1:
                    try:
                        os.kill(escaped, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_a_compiler_past_its_deadline_is_killed_with_its_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "grandchild"
            code, err = run_bounded(["sh", "-c", f"sleep 30 & echo $! > {marker}; wait"], 1)
            self.assertIsNone(code)
            self.assertIn("deadline", err)
            grandchild = int(marker.read_text())
            self.assertGreater(grandchild, 1)
            self.assertTrue(gone(grandchild), "the group's grandchild outlived the deadline kill")

    def test_the_wrong_arch_and_a_non_object_fail(self):
        self.assertNotEqual(problems(self.objects[("honest", "x86_64")], "aarch64"), [])
        self.assertNotEqual(problems(b"\x7fELF" + bytes(64), "aarch64"), [])


def launch_self_check():
    """The only way to run the self-check: hold this namespace's /proc/self/ns/pid open, then re-run the module
    under `unshare --map-current-user --pid --fork --kill-child --mount-proc`, where pidns_problem() proves the
    namespace changed before anything is spawned or signalled."""
    fd = os.open("/proc/self/ns/pid", os.O_RDONLY)
    os.set_inheritable(fd, True)
    os.chdir(Path(__file__).resolve().parent)
    env = dict(os.environ, **{PIDNS_ENV: str(fd)})
    os.execvpe("unshare", ["unshare", "--map-current-user", "--pid", "--fork", "--kill-child", "--mount-proc",
                           sys.executable, "-X", "dev", "-m", "unittest", "-v", Path(__file__).stem], env)


def main(argv):
    """`check-card-authority-mac`: argv = <aarch64 object> <x86_64 object>."""
    if len(argv) != 2:
        print("usage: mac_card_authority_objects_test.py <aarch64-macos object> <x86_64-macos object>", file=sys.stderr)
        return 2
    found = []
    for arch, path in zip(ARCHES, argv):
        found += problems(Path(path).read_bytes(), arch)
    for f in found:
        print(f, file=sys.stderr)
    print("card authority objects:", "FAIL" if found else "OK (both arches)")
    return 1 if found else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-check"]:
        launch_self_check()
    elif len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        sys.exit(main(sys.argv[1:]))
    else:
        sys.exit(f"usage: {sys.argv[0]} --self-check | <aarch64-macos object> <x86_64-macos object>")
