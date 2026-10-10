// Node SDK against the REAL zigBrowser binary (not the mock server).
// Runs only when ZB_BINARY points at a built zigBrowser and a display is
// available (DISPLAY set, e.g. under xvfb-run):
//   ZB_BINARY=zig-out/bin/zigBrowser xvfb-run -a npx vitest run tests/live.test.ts
import { describe, it, expect } from "vitest";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import type { AddressInfo } from "node:net";
import { AutomationError, ZigBrowser } from "../src/index";

const binary = process.env.ZB_BINARY;
const live = binary && process.env.DISPLAY ? describe : describe.skip;

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
    const proc: ChildProcess = spawn(binary!, ["about:blank", "--automation-api"], {
      env: { ...process.env, ZIGBROWSER_SOCKET: socketPath, XDG_DATA_HOME: dir, XDG_CACHE_HOME: dir },
      stdio: "ignore",
    });
    try {
      await waitFor(() => fs.existsSync(socketPath), 20000);
      const zb = new ZigBrowser({ socketPath });
      await zb.connect();

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
      proc.kill("SIGINT");
      await new Promise((r) => proc.once("exit", r));
      server.close();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }, 60000);
});
