#!/usr/bin/env python3
"""Update PIRCAN on this computer. Your agents, keys, settings and handshakes are never touched.

    pircan_update.py check [--source github|site]       is a newer release available?
    pircan_update.py apply [--source github|site]       update the plugin and scripts in place (the default command)
      --from-dir DIR   use an already verified, unpacked plugin (the installer's --update does this)
      --force          update even when the version is the same
      --no-restart     do not restart the background runners

What it replaces: the plugin and helper scripts in ~/.local/share/pircan/marketplace (the previous copy is kept as
marketplace.previous), the plugin inside Claude Code, the OpenCode commands, and it restarts the background runner(s).
What it keeps: agent.json and agent-key.pem (your agent), policy.md, runner.json and the runner's state (your settings),
and everything the network knows (agreements, tasks, messages). It carries over the network address and the sign-in helper
that the installer set up (on Windows that is the exact Python path).

Where the update comes from: GitHub releases (https://github.com/creatimus/pircan/releases) or this network's website,
whichever the installer used (recorded in install.json); --source overrides. The download is checked against the
release's SHA256SUMS and refused on a mismatch. Standard library only (Python 3.8+).
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
from pathlib import Path

USER_AGENT = "pircan-update/0.1 (+https://github.com/creatimus/pircan)"
GITHUB_REPO = "creatimus/pircan"
DEFAULT_SITE = "https://pircan.creatimus.com"
PLUGIN_ARCHIVE = "pircan-claude-plugin.tgz"
SCRIPTS = Path(__file__).resolve().parent


def release_url() -> str:
    return (os.environ.get("PIRCAN_RELEASE_URL") or f"https://github.com/{GITHUB_REPO}/releases/latest/download").rstrip("/")


def release_api() -> str:
    return os.environ.get("PIRCAN_RELEASE_API") or f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest"


def release_page() -> str:
    return os.environ.get("PIRCAN_RELEASE_PAGE") or f"https://github.com/{GITHUB_REPO}/releases/latest"


def pircan_home() -> Path:
    return Path(os.environ.get("PIRCAN_HOME") or "~/.local/share/pircan").expanduser()


def market_dir() -> Path:
    return pircan_home() / "marketplace"


def fail(message: str) -> None:
    print(f"pircan update: {message}", file=sys.stderr)
    sys.exit(1)


# ---- versions --------------------------------------------------------------------------------------------------------

def parse_version(text: str) -> tuple:
    parts = []
    for piece in str(text or "").strip().lstrip("vV").split("."):
        digits = "".join(ch for ch in piece if ch.isdigit())
        parts.append(int(digits) if digits else 0)
    return tuple(parts) or (0,)


def is_newer(latest: str, current: str) -> bool:
    return parse_version(latest) > parse_version(current)


def plugin_version(root: Path) -> str:
    """The version in a plugin folder (the marketplace folder, or one unpacked from a release)."""
    try:
        return str(json.loads((Path(root) / "plugins" / "pircan" / ".claude-plugin" / "plugin.json").read_text()).get("version", ""))
    except (OSError, ValueError):
        return ""


def installed_version() -> str:
    return plugin_version(market_dir())


# ---- install record ------------------------------------------------------------------------------------------------------

def read_record() -> dict:
    try:
        data = json.loads((pircan_home() / "install.json").read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def write_record(**fields) -> None:
    record = {**read_record(), **{k: v for k, v in fields.items() if v is not None}}
    path = pircan_home() / "install.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record, indent=2) + "\n")


def installed_base() -> str:
    """The network address the installer set up, read from the installed plugin's own config."""
    try:
        url = json.loads((market_dir() / "plugins" / "pircan" / ".mcp.json").read_text())["mcpServers"]["pircan"]["url"]
    except (OSError, ValueError, KeyError):
        return DEFAULT_SITE
    url = url.replace("${PIRCAN_URL:-", "").replace("}", "")
    return url[: -len("/mcp")] if url.endswith("/mcp") else (url or DEFAULT_SITE)


# ---- network -------------------------------------------------------------------------------------------------------------

def fetch(url: str, timeout: float = 30) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def source_urls(source: str, base: str) -> tuple[str, str]:
    root = release_url() if source == "github" else f"{base.rstrip('/')}/start"
    return f"{root}/{PLUGIN_ARCHIVE}", f"{root}/SHA256SUMS"


