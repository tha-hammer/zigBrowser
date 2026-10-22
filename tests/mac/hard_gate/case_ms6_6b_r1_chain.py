"""MS6.6 (B), R1's production chain on a Mac (plan rev 18, 18.1; RoseCat 7053), under the STAGED pinned runtime: the
staged python3.12 imports the staged zb_agent_host, and the real setup.probe_r1 runs the real chain:
  setup binds the 127.0.0.1 listener and the census socketpair OUTSIDE Seatbelt
  -> sandbox-exec with setup's rendered profile (pass_fds = exactly the listener and the census end)
  -> python -m zb_agent_host probe-r1 (route_probe: adopts the listener, serves the one-shot Messages API, imports the
     staged claude_agent_sdk) -> the production zb-claude wrapper (token.write_wrapper, as setup.stage writes it)
  -> a CONTROLLED CLI: a native stand-in compiled here (the census finds the CLI by its executable path), which reads
     the token from the backend channel's fd and POSTs /v1/messages with "Bearer <token>" to ANTHROPIC_BASE_URL.
Rows (RoseCat 7053):
 1. positive: an honest CLI -> probe_r1 True; the one sandboxed run is /usr/bin/sandbox-exec with pass_fds exactly
    (listener, census end), the listener on 127.0.0.1:<--listen-port>, the census end an AF_UNIX stream socket, and the
    profile's only outbound rule (remote tcp "localhost:<that port>"); setup's census ran once, over the exact probe
    token shape and the canary ANTHROPIC_BASE_URL=http://127.0.0.1:<that port>, and said clean (listener service +
    census request and reply);
 2. planted-token control: a CLI that re-execs itself with the token in its environment -> probe_r1 False; its own
    positives first (the census ran, and the CLI's real environment, read outside Seatbelt, holds the planted token);
 3. forged capability: the planted CLI first writes "clean" into every socket it holds -> still False. Causal
    (RoseCat 7300 #1): the forge branch re-execs with ZB_FORGED=<fds scanned>,<sockets>,<written> beside the planted
    token, read from its real environment outside Seatbelt; the planted CLI is the same source compiled without the
    forge branch, i.e. the forge-deleted mutant, and the case requires it to carry NO ZB_FORGED;
 4. timeout/lifecycle: a CLI that never calls (and exits by itself after 90 s) -> probe_r1 False within the probe's
    bound and no census at all.
After EVERY row (RoseCat 7300 #2): the listener's port is free again on 127.0.0.1 and ::1, and no part of that row's
probe chain is alive: no process of ours runs that row's CLI (proc_pidpath) or is a python whose argv names that row's
runtime or CLI (the sandboxed probe, the wrapper before its exec). The inspection fails closed (RoseCat 7300 #3): a
failed ps, or any read of one of our processes that fails while it has not vanished, fails the row, even when a later
scan is clean (RoseCat 7312). Any non-clean scan (a survivor, an unreadable pid, a failed ps) is re-inspected until
clean or the row's horizon (every controlled CLI ends itself by 90 s), never signalled, and the final scan must be
clean (RoseCat 7306).
Kill safety (RoseCat 7250, 7454): this case makes no direct signal call. Its compiler and ps run through the guarded
h.spawn_group. Setup's own runs go through the real production seam setup.run_in_owned_group, which DOES send a
guarded killpg to its own child's process group at the end of every run (owned_group, behind the reviewed guards;
fd1bd92, 0ef12ea); that is the production path this case exercises. The observation spies call through to the real
functions and are removed after every row."""
import os
import re
import socket
import subprocess
import sys
import time

NAME = "ms6.6b-r1-chain"

