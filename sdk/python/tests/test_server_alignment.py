"""N9: wrappers emit the shared SDK wire cases (which the real server is
proven to accept in tests/automation_server_test.zig)."""

import asyncio
import json
from pathlib import Path

import pytest
from zigbrowser.client import AsyncZigBrowser, ZigBrowser

OK = {"jsonrpc": "2.0", "result": {"ok": True}, "id": 1}

# Shared with tests/automation_server_test.zig, which proves the real server
# routes and accepts every case, and with the Node SDK tests.
WIRE_CASES = {
    case["id"]: case
    for case in json.loads(
        (Path(__file__).resolve().parents[3] / "tests/fixtures/automation/sdk_wire_cases.json").read_text()
    )["cases"]
}

# How this SDK produces each shared case.
INVOCATIONS = {
    "dom.query": lambda zb: zb.dom.query("css=li", timeout_ms=100),
    "dom.click": lambda zb: zb.dom.click("css=#b", force=True, timeout_ms=900),
    "dom.fill": lambda zb: zb.dom.fill("css=#n", "Ada"),
    "dom.type": lambda zb: zb.dom.type("css=#q", "zig", delay_ms=40),
    "dom.getText": lambda zb: zb.dom.get_text("css=#m", timeout_ms=300),
    "dom.getAttribute": lambda zb: zb.dom.get_attribute("css=a", "href", timeout_ms=300),
    "dom.waitFor": lambda zb: zb.dom.wait_for("css=#x", state="hidden", timeout_ms=250),
    "dom.press": lambda zb: zb.dom.press("Enter"),
    "dom.press.full": lambda zb: zb.dom.press("a", selector="css=#q", modifiers=["Control", "Shift"], timeout_ms=500),
    "dom.selectOption.value": lambda zb: zb.dom.select_option("css=#c", value="fr"),
    "dom.selectOption.label": lambda zb: zb.dom.select_option("css=#c", label="France"),
    "dom.selectOption.index": lambda zb: zb.dom.select_option("css=#c", index=2, timeout_ms=100),
    "page.navigate": lambda zb: zb.page.navigate("https://example.com/", timeout_ms=5000),
    "page.reload": lambda zb: zb.page.reload(),
    "page.url": lambda zb: zb.page.url(),
    "page.title": lambda zb: zb.page.title(),
    "page.evaluate": lambda zb: zb.page.evaluate("1+1"),
    "cookies.getAll": lambda zb: zb.cookies.get_all(),
    "cookies.getAll.url": lambda zb: zb.cookies.get_all(url="https://example.com/"),
    "cookies.set": lambda zb: zb.cookies.set("sid", "v", domain="example.com", http_only=True, same_site="Lax"),
    "cookies.delete": lambda zb: zb.cookies.delete("sid"),
    "cookies.delete.domain": lambda zb: zb.cookies.delete("sid", domain="example.com"),
    "cookies.import": lambda zb: zb.cookies.import_file("/nonexistent/zb-conformance/cookies.txt", "netscape"),
    "social.login_check": lambda zb: zb.social.login_check(),
    "social.rate_status": lambda zb: zb.social.rate_status(),
    "social.pause": lambda zb: zb.social.pause(5),
    "social.set_pacing": lambda zb: zb.social.set_pacing(daily_cap=5),
}


def test_every_shared_case_has_a_wrapper():
    assert sorted(INVOCATIONS) == sorted(WIRE_CASES)


@pytest.mark.parametrize("case_id", sorted(WIRE_CASES))
def test_wrapper_emits_the_shared_wire_case(mock_uds_server, case_id):
    mock_uds_server.set_response(OK)
    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        INVOCATIONS[case_id](zb)
    req = mock_uds_server.last_request()
    assert req["method"] == WIRE_CASES[case_id]["method"]
    assert req["params"] == WIRE_CASES[case_id]["params"]


def test_linkedin_follow_wire_shape_only(mock_uds_server):
    """linkedin.* is NOT routed by the automation socket yet (-32601); this
    only pins the request shape for parity with src/linkedin.zig."""
    mock_uds_server.set_response(OK)
    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        zb.linkedin.follow("https://www.linkedin.com/in/x")
    req = mock_uds_server.last_request()
    assert req == {**req, "method": "linkedin.follow", "params": {"profileUrl": "https://www.linkedin.com/in/x"}}


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