def latest_version(source: str = "github", base: str = DEFAULT_SITE) -> str:
    """The newest released plugin version, or "" when it cannot be found right now (never raises)."""
    try:
        if source == "github":
            try:
                return str(json.loads(fetch(release_api(), 15))["tag_name"]).lstrip("vV")
            except Exception:  # noqa: BLE001 - API limits: the releases page redirects to the newest tag
                request = urllib.request.Request(release_page(), method="HEAD",
                                                 headers={"User-Agent": USER_AGENT})
                with urllib.request.urlopen(request, timeout=15) as response:
                    return response.geturl().rstrip("/").rsplit("/", 1)[-1].lstrip("vV")
        archive, _ = source_urls("site", base)
        with tarfile.open(fileobj=io.BytesIO(fetch(archive, 30)), mode="r:gz") as tar:
            member = tar.extractfile("plugins/pircan/.claude-plugin/plugin.json")
            return str(json.loads(member.read())["version"])
    except Exception:  # noqa: BLE001 - an update check must never break anything
        return ""


def safe_extract(archive: bytes, destination: Path) -> None:
    """Unpack a plugin archive, refusing anything that would land outside the destination or is a link."""
    destination = Path(destination).resolve()
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        for member in tar.getmembers():
            target = (destination / member.name).resolve()
            if destination != target and destination not in target.parents:
                raise ValueError(f"unsafe path in the archive: {member.name}")
            if member.issym() or member.islnk() or member.isdev():
                raise ValueError(f"unsafe entry in the archive: {member.name}")
        tar.extractall(destination)


def download(source: str, base: str, destination: Path) -> None:
    archive_url, sums_url = source_urls(source, base)
    try:
        archive, sums = fetch(archive_url), fetch(sums_url).decode("utf-8", "replace")
    except (urllib.error.URLError, OSError) as exc:
        fail(f"could not download the update from {archive_url} ({exc}). Nothing was changed.")
    wanted = next((line.split()[0] for line in sums.splitlines() if line.strip().endswith(PLUGIN_ARCHIVE)), "")
    if not wanted or wanted.lower() != hashlib.sha256(archive).hexdigest():
        fail("checksum mismatch: the download is corrupted or not what the release published. Nothing was changed.")
    try:
        safe_extract(archive, destination)
    except (ValueError, tarfile.TarError) as exc:
        fail(f"the archive could not be unpacked safely ({exc}). Nothing was changed.")
    if not (destination / ".claude-plugin" / "marketplace.json").exists():
        fail("the archive does not look like the PIRCAN plugin. Nothing was changed.")


# ---- applying ------------------------------------------------------------------------------------------------------------

def carry_over_config(old_market: Path, new_market: Path) -> None:
    """Keep what the installer configured: the network address and the sign-in helper command."""
    old, new = old_market / "plugins" / "pircan" / ".mcp.json", new_market / "plugins" / "pircan" / ".mcp.json"
    try:
        kept = json.loads(old.read_text())["mcpServers"]["pircan"]
        data = json.loads(new.read_text())
    except (OSError, ValueError, KeyError):
        return
    for key in ("url", "headersHelper"):
        if key in kept:
            data["mcpServers"]["pircan"][key] = kept[key]
    new.write_text(json.dumps(data, indent=2))


def agent_folders() -> list[Path]:
    """Folders of agents on this computer that have runner settings."""
    home = Path("~").expanduser()
    candidates = [Path(os.environ.get("PIRCAN_CONFIG_DIR") or home / ".config" / "pircan"),
                  home / ".config" / "pircan", home / ".config" / "pircan-opencode", home / ".config" / "pircan-dev"]
    seen, folders = set(), []
    for folder in candidates:
        key = str(folder.resolve()) if folder.exists() else str(folder)
        if key not in seen and (folder / "runner.json").exists():
            seen.add(key)
            folders.append(folder)
    return folders


def run_quiet(command: list[str], env: dict | None = None, timeout: int = 120) -> tuple[int, str]:
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=timeout, env=env)
        return done.returncode, (done.stdout + done.stderr).strip()
    except (OSError, subprocess.SubprocessError) as exc:
        return 1, str(exc)


def runner_command(action: str, folder: Path, script: Path) -> int:
    return run_quiet([sys.executable, str(script), action, "--config-dir", str(folder)], timeout=90)[0]


def refresh_claude(market: Path) -> str:
    claude = os.environ.get("CLAUDE_BIN") or shutil.which("claude")
    if not claude or not (shutil.which(claude) or Path(claude).exists()):
        return "Claude Code not found (skipped)"
    run_quiet([claude, "plugin", "marketplace", "remove", "creatimus"])            # fails harmlessly when never added
    added, out = run_quiet([claude, "plugin", "marketplace", "add", str(market)])
    if added != 0:
        return f"Claude Code: could not add the marketplace ({out[:120]})"
    installed, out = run_quiet([claude, "plugin", "install", "pircan@creatimus"])
    return "Claude Code: plugin updated (restart it)" if installed == 0 else f"Claude Code: could not install the plugin ({out[:120]})"


def opencode_settings_dir() -> Path:
    return Path(os.environ.get("OPENCODE_CONFIG_DIR") or Path(os.environ.get("XDG_CONFIG_HOME") or "~/.config").expanduser() / "opencode").expanduser()


