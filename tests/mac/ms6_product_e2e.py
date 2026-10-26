#!/usr/bin/env python3
"""One real-app MS6 proof: drawer -> fd 3 -> Seatbelt -> bundled Claude.

The caller supplies an exact committed source export plus the already pinned
Python package and universal site-package inputs.  This test builds the app
natively, provisions only a private agent home, places one disposable test
token in a disposable Keychain through stdin, and drives the real AppKit Send
callback and fd-3 broker.  It never accepts an unsandboxed fallback.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import queue
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


CONNECT = "zigBrowser: agent: netd census api.anthropic.com:443 allowed"
READY = "DRAWER_AGENT_E2E\tready-fd3"
COMMIT_RE = re.compile(r"[0-9a-f]{40}\Z")
BROKER_SOURCE = r'''
#include "agent_helper_mac.h"
#include "agent_secrets_mac.h"
#include <Security/Security.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int present(const char *path, const char *password) {
  char *value = NULL, *error = NULL;
  int rc = zb_keychain_lookup(path, password, "dev.zigbrowser.MS63ProductTest",
                              ZB_MAC_AGENT_TOKEN_ACCOUNT, &value, &error);
  zb_keychain_free(value);
  free(error);
  if (rc == ZB_KC_OK) return 0;
  if (rc == ZB_KC_ABSENT) return 10;
  return 2;
}

static int store(const char *path, const char *password,
                 const char *app_path, const char *broker_path) {
  char token[514];
  size_t used = 0;
  while (used < sizeof(token) - 1) {
    ssize_t n = read(STDIN_FILENO, token + used, sizeof(token) - 1 - used);
    if (n < 0) return 2;
    if (n == 0) break;
    used += (size_t)n;
  }
  if (used == 0 || used > 512) return 2;
  token[used] = '\0';
  SecKeychainRef keychain = NULL;
  SecTrustedApplicationRef app = NULL, broker = NULL;
  SecAccessRef access = NULL;
  SecKeychainItemRef item = NULL;
  OSStatus status = SecKeychainOpen(path, &keychain);
  if (status == errSecSuccess)
    status = SecKeychainUnlock(keychain, (UInt32)strlen(password), password, true);
  if (status == errSecSuccess) status = SecTrustedApplicationCreateFromPath(app_path, &app);
  if (status == errSecSuccess) status = SecTrustedApplicationCreateFromPath(broker_path, &broker);
  CFArrayRef trusted = NULL;
  if (status == errSecSuccess) {
    const void *values[] = {app, broker};
    trusted = CFArrayCreate(NULL, values, 2, &kCFTypeArrayCallBacks);
    if (trusted == NULL) status = errSecAllocate;
  }
  if (status == errSecSuccess)
    status = SecAccessCreate(CFSTR("zigBrowser MS6 product test"), trusted, &access);
  const char *service = "dev.zigbrowser.MS63ProductTest";
  const char *account = ZB_MAC_AGENT_TOKEN_ACCOUNT;
  SecKeychainAttribute attributes[] = {
    {kSecServiceItemAttr, (UInt32)strlen(service), (void *)service},
    {kSecAccountItemAttr, (UInt32)strlen(account), (void *)account},
  };
  SecKeychainAttributeList attribute_list = {2, attributes};
  if (status == errSecSuccess)
    status = SecKeychainItemCreateFromContent(
        kSecGenericPasswordItemClass, &attribute_list, (UInt32)used, token,
        keychain, access, &item);
  memset_s(token, sizeof(token), 0, sizeof(token));
  if (item != NULL) CFRelease(item);
  if (access != NULL) CFRelease(access);
  if (trusted != NULL) CFRelease(trusted);
  if (broker != NULL) CFRelease(broker);
  if (app != NULL) CFRelease(app);
  if (keychain != NULL) CFRelease(keychain);
  return status == errSecSuccess ? 0 : 2;
}

static int clear_item(const char *path, const char *password) {
  char *error = NULL;
  int rc = zb_keychain_clear(path, password, "dev.zigbrowser.MS63ProductTest",
                             ZB_MAC_AGENT_TOKEN_ACCOUNT, &error);
  free(error);
  return rc == ZB_KC_OK ? 0 : 2;
}

static int create_keychain(const char *path, const char *password) {
  SecKeychainRef keychain = NULL;
  OSStatus status = SecKeychainCreate(path, (UInt32)strlen(password), password,
                                      false, NULL, &keychain);
  if (keychain != NULL) CFRelease(keychain);
  return status == errSecSuccess ? 0 : 2;
}

static int delete_keychain(const char *path, const char *password) {
  SecKeychainRef keychain = NULL;
  OSStatus status = SecKeychainOpen(path, &keychain);
  if (status == errSecSuccess)
    status = SecKeychainUnlock(keychain, (UInt32)strlen(password), password, true);
  if (status == errSecSuccess) status = SecKeychainDelete(keychain);
  if (keychain != NULL) CFRelease(keychain);
  return status == errSecSuccess ? 0 : 2;
}

int main(int argc, char **argv) {
  if (argc == 6 && strcmp(argv[1], "store") == 0)
    return store(argv[2], argv[3], argv[4], argv[5]);
  if (argc != 4) return 2;
  if (strcmp(argv[1], "create") == 0) return create_keychain(argv[2], argv[3]);
  if (strcmp(argv[1], "present") == 0) return present(argv[2], argv[3]);
  if (strcmp(argv[1], "clear") == 0) return clear_item(argv[2], argv[3]);
  if (strcmp(argv[1], "delete") == 0) return delete_keychain(argv[2], argv[3]);
  return 2;
}
'''


class Failure(Exception):
    pass


def owned_run(argv, *, cwd=None, env=None, stdin=None, timeout=180, capture=True):
    """Run one owned process group; only that group is signalled on timeout."""
    proc = subprocess.Popen(
        [str(v) for v in argv], cwd=cwd, env=env, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=subprocess.PIPE if capture else subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        out, err = proc.communicate(stdin, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            out, err = proc.communicate(timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            out, err = proc.communicate(timeout=8)
        raise Failure("owned command timed out")
    return proc.returncode, out or b"", err or b""


def require_ok(argv, label, **kwargs):
    rc, out, err = owned_run(argv, **kwargs)
    if rc != 0:
        tail = (err or out)[-500:].decode("utf-8", "replace").replace("\n", " ")
        raise Failure(f"{label} failed (rc={rc}; tail={tail})")
    return out


def make_app(source, root, python_pkg, site_x86, site_arm):
    prefix = root / "native-prefix"
    app = root / "zigBrowser.app"
    contents = app / "Contents"
    macos = contents / "MacOS"
    frameworks = contents / "Frameworks"
    resources = contents / "Resources"
    for directory in (macos, frameworks, resources):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    zig = Path(os.environ.get("ZB_ZIG", str(Path.home() / ".local/bin/zig")))
    if not zig.is_file():
        raise Failure(f"zig is missing at {zig}")
    build_env = dict(os.environ)
    build_env.update({
        "ZIG_LOCAL_CACHE_DIR": str(root / "zig-local-cache"),
        "ZIG_GLOBAL_CACHE_DIR": str(root / "zig-global-cache"),
    })
    require_ok(
        [zig, "build", "--prefix", prefix, "--cache-dir", root / "zig-local-cache",
         "--global-cache-dir", root / "zig-global-cache", "-Dmac-unsandboxed-dev=false"],
        "native app build", cwd=source, env=build_env, timeout=900,
    )
    shutil.copy2(prefix / "bin/zigBrowser", macos / "zigBrowser")
    shutil.copy2(prefix / "Frameworks/libwkwebview_shim.dylib", frameworks / "libwkwebview_shim.dylib")
    shutil.copy2(source / "packaging/macos/Info.plist", contents / "Info.plist")
    pins = json.loads((source / "packaging/macos/agent_runtime_pins.json").read_text())
    require_ok(
        ["/bin/bash", source / "packaging/macos/stage_agent_runtime.sh", python_pkg,
         pins["python_pkg"]["sha256"], contents, site_x86, site_arm],
        "bundled runtime staging", cwd=source, timeout=900,
    )
    return app


def provision(app, root):
    private_home = root / "private-home"
    sai = private_home / ".claude"
    ssh = private_home / ".ssh"
    temp = root / "tmp"
    xdg = private_home / "data"
    for directory in (private_home, sai, ssh, temp, xdg):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    (sai / "CLAUDE.md").write_text("MS6 product e2e private instructions.\n")
    (sai / "settings.json").write_text("{}\n")
    ssh_canary = ssh / "id_test"
    ssh_canary.write_text("private setup ssh canary\n")
    agent_home = xdg / "zigbrowser/agent-home"
    host = app / "Contents/Frameworks/agent-host"
    python = host / "Python.framework/Versions/3.12/bin/python3.12"
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(private_home),
        "XDG_DATA_HOME": str(xdg),
        "TMPDIR": str(temp),
        "LANG": "C.UTF-8",
        "PYTHONPATH": str(host),
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    require_ok(
        [app / "Contents/MacOS/zigBrowser", "--agent-setup", "--e2e-protocol", "--sai-source", sai],
        "built app private agent-home provisioning", env=env, timeout=240,
    )
    if not (agent_home / "current").exists():
        raise Failure("built app private agent-home provisioning did not publish current")
    sys.path.insert(0, str(host / "site-packages"))
    sys.path.insert(0, str(host))
    from zb_agent_host import sandbox_macos

    setup_scratch = root / "setup-denial-scratch"
    setup_scratch.mkdir(mode=0o700)
    probe_started = datetime.datetime.now().astimezone()
    with sandbox_macos.setup_sandbox(str(setup_scratch), [str(python), str(host)],
                                     ["/bin/cat", str(ssh_canary.resolve())]) as argv:
        rc, out, _err = owned_run(argv, env={"PATH": "/usr/bin:/bin", "HOME": str(setup_scratch),
                                             "TMPDIR": str(setup_scratch), "LANG": "C.UTF-8"}, timeout=20)
    if rc == 0 or out:
        raise Failure("setup Seatbelt profile allowed ~/.ssh/id_test read")
    require_log_denial(probe_started, "setup ~/.ssh/id_test", ssh_canary.resolve())
    return private_home, xdg, temp, agent_home, host, python


def compile_broker(source, root):
    broker_src = root / "keychain-broker.m"
    broker = root / "keychain-broker"
    broker_src.write_text(BROKER_SOURCE)
    require_ok(
        ["/usr/bin/xcrun", "clang", "-fobjc-arc", "-Wno-deprecated-declarations",
         "-I", source / "src", broker_src,
         source / "src/agent_secrets_mac.m", "-framework", "Foundation", "-framework", "Security",
         "-o", broker],
        "Keychain stdin broker build", timeout=120,
    )
    return broker


def keychain_create(broker, path, password):
    rc, _, _ = owned_run([broker, "create", path, password], timeout=30)
    if rc != 0:
        raise Failure("disposable test Keychain could not be created")


def keychain_put(broker, path, password, app_binary, token):
    rc, _, _ = owned_run([broker, "present", path, password], timeout=30)
    if rc == 0:
        raise Failure("disposable test Keychain item already exists; refusing to overwrite it")
    if rc != 10:
        raise Failure("disposable test Keychain is unavailable")
    rc, _, _ = owned_run([broker, "store", path, password, app_binary, broker],
                         stdin=token, timeout=30)
    if rc != 0:
        raise Failure("format-valid test token could not be stored in the disposable Keychain")


def keychain_clear(broker, path, password):
    rc, _, _ = owned_run([broker, "clear", path, password], timeout=30)
    return rc == 0


def keychain_delete(broker, path, password):
    rc, _, _ = owned_run([broker, "delete", path, password], timeout=30)
    return rc == 0


def stream_lines(stream, found):
    try:
        for raw in iter(stream.readline, b""):
            found.put(raw.rstrip(b"\r\n"))
    finally:
        stream.close()


def descendant_snapshot(proc_darwin, root_pid, token):
    queue_pids = [root_pid]
    seen = {root_pid}
    parents = {}
    paths = {}
    token_found = False
    unreadable = []
    while queue_pids:
        parent = queue_pids.pop(0)
        try:
            children = proc_darwin.children(parent)
        except ProcessLookupError:
            continue
        except OSError:
            unreadable.append(parent)
            continue
        for pid in children:
            if pid in seen:
                continue
            seen.add(pid)
            parents[pid] = parent
            queue_pids.append(pid)
            try:
                path = proc_darwin.path(pid)
                if path is not None:
                    paths[pid] = os.path.realpath(path)
                raw, _argv, _env = proc_darwin.environ_of(pid)
                if token in raw:
                    token_found = True
            except OSError:
                try:
                    live = proc_darwin.path(pid) is not None
                except OSError:
                    live = True
                if live:
                    unreadable.append(pid)
    return parents, paths, token_found, unreadable


def launch_drawer(app, private_home, xdg, temp, agent_home, host, python, token,
                  keychain_path, keychain_password, denied_paths):
    browser = app / "Contents/MacOS/zigBrowser"
    cli = os.path.realpath(host / "site-packages/claude_agent_sdk/_bundled/claude")
    profile = temp.parent / "browser-profile"
    profile.mkdir(mode=0o700)
    env = dict(os.environ)
    env.update({
        "HOME": str(private_home), "XDG_DATA_HOME": str(xdg), "TMPDIR": str(temp),
        "ZB_DEBUG_DRAWER_AGENT_SEND": "Reply with one word.",
        "ZB_DEBUG_MAC_AGENT_KEYCHAIN": str(keychain_path),
        "ZB_DEBUG_MAC_AGENT_KEYCHAIN_PASSWORD": keychain_password,
    })
    proc = subprocess.Popen(
        [str(browser), "about:blank", "--agent-drawer", "on", "--e2e-protocol",
         "--profile-dir", str(profile)],
        env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True,
    )
    assert proc.stdout is not None and proc.stderr is not None
    lines = queue.Queue()
    threads = [threading.Thread(target=stream_lines, args=(stream, lines), daemon=True)
               for stream in (proc.stdout, proc.stderr)]
    for thread in threads:
        thread.start()
    sys.path.insert(0, str(host))
    from zb_agent_host import parent_watch, proc_darwin

    sandbox_ops = parent_watch.DarwinSessionOps()
    if not sandbox_ops.sandbox_check_available():
        stop_browser(proc)
        raise Failure("sandbox_check is unavailable for the live CLI proof")

    ready = connect = cli_seen = sandbox_seen = False
    census_fault = None
    deadline = time.monotonic() + 120
    token_bytes = token
    try:
        while time.monotonic() < deadline and proc.poll() is None:
            while True:
                try:
                    line = lines.get_nowait()
                except queue.Empty:
                    break
                if token_bytes in line:
                    raise Failure("test token appeared in app output")
                text = line.decode("utf-8", "replace")
                ready = ready or text == READY
                connect = connect or text == CONNECT
            _parents, paths, leaked, unreadable = descendant_snapshot(proc_darwin, proc.pid, token_bytes)
            if leaked:
                raise Failure("test token appeared in a child argv or environment")
            if unreadable:
                census_fault = "child argv/environment census was unreadable"
            for pid, path in paths.items():
                if path == cli:
                    cli_seen = True
                    # sandbox-exec applies the profile and may exec-replace
                    # itself, so process ancestry is not evidence.  Query the
                    # live Claude PID instead: a named permitted executable
                    # read plus all three sensitive-path denials proves the
                    # restrictive Seatbelt profile is attached.
                    sandbox_seen = sandbox_seen or (
                        sandbox_ops.sandbox_allows_canary(pid, cli)
                        and all(not sandbox_ops.sandbox_allows_canary(pid, path)
                                for path in denied_paths)
                    )
            if ready and connect and cli_seen and sandbox_seen and census_fault is None:
                return proc, cli
            time.sleep(0.03)
        if proc.poll() is not None:
            raise Failure(f"drawer app exited before the agent proof (rc={proc.returncode})")
        if census_fault is not None:
            raise Failure(census_fault)
        missing = []
        if not ready:
            missing.append("fd-3 ready")
        if not cli_seen:
            missing.append("bundled CLI")
        if not sandbox_seen:
            missing.append("live CLI Seatbelt policy")
        if not connect:
            missing.append("CONNECT api.anthropic.com:443")
        raise Failure("drawer launch did not reach " + ", ".join(missing))
    except BaseException:
        stop_browser(proc)
        raise


def stop_browser(proc):
    if proc.poll() is not None:
        return True
    os.killpg(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=12)
        return True
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=8)
        return False


def login_keychain_path():
    out = require_ok(["/usr/bin/security", "default-keychain", "-d", "user"],
                     "resolve login Keychain", timeout=30)
    text = out.decode("utf-8", "strict").strip()
    if len(text) >= 2 and text[0] == text[-1] == '"':
        text = text[1:-1]
    path = Path(text).resolve()
    if not path.is_file():
        raise Failure("login Keychain file is missing")
    return path


def denial_proofs(agent_home, host, python, private_home, targets):
    sys.path.insert(0, str(host))
    from zb_agent_host import sandbox_macos

    class ProbeHome:
        root = agent_home
        claude_dir = agent_home / ".claude"
        workspace = agent_home / "workspace"
        scratchpad = agent_home / "scratchpad"
        runtime = agent_home / "runtime"
        state = agent_home / "state"

    old_tempdir = tempfile.tempdir
    tempfile.tempdir = str(agent_home / "scratchpad/tmp")
    probe_started = datetime.datetime.now().astimezone()
    try:
        path_dirs = json.loads((agent_home / "runtime/path.json").read_text())
        reads = (str(Path(python).parent.parent), str(host),
                 *(path for path in path_dirs if path != "/usr" and not path.startswith("/usr/")))
        home = ProbeHome()
        with sandbox_macos.MacSeatbeltBackend(1).launch(home, ro_paths=reads) as spec:
            probe_env = {
                "PATH": "/usr/bin:/bin", "HOME": str(private_home),
                "TMPDIR": str(agent_home / "scratchpad/tmp"), "LANG": "C.UTF-8",
            }
            for label, path in targets:
                rc, out, _err = owned_run([*spec.argv, "/bin/cat", path], env=probe_env, timeout=20)
                if rc == 0 or out:
                    raise Failure(f"Seatbelt allowed {label} read")
    finally:
        tempfile.tempdir = old_tempdir

    for label, path in targets:
        require_log_denial(probe_started, label, path)


def require_log_denial(probe_started, label, path):
    escaped = str(path).replace("\\", "\\\\").replace('"', '\\"')
    predicate = f'eventMessage CONTAINS "{escaped}" AND eventMessage CONTAINS[c] "deny"'
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        rc, out, _ = owned_run(
            ["/usr/bin/log", "show", "--start", probe_started.strftime("%Y-%m-%d %H:%M:%S%z"),
             "--style", "compact", "--predicate", predicate], timeout=30,
        )
        if rc == 0 and str(path).encode() in out and b"deny" in out.lower():
            return
        time.sleep(1)
    raise Failure(f"log show did not contain the {label} sandbox denial")


def assert_no_token_file(root, token):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not Path(base, d).is_symlink()]
        for name in files:
            path = Path(base, name)
            try:
                mode = path.lstat().st_mode
                if not stat.S_ISREG(mode):
                    continue
                with path.open("rb") as stream:
                    while True:
                        chunk = stream.read(1024 * 1024)
                        if not chunk:
                            break
                        if token in chunk:
                            raise Failure("test token appeared in an ordinary file")
            except OSError as exc:
                raise Failure(f"could not inspect private file {path.name}: {exc.strerror}") from None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--python-pkg", required=True, type=Path)
    parser.add_argument("--site-x86", required=True, type=Path)
    parser.add_argument("--site-arm", required=True, type=Path)
    parser.add_argument("--setup-only", action="store_true")
    args = parser.parse_args()
    arch = subprocess.check_output(["/usr/bin/uname", "-m"], text=True).strip()
    label = "ms6-product-e2e"
    if not COMMIT_RE.fullmatch(args.commit):
        print(f"FAIL\t{label}\t{arch}\tinvalid source commit")
        return 1
    source = args.source.resolve()
    cleanup_ok = True
    try:
        for path, what in ((source, "source"), (args.python_pkg.resolve(), "Python package"),
                           (args.site_x86.resolve(), "x86 site tree"),
                           (args.site_arm.resolve(), "arm site tree")):
            if not path.exists():
                raise Failure(f"{what} is missing")
        with tempfile.TemporaryDirectory(prefix="zb-ms6-product-e2e-", dir=str(source.parent)) as raw:
            root = Path(raw).resolve()
            app = make_app(source, root, args.python_pkg.resolve(), args.site_x86.resolve(), args.site_arm.resolve())
            private_home, xdg, temp, agent_home, host, python = provision(app, root)
            if args.setup_only:
                print(f"PASS\tms6-sandboxed-setup\t{arch}\t{args.commit}\t"
                      "built app provisioned agent-home; denied ~/.ssh/id_test")
                return 0
            ssh_canary = private_home / ".ssh/id_canary"
            outside = private_home / "outside-agent-home"
            ssh_canary.parent.mkdir(mode=0o700, exist_ok=True)
            ssh_canary.write_text("private ssh canary\n")
            outside.write_text("outside agent home\n")
            login_keychain = login_keychain_path()
            broker = compile_broker(source, root)
            test_keychain = root / "agent-test.keychain"
            keychain_password = secrets.token_urlsafe(24)
            keychain_create(broker, test_keychain, keychain_password)
            keychain_owned = True
            token = ("sk-ant-oat01-" + secrets.token_urlsafe(48)).encode("ascii")
            token_owned = False
            browser = None
            try:
                keychain_put(broker, test_keychain, keychain_password,
                             app / "Contents/MacOS/zigBrowser", token)
                token_owned = True
                browser, _cli = launch_drawer(app, private_home, xdg, temp, agent_home, host, python, token,
                                               test_keychain, keychain_password,
                                               (ssh_canary.resolve(), login_keychain, outside.resolve()))
                denial_proofs(agent_home, host, python, private_home, (
                    ("~/.ssh", ssh_canary.resolve()),
                    ("login Keychain", login_keychain),
                    ("outside-home", outside.resolve()),
                ))
                assert_no_token_file(root, token)
            finally:
                if browser is not None and not stop_browser(browser):
                    cleanup_ok = False
                if token_owned:
                    if not keychain_clear(broker, test_keychain, keychain_password):
                        cleanup_ok = False
                    token_owned = False
                if keychain_owned:
                    if not keychain_delete(broker, test_keychain, keychain_password):
                        cleanup_ok = False
                    keychain_owned = False
                if not cleanup_ok:
                    raise Failure("owned browser or Keychain cleanup failed")
        print(f"PASS\t{label}\t{arch}\t{args.commit}\tsandboxed setup provisioned; denied ~/.ssh/id_test; "
              "fd3-only; sandbox-exec bundled CLI; CONNECT api.anthropic.com:443; denied ssh,keychain,outside-home")
        return 0
    except Failure as exc:
        print(f"FAIL\t{label}\t{arch}\t{exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
