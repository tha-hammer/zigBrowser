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
    "dom.setInputFiles": lambda zb: zb.dom.set_input_files("css=#f", ["/tmp/zb-conformance/a.txt", "/tmp/zb-conformance/b.png"], timeout_ms=5000),
    "dom.hover": lambda zb: zb.dom.hover("css=#m"),
    "dom.hover.native": lambda zb: zb.dom.hover("css=#m", input="native", humanize=True),
    "dom.scroll": lambda zb: zb.dom.scroll(y=300),
    "dom.scroll.selector": lambda zb: zb.dom.scroll("css=#far", input="native", timeout_ms=9000),
    "page.navigate": lambda zb: zb.page.navigate("https://example.com/", timeout_ms=5000),
    "page.reload": lambda zb: zb.page.reload(),
    "page.url": lambda zb: zb.page.url(),
    "page.title": lambda zb: zb.page.title(),
    "page.evaluate": lambda zb: zb.page.evaluate("1+1"),
    "page.list": lambda zb: zb.page.list(),
    "page.health": lambda zb: zb.page.health(),
    "page.recover": lambda zb: zb.page.recover("window-1"),
    "page.recover.confirm": lambda zb: zb.page.recover("window-1", incident="0123456789abcdef0123456789abcdef", acknowledge=["window-1", "window-2"]),
    "page.close": lambda zb: zb.page.close("window-2"),
    "page.navigate.onBeforeUnload": lambda zb: zb.page.navigate("https://example.com/", on_before_unload="accept"),
    "dialog.get": lambda zb: zb.dialog.get(),
    "dialog.get.window": lambda zb: zb.dialog.get(window_id="window-2"),
    "dialog.respond": lambda zb: zb.dialog.respond(True),
    "dialog.respond.prompt": lambda zb: zb.dialog.respond(True, text="ada", window_id="window-2"),
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
    "x.post": lambda zb: zb.x.post("hello from zigBrowser"),
    "x.post.compose_url": lambda zb: zb.x.post("hello", compose_url="http://127.0.0.1:9/compose"),
    "x.schedule_post": lambda zb: zb.x.schedule_post("later", "2026-11-05", "14:07"),
    "x.login_check": lambda zb: zb.x.login_check(),
    "x.selfcheck": lambda zb: zb.x.selfcheck(),
    "linkedin.visit": lambda zb: zb.linkedin.visit("https://www.linkedin.com/in/ada/"),
    "linkedin.connect": lambda zb: zb.linkedin.connect("https://www.linkedin.com/in/ada/"),
    "linkedin.connect.note": lambda zb: zb.linkedin.connect("https://www.linkedin.com/in/ada/", note="Hi Ada"),
    "linkedin.follow": lambda zb: zb.linkedin.follow("https://www.linkedin.com/in/ada/"),
    "linkedin.message.conversation": lambda zb: zb.linkedin.message("Hello", conversation_url="https://www.linkedin.com/messaging/thread/1/"),
    "linkedin.message.profile": lambda zb: zb.linkedin.message("Hello", profile_url="https://www.linkedin.com/in/ada/"),
    "linkedin.like": lambda zb: zb.linkedin.like("https://www.linkedin.com/feed/update/urn:li:activity:1/"),
    "linkedin.comment": lambda zb: zb.linkedin.comment("https://www.linkedin.com/feed/update/urn:li:activity:1/", "Great post"),
    "linkedin.search": lambda zb: zb.linkedin.search("zig"),
    "linkedin.search.type": lambda zb: zb.linkedin.search("zig", search_type="companies"),
    "linkedin.extract": lambda zb: zb.linkedin.extract("https://www.linkedin.com/in/ada/"),
    "linkedin.selfcheck": lambda zb: zb.linkedin.selfcheck(),
    "instagram.follow": lambda zb: zb.instagram.follow("https://www.instagram.com/ada/"),
    "instagram.like": lambda zb: zb.instagram.like("https://www.instagram.com/p/C0ffee/"),
    "instagram.comment": lambda zb: zb.instagram.comment("https://www.instagram.com/p/C0ffee/", "So good"),
    "instagram.dm": lambda zb: zb.instagram.dm("ada", "hi"),
    "instagram.story_view": lambda zb: zb.instagram.story_view("ada"),
    "instagram.selfcheck": lambda zb: zb.instagram.selfcheck(),
    # options.dry_run: up to the committing click, which is only tried.
    "x.post.dry_run": lambda zb: zb.x.post("hello", dry_run=True),
    "x.schedule_post.dry_run": lambda zb: zb.x.schedule_post("later", "2026-11-05", "14:07", dry_run=True),
    "linkedin.connect.dry_run": lambda zb: zb.linkedin.connect("https://www.linkedin.com/in/ada/", note="Hi Ada", dry_run=True),
    "linkedin.follow.dry_run": lambda zb: zb.linkedin.follow("https://www.linkedin.com/in/ada/", dry_run=True),
    "linkedin.like.dry_run": lambda zb: zb.linkedin.like("https://www.linkedin.com/feed/update/urn:li:activity:1/", dry_run=True),
    "linkedin.comment.dry_run": lambda zb: zb.linkedin.comment("https://www.linkedin.com/feed/update/urn:li:activity:1/", "Great post", dry_run=True),
    "instagram.follow.dry_run": lambda zb: zb.instagram.follow("https://www.instagram.com/ada/", dry_run=True),
    "instagram.like.dry_run": lambda zb: zb.instagram.like("https://www.instagram.com/p/C0ffee/", dry_run=True),
    "instagram.comment.dry_run": lambda zb: zb.instagram.comment("https://www.instagram.com/p/C0ffee/", "So good", dry_run=True),
    "instagram.story_view.dry_run": lambda zb: zb.instagram.story_view("ada", dry_run=True),
    # window_id: the flow runs in that window (page.list).
    "x.post.window": lambda zb: zb.x.post("hello", window_id="window-2"),
    "x.login_check.window": lambda zb: zb.x.login_check(window_id="window-2"),
    "linkedin.connect.window": lambda zb: zb.linkedin.connect("https://www.linkedin.com/in/ada/", note="Hi Ada", dry_run=True, window_id="window-2"),
    "linkedin.message.window": lambda zb: zb.linkedin.message("hi", conversation_url="https://www.linkedin.com/messaging/thread/1/", window_id="window-2"),
    "linkedin.search.window": lambda zb: zb.linkedin.search("zig", search_type="companies", window_id="window-2"),
    "instagram.story_view.window": lambda zb: zb.instagram.story_view("ada", window_id="window-2"),
    "instagram.selfcheck.window": lambda zb: zb.instagram.selfcheck(window_id="window-2"),
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


