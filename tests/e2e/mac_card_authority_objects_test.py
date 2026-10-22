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
- R2 exactly one referrer each: Cards.approve <- zb_agent_tools_approve; Cards.deny <- zb_agent_tools_deny;
  zb_agent_tools_approve <- toolsApprove; zb_agent_tools_deny <- toolsDeny; toolsApprove and toolsDeny <-
  zb_drawer_card_press; zb_drawer_card_press <- nothing in Zig (the AppKit buttons call it from the dylib).
- R3 no other symbol in the object is named for a minter, a Cards method or the bridge (no second definition, no
  undefined reference to a minter name).
Not covered here, and named: a re-implementation of Cards.approve's state change on the cards' fields, and native
event ingress (the ObjC rules of mac_drawer_card_authority_test.py, and the owner-run real-screen click).
Self-checking: an honest fixture graph compiled for both Darwin arches passes; each dishonest graph (RoseCat's
@field and @extern callers, an alias, files substituted under src/evil/, a function-pointer table, a second
Cards.approve caller, an inlined Cards.approve, a minter outside the object) compiled the same way fails, each with
its own reason. The compiler runs as a plain child (no timeout, no signal).
Run (self-check): cd tests/e2e && python3 -X dev -m unittest -v mac_card_authority_objects_test
Run (real objects): zig build check-card-authority-mac (unregistered; RED until the macOS build defines the minters
and the bridge)."""
import bisect
import collections
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

CPU_X86_64, CPU_ARM64 = 0x01000007, 0x0100000C
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
        """{referrer: {target}} over every code and data relocation."""
        refs = collections.defaultdict(set)
        for si, s in enumerate(self.sects, 1):
            if s["seg"] in ("__DWARF", "__LD") or s["name"] == "__eh_frame":
                continue
            for k in range(s["nreloc"]):
                r_addr, info = struct.unpack_from("<iI", self.data, s["reloff"] + 8 * k)
                num, pcrel, length, ext, typ = (info & 0xFFFFFF, (info >> 24) & 1, (info >> 25) & 3, (info >> 27) & 1,
                                                info >> 28)
                if r_addr < 0:
                    raise ValueError("a scattered relocation")
                if self.cpu == CPU_ARM64 and typ == 10:
                    continue  # ARM64_RELOC_ADDEND carries the next entry's addend, not a symbol
                src = self.owner(si, s["addr"] + r_addr)
                if ext:
                    t = self.syms[num]
                    refs[src].add(self.owner(t["sect"], t["value"]) if is_defined(t) else t["name"])
                elif num == self.text:
                    loc = s["foff"] + r_addr
                    if self.cpu == CPU_X86_64 and pcrel and length == 2:
                        target = s["addr"] + r_addr + 4 + struct.unpack_from("<i", self.data, loc)[0] + {6: 1, 7: 2, 8: 4}.get(typ, 0)
                    elif not pcrel and length == 3:
                        target = struct.unpack_from("<Q", self.data, loc)[0]
                    else:
                        raise ValueError(f"an undecodable local relocation into code (type {typ}) in {src}")
                    refs[src].add(self.owner(self.text, target))
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
    by_target = collections.defaultdict(set)
    for src, targets in refs.items():
        for t in targets:
            by_target[t].add(src)
    for target, want in REFERRERS.items():
        got = by_target.get(target, set())
        if got != want:
            found.append(f"R2 {arch}: {target} is referenced by {sorted(got)}, want {sorted(want)}")
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
    r = subprocess.run(["zig", "build-obj", "-target", f"{arch}-macos", "-O", "Debug", "-lc", str(root / "main.zig"),
                        f"-femit-bin={out}", "--cache-dir", str(Path(work) / "zc"), "--global-cache-dir",
                        str(Path(work) / "zgc")], capture_output=True, text=True)
    if r.returncode != 0:
        raise AssertionError(f"zig build-obj failed for {arch}: {r.stderr[-2000:]}")
    return out.read_bytes()


def compiled(cases):
    """{name: files} -> {(name, arch): object bytes}, each compiled in its own directory."""
    with tempfile.TemporaryDirectory() as tmp:
        jobs = {(name, arch): Path(tmp) / f"{i}-{arch}" for i, name in enumerate(cases) for arch in ARCHES}
        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = {key: pool.submit(compile_graph, cases[key[0]], key[1], str(work)) for key, work in jobs.items()}
            return {key: f.result() for key, f in futures.items()}


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
                    self.assertTrue(any(reason.format(arch=arch) in f for f in found), (name, found))

    def test_the_wrong_arch_and_a_non_object_fail(self):
        self.assertNotEqual(problems(self.objects[("honest", "x86_64")], "aarch64"), [])
        self.assertNotEqual(problems(b"\x7fELF" + bytes(64), "aarch64"), [])


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
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        sys.exit(main(sys.argv[1:]))
    unittest.main()
