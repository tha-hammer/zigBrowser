"""Exact red vectors for the Mac runtime rows (tests/mac/ms_runtime_rows_gate.sh; SilverRidge cf7a783).

A red counts only in the exact shape that was accepted: every assertion it names ran, each one failed or passed
as its accepted vector says, nothing else ran, and no precondition or unexpected error intervened. A test
records each assertion under a stable id with check(), each precondition or unexpected error with problem(),
and ends with report(). report() prints one `ASSERT\t<test>\t<id>\tpass|fail` line per assertion, then:
  every assertion of the vector passed, nothing else  -> PASS\t<test>, exit code 0 (the green);
  otherwise FAIL\t<test>, then
    RED_SHAPE\t<test>                     when the outcome is exactly the accepted red vector, or
    RED_SHAPE_MISMATCH\t<test>\t<why>     for each way it differs (missing, extra, flipped, problem).
The rows gate requires RED_SHAPE\t<test> for a red row, so a red that fails in any other way is a MISMATCH.
Hostless proof: tests/e2e/mac_red_shape_selftest.py.
"""
import sys

PASS, FAIL = "pass", "fail"


class RedShape:
    def __init__(self, test_id: str, vector: dict):
        bad = {k: v for k, v in vector.items() if v not in (PASS, FAIL)}
        if not vector or bad:
            raise ValueError(f"red vector of {test_id} must map assertion ids to pass/fail: {bad or vector!r}")
        self.test_id = test_id
        self.vector = dict(vector)
        self.results: dict = {}  # id -> (ok, detail), in the order the assertions ran
        self.problems: list = []

    def check(self, aid: str, ok: bool, detail: str = "") -> bool:
        if aid in self.results:
            self.problems.append(f"assertion {aid} ran twice")
        self.results[aid] = (bool(ok), detail)
        return bool(ok)

    def problem(self, msg: str) -> None:
        self.problems.append(msg)

    def mismatches(self) -> list:
        out = list(f"problem: {p}" for p in self.problems)
        out += [f"missing assertion {aid}" for aid in self.vector if aid not in self.results]
        out += [f"unexpected assertion {aid}" for aid in self.results if aid not in self.vector]
        for aid, want in self.vector.items():
            if aid in self.results:
                got = PASS if self.results[aid][0] else FAIL
                if got != want:
                    out.append(f"{aid} {got}ed, the accepted red vector says {want}")
        return out

    def report(self) -> int:
        for aid, (ok, _detail) in self.results.items():
            print(f"ASSERT\t{self.test_id}\t{aid}\t{PASS if ok else FAIL}")
        complete = not self.problems and set(self.results) == set(self.vector)
        if complete and all(ok for ok, _ in self.results.values()):
            print(f"PASS\t{self.test_id}", flush=True)
            return 0
        print(f"FAIL\t{self.test_id}")
        for aid, (ok, detail) in self.results.items():
            if not ok:
                print(f"  {aid}: {detail}", file=sys.stderr)
        for p in self.problems:
            print(f"  {p}", file=sys.stderr)
        why = self.mismatches()
        if why:
            for w in why:
                print(f"RED_SHAPE_MISMATCH\t{self.test_id}\t{w}")
        else:
            print(f"RED_SHAPE\t{self.test_id}")
        sys.stdout.flush()
        return 1
