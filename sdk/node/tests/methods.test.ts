import { describe, it, expect, afterEach } from "vitest";
import { createMockServer, MockUDSServer } from "./helpers";
import { ZigBrowser } from "../src/index";

type Case = [string, (zb: ZigBrowser) => Promise<unknown>, string, Record<string, unknown>];

// Every method the server's router accepts, with its exact wire params.
const CASES: Case[] = [
  ["dom.query", (zb) => zb.dom.query("css=li", { timeoutMs: 100, strict: true }), "dom.query", { selector: "css=li", timeout_ms: 100, strict: true }],
  ["dom.click", (zb) => zb.dom.click("css=#b", { force: true, timeoutMs: 900 }), "dom.click", { selector: "css=#b", options: { force: true, timeout_ms: 900 } }],
  ["dom.fill", (zb) => zb.dom.fill("css=#n", "Ada"), "dom.fill", { selector: "css=#n", value: "Ada" }],
  ["dom.type", (zb) => zb.dom.type("css=#q", "zig", { delayMs: 40 }), "dom.type", { selector: "css=#q", text: "zig", delay_ms: 40 }],
  ["dom.getText", (zb) => zb.dom.getText("css=#m", { timeoutMs: 300 }), "dom.getText", { selector: "css=#m", timeout_ms: 300 }],
  ["dom.getAttribute", (zb) => zb.dom.getAttribute("css=a", "href"), "dom.getAttribute", { selector: "css=a", name: "href" }],
  ["dom.waitFor", (zb) => zb.dom.waitFor("css=#x", { state: "hidden", timeoutMs: 250 }), "dom.waitFor", { selector: "css=#x", state: "hidden", timeout_ms: 250 }],
  ["dom.press", (zb) => zb.dom.press("Enter"), "dom.press", { key: "Enter" }],
  ["dom.press+", (zb) => zb.dom.press("a", { selector: "css=#q", modifiers: ["Control"], timeoutMs: 5 }), "dom.press", { key: "a", selector: "css=#q", modifiers: ["Control"], timeout_ms: 5 }],
  ["dom.selectOption", (zb) => zb.dom.selectOption("css=#c", { label: "France" }), "dom.selectOption", { selector: "css=#c", label: "France" }],
  ["page.navigate", (zb) => zb.page.navigate("https://e.test/", { waitUntil: "load", timeoutMs: 5000 }), "page.navigate", { url: "https://e.test/", waitUntil: "load", timeout_ms: 5000 }],
  ["page.reload", (zb) => zb.page.reload(), "page.reload", {}],
  ["page.url", (zb) => zb.page.url(), "page.url", {}],
  ["page.title", (zb) => zb.page.title(), "page.title", {}],
  ["page.evaluate", (zb) => zb.page.evaluate("1+1"), "page.evaluate", { expression: "1+1" }],
  ["page.screenshot", (zb) => zb.page.screenshot({ fullPage: true }), "page.screenshot", { fullPage: true }],
  ["cookies.getAll", (zb) => zb.cookies.getAll({ url: "https://e.test/" }), "cookies.getAll", { url: "https://e.test/" }],
  ["cookies.set", (zb) => zb.cookies.set({ name: "sid", value: "v", domain: "e.test", httpOnly: true, sameSite: "Lax" }), "cookies.set", { name: "sid", value: "v", domain: "e.test", httpOnly: true, sameSite: "Lax" }],
  ["cookies.delete", (zb) => zb.cookies.delete("sid"), "cookies.delete", { name: "sid" }],
  ["cookies.import", (zb) => zb.cookies.import("/tmp/c.txt", "netscape"), "cookies.import", { path: "/tmp/c.txt", format: "netscape" }],
  ["social.loginCheck", (zb) => zb.social.loginCheck(), "social.login_check", {}],
  ["social.rateStatus", (zb) => zb.social.rateStatus(), "social.rate_status", {}],
  ["social.pause", (zb) => zb.social.pause(10), "social.pause", { duration_ms: 10 }],
  ["social.setPacing", (zb) => zb.social.setPacing({ dailyCap: 5 }), "social.set_pacing", { daily_cap: 5 }],
];

describe("typed wrappers", () => {
  let server: MockUDSServer;
  afterEach(async () => {
    if (server) await server.close();
  });

  for (const [name, invoke, method, params] of CASES) {
    it(`${name} sends ${method}`, async () => {
      server = await createMockServer();
      server.setResponse({ jsonrpc: "2.0", result: { ok: true }, id: 1 });
      const zb = new ZigBrowser({ socketPath: server.path });
      await zb.connect();
      await invoke(zb);
      const req = server.lastRequest();
      expect(req.method).toBe(method);
      expect(req.params).toEqual(params);
      expect("auth" in req).toBe(false);
      await zb.disconnect();
    });
  }

  it("returns typed results", async () => {
    server = await createMockServer();
    server.setResponse({ jsonrpc: "2.0", result: { title: "Fixture" }, id: 1 });
    const zb = new ZigBrowser({ socketPath: server.path });
    await zb.connect();
    const result = await zb.page.title();
    expect(result.title).toBe("Fixture");
    await zb.disconnect();
  });

  it("sends the token as auth on every request", async () => {
    server = await createMockServer();
    server.setResponse({ jsonrpc: "2.0", result: { ok: true }, id: 1 });
    const zb = new ZigBrowser({ socketPath: server.path, token: "s3cret" });
    await zb.connect();
    await zb.page.url();
    expect(server.lastRequest().auth).toBe("s3cret");
    await zb.dom.click("css=#b");
    expect(server.lastRequest().auth).toBe("s3cret");
    await zb.disconnect();
  });

  it("selectOption requires exactly one choice", async () => {
    const zb = new ZigBrowser({ socketPath: "/nonexistent" });
    await expect(zb.dom.selectOption("css=#c", {} as never)).rejects.toThrow(/exactly one/);
  });
});
