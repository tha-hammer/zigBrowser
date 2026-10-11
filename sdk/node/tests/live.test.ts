// Node SDK against the REAL zigBrowser binary (not the mock server).
// Runs only when ZB_BINARY points at a built zigBrowser, and python3, Xvfb
// and xauth are installed:
//   ZB_BINARY=zig-out/bin/zigBrowser npx vitest run tests/live.test.ts
// The browser is started through the E2E launcher (tests/e2e/xsession.py)
// on its own private Xvfb display, never the caller's DISPLAY. The launcher
// makes the browser lead its own process group and leaves a guardian that
// owns the Xvfb: if this test process dies (a killed vitest run), the
// guardian ends the browser's whole group and removes the display; teardown
// here signals that group too. tests/e2e/node_live_group_test.py checks it.
import { describe, it, expect } from "vitest";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { AddressInfo } from "node:net";
import { AutomationError, ZigBrowser } from "../src/index";

const binary = process.env.ZB_BINARY ? path.resolve(process.env.ZB_BINARY) : undefined;
const xsession = fileURLToPath(new URL("../../../tests/e2e/xsession.py", import.meta.url));
const hasTools = spawnSync("sh", ["-c", "command -v python3 && command -v Xvfb && command -v xauth"], { stdio: "ignore" }).status === 0;
const live = binary && hasTools && fs.existsSync(xsession) ? describe : describe.skip;

const PAGE = `<!doctype html><html><head><meta charset="utf-8"><title>Node SDK Live</title></head>
<body>
  <input id="q" autocomplete="off"><p id="mirror"></p>
  <button id="go" onclick="document.getElementById('status').textContent = 'clicked:' + document.getElementById('q').value">Go</button>
  <p id="status">idle</p>
  <script>document.getElementById('q').addEventListener('input', e => { document.getElementById('mirror').textContent = e.target.value; });</script>
</body></html>`;

async function waitFor(check: () => boolean, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!check()) {
    if (Date.now() > deadline) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 50));
  }
}

/** The browser under the launcher: `proc.pid` is the browser itself (the
 *  launcher execs into it) and leads its own process group. */
function startBrowser(args: string[], env: NodeJS.ProcessEnv): ChildProcess {
  const { DISPLAY: _display, WAYLAND_DISPLAY: _wayland, ...rest } = env;
  return spawn("python3", [xsession, "--xvfb", "--", binary!, ...args], { env: rest, stdio: "ignore" });
}

/** Like slice2_common.stop_browser: SIGINT (a clean shutdown); a browser
 *  still running after 8 s gets SIGKILL with its whole process group
 *  (browser and WebKit helpers). The guardian then removes the display.
 *  Never waits on an already-exited child. */
async function stopBrowser(proc: ChildProcess): Promise<void> {
  const exited = () => proc.exitCode !== null || proc.signalCode !== null;
  if (exited()) return;
  const done = new Promise<void>((r) => proc.once("exit", () => r()));
  proc.kill("SIGINT");
  const timedOut = await Promise.race([done.then(() => false), new Promise<boolean>((r) => setTimeout(() => r(true), 8000))]);
  if (timedOut && !exited()) {
    try {
      process.kill(-proc.pid!, "SIGKILL");
    } catch {
      // the group is already gone
    }
    await Promise.race([done, new Promise<void>((r) => setTimeout(r, 5000))]);
  }
}

live("Node SDK against the real binary", () => {
  it("navigate -> type -> click -> getText, and typed errors with a trace", async () => {
    const server = http.createServer((req, res) => {
      res.writeHead(req.url === "/live" ? 200 : 404, { "Content-Type": "text/html; charset=utf-8" });
      res.end(req.url === "/live" ? PAGE : "not found");
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
    const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "zb-sdk-node-"));
    const socketPath = path.join(dir, "automation.sock");
    const proc = startBrowser(["about:blank", "--automation-api"], {
      ...process.env,
      ZIGBROWSER_SOCKET: socketPath,
      XDG_DATA_HOME: dir,
      XDG_CACHE_HOME: dir,
    });
    try {
      await waitFor(() => fs.existsSync(socketPath), 20000);
      const zb = new ZigBrowser({ socketPath });
      await zb.connect();
      // tests/e2e/node_live_group_test.py kills this run while the browser
      // is up: ZB_LIVE_HOLD_MS keeps it up that long (tests only).
      const holdMs = Number(process.env.ZB_LIVE_HOLD_MS ?? 0);
      if (holdMs > 0) await new Promise((r) => setTimeout(r, Math.min(holdMs, 30000)));

      expect(await zb.page.navigate(`${base}/live`, { timeoutMs: 15000 })).toEqual({ ok: true });
      expect((await zb.page.title()).title).toBe("Node SDK Live");
      expect(await zb.dom.type("css=#q", "zig node")).toEqual({ ok: true });
      expect((await zb.dom.getText("css=#mirror")).text).toBe("zig node");
      expect(await zb.dom.click("css=#go")).toEqual({ ok: true });
      expect((await zb.dom.getText("css=#status")).text).toBe("clicked:zig node");

      const err = await zb.dom.click("css=#missing", { timeoutMs: 200 }).catch((e: unknown) => e);
      expect(err).toBeInstanceOf(AutomationError);
      expect((err as AutomationError).code).toBe(-32001);
      const traceId = (err as AutomationError).traceId!;
      expect(traceId).toBeTruthy();
      const trace = (await zb.call("telemetry.query", { trace_id: traceId })) as { spans: { name: string }[] };
      expect(trace.spans[0].name).toBe("automation.command");

      await zb.disconnect();
    } finally {
      await stopBrowser(proc);
      server.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }, 60000);
});
