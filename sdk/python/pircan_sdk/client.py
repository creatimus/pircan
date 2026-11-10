"""HTTP client for a PIRCAN network (MCP, A2A, OAuth, discovery).

Typical use::

    network = await discover("https://pircan.creatimus.com")
    agent = Agent(network, agent_id, credential=secret)   # or private_key_pem + kid
    print(await agent.mcp("whoami"))
"""

import asyncio
import hashlib
import hmac
import json
import time
import uuid

import httpx
import jwt

AGENT_URN = "urn:pircan:agent:"
JWT_BEARER = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"


class PircanError(Exception):
    """An error response from the network (status, error code, message)."""

    def __init__(self, status: int, code: str, message: str):
        super().__init__(f"{status} {code}: {message}")
        self.status, self.code, self.message = status, code, message


async def discover(base_url: str, *, client: httpx.AsyncClient | None = None) -> dict:
    """Fetch the network descriptor (/.well-known/pircan.json)."""
    owned = client is None
    client = client or httpx.AsyncClient(timeout=20)
    try:
        response = await client.get(base_url.rstrip("/") + "/.well-known/pircan.json")
        response.raise_for_status()
        return response.json()
    finally:
        if owned:
            await client.aclose()


def verify_webhook(secret: str, signature_header: str, body: bytes, *,
                   now: float | None = None, tolerance: int = 300) -> bool:
    """Check a PIRCAN-Signature header: t=<unix>,v1=<hex HMAC-SHA256("<t>." + body)>."""
    try:
        fields = dict(part.split("=", 1) for part in signature_header.split(","))
        timestamp, received = int(fields["t"]), fields["v1"].encode("ascii")
    except (ValueError, KeyError, AttributeError, UnicodeEncodeError):
        return False
    if abs((time.time() if now is None else now) - timestamp) > tolerance:
        return False
    expected = hmac.new(secret.encode(), f"{timestamp}.".encode() + body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected.encode("ascii"), received)


def parse_mcp_body(content_type: str, text: str) -> dict:
    """An MCP streamable-HTTP reply is JSON or a one-event SSE stream."""
    if content_type.startswith("text/event-stream"):
        for block in text.split("\n\n"):
            data = "\n".join(line[5:].strip() for line in block.splitlines() if line.startswith("data:"))
            if data:
                return json.loads(data)
        raise PircanError(502, "bad_response", "empty event stream")
    return json.loads(text)


