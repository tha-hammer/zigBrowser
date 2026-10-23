"""Exact red vectors for the Mac runtime rows (tests/mac/ms_runtime_rows_gate.sh; SilverRidge cf7a783, 8721b6d).

A red counts only in the exact shape that was accepted: every assertion it names ran, each one passed, or failed
WITH ITS ACCEPTED RED VALUE (an exit code, a reply kind, a window id, a timing), nothing else ran, and no
precondition or unexpected error intervened. A test records each assertion under a stable id with
check(aid, ok, detail, observed), each precondition or unexpected error with problem(), and ends with report().
report() prints one `ASSERT\t<test>\t<id>\tpass|fail\t<observed>` line per assertion, then:
  every assertion of the vector passed, nothing else  -> PASS\t<test>, exit code 0 (the green);
  otherwise FAIL\t<test>, then
    RED_SHAPE\t<test>                     when the outcome is exactly the accepted red vector, or
    RED_SHAPE_MISMATCH\t<test>\t<why>     for each way it differs (missing, extra, flipped, wrong value, problem).
The rows gate requires RED_SHAPE\t<test> for a red row, so a red that fails in any other way is a MISMATCH.
Hostless proof: tests/e2e/mac_red_shape_selftest.py.
"""
import sys

PASS, FAIL = "pass", "fail"
_NONE = object()  # check() called without an observed value


class Red:
    """An accepted red outcome: the assertion fails AND its observed value is `accepted` (same type and value), or
    satisfies `accepts` when given (described by `desc`). `counter` is a realistic wrong value of the same polarity,
    used by the hostless selftest to prove that a failure with any other value is a MISMATCH."""

    def __init__(self, accepted, counter, desc: str = "", accepts=None):
        self.accepted, self.counter, self._accepts = accepted, counter, accepts
        self.desc = desc or repr(accepted)
        if self.accepts(counter) or not self.accepts(accepted):
            raise ValueError(f"red value {self.desc}: must accept {accepted!r} and reject {counter!r}")

    def accepts(self, value) -> bool:
        if self._accepts is not None:
            return bool(self._accepts(value))
        return type(value) is type(self.accepted) and value == self.accepted


def reply_kind(reply) -> str:
    """'result', or 'error:<data.reason or message>' for a JSON-RPC reply dict; 'not-a-reply' otherwise."""
    if not isinstance(reply, dict):
        return "not-a-reply"
    if "error" in reply:
        err = reply.get("error") or {}
        return f"error:{(err.get('data') or {}).get('reason') or err.get('message')}"
    return "result" if "result" in reply else "not-a-reply"


class RedShape:
    def __init__(self, test_id: str, vector: dict):
        bad = {k: v for k, v in vector.items() if v != PASS and not isinstance(v, Red)}
        if not vector or bad:
            raise ValueError(f"red vector of {test_id} must map assertion ids to PASS or Red(...): {bad or vector!r}")
        self.test_id = test_id
        self.vector = dict(vector)
        self.results: dict = {}  # id -> (ok, detail, observed), in the order the assertions ran
        self.problems: list = []

    def check(self, aid: str, ok: bool, detail: str = "", observed=_NONE) -> bool:
        if aid in self.results:
            self.problems.append(f"assertion {aid} ran twice")
        self.results[aid] = (bool(ok), detail, observed)
        return bool(ok)

    def problem(self, msg: str) -> None:
        self.problems.append(msg)

    def mismatches(self) -> list:
        out = list(f"problem: {p}" for p in self.problems)
        out += [f"missing assertion {aid}" for aid in self.vector if aid not in self.results]
        out += [f"unexpected assertion {aid}" for aid in self.results if aid not in self.vector]
        for aid, want in self.vector.items():
            if aid not in self.results:
                continue
            ok, _detail, observed = self.results[aid]
            if want == PASS:
                if not ok:
                    out.append(f"{aid} failed, the accepted red vector says pass")
            elif ok:
                out.append(f"{aid} passed, the accepted red vector says fail with {want.desc}")
            elif observed is _NONE:
                out.append(f"{aid} failed with no observed value, the accepted red value is {want.desc}")
            elif not want.accepts(observed):
                out.append(f"{aid} failed with {observed!r}, the accepted red value is {want.desc}")
        return out

    def report(self) -> int:
        for aid, (ok, _detail, observed) in self.results.items():
            shown = "-" if observed is _NONE else repr(observed)
            print(f"ASSERT\t{self.test_id}\t{aid}\t{PASS if ok else FAIL}\t{shown}")
        complete = not self.problems and set(self.results) == set(self.vector)
        if complete and all(ok for ok, _d, _o in self.results.values()):
            print(f"PASS\t{self.test_id}", flush=True)
            return 0
        print(f"FAIL\t{self.test_id}")
        for aid, (ok, detail, _observed) in self.results.items():
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
