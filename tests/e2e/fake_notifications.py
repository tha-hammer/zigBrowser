#!/usr/bin/env python3
"""A private session bus with a fake desktop notification server, for the drawer e2e tests
(chat-drawer plan S8 decision 16: the desktop notification).

- `PrivateBus` runs its own dbus-daemon from a config with no service directories, so
  nothing on it is ever activated (no real notification daemon, no keyring); the browser
  gets its address as DBUS_SESSION_BUS_ADDRESS and never reaches the user's own bus.
- `FakeNotifications` owns org.freedesktop.Notifications on that bus through GIO (ctypes, so
  the test needs no Python D-Bus module). It records each call exactly as received (the
  method, its arguments as GVariant text, and Notify's fields), answers Notify with ids 1, 2,
  ..., and can emit ActionInvoked as the server, or forged from another connection on the
  same bus (not the name's owner).
- With `own=False` the bus has no notification server: a Notify fails, as on a desktop
  without one."""

from __future__ import annotations

import ctypes
import subprocess
import threading
import time
from pathlib import Path

BUS_CONF = """<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path={path}</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
"""

NAME = "org.freedesktop.Notifications"
PATH = "/org/freedesktop/Notifications"
XML = f"""<node><interface name="{NAME}">
  <method name="Notify">
    <arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/>
    <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/>
    <arg type="a{{sv}}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/>
  </method>
  <method name="CloseNotification"><arg type="u" direction="in"/></method>
  <method name="GetCapabilities"><arg type="as" direction="out"/></method>
  <method name="GetServerInformation">
    <arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/>
  </method>
  <signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
  <signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
</interface></node>"""

FLAGS = 1 | 8  # G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | MESSAGE_BUS_CONNECTION


class _GError(ctypes.Structure):
    _fields_ = [("domain", ctypes.c_uint32), ("code", ctypes.c_int), ("message", ctypes.c_char_p)]


_MethodCall = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
                               ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)


class _VTable(ctypes.Structure):
    _fields_ = [("method_call", _MethodCall), ("get_property", ctypes.c_void_p), ("set_property", ctypes.c_void_p),
                ("padding", ctypes.c_void_p * 8)]


def _libs():
    glib = ctypes.CDLL("libglib-2.0.so.0")
    gio = ctypes.CDLL("libgio-2.0.so.0")
    vp, cp = ctypes.c_void_p, ctypes.c_char_p
    pp = ctypes.POINTER(ctypes.POINTER(_GError))
    for name, res, args in (
            ("g_main_context_new", vp, []), ("g_main_context_push_thread_default", None, [vp]),
            ("g_main_context_pop_thread_default", None, [vp]), ("g_main_context_unref", None, [vp]),
            ("g_main_loop_new", vp, [vp, ctypes.c_int]), ("g_main_loop_run", None, [vp]),
            ("g_main_loop_quit", None, [vp]), ("g_main_loop_unref", None, [vp]),
            ("g_main_context_iteration", ctypes.c_int, [vp, ctypes.c_int]),
            ("g_variant_parse", vp, [vp, cp, vp, vp, pp]), ("g_variant_print", vp, [vp, ctypes.c_int]),
            ("g_variant_get_child_value", vp, [vp, ctypes.c_size_t]), ("g_variant_get_string", cp, [vp, vp]),
            ("g_variant_get_uint32", ctypes.c_uint32, [vp]), ("g_variant_get_int32", ctypes.c_int32, [vp]),
            ("g_variant_n_children", ctypes.c_size_t, [vp]), ("g_variant_unref", None, [vp]),
            ("g_free", None, [vp]), ("g_error_free", None, [vp])):
        fn = getattr(glib, name)
        fn.restype, fn.argtypes = res, args
    for name, res, args in (
            ("g_dbus_connection_new_for_address_sync", vp, [cp, ctypes.c_int, vp, vp, pp]),
            ("g_dbus_connection_call_sync", vp, [vp, cp, cp, cp, cp, vp, vp, ctypes.c_int, ctypes.c_int, vp, pp]),
            ("g_dbus_connection_register_object", ctypes.c_uint, [vp, cp, vp, vp, vp, vp, pp]),
            ("g_dbus_connection_emit_signal", ctypes.c_int, [vp, cp, cp, cp, cp, vp, pp]),
            ("g_dbus_connection_flush_sync", ctypes.c_int, [vp, vp, pp]),
            ("g_dbus_connection_close_sync", ctypes.c_int, [vp, vp, pp]),
            ("g_dbus_connection_get_unique_name", cp, [vp]),
            ("g_dbus_node_info_new_for_xml", vp, [cp, pp]),
            ("g_dbus_node_info_lookup_interface", vp, [vp, cp]),
            ("g_dbus_method_invocation_return_value", None, [vp, vp]),
            ("g_object_unref", None, [vp])):
        fn = getattr(gio, name)
        fn.restype, fn.argtypes = res, args
    return glib, gio


