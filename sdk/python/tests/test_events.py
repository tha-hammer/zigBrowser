import time

from zigbrowser.client import ZigBrowser


def test_event_subscription(mock_uds_server):
    received = []

    def on_nav(params):
        received.append(params)

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        zb.on("event.navigation", on_nav)
        mock_uds_server.push_notification({
            "jsonrpc": "2.0",
            "method": "event.navigation",
            "params": {"state": "network_idle", "url": "https://example.com"},
        })
        time.sleep(0.2)

    assert len(received) == 1
    assert received[0]["state"] == "network_idle"


def test_multiple_listeners_same_event(mock_uds_server):
    received_a = []
    received_b = []

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        zb.on("event.navigation", lambda p: received_a.append(p))
        zb.on("event.navigation", lambda p: received_b.append(p))
        mock_uds_server.push_notification({
            "jsonrpc": "2.0",
            "method": "event.navigation",
            "params": {"url": "https://example.com"},
        })
        time.sleep(0.2)

    assert len(received_a) == 1
    assert len(received_b) == 1


def test_unmatched_event_silently_dropped(mock_uds_server):
    received = []

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        zb.on("event.navigation", lambda p: received.append(p))
        mock_uds_server.push_notification({
            "jsonrpc": "2.0",
            "method": "event.dom_change",
            "params": {"selector": "div"},
        })
        time.sleep(0.2)

    assert len(received) == 0
