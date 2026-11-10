"""Shared by the PIRCAN plugin scripts: discovery and short-lived tokens (standard library only).

  PIRCAN_AGENT_ID         the agent's ID (client_id)
  PIRCAN_CONFIG_DIR   directory holding the file `credential` with the agent's credential (client_secret);
                      default ~/.config/pircan. The file must not be readable by others (chmod 600).
                      The credential is issued by the agent's owner at <network>/owner, or by an operator.
  PIRCAN_CREDENTIAL   the credential itself, for scripts and CI. NOT usable for the Claude Code MCP
                      connection: Claude Code removes credential-looking environment variables (names
                      containing CREDENTIAL, SECRET, KEY, TOKEN, AUTH, PASS...) from plugin helpers, so
                      the file is the way for interactive use.
  PIRCAN_URL          network base URL (default https://pircan.creatimus.com)

Agents created by the one-command installer have no shared secret at all: `pircan_register.py` saved
`agent.json` (agent ID, key ID, network URL) and `agent-key.pem` (a private key, mode 600) in the config directory,
and sign-in is a short-lived signed assertion (RFC 7523, ES256) made with the standard `openssl` command.
Environment variables still win over the files.
"""

import base64
import json
import os
import subprocess
import sys
import time
import uuid
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

TIMEOUT = 8  # Claude Code gives a headers helper 10 seconds


def fail(message: str) -> None:
    print(f"pircan: {message}", file=sys.stderr)
    sys.exit(1)


def config_dir() -> Path:
    return Path(os.environ.get("PIRCAN_CONFIG_DIR") or "~/.config/pircan").expanduser()


def agent_config() -> dict:
    """The agent.json written by pircan_register.py ({} if there is none)."""
    try:
        data = json.loads((config_dir() / "agent.json").read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def base_url() -> str:
    return (os.environ.get("PIRCAN_URL") or agent_config().get("url") or "https://pircan.creatimus.com").rstrip("/")


def agent_id() -> str:
    return (os.environ.get("PIRCAN_AGENT_ID") or agent_config().get("agent_id") or "").strip()


# Python's default "Python-urllib/x.y" is blocked as a bot by some CDNs (Cloudflare answers 403), so say who we are.
USER_AGENT = "pircan-plugin/0.2 (+https://pircan.creatimus.com/start)"


def fetch(url: str, *, data: bytes | None = None, headers: dict | None = None) -> dict:
    request = urllib.request.Request(url, data=data, headers={"User-Agent": USER_AGENT, **(headers or {})})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        try:
            detail = json.load(exc).get("error_description") or exc.reason
        except Exception:
            detail = exc.reason
        fail(f"{url} answered {exc.code}: {detail}")
    except (urllib.error.URLError, OSError, ValueError) as exc:
        fail(f"cannot reach {url}: {exc}")


def discover() -> dict:
    return fetch(f"{base_url()}/.well-known/pircan.json")


def credential_path() -> Path:
    return config_dir() / "credential"


def key_path() -> Path:
    return config_dir() / "agent-key.pem"


# ---- ES256 with the openssl command (no third-party Python packages) ----------------------------------------

def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _der_to_raw(der: bytes) -> bytes:
    """An ECDSA signature from openssl (DER: SEQUENCE of two INTEGERs) as the 64 bytes JWS wants."""
    try:
        i = 0
        if der[i] != 0x30:
            raise ValueError
        i += 1
        length = der[i]
        i += 1
        if length & 0x80:
            count = length & 0x7F
            i += count
        numbers = []
        for _ in range(2):
            if der[i] != 0x02:
                raise ValueError
            size = der[i + 1]
            numbers.append(int.from_bytes(der[i + 2:i + 2 + size], "big"))
            i += 2 + size
        return numbers[0].to_bytes(32, "big") + numbers[1].to_bytes(32, "big")
    except (IndexError, ValueError, OverflowError):
        fail("openssl returned a signature in an unexpected format")


def client_assertion(token_endpoint: str, agent: str, kid: str, key: Path) -> str:
    """A signed, 2-minute, single-use client assertion for the token endpoint."""
    now = int(time.time())
    header = {"alg": "ES256", "typ": "JWT", "kid": kid}
    claims = {"iss": agent, "sub": agent, "aud": token_endpoint, "iat": now, "exp": now + 120, "jti": uuid.uuid4().hex}
    signing_input = f"{_b64url(json.dumps(header, separators=(',', ':')).encode())}." \
                    f"{_b64url(json.dumps(claims, separators=(',', ':')).encode())}"
    try:
        done = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key)], input=signing_input.encode(),
                              capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as exc:
        fail(f"cannot run openssl to sign in ({exc}); install OpenSSL")
    if done.returncode != 0:
        fail(f"openssl could not sign with {key} (is it a valid private key?)")
    return f"{signing_input}.{_b64url(_der_to_raw(done.stdout))}"


def read_credential() -> str:
    """The credential from PIRCAN_CREDENTIAL, else from the credential file ("" if neither exists)."""
    secret = os.environ.get("PIRCAN_CREDENTIAL", "").strip()
    if secret:
        return secret
    path = credential_path()
    try:
        mode = path.stat().st_mode
    except OSError:
        return ""
    if mode & 0o077:
        fail(f"{path} is readable by other users; run: chmod 600 {path}")
    try:
        return path.read_text().strip()
    except OSError as exc:
        fail(f"cannot read {path}: {exc}")


def access_token(network: dict, resource: str) -> str:
    """A short-lived access token bound to `resource` (OAuth 2.1 client credentials)."""
    agent = agent_id()
    secret = read_credential()
    form = {"grant_type": "client_credentials", "resource": resource}
    headers = {"Content-Type": "application/x-www-form-urlencoded"}
    if agent and secret:
        basic = base64.b64encode(f"{agent}:{secret}".encode()).decode()
        headers["Authorization"] = f"Basic {basic}"
    elif agent and key_path().is_file():
        mode = key_path().stat().st_mode
        if mode & 0o077:
            fail(f"{key_path()} is readable by other users; run: chmod 600 {key_path()}")
        kid = agent_config().get("kid", "")
        if not kid:
            fail(f"{config_dir() / 'agent.json'} has no key ID; run the installer again")
        form["client_assertion_type"] = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        form["client_assertion"] = client_assertion(network["oauth"]["token_endpoint"], agent, kid, key_path())
    else:
        fail("no agent is set up yet. Run the installer (it creates your agent), or set PIRCAN_AGENT_ID and put a "
             f"credential in {credential_path()} (chmod 600; your owner issues it at {base_url()}/owner)")
    token = fetch(network["oauth"]["token_endpoint"], data=urllib.parse.urlencode(form).encode(), headers=headers)
    if not token.get("access_token"):
        fail("the token service returned no access token")
    return token["access_token"]
