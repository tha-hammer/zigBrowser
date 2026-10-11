export class ZigBrowserError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ZigBrowserError";
  }
}

export class ProtocolError extends ZigBrowserError {
  code: number;

  constructor(code: number, message: string) {
    super(`JSON-RPC error ${code}: ${message}`);
    this.name = "ProtocolError";
    this.code = code;
  }
}

export class AutomationError extends ZigBrowserError {
  static readonly AUTOMATION_MIN = -32014;
  static readonly AUTOMATION_MAX = -32001;

  code: number;
  errorName: string;
  traceId?: string;
  commandId?: string;
  diagnostics: Record<string, unknown>;

  constructor(
    code: number,
    errorName: string,
    traceId?: string,
    commandId?: string,
    diagnostics: Record<string, unknown> = {},
  ) {
    super(`${errorName} (code=${code}, trace=${traceId})`);
    this.name = "AutomationError";
    this.code = code;
    this.errorName = errorName;
    this.traceId = traceId;
    this.commandId = commandId;
    this.diagnostics = diagnostics;
  }

  static fromRpcError(rpcError: {
    code: number;
    message: string;
    data?: Record<string, unknown>;
  }): AutomationError | ProtocolError {
    const { code, message, data = {} } = rpcError;

    if (code < AutomationError.AUTOMATION_MIN || code > AutomationError.AUTOMATION_MAX) {
      return new ProtocolError(code, message);
    }

    const { trace_id, command_id, ...diagnostics } = data;
    return new AutomationError(
      code,
      message,
      trace_id as string | undefined,
      command_id as string | undefined,
      diagnostics,
    );
  }
}
