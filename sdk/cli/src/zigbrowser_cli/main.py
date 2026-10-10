import json
import os

import click
from zigbrowser import ZigBrowser
from zigbrowser.errors import AutomationError


@click.group()
def cli():
    pass


@cli.command(name="call")
@click.argument("method")
@click.option("--param", multiple=True, help="key=value parameter pairs")
def call_method(method, param):
    params = {}
    for p in param:
        key, _, value = p.partition("=")
        params[key] = value
    _execute(method, params)


@cli.command(name="trace")
@click.argument("trace_id")
def trace_lookup(trace_id):
    socket_path = os.environ.get("ZIGBROWSER_SOCKET")
    if not socket_path:
        click.echo("Error: ZIGBROWSER_SOCKET not set", err=True)
        raise SystemExit(1)

    try:
        with ZigBrowser(socket_path=socket_path) as zb:
            result = zb.call("telemetry.query", {"trace_id": trace_id})
    except ConnectionError as e:
        click.echo(f"Error: {e}", err=True)
        raise SystemExit(1)

    spans = result.get("spans", [])
    if not spans:
        click.echo(f"Trace {trace_id} not found")
        return

    for span in spans:
        attrs = span.get("attributes", {})
        indent = "  " if span["name"] != "automation.command" else ""
        error = attrs.get("automation.error", "")
        method_name = attrs.get("rpc.method", span["name"])
        duration = span.get("duration_ms", 0)
        line = f"{indent}{span['name']} ({method_name}) — {duration}ms"
        if error:
            line += f" — {error}"
        click.echo(line)


def _execute(method, params):
    socket_path = os.environ.get("ZIGBROWSER_SOCKET")
    if not socket_path:
        click.echo("Error: ZIGBROWSER_SOCKET not set", err=True)
        raise SystemExit(1)

    try:
        with ZigBrowser(socket_path=socket_path) as zb:
            result = zb.call(method, params)
            click.echo(json.dumps(result, indent=2))
    except AutomationError as e:
        click.echo(f"Error: {e.error_name} (code {e.code})", err=True)
        if e.trace_id:
            click.echo(f"  trace_id: {e.trace_id}", err=True)
            click.echo(
                f"  Debug: zigbrowser-cli trace {e.trace_id}", err=True
            )
        raise SystemExit(1)
    except ConnectionError as e:
        click.echo(
            f"Error: Cannot connect to zigBrowser. Is it running with --automation-api? ({e})",
            err=True,
        )
        raise SystemExit(1)
