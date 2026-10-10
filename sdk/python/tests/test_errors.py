import pytest
from zigbrowser.errors import AutomationError, ProtocolError


def test_automation_error_from_rpc():
    rpc_error = {
        "code": -32001,
        "message": "element_not_found",
        "data": {
            "trace_id": "t-abc123",
            "command_id": "c-def456",
            "selector.hash": "h-789",
            "timeout_ms": 5000,
        },
    }
    err = AutomationError.from_rpc_error(rpc_error)
    assert err.code == -32001
    assert err.error_name == "element_not_found"
    assert err.trace_id == "t-abc123"
    assert err.command_id == "c-def456"
    assert err.diagnostics == {"selector.hash": "h-789", "timeout_ms": 5000}
    assert "t-abc123" in repr(err)


def test_automation_error_missing_data():
    rpc_error = {"code": -32005, "message": "element_disabled"}
    err = AutomationError.from_rpc_error(rpc_error)
    assert err.trace_id is None
    assert err.command_id is None
    assert err.diagnostics == {}


def test_protocol_error_for_standard_codes():
    rpc_error = {"code": -32601, "message": "Method not found"}
    err = AutomationError.from_rpc_error(rpc_error)
    assert isinstance(err, ProtocolError)
    assert not isinstance(err, AutomationError)
    assert err.data == {}


def test_protocol_error_keeps_its_data():
    rpc_error = {"code": -32602, "message": "Invalid params", "data": {"reason": "bad_file", "trace_id": "t"}}
    err = AutomationError.from_rpc_error(rpc_error)
    assert isinstance(err, ProtocolError)
    assert err.code == -32602
    assert err.data["reason"] == "bad_file"


ERROR_CODE_MAP = {
    -32001: "element_not_found",
    -32002: "element_not_visible",
    -32003: "element_not_stable",
    -32004: "element_obscured",
    -32005: "element_disabled",
    -32006: "element_not_editable",
    -32007: "navigation_timeout",
    -32008: "navigation_failed",
    -32009: "action_timeout",
    -32010: "platform_rate_limited",
    -32011: "session_invalid",
    -32012: "cancelled",
}


@pytest.mark.parametrize("code,name", ERROR_CODE_MAP.items())
def test_all_12_error_codes_map_correctly(code, name):
    rpc_error = {"code": code, "message": name}
    err = AutomationError.from_rpc_error(rpc_error)
    assert err.code == code
    assert err.error_name == name


def test_sdk_error_diagnostics_contain_only_redacted_fields_c53():
    """C53: SDK must not introduce unredacted fields beyond what the server sent."""
    rpc_error = {
        "code": -32001,
        "message": "element_not_found",
        "data": {
            "trace_id": "t-abc",
            "command_id": "c-def",
            "selector.hash": "h-sha256-abc",
            "timeout_ms": 5000,
            "target.host": "www.linkedin.com",
        },
    }
    err = AutomationError.from_rpc_error(rpc_error)
    assert "selector.hash" in err.diagnostics
    assert "timeout_ms" in err.diagnostics
    assert "target.host" in err.diagnostics
    assert "selector" not in err.diagnostics
    assert "profile.url" not in err.diagnostics
    assert "note.text" not in err.diagnostics


def test_sdk_error_repr_includes_trace_id_never_raw_params():
    """C53: repr() shows trace_id for debugging, never raw params."""
    rpc_error = {
        "code": -32010,
        "message": "platform_rate_limited",
        "data": {"trace_id": "t-rate-123", "command_id": "c-456"},
    }
    err = AutomationError.from_rpc_error(rpc_error)
    err_repr = repr(err)
    assert "t-rate-123" in err_repr
    assert "platform_rate_limited" in err_repr
