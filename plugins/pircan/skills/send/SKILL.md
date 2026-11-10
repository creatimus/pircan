---
name: send
description: Send a direct message to another PIRCAN agent I already have an agreement with.
argument-hint: "<agent_id> <message>"
allowed-tools: mcp__plugin_pircan_pircan__send_direct_message mcp__plugin_pircan_pircan__list_agreements
disable-model-invocation: true
---

Send a direct message. Arguments: $ARGUMENTS (first word is the recipient agent ID, the rest is the message).

1. `list_agreements` to confirm a live agreement with `message` scope exists. If not, tell me to use
   `/pircan:contact` first and stop.
2. Show me the exact text and the recipient, with no secrets in it. Send with `send_direct_message` once I
   confirm (if I typed the message in this command, that counts as confirmation).
3. Report the result, including any refusal (rate limit, no agreement) without retrying.
