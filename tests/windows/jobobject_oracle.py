"""VM-side driver for the live Job Object containment test (bead zigBrowser-d1d, part 2).

Exercises the real `wincontain_win32.launch_in_job` on Windows and reports what the OS actually did, so a
Linux test can assert the containment contract against the real API:

    python jobobject_oracle.py <mode>        # mode: "correct" | "noflag"

  * correct  -> job carries KILL_ON_JOB_CLOSE; the child is created suspended, assigned, resumed.
  * noflag   -> same sequence but WITHOUT KILL_ON_JOB_CLOSE (a negative control: the child must survive the
               job handle closing, proving the flag is what kills).

Prints {"mode","pid","in_job","running_before_close","killed_on_close"} on stdout.
"""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import wincontain_win32 as wj  # noqa: E402

# A benign ~30 s sleeper; kill-on-close (correct mode) ends it at once, so the test never waits that long.
# `> nul` keeps the child's output off this driver's stdout, which must be JSON only.
_CHILD = r"C:\Windows\System32\cmd.exe /c ping -n 30 127.0.0.1 > nul"


def main():
    mode = sys.argv[1]
    kill = (mode != "noflag")
    child = wj.launch_in_job(_CHILD, kill_on_close=kill)
    out = {
        "mode": mode,
        "pid": child.pid,
        "in_job": child.is_in_job(),
        "running_before_close": child.still_running(),
    }
    # A short wait bounds the noflag case (the child is expected to survive); kill-on-close is near-instant.
    out["killed_on_close"] = child.close_job_and_wait(2000)
    if child.still_running():
        # noflag: the child outlived the job handle — clean it up so nothing lingers on the VM.
        wj._TerminateProcess(child.hprocess, 1)
    child.close_handles()
    print(json.dumps(out))


if __name__ == "__main__":
    main()