CLI_C = r"""
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
extern char **environ;
static char tok[700];
static int read_token(void) {
  const char *planted = getenv("ZB_PLANTED");
  if (planted) { snprintf(tok, sizeof tok, "%s", planted); return 0; }
  const char *v = getenv(CHANNEL_ENV);
  if (!v) return -1;
  int fd = atoi(v); size_t n = 0;
  for (;;) {
    struct pollfd p = {fd, POLLIN, 0};
    if (poll(&p, 1, 5000) <= 0) break;
    ssize_t r = read(fd, tok + n, sizeof tok - 1 - n);
    if (r <= 0) break;
    n += (size_t)r;
    if (n >= sizeof tok - 1) break;
  }
  close(fd);
  while (n && (tok[n - 1] == '\n' || tok[n - 1] == '\r')) n--;
  tok[n] = 0;
  return n ? 0 : -1;
}
static char forged[64];
static void forge(void) {  /* the forged capability: "clean" into every socket held; the attempt goes on record */
  int sockets = 0, written = 0;
  signal(SIGPIPE, SIG_IGN);  /* a closed peer is an EPIPE here, not this process's end */
  for (int fd = 0; fd < 1024; fd++) {
    struct stat st;
    if (fstat(fd, &st) == 0 && S_ISSOCK(st.st_mode)) {
      sockets++;
      if (write(fd, "clean\n", 6) == 6) written++;
    }
  }
  snprintf(forged, sizeof forged, "ZB_FORGED=1024,%d,%d", sockets, written);
}
int main(int argc, char **argv) {
  (void)argc;
  if (read_token() != 0) return 3;
  if (MODE_HANG) { sleep(90); return 0; }  /* never calls; ends by itself */
  if (MODE_PLANT && !getenv("ZB_PLANTED")) {
    if (MODE_FORGE) forge();  /* before the re-exec, so its record is in the censused environment */
    size_t n = 0; while (environ[n]) n++;
    char **env = calloc(n + 3, sizeof *env);
    for (size_t i = 0; i < n; i++) env[i] = environ[i];
    static char kv[760]; snprintf(kv, sizeof kv, "ZB_PLANTED=%s", tok);
    env[n] = kv; env[n + 1] = forged[0] ? forged : NULL; env[n + 2] = NULL;
    execve(argv[0], argv, env);  /* same executable path: the census must find it, token in its environment */
    return 4;
  }
  const char *url = getenv("ANTHROPIC_BASE_URL");
  if (!url || strncmp(url, "http://127.0.0.1:", 17) != 0) return 5;
  int port = atoi(url + 17);
  int s = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in a; memset(&a, 0, sizeof a);
  a.sin_family = AF_INET; a.sin_port = htons((unsigned short)port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (s < 0 || connect(s, (struct sockaddr *)&a, sizeof a) != 0) return 6;
  const char *body = "{\"stream\": false}";
  char req[1200];
  int len = snprintf(req, sizeof req,
                     "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer %s\r\n"
                     "Content-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
                     tok, strlen(body), body);
  if (write(s, req, (size_t)len) != len) return 7;
  char buf[512];
  for (;;) {  /* hold on until the server answered: setup's census runs while this process lives */
    struct pollfd p = {s, POLLIN, 0};
    if (poll(&p, 1, 60000) <= 0) break;
    if (read(s, buf, sizeof buf) <= 0) break;
  }
  close(s);
  return 0;
}
"""

MODES = {"honest": (0, 0, 0), "planted": (1, 0, 0), "forge": (1, 1, 0), "hang": (0, 0, 1)}
TOKEN_SHAPE = re.compile(rb"zb-probe-[0-9a-f]{48}")
# owned_group.REASONS, held here: the case trusts no text from an exception, only a code from this fixed set.
STOP_REASONS = ("not_ours", "kill_refused", "reap_timeout", "table_unreadable", "members_alive", "output_held")
DIAG_MAX = 600  # characters of each probe stream shown when a row fails
_REDACT = [re.compile(p) for p in (
    r"zb-probe-\S*",  # the probe token, whatever follows its prefix
    r"(?i)bearer\s+\S+",
    r"sk-ant-\S+",
    r"(?i)(?:token|authorization|secret|key)\w*\s*[=:]\s*\S+",
    r"[0-9A-Fa-f]{6,}",  # any hex run: the token's 48 hex, wrapped pieces, a hex encoding of it
    r"[A-Za-z0-9+_=-]{24,}",  # any long base64-ish run (an encoded token)
)]


