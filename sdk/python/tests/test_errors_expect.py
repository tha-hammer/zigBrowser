"""S8a (chat-drawer plan rev 16.20.38): -32015 `expectation_mismatch` is an automation
error, like -32001..-32014: the SDK keeps its name, trace id and command id."""

from zigbrowser.errors import AutomationError, ProtocolError


def test_expectation_mismatch_is_an_automation_error():
    err = AutomationError.from_rpc_error({"code": -32015, "message": "expectation_mismatch",
                                          "data": {"trace_id": "t-1", "command_id": "cmd-7"}})
    assert isinstance(err, AutomationError)
    assert (err.code, err.error_name, err.trace_id, err.command_id) == (-32015, "expectation_mismatch", "t-1", "cmd-7")


def test_the_range_stops_at_minus_32015():
    assert isinstance(AutomationError.from_rpc_error({"code": -32016, "message": "x"}), ProtocolError)
    assert isinstance(AutomationError.from_rpc_error({"code": -32000, "message": "x"}), ProtocolError)
