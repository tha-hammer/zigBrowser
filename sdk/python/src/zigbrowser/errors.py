class ZigBrowserError(Exception):
    pass


class ProtocolError(ZigBrowserError):
    def __init__(self, code: int, message: str):
        self.code = code
        self.message = message
        super().__init__(f"JSON-RPC error {code}: {message}")


class AutomationError(ZigBrowserError):
    AUTOMATION_RANGE = range(-32012, -32000)

    def __init__(
        self,
        code: int,
        error_name: str,
        trace_id: str | None = None,
        command_id: str | None = None,
        diagnostics: dict | None = None,
    ):
        self.code = code
        self.error_name = error_name
        self.trace_id = trace_id
        self.command_id = command_id
        self.diagnostics = diagnostics or {}
        super().__init__(f"{error_name} (code={code}, trace={trace_id})")

    @classmethod
    def from_rpc_error(cls, rpc_error: dict) -> "AutomationError | ProtocolError":
        code = rpc_error["code"]
        message = rpc_error["message"]

        if code not in cls.AUTOMATION_RANGE:
            return ProtocolError(code, message)

        data = dict(rpc_error.get("data", {}))
        trace_id = data.pop("trace_id", None)
        command_id = data.pop("command_id", None)

        return cls(
            code=code,
            error_name=message,
            trace_id=trace_id,
            command_id=command_id,
            diagnostics=data,
        )

    def __repr__(self):
        return (
            f"AutomationError(code={self.code}, error={self.error_name!r}, "
            f"trace_id={self.trace_id!r})"
        )
