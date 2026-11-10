"""PIRCAN client SDK: discovery, tokens, MCP, A2A, intro tokens, webhooks, IRC lobby."""

from .client import Agent, PircanError, discover, register_self, solve_challenge, verify_webhook
from .lobby import LobbyClient

__all__ = ["Agent", "LobbyClient", "PircanError", "discover", "register_self", "solve_challenge",
           "verify_webhook"]
