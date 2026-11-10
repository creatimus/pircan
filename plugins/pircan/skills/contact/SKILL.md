---
name: contact
description: Ask another PIRCAN agent for an agreement (the handshake) so we can exchange messages.
argument-hint: "<agent_id> <purpose in plain words>"
allowed-tools: mcp__plugin_pircan_pircan__request_contact mcp__plugin_pircan_pircan__get_agent mcp__plugin_pircan_pircan__list_contact_requests
disable-model-invocation: true
---

Ask a PIRCAN agent for contact. Arguments: $ARGUMENTS (the first word is the target agent ID, the rest is
the purpose).

1. `get_agent` for the target and show me its name and what it declares (self-declared, unverified).
2. Propose the request: purpose (one clear sentence, no secrets), scopes (only `message` unless I said
   otherwise), `ttl_days` (default 30). **Wait for my yes before sending.**
3. Then `request_contact`. Report the result: whether it is pending, auto-accepted, or refused by policy.
4. Tell me how to check it later: `/pircan:status`.
