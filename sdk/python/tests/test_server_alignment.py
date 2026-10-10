"""N9: every wrapper sends exactly what the server's router accepts."""

import asyncio

import pytest
from zigbrowser.client import AsyncZigBrowser, ZigBrowser

OK = {"jsonrpc": "2.0", "result": {"ok": True}, "id": 1}

CASES = [
    # dom.*
    (lambda zb: zb.dom.press("Enter"), "dom.press", {"key": "Enter"}),
    (
        lambda zb: zb.dom.press("a", selector="css=#q", modifiers=["Control", "Shift"], timeout_ms=500),
        "dom.press",
        {"key": "a", "selector": "css=#q", "modifiers": ["Control", "Shift"], "timeout_ms": 500},
    ),
    (lambda zb: zb.dom.select_option("css=#c", value="fr"), "dom.selectOption", {"selector": "css=#c", "value": "fr"}),
    (lambda zb: zb.dom.select_option("css=#c", label="France"), "dom.selectOption", {"selector": "css=#c", "label": "France"}),
    (
        lambda zb: zb.dom.select_option("css=#c", index=2, timeout_ms=100),
        "dom.selectOption",
        {"selector": "css=#c", "index": 2, "timeout_ms": 100},
    ),
    (
        lambda zb: zb.dom.wait_for("css=#x", state="hidden", timeout_ms=250),
        "dom.waitFor",
        {"selector": "css=#x", "state": "hidden", "timeout_ms": 250},
    ),
    (lambda zb: zb.dom.get_text("css=#m", timeout_ms=300), "dom.getText", {"selector": "css=#m", "timeout_ms": 300}),
    (
        lambda zb: zb.dom.get_attribute("css=a", "href", timeout_ms=300),
        "dom.getAttribute",
        {"selector": "css=a", "name": "href", "timeout_ms": 300},
    ),
    (
        lambda zb: zb.dom.type("css=#q", "hi", delay_ms=40),
        "dom.type",
        {"selector": "css=#q", "text": "hi", "delay_ms": 40},
    ),
    (
        lambda zb: zb.dom.click("css=#b", force=True, timeout_ms=900),
        "dom.click",
        {"selector": "css=#b", "options": {"force": True, "timeout_ms": 900}},
    ),
    # page.*
    (lambda zb: zb.page.url(), "page.url", {}),
    (lambda zb: zb.page.title(), "page.title", {}),
    (
        lambda zb: zb.page.navigate("https://example.com/", timeout_ms=5000),
        "page.navigate",
        {"url": "https://example.com/", "timeout_ms": 5000},
    ),
    # cookies.*
    (lambda zb: zb.cookies.get_all(), "cookies.getAll", {}),
    (lambda zb: zb.cookies.get_all(url="https://example.com/"), "cookies.getAll", {"url": "https://example.com/"}),
    (lambda zb: zb.cookies.delete("sid"), "cookies.delete", {"name": "sid"}),
    (lambda zb: zb.cookies.delete("sid", domain="example.com"), "cookies.delete", {"name": "sid", "domain": "example.com"}),
    (
        lambda zb: zb.cookies.set("sid", "v", domain="example.com", http_only=True, same_site="Lax"),
        "cookies.set",
        {"name": "sid", "value": "v", "domain": "example.com", "httpOnly": True, "sameSite": "Lax"},
    ),
    (
        lambda zb: zb.cookies.import_file("/tmp/cookies.txt", "netscape"),
        "cookies.import",
        {"path": "/tmp/cookies.txt", "format": "netscape"},
    ),
    # social.* / linkedin.*
    (lambda zb: zb.social.pause(5), "social.pause", {"duration_ms": 5}),
    (lambda zb: zb.linkedin.follow("https://www.linkedin.com/in/x"), "linkedin.follow", {"profileUrl": "https://www.linkedin.com/in/x"}),
]


@pytest.mark.parametrize("invoke,method,params", CASES, ids=[c[1] + str(i) for i, c in enumerate(CASES)])
def test_wrapper_wire_shape(mock_uds_server, invoke, method, params):
    mock_uds_server.set_response(OK)
    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        invoke(zb)
    req = mock_uds_server.last_request()
    assert req["method"] == method
    assert req["params"] == params


def test_select_option_requires_exactly_one_choice():
    zb = ZigBrowser(socket_path="/nonexistent")
    with pytest.raises(ValueError):
        zb.dom.select_option("css=#c")
    with pytest.raises(ValueError):
        zb.dom.select_option("css=#c", value="a", label="b")


def test_cookie_import_rejects_unknown_format():
    zb = ZigBrowser(socket_path="/nonexistent")
    with pytest.raises(ValueError):
        zb.cookies.import_file("/tmp/x", "har")


def test_token_is_sent_as_auth_on_every_request(mock_uds_server):
    mock_uds_server.set_response(OK)
    with ZigBrowser(socket_path=mock_uds_server.path, token="s3cret") as zb:
        zb.page.url()
        assert mock_uds_server.last_request()["auth"] == "s3cret"
        zb.dom.click("css=#b")
        assert mock_uds_server.last_request()["auth"] == "s3cret"


def test_no_token_means_no_auth_member(mock_uds_server):
    mock_uds_server.set_response(OK)
    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        zb.page.url()
    assert "auth" not in mock_uds_server.last_request()


def test_async_client_sends_token(mock_uds_server):
    mock_uds_server.set_response(OK)

    async def run():
        async with AsyncZigBrowser(socket_path=mock_uds_server.path, token="t0k") as zb:
            await zb.call("page.url")

    asyncio.run(run())
    assert mock_uds_server.last_request()["auth"] == "t0k"