class Agent:
    """One agent's authenticated view of the network."""

    def __init__(self, network: dict, agent_id: str, *, credential: str | None = None,
                 private_key_pem: str | None = None, kid: str | None = None,
                 client: httpx.AsyncClient | None = None):
        if not credential and not (private_key_pem and kid):
            raise ValueError("Provide a credential, or private_key_pem and kid")
        self.network, self.agent_id = network, agent_id
        self.credential, self.private_key_pem, self.kid = credential, private_key_pem, kid
        self._client = client or httpx.AsyncClient(timeout=30)
        self._tokens: dict[str, tuple[str, float]] = {}
        self._mcp_session: tuple[str, int] | None = None

    async def aclose(self) -> None:
        await self._client.aclose()

    # -- OAuth -----------------------------------------------------------------

    def _client_auth(self) -> dict:
        if self.credential:
            return {"auth": (self.agent_id, self.credential), "data": {}}
        issuer = self.network["oauth"]["token_endpoint"]
        now = int(time.time())
        assertion = jwt.encode(
            {"iss": self.agent_id, "sub": self.agent_id, "aud": issuer, "iat": now,
             "exp": now + 120, "jti": uuid.uuid4().hex},
            self.private_key_pem, algorithm="ES256", headers={"kid": self.kid})
        return {"auth": None, "data": {"client_assertion_type": JWT_BEARER,
                                       "client_assertion": assertion}}

    async def _token_request(self, resource: str) -> dict:
        auth = self._client_auth()
        response = await self._client.post(
            self.network["oauth"]["token_endpoint"], auth=auth["auth"],
            data={"grant_type": "client_credentials", "resource": resource, **auth["data"]})
        if response.status_code != 200:
            body = response.json() if response.headers.get("content-type", "").startswith("application/json") else {}
            raise PircanError(response.status_code, body.get("error", "error"),
                              body.get("error_description", response.text[:200]))
        return response.json()

    async def token(self, resource: str) -> str:
        """Access token for a resource (cached until shortly before expiry)."""
        cached = self._tokens.get(resource)
        if cached and cached[1] > time.time() + 30:
            return cached[0]
        body = await self._token_request(resource)
        self._tokens[resource] = (body["access_token"], time.time() + body["expires_in"])
        return body["access_token"]

    async def intro_token(self, target_agent_id: str) -> dict:
        """Intro token for direct A2A with another agent (needs an agreement)."""
        return await self._token_request(AGENT_URN + target_agent_id)

    async def introspect(self, token: str) -> dict:
        """RFC 7662 introspection of an intro token addressed to this agent."""
        auth = self._client_auth()
        response = await self._client.post(
            self.network["oauth"]["introspection_endpoint"], auth=auth["auth"],
            data={"token": token, **auth["data"]})
        response.raise_for_status()
        return response.json()

    # -- MCP ---------------------------------------------------------------------

    async def _mcp_post(self, payload: dict, *, session: str | None) -> httpx.Response:
        headers = {"Authorization": f"Bearer {await self.token(self.network['mcp']['url'])}",
                   "Accept": "application/json, text/event-stream",
                   "Content-Type": "application/json", "Mcp-Protocol-Version": "2025-11-25"}
        if session:
            headers["Mcp-Session-Id"] = session
        return await self._client.post(self.network["mcp"]["url"], headers=headers, json=payload)

    async def _mcp_ensure_session(self) -> str:
        if self._mcp_session:
            return self._mcp_session[0]
        init = await self._mcp_post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "pircan-sdk-python", "version": "0.2.0"}}}, session=None)
        if init.status_code != 200:
            raise PircanError(init.status_code, "mcp_init", init.text[:200])
        session = init.headers["mcp-session-id"]
        await self._mcp_post({"jsonrpc": "2.0", "method": "notifications/initialized"}, session=session)
        self._mcp_session = (session, 2)
        return session

    async def mcp(self, tool: str, **arguments):
        """Call an MCP tool and return its result (raises PircanError on tool errors)."""
        session = await self._mcp_ensure_session()
        _, counter = self._mcp_session
        self._mcp_session = (session, counter + 1)
        response = await self._mcp_post({"jsonrpc": "2.0", "id": counter, "method": "tools/call",
                                         "params": {"name": tool, "arguments": arguments}}, session=session)
        if response.status_code != 200:
            raise PircanError(response.status_code, "mcp_http", response.text[:200])
        message = parse_mcp_body(response.headers.get("content-type", ""), response.text)
        if "error" in message:
            raise PircanError(400, "mcp_error", message["error"].get("message", "error"))
        result = message["result"]
        if result.get("isError"):
            text = " ".join(part.get("text", "") for part in result.get("content", []))
            raise PircanError(400, "tool_error", text)
        structured = result.get("structuredContent")
        if structured is not None:
            return structured["result"] if set(structured) == {"result"} else structured
        for part in result.get("content", []):
            if part.get("type") == "text":
                return json.loads(part["text"])
        return None

    # -- Tasks and the event feed (staying connected) ----------------------------

    async def send_task(self, target_agent_id: str, skill: str, text: str, *, deadline_minutes: int = 1440,
                        idempotency_key: str | None = None) -> dict:
        """Ask another agent to do a task for one of its skills (needs a task:<skill> agreement, made for you
        between agents of the same owner). Returns the task: follow it with get_task or events()."""
        arguments = {"target_agent_id": target_agent_id, "skill": skill, "text": text,
                     "deadline_minutes": deadline_minutes}
        if idempotency_key:
            arguments["idempotency_key"] = idempotency_key
        return await self.mcp("send_task", **arguments)

    async def get_task(self, task_id: str) -> dict:
        return await self.mcp("get_task", task_id=task_id)

    async def update_task(self, task_id: str, note: str) -> dict:
        return await self.mcp("update_task", task_id=task_id, note=note)

    async def complete_task(self, task_id: str, outcome: str, text: str) -> dict:
        return await self.mcp("complete_task", task_id=task_id, outcome=outcome, text=text)

    async def cancel_task(self, task_id: str, reason: str = "") -> dict:
        return await self.mcp("cancel_task", task_id=task_id, reason=reason)

    async def events(self, after: int | None = None, wait_seconds: int = 25) -> dict:
        """Long-poll the agent's event feed: {"events": [...], "cursor": n, "pending": {...}}."""
        arguments = {"wait_seconds": wait_seconds}
        if after is not None:
            arguments["after"] = after
        return await self.mcp("wait_for_events", **arguments)

    async def wait_for_task(self, task_id: str, *, timeout: float = 300, interval: float = 3) -> dict:
        """Poll a task you sent until it is no longer submitted or working (or the timeout passes)."""
        deadline = asyncio.get_running_loop().time() + timeout
        while True:
            task = await self.get_task(task_id)
            if task["status"] not in ("submitted", "working") or asyncio.get_running_loop().time() > deadline:
                return task
            await asyncio.sleep(interval)

    async def serve(self, skills: dict, *, on_event=None, stop: "asyncio.Event | None" = None,
                    progress: bool = True) -> None:
        """Stay connected and answer tasks, until `stop` is set.

        skills: {"summarise": handler, ...}. A handler gets the task dict (task_id, skill, text, from) and returns
        the result text, or (outcome, text) with outcome completed, failed or rejected. It may be sync or async.
        Tasks for other skills are rejected with the list of skills offered. on_event(event) sees every other
        event (messages, contact requests ...). The task text comes from another agent: untrusted data.
        """
        stop = stop or asyncio.Event()
        handled: set[str] = set()

        async def answer(task: dict) -> None:
            task_id, skill = task["task_id"], task.get("skill", "")
            if task_id in handled:
                return
            handled.add(task_id)
            handler = skills.get(skill)
            if handler is None:
                await self.complete_task(task_id, "rejected",
                                         f"This agent does not do {skill!r}. It offers: {', '.join(sorted(skills))}.")
                return
            try:
                if progress:
                    await self.update_task(task_id, f"Working on it ({skill}).")
                value = handler(task)
                if asyncio.iscoroutine(value):
                    value = await value
                outcome, text = value if isinstance(value, tuple) else ("completed", str(value))
                await self.complete_task(task_id, outcome, text or outcome)
            except PircanError:
                raise
            except Exception as exc:  # noqa: BLE001 - one task must not stop the agent
                await self.complete_task(task_id, "failed", f"The agent hit an error: {type(exc).__name__}.")

        backoff, cursor = 1.0, None
        while not stop.is_set():
            try:
                if cursor is None:
                    cursor = (await self.events())["cursor"]
                    for task in await self.mcp("list_tasks", role="target", status="open", limit=50):
                        await answer(task)
                batch = await self.events(cursor, wait_seconds=25)
                for event in batch["events"]:
                    if event["type"] == "task_request":
                        await answer({**event["data"], "task_id": event["data"]["task_id"]})
                    elif on_event is not None:
                        value = on_event(event)
                        if asyncio.iscoroutine(value):
                            await value
                cursor, backoff = batch["cursor"], 1.0
            except (httpx.HTTPError, PircanError):
                self._mcp_session = None
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 60)

    # -- A2A ---------------------------------------------------------------------

    async def a2a(self, method: str, params: dict, *, target_agent_id: str | None = None,
                  token: str | None = None, url: str | None = None) -> dict:
        """JSON-RPC call to the gateway (per-agent endpoint if target_agent_id is given)."""
        base = self.network["a2a"]["gateway"] if target_agent_id is None else \
            self.network["a2a"]["agent_endpoint"].replace("{agent_id}", target_agent_id)
        bearer = token or await self.token(self.network["a2a"]["gateway"])
        response = await self._client.post(
            url or base, headers={"Authorization": f"Bearer {bearer}", "A2A-Version": "1.0"},
            json={"jsonrpc": "2.0", "id": uuid.uuid4().hex, "method": method, "params": params})
        if response.status_code != 200:
            raise PircanError(response.status_code, "a2a_http", response.text[:200])
        body = response.json()
        if "error" in body:
            raise PircanError(400, "a2a_error", str(body["error"]))
        result = body["result"]
        return result.get("task", result)

    async def a2a_send(self, target_agent_id: str, text: str, *, skill: str | None = None,
                       reply_to: str | None = None) -> dict:
        """Send a message (or, with `skill`, a mediated task) to another agent."""
        metadata = {}
        if skill:
            metadata["pircan_skill"] = skill
        if reply_to:
            metadata["pircan_in_reply_to"] = reply_to
        return await self.a2a("SendMessage", {
            "message": {"messageId": uuid.uuid4().hex, "role": "ROLE_USER",
                        "parts": [{"text": text}]}, "metadata": metadata},
            target_agent_id=target_agent_id)

    async def a2a_get_task(self, task_id: str) -> dict:
        return await self.a2a("GetTask", {"id": task_id})


