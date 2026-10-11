import { describe, it, expect, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createMockServer, MockUDSServer } from "./helpers";
import { ZigBrowser } from "../src/index";

// Shared with tests/automation_server_test.zig (which proves the real server
// routes and accepts every case) and with the Python SDK tests.
const wirePath =
  process.env.ZB_WIRE_CASES ??
  path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../tests/fixtures/automation/sdk_wire_cases.json");
const WIRE_CASES: Record<string, { method: string; params: Record<string, unknown> }> = Object.fromEntries(
  (JSON.parse(fs.readFileSync(wirePath, "utf-8")).cases as { id: string; method: string; params: Record<string, unknown> }[]).map(
    (c) => [c.id, { method: c.method, params: c.params }],
  ),
);

// How this SDK produces each shared case.
const INVOCATIONS: Record<string, (zb: ZigBrowser) => Promise<unknown>> = {
  "dom.query": (zb) => zb.dom.query("css=li", { timeoutMs: 100 }),
  "dom.click": (zb) => zb.dom.click("css=#b", { force: true, timeoutMs: 900 }),
  "dom.fill": (zb) => zb.dom.fill("css=#n", "Ada"),
  "dom.type": (zb) => zb.dom.type("css=#q", "zig", { delayMs: 40 }),
  "dom.getText": (zb) => zb.dom.getText("css=#m", { timeoutMs: 300 }),
  "dom.getAttribute": (zb) => zb.dom.getAttribute("css=a", "href", { timeoutMs: 300 }),
  "dom.waitFor": (zb) => zb.dom.waitFor("css=#x", { state: "hidden", timeoutMs: 250 }),
  "dom.press": (zb) => zb.dom.press("Enter"),
  "dom.press.full": (zb) => zb.dom.press("a", { selector: "css=#q", modifiers: ["Control", "Shift"], timeoutMs: 500 }),
  "dom.selectOption.value": (zb) => zb.dom.selectOption("css=#c", { value: "fr" }),
  "dom.selectOption.label": (zb) => zb.dom.selectOption("css=#c", { label: "France" }),
  "dom.selectOption.index": (zb) => zb.dom.selectOption("css=#c", { index: 2, timeoutMs: 100 }),
  "dom.setInputFiles": (zb) => zb.dom.setInputFiles("css=#f", ["/tmp/zb-conformance/a.txt", "/tmp/zb-conformance/b.png"], { timeoutMs: 5000 }),
  "dom.hover": (zb) => zb.dom.hover("css=#m"),
  "dom.hover.native": (zb) => zb.dom.hover("css=#m", { input: "native", humanize: true }),
  "dom.scroll": (zb) => zb.dom.scroll({ y: 300 }),
  "dom.scroll.selector": (zb) => zb.dom.scroll({ selector: "css=#far" }, { input: "native", timeoutMs: 9000 }),
  "page.navigate": (zb) => zb.page.navigate("https://example.com/", { timeoutMs: 5000 }),
  "page.reload": (zb) => zb.page.reload(),
  "page.url": (zb) => zb.page.url(),
  "page.title": (zb) => zb.page.title(),
  "page.evaluate": (zb) => zb.page.evaluate("1+1"),
  "page.list": (zb) => zb.page.list(),
  "page.close": (zb) => zb.page.close("window-2"),
  "page.navigate.onBeforeUnload": (zb) => zb.page.navigate("https://example.com/", { onBeforeUnload: "accept" }),
  "dialog.get": (zb) => zb.dialog.get(),
  "dialog.get.window": (zb) => zb.dialog.get({ windowId: "window-2" }),
  "dialog.respond": (zb) => zb.dialog.respond(true),
  "dialog.respond.prompt": (zb) => zb.dialog.respond(true, { text: "ada", windowId: "window-2" }),
  "cookies.getAll": (zb) => zb.cookies.getAll(),
  "cookies.getAll.url": (zb) => zb.cookies.getAll({ url: "https://example.com/" }),
  "cookies.set": (zb) => zb.cookies.set({ name: "sid", value: "v", domain: "example.com", httpOnly: true, sameSite: "Lax" }),
  "cookies.delete": (zb) => zb.cookies.delete("sid"),
  "cookies.delete.domain": (zb) => zb.cookies.delete("sid", "example.com"),
  "cookies.import": (zb) => zb.cookies.import("/nonexistent/zb-conformance/cookies.txt", "netscape"),
  "social.login_check": (zb) => zb.social.loginCheck(),
  "social.rate_status": (zb) => zb.social.rateStatus(),
  "social.pause": (zb) => zb.social.pause(5),
  "social.set_pacing": (zb) => zb.social.setPacing({ dailyCap: 5 }),
  "x.post": (zb) => zb.x.post("hello from zigBrowser"),
  "x.post.compose_url": (zb) => zb.x.post("hello", { composeUrl: "http://127.0.0.1:9/compose" }),
  "x.schedule_post": (zb) => zb.x.schedulePost("later", "2026-11-05", "14:07"),
  "x.login_check": (zb) => zb.x.loginCheck(),
  "x.selfcheck": (zb) => zb.x.selfcheck(),
  "linkedin.visit": (zb) => zb.linkedin.visit("https://www.linkedin.com/in/ada/"),
  "linkedin.connect": (zb) => zb.linkedin.connect("https://www.linkedin.com/in/ada/"),
  "linkedin.connect.note": (zb) => zb.linkedin.connect("https://www.linkedin.com/in/ada/", { note: "Hi Ada" }),
  "linkedin.follow": (zb) => zb.linkedin.follow("https://www.linkedin.com/in/ada/"),
  "linkedin.message.conversation": (zb) => zb.linkedin.message("Hello", { conversationUrl: "https://www.linkedin.com/messaging/thread/1/" }),
  "linkedin.message.profile": (zb) => zb.linkedin.message("Hello", { profileUrl: "https://www.linkedin.com/in/ada/" }),
  "linkedin.like": (zb) => zb.linkedin.like("https://www.linkedin.com/feed/update/urn:li:activity:1/"),
  "linkedin.comment": (zb) => zb.linkedin.comment("https://www.linkedin.com/feed/update/urn:li:activity:1/", "Great post"),
  "linkedin.search": (zb) => zb.linkedin.search("zig"),
  "linkedin.search.type": (zb) => zb.linkedin.search("zig", { searchType: "companies" }),
  "linkedin.extract": (zb) => zb.linkedin.extract("https://www.linkedin.com/in/ada/"),
  "linkedin.selfcheck": (zb) => zb.linkedin.selfcheck(),
  "instagram.follow": (zb) => zb.instagram.follow("https://www.instagram.com/ada/"),
  "instagram.like": (zb) => zb.instagram.like("https://www.instagram.com/p/C0ffee/"),
  "instagram.comment": (zb) => zb.instagram.comment("https://www.instagram.com/p/C0ffee/", "So good"),
  "instagram.dm": (zb) => zb.instagram.dm("ada", "hi"),
  "instagram.story_view": (zb) => zb.instagram.storyView("ada"),
  "instagram.selfcheck": (zb) => zb.instagram.selfcheck(),
};

