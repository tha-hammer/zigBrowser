import pytest
from zigbrowser.client import AsyncZigBrowser, ZigBrowser
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


def test_dom_click_wrapper(mock_uds_server):
    mock_uds_server.set_response({"jsonrpc": "2.0", "result": {"ok": True}, "id": 1})

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        result = zb.dom.click("role=button[name='OK']", timeout_ms=5000)

    assert result["ok"] is True
    req = mock_uds_server.last_request()
    assert req["method"] == "dom.click"
    assert req["params"]["selector"] == "role=button[name='OK']"
    assert req["params"]["options"]["timeout_ms"] == 5000


def test_dom_fill_wrapper(mock_uds_server):
    mock_uds_server.set_response({"jsonrpc": "2.0", "result": {"ok": True}, "id": 1})

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        result = zb.dom.fill("input#name", "Jane Doe")

    req = mock_uds_server.last_request()
    assert req["method"] == "dom.fill"
    assert req["params"]["selector"] == "input#name"
    assert req["params"]["value"] == "Jane Doe"


def test_page_navigate_wrapper(mock_uds_server):
    mock_uds_server.set_response({"jsonrpc": "2.0", "result": {"ok": True}, "id": 1})

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        zb.page.navigate("https://example.com", wait_until="networkidle")

    req = mock_uds_server.last_request()
    assert req["method"] == "page.navigate"
    assert req["params"]["url"] == "https://example.com"
    assert req["params"]["waitUntil"] == "networkidle"


def test_linkedin_connect_wrapper(mock_uds_server):
    mock_uds_server.set_response({"jsonrpc": "2.0", "result": {"ok": True}, "id": 1})

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        result = zb.linkedin.connect(
            "https://www.linkedin.com/in/jane/", note="Hi Jane!"
        )

    req = mock_uds_server.last_request()
    assert req["method"] == "linkedin.connect"
    assert req["params"]["profileUrl"] == "https://www.linkedin.com/in/jane/"
    assert req["params"]["note"] == "Hi Jane!"


def test_linkedin_visit_wrapper(mock_uds_server):
    mock_uds_server.set_response({"jsonrpc": "2.0", "result": {"ok": True}, "id": 1})

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        zb.linkedin.visit("https://www.linkedin.com/in/jane/")

    req = mock_uds_server.last_request()
    assert req["method"] == "linkedin.visit"
    assert req["params"]["profileUrl"] == "https://www.linkedin.com/in/jane/"


def test_instagram_follow_wrapper(mock_uds_server):
    mock_uds_server.set_response({"jsonrpc": "2.0", "result": {"ok": True}, "id": 1})

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        zb.instagram.follow("https://www.instagram.com/janedoe/")

    req = mock_uds_server.last_request()
    assert req["method"] == "instagram.follow"
    assert req["params"]["profileUrl"] == "https://www.instagram.com/janedoe/"


def test_social_login_check_wrapper(mock_uds_server):
    mock_uds_server.set_response({
        "jsonrpc": "2.0",
        "result": {"loggedIn": True, "platform": "linkedin", "username": "jane"},
        "id": 1,
    })

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        result = zb.social.login_check()

    req = mock_uds_server.last_request()
    assert req["method"] == "social.login_check"
    assert result["loggedIn"] is True


def test_social_rate_status_wrapper(mock_uds_server):
    mock_uds_server.set_response({
        "jsonrpc": "2.0",
        "result": {"remaining_actions": 73, "daily_cap": 100},
        "id": 1,
    })

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        result = zb.social.rate_status()

    req = mock_uds_server.last_request()
    assert req["method"] == "social.rate_status"
    assert result["remaining_actions"] == 73


@pytest.mark.asyncio
async def test_async_call(mock_uds_server):
    mock_uds_server.set_response({"jsonrpc": "2.0", "result": {"ok": True}, "id": 1})

    async with AsyncZigBrowser(socket_path=mock_uds_server.path) as zb:
        result = await zb.call("dom.click", {"selector": "role=button"})

    assert result == {"ok": True}


@pytest.mark.asyncio
async def test_async_call_error(mock_uds_server):
    mock_uds_server.set_response({
        "jsonrpc": "2.0",
        "error": {
            "code": -32001,
            "message": "element_not_found",
            "data": {"trace_id": "t-async-123"},
        },
        "id": 1,
    })

    async with AsyncZigBrowser(socket_path=mock_uds_server.path) as zb:
        with pytest.raises(AutomationError) as exc_info:
            await zb.call("dom.click", {"selector": "role=button"})

        assert exc_info.value.trace_id == "t-async-123"


@pytest.mark.asyncio
async def test_async_context_manager(mock_uds_server):
    zb = AsyncZigBrowser(socket_path=mock_uds_server.path)
    assert not zb.connected
    async with zb:
        assert zb.connected
    assert not zb.connected