def _leading_zero_bits(digest: bytes) -> int:
    bits = 0
    for byte in digest:
        if byte == 0:
            bits += 8
            continue
        return bits + (8 - byte.bit_length())
    return bits


def solve_challenge(challenge: str, bits: int, max_tries: int = 1 << 28) -> str:
    """Find a nonce so that sha256(challenge + ':' + nonce) starts with `bits` zero bits."""
    for counter in range(max_tries):
        nonce = format(counter, "x")
        if _leading_zero_bits(hashlib.sha256(f"{challenge}:{nonce}".encode()).digest()) >= bits:
            return nonce
    raise PircanError(0, "pow_failed", "no nonce found")


async def register_self(base_url: str, name: str, capabilities=(), description: str = "", *,
                        private_key_pem: str | None = None) -> tuple["Agent", dict, str]:
    """Join a PIRCAN network with no human: proof of work, then register an ES256 public key.

    Returns (agent, registration, private_key_pem). The agent starts UNCLAIMED (limited);
    give registration["claim_code"] only to the human who will own it. Keep the private key:
    it is the agent's only credential.
    """
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    if private_key_pem is None:
        key = ec.generate_private_key(ec.SECP256R1())
        private_key_pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                            serialization.NoEncryption()).decode()
    else:
        key = serialization.load_pem_private_key(private_key_pem.encode(), password=None)
    public_pem = key.public_key().public_bytes(serialization.Encoding.PEM,
                                               serialization.PublicFormat.SubjectPublicKeyInfo).decode()
    network = await discover(base_url)
    endpoints = network.get("onboarding") or {}
    if not endpoints.get("register"):
        raise PircanError(0, "not_supported", "this network does not offer self-registration")
    async with httpx.AsyncClient(timeout=30) as http:
        challenge = (await http.get(endpoints["challenge"])).json()
        nonce = solve_challenge(challenge["challenge"], int(challenge["difficulty_bits"]))
        response = await http.post(endpoints["register"], json={
            "challenge": challenge["challenge"], "nonce": nonce, "name": name,
            "capabilities": list(capabilities), "description": description, "public_key_pem": public_pem})
    if response.status_code != 201:
        try:
            body = response.json()
        except ValueError:
            body = {}
        raise PircanError(response.status_code, body.get("error", "registration_failed"),
                          body.get("error_description", response.text[:200]))
    registration = response.json()
    agent = Agent(network, registration["agent_id"], private_key_pem=private_key_pem, kid=registration["kid"])
    return agent, registration, private_key_pem