def _sanitize(text):
    """The probe's stdout/stderr made safe to print (RoseCat 7358): every redaction runs BEFORE the text is bounded to
    its last DIAG_MAX characters, so no cut can expose a token; no run of 6 hex characters, no "zb-probe-" text, no
    Bearer/assignment value and no long base64-ish run survives; control characters become "?"."""
    if text is None:
        return ""
    if isinstance(text, bytes):
        text = text.decode("utf-8", "replace")
    for rx in _REDACT:
        text = rx.sub("<redacted>", text)
    text = "".join(c if c == "\n" or c.isprintable() else "?" for c in text)
    return text[-DIAG_MAX:]


def _census_view(seen):
    """A census record as a label may print it (RoseCat 7366 #1): never the token itself, only whether it had the
    probe token's exact shape; the rest (exe, root, canary, verdicts, forge record) carries no secret, and a read error
    goes through _sanitize."""
    tok = seen.get("token")
    return {"token_shape_ok": isinstance(tok, bytes) and TOKEN_SHAPE.fullmatch(tok) is not None,
            "exe": seen.get("exe"), "root": seen.get("root"), "canary": seen.get("canary"),
            "clean": seen.get("clean"), "planted": seen.get("planted"), "forged": seen.get("forged"),
            "read_error": _sanitize(seen.get("read_error")) or None}


def _diag(rec):
    return rec.get("diag", "no sandboxed run was recorded") if rec else "no sandboxed run was recorded"


def _port_free(port):
    """No live socket holds `port` on 127.0.0.1 or ::1. SO_REUSEADDR only so the served connection's TIME_WAIT does
    not count: on Darwin a socket still bound to the exact address (setup's listener or ::1 reservation, which set no
    reuse flag) refuses the bind anyway."""
    for family, host in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        s = socket.socket(family, socket.SOCK_STREAM)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if family == socket.AF_INET6:
                s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            s.bind((host, port))
        except OSError:
            return False
        finally:
            s.close()
    return True


_PS_ROW = re.compile(r"([0-9]+)\s+(-?[0-9]+)\s+(\S+)")  # pid, uid (macOS shows nobody as -2), stat


def _chain_alive(h, proc_darwin, cli, markers):
    """(inspected, alive, unreadable) over OUR processes (an orphaned chain member is no longer setup's descendant, so
    the whole table is read; ps runs through the guarded h.spawn_group). Alive: a process running `cli`
    (proc_pidpath, as the census reads it), or a python whose argv names one of `markers` (this row's runtime and CLI
    dirs: the sandboxed probe, the wrapper before its exec). Fails closed (RoseCat 7300 #3): a failed ps is
    inspected=False, and any read that fails while the pid has not vanished is listed as unreadable. Zombies have
    exited and run nothing; they are skipped."""
    code, out, _ = h.spawn_group(["/bin/ps", "-axo", "pid=,uid=,stat="], env={"PATH": "/usr/bin:/bin"}, timeout=20)
    if code != 0:
        return False, [], []
    alive, unreadable = [], []
    for line in out.decode(errors="replace").splitlines():
        m = _PS_ROW.fullmatch(line.strip())
        if m is None:
            return False, [], [line]
        pid, uid, stat = int(m.group(1)), int(m.group(2)), m.group(3)
        if uid != os.getuid() or pid == os.getpid() or stat.startswith("Z"):
            continue
        try:
            exe = proc_darwin.path(pid)
        except OSError as e:
            unreadable.append((pid, f"path: {e}"))
            continue
        if exe is None:
            continue  # vanished (ESRCH)
        if exe == cli:
            alive.append((pid, exe))
            continue
        if not os.path.basename(exe).lower().startswith("python"):
            continue
        try:
            _raw, argv, _env = proc_darwin.environ_of(pid)
        except OSError as e:
            try:
                gone = proc_darwin.path(pid) is None
            except OSError:
                gone = False
            if not gone:
                unreadable.append((pid, f"procargs: {e}"))
            continue
        if any(os.fsencode(m) in a for a in argv for m in markers):  # environ_of's argv is list[bytes] (7306 #1)
            alive.append((pid, exe))
    return True, alive, unreadable


