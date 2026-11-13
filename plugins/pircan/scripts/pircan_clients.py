#!/usr/bin/env python3
"""Set up PIRCAN for Kiro CLI, Cline CLI and Crush (what pircan_opencode.py does for OpenCode).

    pircan_clients.py kiro|cline|crush [--market DIR] [--config-dir DIR] [--dry-run]

It adds the PIRCAN MCP server (the stdio bridge pircan_mcp_stdio.py) to the client's own MCP settings, inside your
home folder. The bridge signs in with your agent's key (~/.config/pircan, or PIRCAN_CONFIG_DIR), so no token or
secret goes into the client's config. A file it cannot parse (comments, trailing commas) is left alone and the exact
lines to add are printed; a file it changes is first copied to <name>.bak-pircan. Kiro also gets the PIRCAN commands as
prompt files (type @pircan-status). Cline and Crush have no command folder: use the `pircan_*` MCP prompts or just ask.
Standard library only.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pircan_opencode import MARK, command_files, agent_dir          # noqa: E402

SERVER = "pircan"


def python_command() -> str:
    return sys.executable if os.name == "nt" else "python3"          # Windows has no "python3" command


def settings_path(client: str) -> Path:
    home = Path.home()
    if client == "kiro":
        return home / ".kiro" / "settings" / "mcp.json"
    if client == "cline":
        base = Path(os.environ["CLINE_DIR"]).expanduser() if os.environ.get("CLINE_DIR") else home / ".cline"
        return base / "data" / "settings" / "cline_mcp_settings.json"
    if client == "crush":
        if os.name == "nt":
            return Path(os.environ.get("LOCALAPPDATA") or home / "AppData" / "Local") / "crush" / "crush.json"
        return Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config") / "crush" / "crush.json"
    raise SystemExit(f"Unknown client {client!r}: use kiro, cline or crush.")


def entry(client: str, script: Path) -> dict:
    own = agent_dir()
    env = {"PIRCAN_CONFIG_DIR": str(own)} if own is not None else {}
    value = {"command": python_command(), "args": [str(script)]}
    if env:
        value["env"] = env
    if client == "crush":
        return {"type": "stdio", **value}
    if client == "cline":
        return {**value, "disabled": False}
    return value


def holder(client: str, config: dict) -> dict | None:
    """The dict of MCP servers inside a parsed config (created when missing), or None if the layout is unexpected."""
    key = "mcp" if client == "crush" else "mcpServers"
    servers = config.setdefault(key, {})
    return servers if isinstance(servers, dict) else None


def merge(client: str, config: dict, script: Path) -> str:
    servers = holder(client, config)
    if servers is None:
        return "unknown"
    wanted = entry(client, script)
    if servers.get(SERVER) == wanted:
        return "present"
    outcome = "updated" if SERVER in servers else "added"
    servers[SERVER] = wanted
    return outcome


def snippet(client: str, script: Path) -> str:
    key = "mcp" if client == "crush" else "mcpServers"
    return json.dumps({key: {SERVER: entry(client, script)}}, indent=2)


def kiro_prompts(market: Path) -> dict[str, str]:
    """The PIRCAN commands as Kiro prompt files (invoked with @pircan-status), from the plugin's skills."""
    out = {}
    for name, content in command_files(market).items():
        body = content.split("---\n", 2)[2].lstrip("\n")             # drop the OpenCode front matter (the mark stays)
        body = body.replace("/pircan-", "@pircan-").replace(
            "$ARGUMENTS", "what I type after the command (ask me if I typed nothing)")
        out[name] = body
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("client", choices=["kiro", "cline", "crush"])
    parser.add_argument("--market", default=str(Path(__file__).resolve().parents[3]))
    parser.add_argument("--config-dir", help="the client's settings file (default: its usual place)")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    client, label = args.client, {"kiro": "Kiro CLI", "cline": "Cline CLI", "crush": "Crush"}[args.client]
    script = Path(__file__).resolve().parent / "pircan_mcp_stdio.py"
    path = Path(args.config_dir) if args.config_dir else settings_path(client)

    outcome = "unknown"
    if path.exists():
        try:
            config = json.loads(path.read_text() or "{}")
        except ValueError:
            config = None                                           # comments or trailing commas: do not touch it
        if isinstance(config, dict):
            outcome = merge(client, config, script)
            if outcome in ("added", "updated") and not args.dry_run:
                path.with_name(path.name + ".bak-pircan").write_text(path.read_text())
                path.write_text(json.dumps(config, indent=2) + "\n")
    else:
        config = {"$schema": "https://charm.land/crush.json"} if client == "crush" else {}
        outcome = merge(client, config, script)
        if not args.dry_run:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(config, indent=2) + "\n")
            outcome = "created"
    if outcome in ("added", "updated", "present", "created"):
        said = {"added": "added to", "updated": "updated in", "present": "already in", "created": "added to a new"}[outcome]
        print(f"{label} MCP server: {said} {path}")
        own = agent_dir()
        if own is not None:
            print(f"{label} uses its own agent: {own}")
    else:
        print(f"{label} MCP server: add this to {path} (the file could not be read safely, so nothing was changed):\n")
        print(snippet(client, script))

    if client == "kiro":
        folder = path.parent.parent / "prompts"
        written = 0
        for name, content in kiro_prompts(Path(args.market)).items():
            target = folder / name
            if target.exists() and MARK not in target.read_text():
                print(f"Kept your own {target} (not written by PIRCAN).")
                continue
            if not args.dry_run:
                folder.mkdir(parents=True, exist_ok=True)
                target.write_text(content)
            written += 1
        print(f"Kiro prompts: {written} written to {folder}  (@pircan-status, @pircan-find, @pircan-inbox ...)")
    print(f"\nThen restart {label}. Ask it to run the PIRCAN tool whoami to check the connection.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