describe("typed wrappers", () => {
  let server: MockUDSServer;
  afterEach(async () => {
    if (server) await server.close();
  });

  it("covers every shared wire case", () => {
    expect(Object.keys(INVOCATIONS).sort()).toEqual(Object.keys(WIRE_CASES).sort());
  });

  for (const id of Object.keys(WIRE_CASES).sort()) {
    it(`${id} emits the shared wire case`, async () => {
      server = await createMockServer();
      server.setResponse({ jsonrpc: "2.0", result: { ok: true }, id: 1 });
      const zb = new ZigBrowser({ socketPath: server.path });
      await zb.connect();
      await INVOCATIONS[id](zb);
      const req = server.lastRequest();
      expect(req.method).toBe(WIRE_CASES[id].method);
      expect(req.params).toEqual(WIRE_CASES[id].params);
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

  it("reads the token from the <socket>.token sidecar when none is given", async () => {
    server = await createMockServer();
    server.setResponse({ jsonrpc: "2.0", result: { ok: true }, id: 1 });
    fs.writeFileSync(`${server.path}.token`, "sidecar-t0k");
    try {
      const zb = new ZigBrowser({ socketPath: server.path });
      await zb.connect();
      await zb.page.url();
      expect(server.lastRequest().auth).toBe("sidecar-t0k");
      await zb.disconnect();
    } finally {
      fs.unlinkSync(`${server.path}.token`);
    }
  });

  it("the same client re-reads a rotated sidecar on reconnect", async () => {
    server = await createMockServer();
    server.setResponse({ jsonrpc: "2.0", result: { ok: true }, id: 1 });
    const sidecar = `${server.path}.token`;
    const zb = new ZigBrowser({ socketPath: server.path });
    try {
      fs.writeFileSync(sidecar, "first");
      await zb.connect();
      await zb.page.url();
      expect(server.lastRequest().auth).toBe("first");
      await zb.disconnect();

      fs.writeFileSync(sidecar, "second");
      await zb.connect();
      await zb.page.url();
      expect(server.lastRequest().auth).toBe("second");
      await zb.disconnect();

      fs.unlinkSync(sidecar);
      await zb.connect();
      await zb.page.url();
      expect("auth" in server.lastRequest()).toBe(false);
      await zb.disconnect();
    } finally {
      if (fs.existsSync(sidecar)) fs.unlinkSync(sidecar);
    }
  });

  it("selectOption requires exactly one choice", async () => {
    const zb = new ZigBrowser({ socketPath: "/nonexistent" });
    await expect(zb.dom.selectOption("css=#c", {} as never)).rejects.toThrow(/exactly one/);
  });
});
