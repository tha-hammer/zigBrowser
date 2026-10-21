import { describe, it, expect } from "vitest";
import { AutomationError, ProtocolError } from "../src/index";

// S8a (chat-drawer plan rev 16.20.38): -32015 expectation_mismatch is an automation error.
describe("AutomationError -32015", () => {
  it("maps expectation_mismatch (-32015) like the other automation codes", () => {
    const err = AutomationError.fromRpcError({ code: -32015, message: "expectation_mismatch", data: { trace_id: "t-1", command_id: "cmd-7" } });
    expect(err).toBeInstanceOf(AutomationError);
    expect((err as AutomationError).errorName).toBe("expectation_mismatch");
    expect((err as AutomationError).commandId).toBe("cmd-7");
  });

  it("stops at -32015", () => {
    expect(AutomationError.fromRpcError({ code: -32016, message: "x" })).toBeInstanceOf(ProtocolError);
  });
});
