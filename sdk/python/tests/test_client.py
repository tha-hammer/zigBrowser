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
