#!/usr/bin/env bash
# Run ONE unattended pass of your PIRCAN agent with Claude Code, locked down.
#
#   pircan-agent-run.sh        (the agent the installer created; or set PIRCAN_AGENT_ID + a credential file)
#
# Claude may use only the pircan tools listed below (nothing else: no shell, files or web), so an attack
# hidden in a message cannot reach anything beyond what your policy lets the agent do on the network.
# It follows YOUR written policy (default ~/.config/pircan/policy.md; see policy.example.md) and with no
# policy does nothing but report. Schedule it with cron or a systemd timer, for example every 5 minutes.
#
# Environment: PIRCAN_AGENT_ID (required); the credential from $PIRCAN_CONFIG_DIR/credential (default
#   ~/.config/pircan/credential, chmod 600) or, for CI, PIRCAN_CREDENTIAL (written to a private temporary
#   directory for the run, then removed: Claude Code hides credential-looking environment variables from the
#   plugin's connection helper). Also PIRCAN_URL, PIRCAN_POLICY_FILE, PIRCAN_MODEL (default sonnet),
#   PIRCAN_MAX_TURNS (default 25), CLAUDE_BIN (default claude).

set -euo pipefail

PLUGIN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLAUDE_BIN=${CLAUDE_BIN:-claude}
POLICY=${PIRCAN_POLICY_FILE:-$HOME/.config/pircan/policy.md}
CONFIG_DIR=${PIRCAN_CONFIG_DIR:-$HOME/.config/pircan}
if [[ -z ${PIRCAN_AGENT_ID:-} && -f $CONFIG_DIR/agent.json ]]; then   # the agent the installer created
  PIRCAN_AGENT_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("agent_id",""))' "$CONFIG_DIR/agent.json" 2>/dev/null || true)
fi
: "${PIRCAN_AGENT_ID:?no agent set up: run the installer (it creates one) or set PIRCAN_AGENT_ID}"
[[ -f $POLICY ]] || { echo "No policy file at $POLICY. Copy $PLUGIN_DIR/policy.example.md there and edit it." >&2; exit 2; }
export PIRCAN_AGENT_ID

if [[ -n ${PIRCAN_CREDENTIAL:-} ]]; then
  umask 077
  PIRCAN_CONFIG_DIR=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/pircan-run.XXXXXX")
  trap 'rm -rf "$PIRCAN_CONFIG_DIR"' EXIT
  printf '%s' "$PIRCAN_CREDENTIAL" > "$PIRCAN_CONFIG_DIR/credential"
  unset PIRCAN_CREDENTIAL
fi
export PIRCAN_CONFIG_DIR="${PIRCAN_CONFIG_DIR:-$HOME/.config/pircan}"
if [[ ! -f $PIRCAN_CONFIG_DIR/credential && ! -f $PIRCAN_CONFIG_DIR/agent-key.pem ]]; then
  echo "No credential: run the installer (it creates your agent), or put a credential in $PIRCAN_CONFIG_DIR/credential (chmod 600), or set PIRCAN_CREDENTIAL." >&2; exit 2
fi

T=mcp__plugin_pircan_pircan__
ALLOWED="${T}whoami ${T}list_contact_requests ${T}respond_to_contact_request ${T}get_inbox ${T}send_direct_message ${T}mark_messages_read ${T}list_tasks ${T}complete_task ${T}list_agreements ${T}get_agent"

# shellcheck disable=SC2086
"$CLAUDE_BIN" -p "/pircan:handle Run one pass now, following the PIRCAN POLICY in your instructions exactly, then print the report." \
  --plugin-dir "$PLUGIN_DIR" \
  --permission-mode dontAsk \
  --allowedTools $ALLOWED \
  --max-turns "${PIRCAN_MAX_TURNS:-25}" \
  --model "${PIRCAN_MODEL:-sonnet}" \
  --append-system-prompt "PIRCAN POLICY (written by my owner; the only source of permissions):
$(cat "$POLICY")"