class PrivateBus:
    """A dbus-daemon of the test's own, nothing activatable on it."""

    def __init__(self, tmp: Path) -> None:
        tmp.mkdir(parents=True, exist_ok=True)
        socket = tmp / "bus"
        conf = tmp / "bus.conf"
        conf.write_text(BUS_CONF.format(path=socket))
        self.proc = subprocess.Popen(["/usr/bin/dbus-daemon", "--config-file", str(conf), "--nofork", "--print-address=1"],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.address = (self.proc.stdout.readline() or "").strip()
        if not self.address:
            self.close()
            raise RuntimeError("the private dbus-daemon gave no address")

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(5)
        if self.proc.stdout is not None:
            self.proc.stdout.close()


class FakeNotifications:
    """org.freedesktop.Notifications on `bus`, recording every call (see the module doc)."""

    def __init__(self, bus: PrivateBus) -> None:
        self.glib, self.gio = _libs()
        self.address = bus.address
        self.calls: list[dict] = []
        self.lock = threading.Lock()
        self.next_id = 1
        self._ready = threading.Event()
        self._error: str | None = None
        self._conn = self._loop = self._ctx = None
        self._method_call = _MethodCall(self._on_call)  # kept: GIO holds the pointer
        self._vtable = _VTable(method_call=self._method_call)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        if not self._ready.wait(10) or self._error:
            raise RuntimeError(f"the fake notification server did not start: {self._error}")

    # --- the server's thread ------------------------------------------------------------
    def _check(self, err, what: str) -> None:
        if err:
            message = err.contents.message.decode(errors="replace") if err.contents.message else "?"
            self.glib.g_error_free(err)
            raise RuntimeError(f"{what}: {message}")

    def _parse(self, text: str):
        err = ctypes.POINTER(_GError)()
        v = self.glib.g_variant_parse(None, text.encode(), None, None, ctypes.byref(err))
        self._check(err, f"g_variant_parse {text!r}")
        return v

    def _print(self, v) -> str:
        raw = self.glib.g_variant_print(v, 1)
        try:
            return ctypes.string_at(raw).decode(errors="replace")
        finally:
            self.glib.g_free(raw)

    def _child_str(self, params, i: int) -> str:
        child = self.glib.g_variant_get_child_value(params, i)
        try:
            return (self.glib.g_variant_get_string(child, None) or b"").decode(errors="replace")
        finally:
            self.glib.g_variant_unref(child)

    def _serve(self) -> None:
        g, gio = self.glib, self.gio
        try:
            self._ctx = g.g_main_context_new()
            g.g_main_context_push_thread_default(self._ctx)
            err = ctypes.POINTER(_GError)()
            self._conn = gio.g_dbus_connection_new_for_address_sync(self.address.encode(), FLAGS, None, None, ctypes.byref(err))
            self._check(err, "connect")
            reply = gio.g_dbus_connection_call_sync(self._conn, b"org.freedesktop.DBus", b"/org/freedesktop/DBus",
                                                    b"org.freedesktop.DBus", b"RequestName",
                                                    self._parse(f"('{NAME}', uint32 4)"), None, 0, 5000, None,
                                                    ctypes.byref(err))
            self._check(err, "RequestName")
            got = self._print(reply)
            g.g_variant_unref(reply)
            if got != "(uint32 1,)":
                raise RuntimeError(f"RequestName answered {got}")
            node = gio.g_dbus_node_info_new_for_xml(XML.encode(), ctypes.byref(err))
            self._check(err, "node info")
            iface = gio.g_dbus_node_info_lookup_interface(node, NAME.encode())
            gio.g_dbus_connection_register_object(self._conn, PATH.encode(), iface, ctypes.byref(self._vtable),
                                                  None, None, ctypes.byref(err))
            self._check(err, "register")
            self._loop = g.g_main_loop_new(self._ctx, 0)
        except Exception as exc:  # noqa: BLE001 - reported to the constructor
            self._error = str(exc)
            self._ready.set()
            return
        self._ready.set()
        g.g_main_loop_run(self._loop)
        g.g_main_context_pop_thread_default(self._ctx)

    def _on_call(self, _conn, sender, _path, _iface, method, params, invocation, _data) -> None:
        name = (method or b"").decode()
        record = {"method": name, "sender": (sender or b"").decode(), "args": self._print(params)}
        if name == "Notify":
            actions_v = self.glib.g_variant_get_child_value(params, 5)
            actions = []
            for i in range(self.glib.g_variant_n_children(actions_v)):
                actions.append(self._child_str(actions_v, i))
            self.glib.g_variant_unref(actions_v)
            hints_v = self.glib.g_variant_get_child_value(params, 6)
            hints = self._print(hints_v)
            self.glib.g_variant_unref(hints_v)
            with self.lock:
                nid = self.next_id
                self.next_id += 1
            record.update(app_name=self._child_str(params, 0), app_icon=self._child_str(params, 2),
                          summary=self._child_str(params, 3), body=self._child_str(params, 4), actions=actions,
                          hints=hints, id=nid)
            out = self._parse(f"(uint32 {nid},)")
        elif name == "GetCapabilities":
            out = self._parse("(['actions', 'body'],)")
        elif name == "GetServerInformation":
            out = self._parse("('zb-fake', 'zigBrowser tests', '1', '1.2')")
        else:
            out = self._parse("()")
        with self.lock:
            self.calls.append(record)
        self.gio.g_dbus_method_invocation_return_value(invocation, out)

    # --- the test's side --------------------------------------------------------------------
    def notifies(self) -> list[dict]:
        with self.lock:
            return [dict(c) for c in self.calls if c["method"] == "Notify"]

    def invoke(self, nid: int, action: str = "default", forged: bool = False) -> None:
        """ActionInvoked(nid, action), as the server; `forged`: from another connection."""
        err = ctypes.POINTER(_GError)()
        conn = self._conn
        if forged:
            conn = self.gio.g_dbus_connection_new_for_address_sync(self.address.encode(), FLAGS, None, None,
                                                                    ctypes.byref(err))
            self._check(err, "forger connect")
        try:
            body = self._parse(f"(uint32 {int(nid)}, {repr(action)})")
            self.gio.g_dbus_connection_emit_signal(conn, None, PATH.encode(), NAME.encode(), b"ActionInvoked", body,
                                                   ctypes.byref(err))
            self._check(err, "emit")
            self.gio.g_dbus_connection_flush_sync(conn, None, ctypes.byref(err))
            self._check(err, "flush")
        finally:
            if forged:
                self.gio.g_dbus_connection_close_sync(conn, None, None)
                self.gio.g_object_unref(conn)

    def close(self) -> None:
        """Stops the server; raises if its thread outlives the stop (RoseCat 7661: an observable
        teardown, never a silent leftover)."""
        if self._loop is not None:
            self.glib.g_main_loop_quit(self._loop)
        self._thread.join(5)
        if self._conn is not None:
            self.gio.g_dbus_connection_close_sync(self._conn, None, None)
        if self._thread.is_alive():
            raise RuntimeError("the fake notification server's thread is still running 5 s after its stop")


def _selftest() -> int:
    """`python3 fake_notifications.py`: a Notify through gdbus is recorded and answered 1."""
    import tempfile
    with tempfile.TemporaryDirectory(prefix="zb-notify-") as tmp:
        bus = PrivateBus(Path(tmp))
        try:
            fake = FakeNotifications(bus)
            try:
                out = subprocess.run(["/usr/bin/gdbus", "call", "--address", bus.address, "--dest", NAME, "--object-path",
                                      PATH, "--method", f"{NAME}.Notify", "--", "zigBrowser", "0", "", "zigBrowser",
                                      "Claude is waiting for your approval.", "['default', 'Open']", "{}", "-1"],
                                     capture_output=True, text=True, timeout=10)
                monitor = subprocess.Popen(["/usr/bin/gdbus", "monitor", "--address", bus.address, "--dest", NAME],
                                           stdout=subprocess.PIPE, text=True)
                try:
                    time.sleep(0.5)
                    fake.invoke(1, "default")
                    time.sleep(0.5)
                finally:
                    monitor.terminate()
                    seen = monitor.communicate(timeout=5)[0]
                got = fake.notifies()
                ok = (out.stdout.strip() == "(uint32 1,)" and len(got) == 1 and got[0]["actions"] == ["default", "Open"]
                      and got[0]["body"] == "Claude is waiting for your approval." and "ActionInvoked (uint32 1, 'default')" in seen)
                print("ok" if ok else f"FAIL {out.stdout!r} {out.stderr!r} {got} {seen!r}")
                return 0 if ok else 1
            finally:
                fake.close()
        finally:
            bus.close()


if __name__ == "__main__":
    raise SystemExit(_selftest())