def refresh_opencode(market: Path) -> str:
    config = opencode_settings_dir()
    agent_dir = ""
    try:
        data = json.loads((config / "opencode.json").read_text())
        mcp = data.get("mcp") or {}
        entry = (mcp.get("servers") or {}).get("pircan") or mcp.get("pircan") or {}
        agent_dir = (entry.get("environment") or {}).get("PIRCAN_CONFIG_DIR", "")
        present = bool(entry)
    except (OSError, ValueError, AttributeError):
        present = False
    if not present and not (config / "command" / "pircan-status.md").exists():
        return "OpenCode not set up (skipped)"
    env = {**os.environ, **({"PIRCAN_CONFIG_DIR": agent_dir} if agent_dir else {})}
    code, out = run_quiet([sys.executable, str(market / "plugins" / "pircan" / "scripts" / "pircan_opencode.py"), "--market", str(market)], env=env)
    return "OpenCode: commands updated (restart it)" if code == 0 else f"OpenCode: could not update ({out[:120]})"


def swap_in(staging: Path, market: Path) -> str:
    """Put the new copy in place; keep the previous one as marketplace.previous. Returns "" or a note."""
    previous = market.with_name("marketplace.previous")
    if previous.exists():
        shutil.rmtree(previous, ignore_errors=True)
    try:
        os.replace(market, previous)
        os.replace(staging, market)
        return ""
    except OSError:
        # A folder that is in use cannot always be renamed (Windows): copy the files over instead.
        if not market.exists() and previous.exists():
            os.replace(previous, market)
        shutil.copytree(staging, market, dirs_exist_ok=True)
        shutil.rmtree(staging, ignore_errors=True)
        return "(files copied over in place; the previous copy was not kept)"


def apply(source: str, base: str, from_dir: str = "", force: bool = False, restart: bool = True) -> int:
    market = market_dir()
    if not (market / ".claude-plugin" / "marketplace.json").exists():
        fail(f"PIRCAN is not installed here ({market}). Run the installer first.")
    old_version = installed_version() or "unknown"
    staging = market.with_name("marketplace.new")
    shutil.rmtree(staging, ignore_errors=True)
    try:
        if from_dir:
            shutil.copytree(from_dir, staging)
        else:
            staging.mkdir(parents=True)
            download(source, base, staging)
        new_version = plugin_version(staging)
        if not new_version:
            fail("the update has no version number; refusing it. Nothing was changed.")
        if not force and not is_newer(new_version, old_version) and old_version != "unknown":
            print(f"PIRCAN is already up to date ({old_version}).")
            shutil.rmtree(staging, ignore_errors=True)
            return 0
        carry_over_config(market, staging)
    except BaseException:                 # a refused or failed download leaves nothing half-made behind
        shutil.rmtree(staging, ignore_errors=True)
        raise

    folders = agent_folders()
    runner_script = market / "plugins" / "pircan" / "scripts" / "pircan_runner.py"
    if restart:
        for folder in folders:
            runner_command("stop", folder, runner_script)
    note = swap_in(staging, market)
    new_runner = market / "plugins" / "pircan" / "scripts" / "pircan_runner.py"
    results = [refresh_claude(market), refresh_opencode(market)]
    if restart:
        for folder in folders:
            code = runner_command("restart", folder, new_runner)
            results.append(f"Runner ({folder.name}): " + ("restarted" if code == 0 else "not running as a service (start it yourself if you use it)"))
    write_record(source=source, base=base, version=new_version, updated_at=time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()))
    print(f"Updated PIRCAN {old_version} -> {new_version} {note}".rstrip())
    for line in results:
        print(f"  {line}")
    print("Your agents, keys, settings and handshakes were not touched.")
    if (market.with_name("marketplace.previous")).exists():
        print(f"The previous version is kept in {market.with_name('marketplace.previous')} (delete it when you like).")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", nargs="?", default="apply", choices=["check", "apply"])
    parser.add_argument("--source", choices=["github", "site"])
    parser.add_argument("--base")
    parser.add_argument("--from-dir", default="")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--no-restart", action="store_true")
    args = parser.parse_args(argv)
    record = read_record()
    source = args.source or record.get("source") or "github"
    base = (args.base or record.get("base") or installed_base()).rstrip("/")
    if args.command == "check":
        current, latest = installed_version(), latest_version(source, base)
        where = "GitHub" if source == "github" else base
        print(f"Installed: {current or 'unknown'}   Latest ({where}): {latest or 'could not be found'}")
        if latest and is_newer(latest, current or "0"):
            print("An update is available. Run:  python3 pircan_update.py apply   (or /pircan:update in Claude Code, "
                  "or run the installer again with --update)")
        elif latest:
            print("You are up to date.")
        return 0
    return apply(source, base, from_dir=args.from_dir, force=args.force, restart=not args.no_restart)


if __name__ == "__main__":
    sys.exit(main())
