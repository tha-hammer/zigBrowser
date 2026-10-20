"""The login helper and the app check authorize URLs alike (chat-drawer plan rev 16.18.11;
BlackRobin 5924). tests/fixtures/agent/authorize_url_cases.json holds every case; the app's
answer is `app` (tests/agent_auth_authorize_test.zig runs it against agent_auth.authorizeUrl),
and login.authorize_url must give `helper` where a case sets it (an intended difference),
else `app`. Run the module alone, as the gate does."""

import json
import sys
import unittest
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parents[1]
REPO = HOST_DIR.parents[1]
sys.path.insert(0, str(HOST_DIR))

from zb_agent_host import login  # noqa: E402

TABLE = REPO / "tests" / "fixtures" / "agent" / "authorize_url_cases.json"


class AuthorizeParity(unittest.TestCase):
    def test_the_helper_answers_every_case_as_the_table_says(self):
        cases = json.loads(TABLE.read_text(encoding="utf-8"))["cases"]
        self.assertGreaterEqual(len(cases), 30)
        wrong = [(c["name"], c["why"]) for c in cases
                 if bool(login.authorize_url(c["url"])) != c.get("helper", c["app"])]
        self.assertEqual(wrong, [])

    def test_only_visible_ascii_anywhere(self):
        """Rev 16.18.14 (RoseCat 6261): the helper refuses a NUL, a control byte, a space, DEL
        or a non-ASCII character anywhere in the URL, as the app does; so its 4096 cap counts
        bytes (bytes equal characters)."""
        captured = {c["name"]: c for c in json.loads(TABLE.read_text(encoding="utf-8"))["cases"]}["captured-shape"]["url"]
        self.assertTrue(login.authorize_url(captured))
        scheme_end = captured.index("://") + 3
        path_at = captured.index("/cai/")
        query_at = captured.index("?") + 1
        state_at = captured.index("zbState-0123")
        for bad in ("\x00", "\x01", "\x1f", "\x7f", "\t", "\n", " ", "\u00e9", "\u2028"):
            for at in (scheme_end, path_at, query_at, state_at, len(captured)):
                url = captured[:at] + bad + captured[at:]
                with self.subTest(byte=repr(bad), at=at):
                    self.assertIsNone(login.authorize_url(url))
        # bytes, not characters: a non-ASCII state that would fit as characters is refused anyway
        pad = 4096 - len(captured) + len("zbState-0123") - 1
        url = captured.replace("zbState-0123", "\u00e9" + "s" * pad)
        self.assertEqual(len(url), 4096)
        self.assertGreater(len(url.encode("utf-8")), 4096)
        self.assertIsNone(login.authorize_url(url))

    def test_case_names_are_unique(self):
        names = [c["name"] for c in json.loads(TABLE.read_text(encoding="utf-8"))["cases"]]
        self.assertEqual(len(names), len(set(names)))

    def test_the_differences_are_few_and_named(self):
        cases = json.loads(TABLE.read_text(encoding="utf-8"))["cases"]
        differ = [c["name"] for c in cases if "helper" in c]
        self.assertEqual(differ, ["malformed-escape"])

    def test_the_captured_url_is_accepted_by_both(self):
        cases = {c["name"]: c for c in json.loads(TABLE.read_text(encoding="utf-8"))["cases"]}
        self.assertTrue(cases["captured-shape"]["app"])
        self.assertTrue(login.authorize_url(cases["captured-shape"]["url"]))


if __name__ == "__main__":
    unittest.main()
