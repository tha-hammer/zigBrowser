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
