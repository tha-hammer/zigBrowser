"""Unit tests for zb_agent_host.wincontain — the pure Windows helper branches (WS item b).

Path containment (lexical, fail-closed), argv quoting (round-tripped through a reference
CommandLineToArgvW parser), and the fail-closed containment choice. All pure — runs on Linux under
python3 -I with no Windows host.

Run the module alone, as the gate does:
  cd agent/host/tests && python3 -I -m unittest -v test_wincontain
"""
import unittest

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import wincontain as wc


def parse_cmdline(s):
    """Reference CommandLineToArgvW for args after argv[0] (the convention quote_arg targets).

    Backslashes: a run of n before a `"` yields n//2 literal backslashes and, if n is odd, a literal quote;
    if n is even the quote toggles the in-quotes state. Backslashes not before a quote are literal.
    Unquoted whitespace separates arguments.
    """
    args, cur, i, n, in_q, had = [], [], 0, len(s), False, False
    while i < n:
        c = s[i]
        if c == "\\":
            j = i
            while j < n and s[j] == "\\":
                j += 1
            nb = j - i
            if j < n and s[j] == '"':
                cur.append("\\" * (nb // 2))
                if nb % 2 == 1:
                    cur.append('"'); had = True; i = j + 1
                else:
                    i = j  # even: fall through so the quote toggles
            else:
                cur.append("\\" * nb); had = True; i = j
        elif c == '"':
            in_q = not in_q; had = True; i += 1
        elif c in " \t" and not in_q:
            if had:
                args.append("".join(cur)); cur = []; had = False
            i += 1
        else:
            cur.append(c); had = True; i += 1
    if had:
        args.append("".join(cur))
    return args


class ArgvQuoting(unittest.TestCase):
    def test_spot_cases(self):
        self.assertEqual(wc.quote_arg(""), '""')
        self.assertEqual(wc.quote_arg("abc"), "abc")
        self.assertEqual(wc.quote_arg("a b"), '"a b"')
        self.assertEqual(wc.quote_arg("a\\b"), "a\\b")           # backslash not before a quote: literal, no quoting
        self.assertEqual(wc.quote_arg('a"b'), '"a\\"b"')

    def test_roundtrips_through_reference_parser(self):
        batteries = [
            ["abc"],
            ["a b", "c"],
            ['a"b'],
            ["a\\b"],
            ["a\\", "b"],
            ["a b\\"],                                   # trailing backslash inside a quoted arg -> doubled
            ["", "x"],                                   # an empty argument
            ['c:\\path with space\\', 'arg"2', "a\\\\b", "tab\there"],
            ["C:\\Program Files\\zig\\zig.exe", "build", "-Dfoo=a b", "-Dp=a\\b\\"],
            ['weird " \\ "" \\\\" end'],
        ]
        for args in batteries:
            line = wc.join_argv(args)
            self.assertEqual(parse_cmdline(line), args, f"round-trip failed for {args!r} -> {line!r}")

    def test_join_argv_rejects_empty(self):
        with self.assertRaises(wc.ContainError):
            wc.join_argv([])


class PathContainment(unittest.TestCase):
    ROOT = r"C:\Users\zbtext\zb"

    def test_within_returns_normalized(self):
        self.assertEqual(wc.normalize_within(self.ROOT, r"C:\Users\zbtext\zb\build\x"),
                         r"C:\Users\zbtext\zb\build\x")

    def test_equal_to_root_is_within(self):
        self.assertEqual(wc.normalize_within(self.ROOT, self.ROOT), self.ROOT)

    def test_forward_slashes_normalize_and_pass(self):
        self.assertEqual(wc.normalize_within(self.ROOT, "C:/Users/zbtext/zb/a"), r"C:\Users\zbtext\zb\a")

    def test_case_insensitive(self):
        self.assertEqual(wc.normalize_within(self.ROOT, r"c:\users\ZBTEXT\zb\a"), r"c:\users\ZBTEXT\zb\a")

    def test_dotdot_escape_rejected(self):
        with self.assertRaises(wc.ContainError):
            wc.normalize_within(self.ROOT, r"C:\Users\zbtext\zb\..\evil")

    def test_dotdot_internal_stays_within(self):
        self.assertEqual(wc.normalize_within(self.ROOT, r"C:\Users\zbtext\zb\sub\..\a"),
                         r"C:\Users\zbtext\zb\a")

    def test_sibling_prefix_not_within(self):
        with self.assertRaises(wc.ContainError):
            wc.normalize_within(r"C:\a", r"C:\ab\x")      # "ab" must not count as under "a"

    def test_unc_rejected(self):
        with self.assertRaises(wc.ContainError):
            wc.normalize_within(self.ROOT, r"\\server\share\x")

    def test_device_namespace_rejected(self):
        with self.assertRaises(wc.ContainError):
            wc.normalize_within(self.ROOT, r"\\?\C:\Users\zbtext\zb\x")

    def test_drive_relative_rejected(self):
        with self.assertRaises(wc.ContainError):
            wc.normalize_within(self.ROOT, r"C:zb\x")

    def test_alternate_data_stream_rejected(self):
        with self.assertRaises(wc.ContainError):
            wc.normalize_within(self.ROOT, r"C:\Users\zbtext\zb\a:secret")

    def test_reserved_device_name_rejected(self):
        for bad in (r"C:\Users\zbtext\zb\NUL", r"C:\Users\zbtext\zb\NUL.txt", r"C:\Users\zbtext\zb\COM3"):
            with self.assertRaises(wc.ContainError):
                wc.normalize_within(self.ROOT, bad)

    def test_trailing_dot_or_space_component_rejected(self):
        for bad in (r"C:\Users\zbtext\zb\foo.", "C:\\Users\\zbtext\\zb\\foo "):
            with self.assertRaises(wc.ContainError):
                wc.normalize_within(self.ROOT, bad)

    def test_empty_and_nul_rejected(self):
        with self.assertRaises(wc.ContainError):
            wc.normalize_within(self.ROOT, "")
        with self.assertRaises(wc.ContainError):
            wc.normalize_within(self.ROOT, "C:\\Users\\zbtext\\zb\\a\x00b")

    def test_rootless_rejected(self):
        with self.assertRaises(wc.ContainError):
            wc.normalize_within(self.ROOT, r"\Users\zbtext\zb\a")


    def test_illegal_characters_rejected(self):
        for bad in (r"C:\Users\zbtext\zb\a|b", r"C:\Users\zbtext\zb\a<b", 'C:\\Users\\zbtext\\zb\\a\x01b'):
            with self.assertRaises(wc.ContainError):
                wc.normalize_within(self.ROOT, bad)


class _Resolver:
    """A fake PathResolver: identity unless a path is remapped; can also fail (resolution error)."""
    def __init__(self, mapping=None, fail=False):
        self.mapping = mapping or {}
        self.fail = fail

    def resolve(self, path):
        if self.fail:
            raise OSError("cannot resolve (reparse)")
        return self.mapping.get(path, path)


class ResolvedContainment(unittest.TestCase):
    ROOT = r"C:\Users\zbtext\zb"

    def test_identity_resolver_passes(self):
        got = wc.resolved_within(self.ROOT, r"C:\Users\zbtext\zb\build\x", _Resolver())
        self.assertEqual(got, r"C:\Users\zbtext\zb\build\x")

    def test_junction_escape_fails_closed(self):
        # lexically in-root, but the junction resolves OUT of root
        cand = r"C:\Users\zbtext\zb\j\x"
        resolver = _Resolver({cand: r"C:\Windows\System32\x", self.ROOT: self.ROOT})
        with self.assertRaises(wc.ContainError):
            wc.resolved_within(self.ROOT, cand, resolver)

    def test_resolver_failure_fails_closed(self):
        with self.assertRaises(wc.ContainError):
            wc.resolved_within(self.ROOT, r"C:\Users\zbtext\zb\x", _Resolver(fail=True))

    def test_resolver_empty_result_fails_closed(self):
        cand = r"C:\Users\zbtext\zb\x"
        with self.assertRaises(wc.ContainError):
            wc.resolved_within(self.ROOT, cand, _Resolver({cand: ""}))

    def test_lexical_prefilter_runs_before_resolver(self):
        # a lexically-bad candidate must be rejected without ever consulting the resolver
        with self.assertRaises(wc.ContainError):
            wc.resolved_within(self.ROOT, r"\\server\share\x", _Resolver(fail=True))


class _Probe:
    def __init__(self, available):
        self._a = available

    def job_object_available(self):
        return self._a


class ContainmentChoice(unittest.TestCase):
    def test_linux_is_bwrap(self):
        c = wc.choose_containment("linux", None)
        self.assertEqual(c.kind, "bwrap")
        self.assertFalse(c.kill_on_close)

    def test_darwin_is_seatbelt(self):
        self.assertEqual(wc.choose_containment("darwin", None).kind, "seatbelt")

    def test_windows_with_job_object_is_job_object_kill_on_close(self):
        c = wc.choose_containment("win32", _Probe(True))
        self.assertEqual(c.kind, "job-object")
        self.assertTrue(c.kill_on_close)
        self.assertTrue(c.create_suspended, "the child must be created suspended, assigned, then resumed")

    def test_windows_without_job_object_fails_closed(self):
        with self.assertRaises(wc.ContainError):
            wc.choose_containment("win32", _Probe(False))

    def test_windows_without_probe_fails_closed(self):
        with self.assertRaises(wc.ContainError):
            wc.choose_containment("win32", None)

    def test_unknown_platform_fails_closed(self):
        with self.assertRaises(wc.ContainError):
            wc.choose_containment("plan9", _Probe(True))


if __name__ == "__main__":
    unittest.main()
