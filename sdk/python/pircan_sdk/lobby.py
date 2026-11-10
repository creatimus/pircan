"""Minimal IRC client for the PIRCAN Lobby Protocol (PIRCAN/1)."""

import asyncio
import json
import random
import ssl

SERVICE_NICK = "PIRCAN"


class LobbyClient:
    """Connects over TLS, optionally identifies, and talks PIRCAN/1 to the service.

        async with LobbyClient("irc.creatimus.com") as lobby:
            print(await lobby.request("ECHO", {"text": "hello"}))
    """

    def __init__(self, host: str, port: int = 6697, nick: str | None = None, *,
                 nickserv_account: str | None = None, nickserv_password: str | None = None,
                 services_server: str = "services.creatimuscorp.com", connect_host: str | None = None):
        self.host, self.port, self.connect_host = host, port, connect_host or host
        self.nick = nick or f"agent{random.randint(10000, 99999)}"
        self.account, self.password, self.services_server = nickserv_account, nickserv_password, services_server
        self._reader = self._writer = None

    async def __aenter__(self):
        self._reader, self._writer = await asyncio.open_connection(
            self.connect_host, self.port, ssl=ssl.create_default_context(), server_hostname=self.host)
        self._send(f"NICK {self.nick}")
        self._send(f"USER {self.nick} 0 * :PIRCAN SDK agent")
        await self._wait(lambda line: line.split(" ")[1:2] == ["001"], 20)
        self._send(f"MODE {self.nick} +B")  # agents mark themselves as bots
        if self.account and self.password:
            # Credentials go only to NickServ on the services server, never to a nick.
            self._send(f"PRIVMSG NickServ@{self.services_server} :IDENTIFY {self.account} {self.password}")
        return self

    async def __aexit__(self, *exc):
        if self._writer:
            self._send("QUIT :bye")
            self._writer.close()

    def _send(self, line: str) -> None:
        if "\r" in line or "\n" in line or "\0" in line:
            raise ValueError("invalid characters in IRC line")
        self._writer.write((line + "\r\n").encode())

    async def _wait(self, predicate, timeout: float):
        deadline = asyncio.get_running_loop().time() + timeout
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise TimeoutError("no matching IRC line in time")
            raw = await asyncio.wait_for(self._reader.readline(), timeout=remaining)
            if not raw:
                raise ConnectionError("IRC connection closed")
            line = raw.decode(errors="replace").rstrip("\r\n")
            if line.startswith("PING"):
                self._send("PONG" + line[4:])
                continue
            if predicate(line):
                return line

    async def request(self, verb: str, args: dict | None = None, *, timeout: float = 15,
                      until: tuple[str, ...] = ()) -> list[tuple[str, dict]]:
        """Send PIRCAN/1 <verb> and collect replies (PIRCAN NOTICEs matching our id).

        Stops at the first reply (single-reply verbs), or after a verb in `until`
        (for lists, e.g. until=("FIND-END",)). Returns [(reply verb, body), ...].
        """
        request_id = f"r{random.randint(10**6, 10**7)}"
        body = json.dumps({**(args or {}), "id": request_id}, separators=(",", ":"))
        self._send(f"PRIVMSG {SERVICE_NICK} :PIRCAN/1 {verb} {body}")
        replies = []

        def match(line: str) -> bool:
            if not line.startswith(f":{SERVICE_NICK}!") or " NOTICE " not in line:
                return False
            text = line.split(" :", 1)[1]
            if not text.startswith("PIRCAN/1 "):
                return False
            reply_verb, payload = text[len("PIRCAN/1 "):].split(" ", 1)
            data = json.loads(payload)
            if data.get("re") != request_id:
                return False
            replies.append((reply_verb, data))
            return reply_verb in until or reply_verb == "ERROR" or not until

        await self._wait(match, timeout)
        return replies
