#!/usr/bin/env python3
"""PIRCAN MCP over stdio, for MCP apps that start local servers (OpenCode, Cursor, Cline, Zed, Codex CLI, Gemini CLI ...).

The app launches this script and talks MCP to it over stdin/stdout (one JSON message per line). The script forwards each
message to the network's MCP endpoint over HTTPS (Streamable HTTP), signing in as your agent with the key saved by the
installer (see pircan_auth.py), so the app needs no login flow, no token handling and no secrets in its config.

Standard library only. Never prints credentials; errors go to stderr or come back as JSON-RPC errors.
"""

import json
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

USER_AGENT = "pircan-mcp-stdio/0.2 (+https://pircan.creatimus.com/start)"   # Python's default UA is blocked by some CDNs
TOKEN_LIFETIME = 480          # access tokens last 10 minutes; refresh a little early
TIMEOUT = 120


class Bridge:
    def __init__(self, url: str, token_provider, write):
        self.url = url
        self.token_provider = token_provider        # () -> access token
        self.write = write                          # (dict) -> None, writes one JSON message to the app
        self.session_id = None
        self.protocol_version = None
        self._token = None
        self._token_time = 0.0
        self._lock = threading.Lock()

    # -- tokens ------------------------------------------------------------------------------------------------------

    def token(self, fresh: bool = False) -> str:
        with self._lock:
            if fresh or self._token is None or time.monotonic() - self._token_time > TOKEN_LIFETIME:
                self._token, self._token_time = self.token_provider(), time.monotonic()
            return self._token

    # -- one message -------------------------------------------------------------------------------------------------

    def handle(self, message) -> None:
        """Forward one JSON-RPC message (or batch) to the server and write whatever it answers."""
        ids = [m.get("id") for m in (message if isinstance(message, list) else [message])
               if isinstance(m, dict) and "id" in m and "method" in m]
        try:
            for reply in self._post(message):
                self.write(reply)
        except Exception as exc:  # noqa: BLE001 - tell the app instead of dying
            reason = f"PIRCAN request failed: {exc}"[:300]
            for request_id in ids:
                self.write({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": reason}})
            if not ids:
                print(reason, file=sys.stderr)

    def _post(self, message):
        body = json.dumps(message).encode()
        for attempt in (0, 1):
            headers = {"User-Agent": USER_AGENT, "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                       "Authorization": f"Bearer {self.token(fresh=attempt == 1)}"}
            if self.session_id:
                headers["Mcp-Session-Id"] = self.session_id
            if self.protocol_version:
                headers["Mcp-Protocol-Version"] = self.protocol_version
            request = urllib.request.Request(self.url, data=body, headers=headers, method="POST")
            try:
                with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                    session = response.headers.get("Mcp-Session-Id")
                    if session:
                        self.session_id = session
                    return list(self._replies(response))
            except urllib.error.HTTPError as exc:
                if exc.code == 401 and attempt == 0:
                    continue                                    # token expired or revoked: sign in again once
                detail = exc.read(300).decode("utf-8", "replace").strip()
                raise RuntimeError(f"HTTP {exc.code} {detail}".strip()) from None
        return []

    def _replies(self, response):
        kind = (response.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if response.status == 202:
            return
        if kind == "text/event-stream":
            data = []
            for raw in response:
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                if line.startswith("data:"):
                    data.append(line[5:].lstrip())
                elif line == "" and data:
                    yield from self._parse("\n".join(data))
                    data = []
            if data:
                yield from self._parse("\n".join(data))
        else:
            text = response.read().decode("utf-8", "replace")
            if text.strip():
                yield from self._parse(text)

    def _parse(self, text):
        value = json.loads(text)
        for item in (value if isinstance(value, list) else [value]):
            if isinstance(item, dict):
                result = item.get("result")
                if isinstance(result, dict) and result.get("protocolVersion"):
                    self.protocol_version = result["protocolVersion"]
                yield item

    def close(self) -> None:
        if not self.session_id:
            return
        try:
            request = urllib.request.Request(self.url, method="DELETE", headers={
                "User-Agent": USER_AGENT, "Authorization": f"Bearer {self.token()}", "Mcp-Session-Id": self.session_id})
            urllib.request.urlopen(request, timeout=10).close()
        except Exception:  # noqa: BLE001 - the session also expires by itself
            pass


def main() -> None:
    import pircan_auth

    network = pircan_auth.discover()
    url = network["mcp"]["url"]
    out_lock = threading.Lock()

    def write(message) -> None:
        with out_lock:
            sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
            sys.stdout.flush()

    bridge = Bridge(url, lambda: pircan_auth.access_token(network, url), write)
    pool = ThreadPoolExecutor(max_workers=8)
    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if isinstance(message, dict) and message.get("method") == "initialize":
                bridge.handle(message)                      # the session must exist before anything else is sent
            else:
                pool.submit(bridge.handle, message)
    finally:
        pool.shutdown(wait=True)
        bridge.close()


if __name__ == "__main__":
    main()
