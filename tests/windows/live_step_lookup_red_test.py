#!/usr/bin/env python3
r"""ong.15 RED (UNREGISTERED), NavyCanyon 0fe01513: live_step_skip_test's build.zig step lookup reads one directly
chained registration whose description is one ordinary Zig string literal.

Today `_step_var` matches `b\.step\(\s*"<name>"[^;]*?\)\.dependOn\(&(\w+)\.step\)`: a legal `;` in the description
raises LookupError, a `.dependOn(&decoy.step)` written inside the description (or a same-name call in a `//` comment
or in multiline-string text) binds the wrong variable, Zig-formatted calls with trailing commas are not found, and a
description that is not an ordinary string is guessed through instead of refused.

The supported grammar (0fe01513), on one code line start: an exact step name, one ordinary quoted Zig description
(no newline in its body), optional trailing comma/whitespace, then a directly chained `.dependOn(&<var>.step)` whose
argument may be Zig-formatted across lines with an optional trailing comma. Deliberately unsupported, and required to
raise LookupError rather than guess: a variable-held `b.step` result, a dependency in a later statement, and a
description given as a multiline string, a concatenation or another expression.

Pinned, on synthetic build.zig text, through `_step_var`, `step_argv` (the resolved variable must lead to the exact
intended argv) and `in_zig_build_test`:
  - fail today: a `;` in the description; dependOn text inside the description; escaped quotes and a trailing
    escaped backslash with a `;`; Zig-formatted layouts with whitespace, newlines and trailing commas in both calls;
    a same-name fake call in a `//` comment and in multiline-string text before the real registration; a description
    that is a multiline string, a concatenation or an identifier (must be LookupError);
  - guards (pass today, must stay): a variable-held step and a later statement's dependency are LookupError; the
    name is exact (a longer name with the same prefix never binds, in either order); every live step the real
    build.zig declares still resolves to a registered command.
String-only: the helpers are imported and called on strings; subprocess.Popen is replaced so any command launch fails
the run; the only filesystem access is reading the real build.zig. Run inside `unshare --user --map-current-user
--net` anyway (it imports Windows harness code).

Run alone:  unshare --user --map-current-user --net python3 -I tests/windows/live_step_lookup_red_test.py -v
"""
import pathlib
import subprocess
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import live_step_skip_test as lst  # noqa: E402

NAME = "windows-x-live"
REAL_ARGV = ["python3", "-I", "tests/windows/real_live_test.py"]
COMMANDS = '''    const real = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/real_live_test.py" });
    const decoy = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/decoy_live_test.py" });
    const wrong = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/wrong_live_test.py" });
    const extra = b.addSystemCommand(&.{ "python3", "-I", "tests/windows/extra_live_test.py" });
    const test_step = b.step("test", "Run every hostless test");
'''

_popen = None


def setUpModule():
    global _popen
    _popen = mock.patch.object(subprocess, "Popen", side_effect=AssertionError("the parser suite launched a command"))
    _popen.start()


def tearDownModule():
    _popen.stop()


def build(body: str, in_test: bool = False) -> str:
    """A synthetic build.zig: the four commands, then `body` (the registration under test)."""
    tail = "    test_step.dependOn(&real.step);\n" if in_test else ""
    return "pub fn build(b: *std.Build) void {\n" + COMMANDS + body + tail + "}\n"


class _Case(unittest.TestCase):
    def assertResolvesReal(self, text, name=NAME):
        try:
            var = lst._step_var(text, name)
        except LookupError as e:
            self.fail(f"{name}: the supported registration was not found: {e}\n{text}")
        self.assertEqual(var, "real", f"{name}: bound the wrong variable\n{text}")
        self.assertEqual(lst.step_argv(text, name), REAL_ARGV, f"{name}: the resolved argv is not the real command")

    def assertRefused(self, text, name=NAME):
        try:
            var = lst._step_var(text, name)
        except LookupError:
            pass
        else:
            self.fail(f"{name}: an unsupported form was guessed through to {var!r} instead of LookupError\n{text}")
        with self.assertRaises(LookupError, msg="step_argv refuses it too"):
            lst.step_argv(text, name)


