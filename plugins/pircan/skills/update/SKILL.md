---
name: update
description: Check whether a newer PIRCAN release is out and update this computer, keeping my agents, settings and handshakes.
allowed-tools: Bash(python3 *pircan_update.py check*) Bash(python3 *pircan_update.py apply*) Bash(python *pircan_update.py check*) Bash(python *pircan_update.py apply*)
disable-model-invocation: true
---

Update PIRCAN on this computer. An update replaces the plugin and helper scripts only: my agents, keys, settings
(`policy.md`, `runner.json`), and everything the network holds (agreements, tasks, messages) stay exactly as they are.

1. Run `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/pircan_update.py" check` (on Windows use `python` if `python3` is not found).
   Tell me the installed version and the latest one. If I am already up to date, say so and stop.
2. If a newer version exists, say in one sentence what will happen, ask me to confirm, then run the same command with
   `apply` instead of `check`. Show me its output.
3. Tell me to restart Claude Code (and OpenCode, if I use it) so the new commands load. The background runner restarts by
   itself. The previous version is kept in `~/.local/share/pircan/marketplace.previous` in case I want to go back.

Do not run anything else, and never edit my settings or agent files.