def test_linkedin_message_needs_exactly_one_target_and_search_type_is_checked():
    zb = ZigBrowser(socket_path="/nonexistent")
    with pytest.raises(ValueError):
        zb.linkedin.message("hi")
    with pytest.raises(ValueError):
        zb.linkedin.message("hi", conversation_url="https://www.linkedin.com/messaging/thread/1/", profile_url="https://www.linkedin.com/in/x/")
    with pytest.raises(ValueError):
        zb.linkedin.search("zig", search_type="groups")


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


def test_token_is_read_from_the_socket_sidecar_when_not_given(mock_uds_server):
    sidecar = Path(mock_uds_server.path + ".token")
    sidecar.write_text("sidecar-t0k")
    try:
        mock_uds_server.set_response(OK)
        with ZigBrowser(socket_path=mock_uds_server.path) as zb:
            zb.page.url()
        assert mock_uds_server.last_request()["auth"] == "sidecar-t0k"
    finally:
        sidecar.unlink()


def test_explicit_token_wins_over_the_sidecar(mock_uds_server):
    sidecar = Path(mock_uds_server.path + ".token")
    sidecar.write_text("sidecar-t0k")
    try:
        mock_uds_server.set_response(OK)
        with ZigBrowser(socket_path=mock_uds_server.path, token="explicit") as zb:
            zb.page.url()
        assert mock_uds_server.last_request()["auth"] == "explicit"
    finally:
        sidecar.unlink()


def test_async_client_reads_the_sidecar(mock_uds_server):
    sidecar = Path(mock_uds_server.path + ".token")
    sidecar.write_text("async-sidecar")
    mock_uds_server.set_response(OK)

    async def run():
        async with AsyncZigBrowser(socket_path=mock_uds_server.path) as zb:
            await zb.call("page.url")

    try:
        asyncio.run(run())
        assert mock_uds_server.last_request()["auth"] == "async-sidecar"
    finally:
        sidecar.unlink()


def test_same_client_rereads_a_rotated_sidecar_on_reconnect(mock_uds_server):
    sidecar = Path(mock_uds_server.path + ".token")
    mock_uds_server.set_response(OK)
    zb = ZigBrowser(socket_path=mock_uds_server.path)
    try:
        sidecar.write_text("first")
        zb.connect()
        zb.page.url()
        assert mock_uds_server.last_request()["auth"] == "first"
        zb.disconnect()

        sidecar.write_text("second")  # browser restarted with a new session token
        zb.connect()
        zb.page.url()
        assert mock_uds_server.last_request()["auth"] == "second"
        zb.disconnect()

        sidecar.unlink()  # restarted without a sidecar: stop sending the old one
        zb.connect()
        zb.page.url()
        assert "auth" not in mock_uds_server.last_request()
        zb.disconnect()
    finally:
        sidecar.unlink(missing_ok=True)


def test_async_client_rereads_a_rotated_sidecar(mock_uds_server):
    sidecar = Path(mock_uds_server.path + ".token")
    mock_uds_server.set_response(OK)
    zb = AsyncZigBrowser(socket_path=mock_uds_server.path)

    async def once():
        await zb.connect()
        await zb.call("page.url")
        await zb.disconnect()

    try:
        sidecar.write_text("a1")
        asyncio.run(once())
        assert mock_uds_server.last_request()["auth"] == "a1"
        sidecar.write_text("a2")
        asyncio.run(once())
        assert mock_uds_server.last_request()["auth"] == "a2"
    finally:
        sidecar.unlink(missing_ok=True)