CHAIN_GRACE_S = 15  # a finished row's chain is gone within this
CHAIN_HORIZON_S = 100  # from the row's start: every controlled CLI has ended itself by then (the hang CLI at 90 s)


def _clean(scan):
    inspected, alive, unreadable = scan
    return inspected and not alive and not unreadable


def _chain_release(scan, started_at, clock=time.monotonic, sleep=time.sleep):
    """(faults, survivors, last). Scans once a second until a clean, empty scan or the end: the row's self-exit horizon,
    and never before a full CHAIN_GRACE_S from now. `faults`: every scan that was not inspected or listed an unreadable
    pid, kept even when a later scan is clean (sticky row-failure evidence; RoseCat 7312). `survivors`: what was still
    alive once the grace had passed ([] when the chain was gone within it). `last`: the final scan. Nothing is ever
    signalled: a survivor is waited out (RoseCat 7306 #2)."""
    faults, survivors = [], None
    grace = clock() + CHAIN_GRACE_S
    end = max(grace, started_at + CHAIN_HORIZON_S)
    while True:
        result = scan()
        inspected, alive, unreadable = result
        if not inspected or unreadable:
            faults.append(result)
        now = clock()
        if _clean(result) or now >= end:
            return faults, (survivors if survivors is not None else ([] if now < grace else list(alive))), result
        if survivors is None and now >= grace:
            survivors = list(alive)
        sleep(1)


def _released(h, proc_darwin, label, cli, runtime, runs, started_at):
    """After EVERY row (RoseCat 7300 #2): the port free on both families; no inspection fault in any scan (RoseCat
    7312); no part of the chain alive after CHAIN_GRACE_S; and, waited out unsignalled to the row's horizon, a
    clean, empty final scan (RoseCat 7306 #2). `label` names the evidence row, `cli` is that row's own CLI (never
    looked up by the label: 4e17273's KeyError 'positive'; RoseCat 7358)."""
    argv = runs[0]["argv"] if len(runs) == 1 else []
    port = int(argv[argv.index("--listen-port") + 1]) if "--listen-port" in argv else None
    h.check(port is not None and _port_free(port), f"{label}: afterwards port {port} is free on 127.0.0.1 and ::1")
    markers = [runtime, os.path.dirname(cli)]
    faults, survivors, last = _chain_release(lambda: _chain_alive(h, proc_darwin, cli, markers), started_at)
    h.check(faults == [], f"{label}: every scan inspected every process of ours ({faults})")
    h.check(survivors == [], f"{label}: no part of the probe chain is alive after {CHAIN_GRACE_S} s ({survivors})")
    h.check(_clean(last), f"{label}: waited out unsignalled, a clean, empty final scan ({last})")


