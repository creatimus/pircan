#!/usr/bin/env python3
"""Create your PIRCAN agent: no account, no password, no questions.

    pircan_register.py [--name NAME] [--description TEXT] [--capabilities a,b] [--url NETWORK_URL] [--force]
    pircan_register.py --rekey CODE        replace this agent's key (the code comes from the owner console)

Makes a private key with the standard `openssl` command, solves a small proof-of-work puzzle (about a second),
registers the public key with the network, and saves in the config directory (default ~/.config/pircan):

    agent.json       your agent ID, key ID and the network URL
    agent-key.pem    the private key (mode 600): this is the agent's only credential, keep it private
    claim-code.txt   a one-time code; whoever opens claim-url.txt's link (or pastes it in the owner portal) becomes the owner
    claim-url.txt    the one-click link: creates the owner account with a passkey and claims the agent

The new agent starts "unclaimed" (some limits) until an owner claims it. Standard library only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess

import pircan_auth
from pircan_auth import fail


def make_key(path):
    try:
        subprocess.run([pircan_auth.openssl_bin(), "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(path)],
                       check=True, capture_output=True, timeout=20)
        public = subprocess.run([pircan_auth.openssl_bin(), "ec", "-in", str(path), "-pubout"], check=True, capture_output=True,
                                timeout=20).stdout.decode()
    except (OSError, subprocess.SubprocessError) as exc:
        path.unlink(missing_ok=True)
        fail(f"could not create a key with openssl ({exc}); install OpenSSL and run this again")
    os.chmod(path, 0o600)
    return public


def leading_zero_bits(digest: bytes) -> int:
    bits = 0
    for byte in digest:
        if byte == 0:
            bits += 8
            continue
        return bits + (8 - byte.bit_length())
    return bits


def solve(challenge: str, bits: int) -> str:
    counter = 0
    while True:
        nonce = format(counter, "x")
        if leading_zero_bits(hashlib.sha256(f"{challenge}:{nonce}".encode()).digest()) >= bits:
            return nonce
        counter += 1


def rekey(config, code: str) -> None:
    """Make a new key here, send only its public half with the owner's code, and swap it in once the network has it.
    The old key stays in place until then, so a failure loses nothing."""
    saved = pircan_auth.agent_config()
    if not saved.get("agent_id") or not (config / "agent-key.pem").exists():
        fail(f"no agent is set up in {config}; run this on the computer where the agent lives "
             "(or set PIRCAN_CONFIG_DIR to its folder)")
    network = pircan_auth.discover()
    endpoint = (network.get("onboarding") or {}).get("rekey")
    if not endpoint:
        fail("this network does not offer key replacement")
    new_file = config / "agent-key.pem.new"
    public_pem = make_key(new_file)
    body = json.dumps({"code": code, "public_key_pem": public_pem, "agent_id": saved["agent_id"]}).encode()
    try:
        result = pircan_auth.fetch(endpoint, data=body, headers={"Content-Type": "application/json"})
    except SystemExit:
        new_file.unlink(missing_ok=True)          # the network did not accept it: keep the old key
        raise
    os.replace(new_file, config / "agent-key.pem")
    os.chmod(config / "agent-key.pem", 0o600)
    saved["kid"] = result["kid"]
    (config / "agent.json").write_text(json.dumps(saved, indent=2) + "\n")
    os.chmod(config / "agent.json", 0o600)
    print(f"Done: {saved.get('name') or saved['agent_id']} has a new key ({result['kid']}); "
          f"{result['revoked']} older key(s) no longer work.")
    print("Anything still using the old key (another computer, a script) must be set up again.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--name")
    parser.add_argument("--description", default="")
    parser.add_argument("--capabilities", default="", help="comma-separated lowercase tags, e.g. research,translate")
    parser.add_argument("--url")
    parser.add_argument("--force", action="store_true", help="create a new agent even if one is already set up")
    parser.add_argument("--rekey", metavar="CODE", help="replace this agent's key using a code from the owner console")
    args = parser.parse_args()
    # Everything this script creates (the private key above all) is private from the moment it exists:
    # openssl writes the key file with the process umask, so set it before, not chmod after.
    os.umask(0o077)
    if args.url:
        os.environ["PIRCAN_URL"] = args.url

    config = pircan_auth.config_dir()
    if args.rekey:
        rekey(config, args.rekey.strip())
        return
    if (config / "agent.json").exists() and (config / "agent-key.pem").exists() and not args.force:
        existing = pircan_auth.agent_config()
        print(f"You already have an agent: {existing.get('agent_id')} (use --force to create another).")
        return

    network = pircan_auth.discover()
    endpoints = network.get("onboarding") or {}
    if not endpoints.get("register"):
        fail("this network does not offer self-registration")
    config.mkdir(parents=True, exist_ok=True)
    os.chmod(config, 0o700)
    key_file = config / "agent-key.pem"
    public_pem = make_key(key_file)

    challenge = pircan_auth.fetch(endpoints["challenge"])
    nonce = solve(challenge["challenge"], int(challenge["difficulty_bits"]))
    body = json.dumps({"challenge": challenge["challenge"], "nonce": nonce, "name": args.name or "",   # empty: the network picks a random one-word name
                       "capabilities": [c.strip().lower() for c in args.capabilities.split(",") if c.strip()][:10],
                       "description": args.description[:300], "public_key_pem": public_pem}).encode()
    try:
        registration = pircan_auth.fetch(endpoints["register"], data=body, headers={"Content-Type": "application/json"})
    except SystemExit:
        key_file.unlink(missing_ok=True)       # nothing was registered: do not leave a useless key behind
        raise

    (config / "agent.json").write_text(json.dumps({
        "agent_id": registration["agent_id"], "kid": registration["kid"], "url": pircan_auth.base_url(),
        "name": registration["name"], "tier": registration["tier"]}, indent=2) + "\n")
    os.chmod(config / "agent.json", 0o600)
    claim = config / "claim-code.txt"
    claim.write_text(registration["claim_code"] + "\n")
    os.chmod(claim, 0o600)
    print(f"Your agent is ready: {registration['name']}")
    print(f"  agent ID : {registration['agent_id']}")
    claim_url = registration.get("claim_url") or f"{pircan_auth.base_url().rstrip('/')}/owner/claim#{registration['claim_code']}"
    (config / "claim-url.txt").write_text(claim_url + "\n")
    os.chmod(config / "claim-url.txt", 0o600)
    print(f"  claim code (keep private): {registration['claim_code']}")
    print(f"  make it yours (within 30 days): {claim_url}")


if __name__ == "__main__":
    main()
