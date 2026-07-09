from click.testing import CliRunner
from zigbrowser_cli.main import cli


def test_cli_sends_command(mock_uds_server, monkeypatch):
    monkeypatch.setenv("ZIGBROWSER_SOCKET", mock_uds_server.path)
    mock_uds_server.set_response(
        {"jsonrpc": "2.0", "result": {"ok": True}, "id": 1}
    )

    runner = CliRunner()
    result = runner.invoke(cli, ["call", "dom.click", "--param", "selector=role=button[name='OK']"])

    assert result.exit_code == 0
    assert '"ok": true' in result.output


def test_cli_shows_error_with_trace_id(mock_uds_server, monkeypatch):
    monkeypatch.setenv("ZIGBROWSER_SOCKET", mock_uds_server.path)
    mock_uds_server.set_response({
        "jsonrpc": "2.0",
        "error": {
            "code": -32001,
            "message": "element_not_found",
            "data": {"trace_id": "t-abc123"},
        },
        "id": 1,
    })

    runner = CliRunner()
    result = runner.invoke(cli, ["call", "dom.click", "--param", "selector=role=button"])

    assert result.exit_code == 1
    assert "element_not_found" in result.output
    assert "t-abc123" in result.output
    assert "zigbrowser-cli --trace t-abc123" in result.output


def test_cli_no_socket_env():
    runner = CliRunner()
    result = runner.invoke(cli, ["call", "dom.click", "--param", "selector=x"], env={})

    assert result.exit_code == 1
    assert "ZIGBROWSER_SOCKET" in result.output


def test_trace_displays_span_tree(mock_uds_server, monkeypatch):
    monkeypatch.setenv("ZIGBROWSER_SOCKET", mock_uds_server.path)
    mock_uds_server.set_response({
        "jsonrpc": "2.0",
        "result": {
            "spans": [
                {
                    "name": "automation.command",
                    "trace_id": "t-abc",
                    "duration_ms": 1234,
                    "attributes": {
                        "rpc.method": "dom.click",
                        "result.status": "error",
                        "automation.error": "element_not_found",
                    },
                },
                {
                    "name": "automation.selector.resolve",
                    "trace_id": "t-abc",
                    "duration_ms": 1200,
                    "attributes": {
                        "selector.kind": "role",
                        "selector.match_count": 0,
                    },
                },
            ],
        },
        "id": 1,
    })

    runner = CliRunner()
    result = runner.invoke(cli, ["trace", "t-abc"])

    assert result.exit_code == 0
    assert "automation.command" in result.output
    assert "dom.click" in result.output
    assert "element_not_found" in result.output
    assert "1234ms" in result.output


def test_trace_not_found(mock_uds_server, monkeypatch):
    monkeypatch.setenv("ZIGBROWSER_SOCKET", mock_uds_server.path)
    mock_uds_server.set_response(
        {"jsonrpc": "2.0", "result": {"spans": []}, "id": 1}
    )

    runner = CliRunner()
    result = runner.invoke(cli, ["trace", "t-nonexistent"])

    assert "not found" in result.output