def run(h):
    prefix = h.prefix
    if not h.check(bool(prefix) and os.path.isdir(os.path.join(prefix or "", "zb_agent_host")),
                   f"the staged agent-host is present (ZB_HG_PREFIX={prefix!r})"):
        return
    if not h.check(bool(h.python) and os.path.realpath(sys.executable) == os.path.realpath(h.python),
                   f"this case runs under the staged interpreter ({sys.executable} vs {h.python})"):
        return
    sys.path.insert(0, prefix)
    from zb_agent_host import proc_darwin, sandbox, setup, token  # the staged tree's own modules
    h.check(setup.PLATFORM == "darwin" and str(setup.PACKAGE_DIR) == os.path.realpath(prefix),
            f"setup is the staged one, on Darwin ({setup.PACKAGE_DIR})")

    channel = sandbox.channel()
    clis = {}
    for mode, (plant, forge, hang) in MODES.items():
        d = os.path.join(h.scratch, f"cli-{mode}")
        os.mkdir(d, 0o700)
        src = os.path.join(d, "cli.c")
        with open(src, "w") as f:
            f.write(CLI_C)
        exe = os.path.join(d, "claude")
        code, _out, err = h.spawn_group(
            ["/usr/bin/xcrun", "clang", "-std=gnu11", "-Wall", "-Werror", f"-DCHANNEL_ENV=\"{channel.env}\"",
             f"-DMODE_PLANT={plant}", f"-DMODE_FORGE={forge}", f"-DMODE_HANG={hang}", src, "-o", exe],
            env={"PATH": "/usr/bin:/bin"}, timeout=120)
        if not h.check(code == 0 and os.access(exe, os.X_OK), f"the {mode} CLI compiles ({err[-300:]!r})"):
            return
        clis[mode] = os.path.realpath(exe)

    real_run, real_census = setup.run_in_owned_group, proc_darwin.cli_env_clean  # setup's named run seam (fd1bd92)

    def one(mode):
        """probe_r1 through the production wrapper in front of the `mode` CLI, observed from outside."""
        runtime = os.path.join(h.scratch, f"runtime-{mode}")
        os.makedirs(os.path.join(runtime, "bin"), 0o700)
        wrapper = os.path.join(runtime, "bin", "zb-claude")
        token.write_wrapper(wrapper, clis[mode])  # as setup.stage writes it
        runs, censuses = [], []

        def spy_run(argv, *args, **kw):
            rec = {"argv": list(argv), "pass_fds": tuple(kw.get("pass_fds", ())), "fds": []}
            for fd in rec["pass_fds"]:
                dup = socket.socket(fileno=os.dup(fd))
                try:
                    rec["fds"].append((dup.family, dup.type, dup.getsockname()))
                finally:
                    dup.close()
            if "-f" in rec["argv"]:
                with open(rec["argv"][rec["argv"].index("-f") + 1]) as f:
                    rec["profile"] = f.read()
            runs.append(rec)
            try:
                done = real_run(argv, *args, **kw)
            except subprocess.TimeoutExpired as e:
                rec["diag"] = (f"probe timed out after {e.timeout} s; stdout {_sanitize(e.stdout)!r}; "
                               f"stderr {_sanitize(e.stderr)!r}")
                raise
            except Exception as e:
                reason = getattr(e, "reason", None)  # owned_group's fixed code for which stop proof failed; never text
                rec["diag"] = f"probe run raised {type(e).__name__}" + (
                    "" if reason is None else f" (reason={reason if reason in STOP_REASONS else 'unknown'})")
                raise
            rec["diag"] = (f"probe rc={done.returncode}; stdout {_sanitize(done.stdout)!r}; "
                           f"stderr {_sanitize(done.stderr)!r}")
            return done

        def spy_census(exe, root, tok, canary):
            seen = {"exe": exe, "root": root, "token": tok, "canary": canary, "planted": None, "forged": None}
            try:
                for pid in proc_darwin.descendants_running(exe, root):
                    _raw, _argv, env = proc_darwin.environ_of(pid)
                    seen["planted"] = any(e.startswith(b"ZB_PLANTED=") and tok in e for e in env)
                    seen["forged"] = [e for e in env if e.startswith(b"ZB_FORGED=")]
            except OSError as e:
                seen["read_error"] = str(e)  # leaves planted/forged None: their checks then fail
            seen["clean"] = real_census(exe, root, tok, canary)
            censuses.append(seen)
            return seen["clean"]

        setup.run_in_owned_group, proc_darwin.cli_env_clean = spy_run, spy_census
        started = time.monotonic()
        try:
            verdict = setup.probe_r1(wrapper, clis[mode])
        finally:
            setup.run_in_owned_group, proc_darwin.cli_env_clean = real_run, real_census
        return verdict, time.monotonic() - started, runs, censuses, runtime

    # 1. positive
    t0 = time.monotonic()
    verdict, _took, runs, censuses, runtime = one("honest")
    h.check(verdict is True, "positive: an honest CLI through the real chain selects R1"
            + ("" if verdict is True else f" ({_diag(runs[0] if runs else None)})"))
    if h.check(len(runs) == 1, f"positive: exactly one sandboxed run ({len(runs)})"):
        r = runs[0]
        argv = r["argv"]
        port = int(argv[argv.index("--listen-port") + 1]) if "--listen-port" in argv else None
        lfd = int(argv[argv.index("--listen-fd") + 1]) if "--listen-fd" in argv else None
        cfd = int(argv[argv.index("--census-fd") + 1]) if "--census-fd" in argv else None
        h.check(argv[0] == "/usr/bin/sandbox-exec", f"positive: the probe runs under sandbox-exec ({argv[0]})")
        h.check(r["pass_fds"] == (lfd, cfd), f"positive: pass_fds is exactly (listener, census end) {r['pass_fds']}")
        h.check(len(r["fds"]) == 2 and r["fds"][0][:2] == (socket.AF_INET, socket.SOCK_STREAM)
                and r["fds"][0][2] == ("127.0.0.1", port), f"positive: the listener is 127.0.0.1:{port} ({r['fds']})")
        h.check(len(r["fds"]) == 2 and r["fds"][1][:2] == (socket.AF_UNIX, socket.SOCK_STREAM),
                "positive: the census end is an AF_UNIX stream socket")
        rules = re.findall(r"\(allow network-outbound[^\n]*", r.get("profile", ""))
        h.check(rules == [f'(allow network-outbound (remote tcp "localhost:{port}"))'],
                f"positive: the profile's only outbound rule is that port ({rules})")
        h.check(len(censuses) == 1 and TOKEN_SHAPE.fullmatch(censuses[0]["token"]) is not None
                and censuses[0]["canary"] == f"ANTHROPIC_BASE_URL=http://127.0.0.1:{port}".encode()
                and censuses[0]["exe"] == clis["honest"] and censuses[0]["root"] == os.getpid()
                and censuses[0]["clean"] is True,
                f"positive: setup's census ran once, exact request, clean ({[_census_view(c) for c in censuses]})")
    _released(h, proc_darwin, "positive", clis["honest"], runtime, runs, t0)

    # 2. planted-token control and 3. forged capability: their own positives first. The planted CLI is the forge CLI
    # compiled without its forge branch (the forge-deleted mutant): it must carry no ZB_FORGED (RoseCat 7300 #1).
    for mode in ("planted", "forge"):
        t0 = time.monotonic()
        verdict, _took, runs, censuses, runtime = one(mode)
        h.check(len(censuses) == 1, f"{mode}: the CLI called the server and setup's census ran ({len(censuses)})"
                + ("" if len(censuses) == 1 else f" ({_diag(runs[0] if runs else None)})"))
        seen = censuses[0] if censuses else {}
        h.check(seen.get("planted") is True,
                f"{mode}: the CLI's real environment, read outside Seatbelt, holds the planted token "
                f"({_census_view(seen) if seen else None})")
        forged = seen.get("forged")
        if mode == "forge":
            h.check(forged is not None and len(forged) == 1 and re.fullmatch(rb"ZB_FORGED=1024,[0-9]+,[0-9]+",
                                                                             forged[0]) is not None,
                    f"forge: the forge branch ran, scanned fds 0..1023 and is on record ({forged})")
        else:
            h.check(forged == [], f"planted: the forge-deleted mutant carries no forge record ({forged})")
        h.check(seen.get("clean") is False, f"{mode}: setup's census says dirty")
        h.check(verdict is False, f"{mode}: probe_r1 is False (no R1)")
        _released(h, proc_darwin, mode, clis[mode], runtime, runs, t0)

    # 4. timeout and lifecycle
    t0 = time.monotonic()
    verdict, took, runs, censuses, runtime = one("hang")
    h.check(verdict is False, "hang: a CLI that never calls is no R1")
    h.check(took <= setup.PROBE_TIMEOUT_S + 45, f"hang: probe_r1 ends within its bound ({took:.1f} s)")
    h.check(censuses == [], "hang: no census without a call")
    _released(h, proc_darwin, "hang", clis["hang"], runtime, runs, t0)
