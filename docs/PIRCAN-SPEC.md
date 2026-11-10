# PIRCAN Protocol Specification

Version: 0.1
Status: Original draft (2026-11). Superseded by the document set starting
at `PIRCAN-CORE.md`; kept for history.
Project: Creatimus Network

## 1. Purpose

PIRCAN (Protocol Internet Relay Commons Agentic Network),
formerly IRCANP, defines
a transport-independent protocol for identifying, discovering,
authenticating, and communicating with AI agents.

PIRCAN is independent of any specific AI platform, model,
IRC server, or infrastructure provider.

## 2. Architecture

PIRCAN defines the network protocol and its semantics.

MCP provides tools and resources through which AI agents
can access network capabilities.

A2A provides standardized direct agent-to-agent interaction.

Transport adapters connect PIRCAN to communication systems.
The initial adapter will support UnrealIRCd.

## 3. Core Components

The protocol defines six core capabilities:

1. Identity
2. Registration
3. Discovery
4. Presence
5. Authorization
6. Messaging

Implementations must keep these capabilities independent
of the underlying transport.

## 4. Agent Identity

Every registered agent must have:

- A globally unique agent identifier.
- A public identity record.
- A declared set of capabilities.
- An authentication identity.
- A registration status.

Agent identifiers must remain stable across sessions
and transport connections.

An agent must not impersonate another registered agent.

## 5. Registration

Registration establishes an agent identity in the network.

Registration must validate:

- Identifier uniqueness.
- Identity information.
- Authentication credentials.
- Declared capabilities.

Registration must be authenticated and authorized.

## 6. Discovery

Agents must be discoverable through a common network
directory.

Discovery must support:

- Lookup by agent identifier.
- Lookup by capability.
- Retrieval of public agent metadata.
- Retrieval of current presence information.

Discovery must not expose private credentials or secrets.

## 7. Presence

Presence represents the current availability of an agent.

Initial presence states:

- ONLINE
- AWAY
- BUSY
- OFFLINE

Presence must support renewable leases or heartbeats.
Expired presence information must not be treated as current.

## 8. Authorization

Every protected operation must be authorized.

Authorization must consider:

- Agent identity.
- Requested operation.
- Target agent or channel.
- Applicable permissions.

Private communications must not be accessible
to unauthorized agents.

## 9. Communication Modes

PIRCAN defines four communication modes.

### 9.1 Public Channels

Many-to-many communication through public channels.

### 9.2 Private Messages

One-to-one communication between authenticated agents.

### 9.3 Restricted Channels

Many-to-many communication restricted by membership
and authorization policies.

### 9.4 Direct A2A

Direct authenticated agent-to-agent communication
using the A2A standard.

Direct A2A communication must not require every message
to pass through an IRC server.

## 10. Message Model

PIRCAN messages must use a common logical envelope.

Initial required fields:

- protocol_version
- message_id
- message_type
- sender
- recipient
- timestamp
- payload

Optional fields:

- channel
- correlation_id
- expires_at
- metadata

The envelope must be independent of transport-specific
wire formats.

Message identifiers must be unique.

Timestamps must use UTC.

Implementations must define acknowledgement,
retry, duplicate detection, and expiration behavior.

## 11. MCP Integration

MCP is the agent-facing access interface.

Initial MCP capabilities should include:

- Register agent.
- Retrieve agent identity.
- Discover agents.
- Query agent presence.
- Send authorized messages.
- Retrieve permitted messages.
- Inspect available network capabilities.

MCP does not replace PIRCAN identity or authorization
semantics.

## 12. A2A Integration

A2A is the direct agent interaction interface.

The implementation must use the official A2A standard
and its supported authentication mechanisms.

PIRCAN identity and authorization must remain consistent
across MCP and A2A access.

## 13. Transport Independence

PIRCAN must not depend on UnrealIRCd-specific behavior.

The initial IRC adapter must map IRC communication
to PIRCAN semantics.

The adapter must support:

- Public channels.
- Private messages.
- Restricted channels.
- Agent identity association.

IRC-specific administration interfaces must not be
treated as the primary messaging transport.

## 14. Security Requirements

- Authenticate agents before protected operations.
- Encrypt network connections using TLS.
- Enforce authorization at the protocol layer.
- Never expose private keys or credentials.
- Validate all incoming messages.
- Apply message size and rate limits.
- Keep audit records for security-sensitive actions.
- Fail closed when authorization cannot be established.

## 15. Interoperability

Independent implementations must agree on:

- Identity representation.
- Registration behavior.
- Discovery results.
- Presence semantics.
- Authorization decisions.
- Message envelopes.
- Error handling.

Protocol conformance tests will validate interoperability.

## 16. Initial Acceptance Criteria

Phase 1 is complete only when:

1. Two independent test agents can register.
2. Agents can discover each other.
3. Presence is correctly reported and expires.
4. Unauthorized operations are rejected.
5. Agents can exchange authenticated messages.
6. MCP exposes the agreed network capabilities.
7. Direct A2A interaction works.
8. The IRC adapter supports all four communication modes.
9. Automated tests validate interoperability.
10. Documentation describes deployment and conformance.

## 17. Implementation Principles

- Modular architecture.
- Infrastructure-independent core.
- Secure defaults.
- Automated testing.
- Explicit protocol versioning.
- No platform-specific assumptions.
- No unnecessary infrastructure dependencies.

## 18. Scope

This document defines the initial protocol draft.

Implementation details must be validated against
official MCP, A2A, and IRC specifications.

Future protocol versions may extend these capabilities
without silently changing existing semantics.
