import { describe, it, expect, afterEach } from "vitest";
import { createMockServer, MockUDSServer } from "./helpers";
import { ZigBrowser } from "../src/index";

describe("Event subscription", () => {
  let server: MockUDSServer;

  afterEach(async () => {
    if (server) await server.close();
  });

  it("dispatches notifications to listeners", async () => {
    server = await createMockServer();
    const received: unknown[] = [];

    const zb = new ZigBrowser({ socketPath: server.path });
    await zb.connect();
    zb.on("event.navigation", (params) => received.push(params));

    server.pushNotification({
      jsonrpc: "2.0",
      method: "event.navigation",
      params: { state: "network_idle", url: "https://example.com" },
    });

    await new Promise((r) => setTimeout(r, 100));
    expect(received).toHaveLength(1);
    expect(received[0]).toEqual({
      state: "network_idle",
      url: "https://example.com",
    });

    await zb.disconnect();
  });

  it("supports multiple listeners for same event", async () => {
    server = await createMockServer();
    const a: unknown[] = [];
    const b: unknown[] = [];

    const zb = new ZigBrowser({ socketPath: server.path });
    await zb.connect();
    zb.on("event.navigation", (params) => a.push(params));
    zb.on("event.navigation", (params) => b.push(params));

    server.pushNotification({
      jsonrpc: "2.0",
      method: "event.navigation",
      params: { url: "https://example.com" },
    });

    await new Promise((r) => setTimeout(r, 100));
    expect(a).toHaveLength(1);
    expect(b).toHaveLength(1);

    await zb.disconnect();
  });

  it("silently drops unmatched events", async () => {
    server = await createMockServer();
    const received: unknown[] = [];

    const zb = new ZigBrowser({ socketPath: server.path });
    await zb.connect();
    zb.on("event.navigation", (params) => received.push(params));

    server.pushNotification({
      jsonrpc: "2.0",
      method: "event.dom_change",
      params: { selector: "div" },
    });

    await new Promise((r) => setTimeout(r, 100));
    expect(received).toHaveLength(0);

    await zb.disconnect();
  });
});
