import { describe, it, expect } from "vitest";
import { AutomationError, ProtocolError } from "../src/index";

describe("AutomationError", () => {
  it("maps all 12 automation codes", () => {
    for (let code = -32001; code >= -32012; code--) {
      const err = AutomationError.fromRpcError({
        code,
        message: `error_${code}`,
      });
      expect(err).toBeInstanceOf(AutomationError);
      expect((err as AutomationError).code).toBe(code);
    }
  });

  it("exposes trace_id and command_id from data", () => {
    const err = AutomationError.fromRpcError({
      code: -32001,
      message: "element_not_found",
      data: {
        trace_id: "t-abc",
        command_id: "c-def",
        "selector.hash": "h123",
      },
    });
    expect(err).toBeInstanceOf(AutomationError);
    const ae = err as AutomationError;
    expect(ae.traceId).toBe("t-abc");
    expect(ae.commandId).toBe("c-def");
    expect(ae.diagnostics).toEqual({ "selector.hash": "h123" });
  });

  it("returns ProtocolError for standard JSON-RPC codes", () => {
    const err = AutomationError.fromRpcError({
      code: -32601,
      message: "Method not found",
    });
    expect(err).toBeInstanceOf(ProtocolError);
    expect(err).not.toBeInstanceOf(AutomationError);
  });

  it("handles missing data gracefully", () => {
    const err = AutomationError.fromRpcError({
      code: -32005,
      message: "element_disabled",
    });
    expect(err).toBeInstanceOf(AutomationError);
    const ae = err as AutomationError;
    expect(ae.traceId).toBeUndefined();
    expect(ae.commandId).toBeUndefined();
    expect(ae.diagnostics).toEqual({});
  });

  it("includes trace_id in error message", () => {
    const err = AutomationError.fromRpcError({
      code: -32010,
      message: "platform_rate_limited",
      data: { trace_id: "t-rate-123" },
    });
    expect(err).toBeInstanceOf(AutomationError);
    expect((err as AutomationError).message).toContain("t-rate-123");
    expect((err as AutomationError).message).toContain(
      "platform_rate_limited",
    );
  });
});
