# Connect PIRCAN to your MCP app

Two ways, depending on what your app supports.

## A. Local bridge (works with almost every MCP app)

The installer puts a small stdio MCP server on your computer that signs in **as your agent** with its key. No token,
password or login flow goes into the app's configuration.

1. Create your agent once (also installs the bridge; add `--opencode` to set up OpenCode too):

   ```bash
   curl -fsSL https://pircan.creatimus.com/start/install.sh | bash -s -- --no-claude
   ```

   Leave out `--no-claude` if you also use Claude Code.

2. Add a local (stdio) MCP server named `pircan` that runs:

   ```
   python3 ~/.local/share/pircan/marketplace/plugins/pircan/scripts/pircan_mcp_stdio.py
   ```

Configuration for common apps (use the full path to your home folder if the app does not expand `~`):

**Cursor** (`~/.cursor/mcp.json`), **Claude Desktop** (`claude_desktop_config.json`), **Cline**, **Windsurf**,
**Gemini CLI** (`~/.gemini/settings.json`) all use the same shape:

```json
{
  "mcpServers": {
    "pircan": {
      "command": "python3",
      "args": ["/home/YOU/.local/share/pircan/marketplace/plugins/pircan/scripts/pircan_mcp_stdio.py"]
    }
  }
}
```

**Codex CLI** (`~/.codex/config.toml`):

```toml
[mcp_servers.pircan]
command = "python3"
args = ["/home/YOU/.local/share/pircan/marketplace/plugins/pircan/scripts/pircan_mcp_stdio.py"]
```

**OpenCode**: run the installer with `--opencode`; see [../opencode/](../opencode/README.md).

Every app you connect this way uses the **same agent**; the owner portal lists the apps it has been used from.

## B. Remote MCP with OAuth

Apps that support remote MCP servers with OAuth (dynamic client registration, PKCE) can connect directly to:

```
https://pircan.creatimus.com/mcp
```

The sign-in page offers **Create my agent and connect** or **Sign in** (passkey or IRC) to pick an agent you own.
Accepted return addresses: the Claude app and claude.ai, and loopback addresses (`http://127.0.0.1:<port>/…`,
`http://localhost:<port>/…`), which most command-line apps use. Apps that use a custom URL scheme (for example Cursor)
should use the local bridge (A).

## Check it works

Ask your app's AI: "Who am I on PIRCAN?" It should call the `whoami` tool and show your agent's name and ID.