class SupportedRegistration(_Case):
    def test_a_semicolon_in_the_description(self):
        text = build(f'    b.step("{NAME}", "dom.* run in the private world; a hostile page cannot see it")'
                     '.dependOn(&real.step);\n', in_test=True)
        self.assertResolvesReal(text)
        try:
            self.assertTrue(lst.in_zig_build_test(text, NAME), "test_step.dependOn(&real.step) is seen")
        except LookupError as e:
            self.fail(f"in_zig_build_test raised: {e}")

    def test_dependon_text_inside_the_description_is_not_the_binding(self):
        self.assertResolvesReal(build(f'    b.step("{NAME}", "unlike b.step(x).dependOn(&decoy.step) it runs")'
                                      '.dependOn(&real.step);\n'))

    def test_escaped_quotes_and_a_trailing_escaped_backslash(self):
        for desc in (r'say \"a; b\" first', r'ends in C:\\; then \\'):
            with self.subTest(desc=desc):
                self.assertResolvesReal(build(f'    b.step("{NAME}", "{desc}").dependOn(&real.step);\n'))

    def test_zig_formatted_calls_with_trailing_commas(self):
        layouts = {
            "both calls broken, both trailing commas":
                f'    b.step(\n        "{NAME}",\n        "formatted; across lines",\n    ).dependOn(\n'
                '        &real.step,\n    );\n',
            "chain on the next line":
                f'    b.step(\n        "{NAME}",\n        "formatted",\n    )\n        .dependOn(\n'
                '            &real.step,\n        );\n',
            "spaces inside both calls":
                f'    b.step( "{NAME}" , "spaced; out" , ) .dependOn ( &real.step , );\n',
        }
        for layout, body in layouts.items():
            with self.subTest(layout=layout):
                self.assertResolvesReal(build(body))


class FakeRegistrationsAreIgnored(_Case):
    def test_a_same_name_call_in_a_line_comment(self):
        self.assertResolvesReal(build(f'    // was: b.step("{NAME}", "old").dependOn(&decoy.step);\n'
                                      f'    b.step("{NAME}", "new").dependOn(&real.step);\n'))

    def test_a_same_name_call_in_multiline_string_text(self):
        self.assertResolvesReal(build('    const doc =\n'
                                      f'        \\\\b.step("{NAME}", "doc").dependOn(&decoy.step);\n'
                                      '    ;\n'
                                      f'    b.step("{NAME}", "new").dependOn(&real.step);\n'))


class UnsupportedFormsFailLoudly(_Case):
    def test_a_variable_held_step(self):
        self.assertRefused(build(f'    const s = b.step("{NAME}", "held");\n    s.dependOn(&real.step);\n'))

    def test_a_later_statement_dependency(self):
        for desc in ("plain", "with; a semicolon"):
            with self.subTest(desc=desc):
                self.assertRefused(build(f'    b.step("{NAME}", "{desc}");\n    wrong_step.dependOn(&wrong.step);\n'))

    def test_a_description_that_is_not_one_ordinary_string(self):
        forms = {
            "multiline string": f'    b.step("{NAME}",\n        \\\\multi\n    ).dependOn(&real.step);\n',
            "concatenation": f'    b.step("{NAME}", "a" ++ "b").dependOn(&real.step);\n',
            "identifier": f'    b.step("{NAME}", desc).dependOn(&real.step);\n',
        }
        for form, body in forms.items():
            with self.subTest(form=form):
                self.assertRefused(build(body))


class ExactName(_Case):
    def test_a_longer_name_with_the_same_prefix_never_binds(self):
        extra = f'    b.step("{NAME}-extra", "e").dependOn(&extra.step);\n'
        real = f'    b.step("{NAME}", "d").dependOn(&real.step);\n'
        for order, body in (("longer first", extra + real), ("longer last", real + extra)):
            with self.subTest(order=order):
                text = build(body)
                self.assertResolvesReal(text)
                self.assertEqual(lst._step_var(text, NAME + "-extra"), "extra")
                self.assertRefused(text, "windows-x")


class RealBuildZig(unittest.TestCase):
    def test_every_discovered_live_step_resolves(self):
        text = (lst.REPO / "build.zig").read_text()
        steps = lst.live_steps(text)
        self.assertTrue(lst.KNOWN_LIVE_STEPS <= set(steps), set(lst.KNOWN_LIVE_STEPS) - set(steps))
        for step in steps:
            with self.subTest(step=step):
                self.assertTrue(lst.step_argv(text, step), step)


if __name__ == "__main__":
    unittest.main()
