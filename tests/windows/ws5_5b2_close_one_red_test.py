"""WS5.5b-2 (A) RED — UNREGISTERED. RoseCat 5a204f3 #1/#2.

Pins two not-yet-present things:
  #2 a STRICT validator for a close-one-early transcript — exactly N windows each [tree,icon,open], one
     `liveclose` row (peak, intermediate) and one terminal `live` row (peak, final), with peak==N,
     intermediate==N-1 and final==0 — plus the skipped / double-decrement / missing-final-cleanup mutants.
  #1 the extra WndProc decrements through an APP-OWNED per-HWND record (iterates app->extra_windows and
     retires rec.live), not a bare GWLP_USERDATA flag.

Red now: win_drawer_behaviors_test.validate_close_one_transcript does not exist, and the shim's
drawer_extra_window_proc body does not yet reference an app-owned record. Green adds both.
"""
import os
import pathlib
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import win_drawer_behaviors_test as whb  # noqa: E402
import win_drawer_test as wd  # noqa: E402

SHIM = pathlib.Path(__file__).resolve().parents[2] / "src" / "webview2_shim.cpp"


def _close_one_transcript(peak, intermediate, final):
    w1 = ("DRAWER\t1\ttree\thost,page,icon,panel\nDRAWER\t1\ticon\t928,649,56,56\n"
          "DRAWER\t1\topen\t0,437,1008,292\n")
    w2 = ("DRAWER\t2\ttree\thost,icon,panel\nDRAWER\t2\ticon\t928,649,56,56\n"
          "DRAWER\t2\topen\t0,437,1008,292\n")
    close = f"DRAWER\t1\tliveclose\t{peak}\t{intermediate}\n"
    final_row = f"DRAWER\t1\tlive\t{peak}\t{final}\n"
    return w1 + w2 + close + final_row


class Ws55b2CloseOneRed(unittest.TestCase):
    def test_validator_accepts_the_exact_close_one_structure(self):
        whb.validate_close_one_transcript(_close_one_transcript(2, 1, 0), 2)  # must not raise

    def test_validator_rejects_skipped_double_and_missing_final(self):
        with self.assertRaises(AssertionError):  # skipped: no liveclose row
            whb.validate_close_one_transcript(
                _close_one_transcript(2, 1, 0).replace("DRAWER\t1\tliveclose\t2\t1\n", ""), 2)
        with self.assertRaises(AssertionError):  # double-decrement: intermediate 0, not 1
            whb.validate_close_one_transcript(_close_one_transcript(2, 0, 0), 2)
        with self.assertRaises(AssertionError):  # missing final cleanup: terminal != 0
            whb.validate_close_one_transcript(_close_one_transcript(2, 1, 1), 2)

    def test_extra_wndproc_uses_an_app_owned_record(self):
        proc = " ".join(wd.extract_cpp_function(SHIM.read_text(encoding="utf-8"), "drawer_extra_window_proc").split())
        self.assertIn("extra_windows", proc, "the WndProc must retire an app-owned per-HWND record")
        self.assertIn(".live", proc, "the record must carry a live flag retired on the destroy path")


if __name__ == "__main__":
    unittest.main()
