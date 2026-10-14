"""Closure adapter (STAGED PROPOSAL — not wired into the repo).

Derived from the ClosureMap for:
  "An automation command sent over the Unix socket drives the live page and its
   result is observable to the client."

Pin: bcc721d527feefb9bce227e40f970173405847ea
Repo: /home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59

This file is a sibling of the research document
  thoughts/searchable/shared/research/2026-10-14-14-19-macos-launch-support-surface.md
It is NOT imported, registered, or built by the repo. A human (or create_tdd_plan at
build time) promotes it into the repo and completes each TODO(promote) with the real
production call. It speaks the 7-op contract apps/closure-oracle already talks to
(see apps/closure-oracle mock_adapter.py): /seed /trigger /drive /observe plus the
control ops /reset /set_connector /seed_sink.

Platform note: on Linux the TODO(promote) symbols below all resolve (the GTK adapter +
webkit_shim). On macOS the platform_adapter / native_shim_effect nodes are unmounted
(wkwebview_shim.m implements none of zb_automation_*); promoting this adapter on macOS
first requires the WKWebView PagePort adapter (highest_new_connector) to exist.
"""
import http.server
import json
import sys

ASYNC_EDGES = ["e5_adapter_to_shim"]   # edge 5: Zig->C-ABI->GTK-main-loop marshal (blocks caller)
CONNECTOR = {e: True for e in ASYNC_EDGES}
SINK = []                               # Phase-0 /seed_sink positive control


def handle(op, p):
    if op == "/reset":
        SINK.clear()
        CONNECTOR.update({e: True for e in ASYNC_EDGES})
        return {"ok": True}
    if op == "/set_connector":
        CONNECTOR[p["edge"]] = p["enabled"]
        return {"ok": True}
    if op == "/seed_sink":
        SINK.append(p["value"])
        return {"ok": True}
    if op == "/seed":
        # TODO(promote): load fixture into window 1 via
        #   zb_automation_navigate_guarded(p["data"])   (src/webkit_shim.c:3076)
        return {"ok": True}
    if op == "/trigger":
        # TODO(promote): send the JSON-RPC command over the automation socket ->
        #   automation_server.handleRequestWith(p["args"])   (src/automation_server.zig:412)
        return {"ok": True}
    if op == "/drive":
        if not CONNECTOR.get(p["edge"], True):
            return {"ok": True}  # oracle disabled this edge = red-at-seam
        # TODO(promote): drive the GTK main loop so the marshalled job runs —
        #   zb_automation_loop_mark / gtk_main   (src/webkit_shim.c:5211)
        return {"ok": True}
    if op == "/observe":
        # TODO(promote): return json.dumps(zb_automation_eval_json(<probe>))
        #   (src/webkit_shim.c:3060)   — or zb_automation_get_url (src/webkit_shim.c:3102)
        return {"ok": True, "value": json.dumps(SINK)}
    return {"ok": False, "error": "unknown op"}


class Hn(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        out = json.dumps(handle(self.path, json.loads(self.rfile.read(n) or "{}"))).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Hn).serve_forever()
