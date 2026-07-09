import pytest
from zigbrowser.client import ZigBrowser
from zigbrowser.errors import AutomationError


def test_connect_to_socket(mock_uds_server):
    client = ZigBrowser(socket_path=mock_uds_server.path)
    client.connect()
    assert client.connected
    client.disconnect()
    assert not client.connected


def test_context_manager(mock_uds_server):
    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        assert zb.connected
    assert not zb.connected


def test_connect_nonexistent_socket():
    client = ZigBrowser(socket_path="/tmp/nonexistent-zigbrowser-test.sock")
    with pytest.raises(ConnectionError, match="socket"):
        client.connect()


def test_call_sends_jsonrpc_request(mock_uds_server):
    mock_uds_server.set_response({"jsonrpc": "2.0", "result": {"ok": True}, "id": 1})

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        result = zb.call("dom.click", {"selector": "role=button[name='OK']"})

    assert result == {"ok": True}
    req = mock_uds_server.last_request()
    assert req["jsonrpc"] == "2.0"
    assert req["method"] == "dom.click"
    assert req["params"]["selector"] == "role=button[name='OK']"
    assert "id" in req


def test_call_raises_on_rpc_error(mock_uds_server):
    mock_uds_server.set_response({
        "jsonrpc": "2.0",
        "error": {
            "code": -32001,
            "message": "element_not_found",
            "data": {"trace_id": "abc123", "command_id": "cmd456"},
        },
        "id": 1,
    })

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        with pytest.raises(AutomationError) as exc_info:
            zb.call("dom.click", {"selector": "role=button[name='Gone']"})

        err = exc_info.value
        assert err.code == -32001
        assert err.error_name == "element_not_found"
        assert err.trace_id == "abc123"
        assert err.command_id == "cmd456"


def test_call_not_connected_raises():
    client = ZigBrowser(socket_path="/tmp/nonexistent.sock")
    with pytest.raises(ConnectionError, match="Not connected"):
        client.call("dom.click", {})
