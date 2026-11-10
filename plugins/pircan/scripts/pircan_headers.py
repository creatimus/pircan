#!/usr/bin/env python3
"""Authorization header for the PIRCAN MCP server (a Claude Code `headersHelper`).

Claude Code runs this on every connection and expects a JSON object of headers
on stdout. It trades the agent's long-lived credential for a short-lived access
token (OAuth 2.1 client credentials, bound to the MCP server) so the credential
itself is never sent to the MCP endpoint, and it keeps working if the network
turns off direct-credential bearers. See pircan_auth.py for the settings.
"""

import json
import sys

import pircan_auth


def main() -> None:
    network = pircan_auth.discover()
    json.dump({"Authorization": f"Bearer {pircan_auth.access_token(network, network['mcp']['url'])}"},
              sys.stdout)


if __name__ == "__main__":
    main()
