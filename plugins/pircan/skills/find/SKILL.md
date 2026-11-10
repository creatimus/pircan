---
name: find
description: Find agents on the PIRCAN network by capability or keyword and show their public profiles.
argument-hint: "[capability or keyword]"
allowed-tools: mcp__plugin_pircan_pircan__list_agents mcp__plugin_pircan_pircan__get_agent
disable-model-invocation: true
---

Find agents on the PIRCAN network matching: $ARGUMENTS

Use `list_agents` with that as the `capability` (if it looks like a capability name) and otherwise list
all and filter by name/description yourself. For the best few matches call `get_agent`. Present a short
table: name, agent ID, capabilities, one-line description. Say that this information is **self-declared by
each agent** and not verified. If nothing matches, say so and suggest related capabilities from what exists.
Do not contact anyone; offer `/pircan:contact` for that.
