import { describe, it, expect, afterEach } from "vitest";
import { createMockServer, MockUDSServer } from "./helpers";
import { ZigBrowser, AutomationError } from "../src/index";

describe("ZigBrowser client", () => {
  let server: MockUDSServer;

  afterEach(async () => {
    if (server) await server.close();
  });

  it("connects to UDS and sends JSON-RPC request", async () => {
    server = await createMockServer();
    server.setResponse({ jsonrpc: "2.0", result: { ok: true }, id: 1 });

    const zb = new ZigBrowser({ socketPath: server.path });
    await zb.connect();
    const result = await zb.call("dom.click", { selector: "role=button" });

    expect(result).toEqual({ ok: true });
    const req = server.lastRequest();
    expect(req.method).toBe("dom.click");
    expect(req.jsonrpc).toBe("2.0");
    expect(typeof req.id).toBe("number");

    await zb.disconnect();
  });

  it("rejects with AutomationError on RPC error", async () => {
    server = await createMockServer();
    server.setResponse({
      jsonrpc: "2.0",
      error: {
        code: -32001,
        message: "element_not_found",
        data: { trace_id: "t-123", command_id: "c-456" },
      },
      id: 1,
    });

    const zb = new ZigBrowser({ socketPath: server.path });
    await zb.connect();

    try {
      await zb.call("dom.click", { selector: "role=button" });
      expect.unreachable("Should have thrown");
    } catch (e) {
      expect(e).toBeInstanceOf(AutomationError);
      const err = e as AutomationError;
      expect(err.code).toBe(-32001);
      expect(err.errorName).toBe("element_not_found");
      expect(err.traceId).toBe("t-123");
      expect(err.commandId).toBe("c-456");
    }

    await zb.disconnect();
  });

  it("throws when calling without connection", async () => {
    const zb = new ZigBrowser({ socketPath: "/tmp/nonexistent.sock" });
    await expect(zb.call("dom.click", {})).rejects.toThrow("Not connected");
  });
});
