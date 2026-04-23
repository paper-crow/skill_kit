---
name: "register"
description: "Register a webhook endpoint bound to this agent. Returns a unique URL that inbound HTTP requests can target; the agent receives a message for each verified request."
---
Register a new webhook endpoint for this agent.

## Your role

You are the **receiver**, not the sender.

This skill configures an HTTP endpoint hosted by this agent's process. When someone POSTs to that URL, the request body becomes a user message delivered to you. That is the entire scope of this skill.

Do **not**:
- Write source scripts, cron jobs, or schedulers that call the endpoint (that's the user's problem or a separate system).
- Create external webhook receivers in other languages (Python Flask, Node, etc.) — this skill IS the receiver.
- Set up anything beyond the single `webhook` tool call unless the user explicitly asks.

Flow: user asks for a webhook → you call the `webhook` tool with `operation: "register"` and the appropriate args → you return the URL to the user. Stop there. The user decides what sends traffic to it.

## How to call it

Use the `webhook` tool available in this turn. Set `operation: "register"` plus the following fields:

- `prompt` (string, required) — the template rendered into a user message each time the webhook fires. Supported tokens:
    - `$WEBHOOK_BODY` — raw request body
    - `$WEBHOOK_METHOD` — HTTP method (usually `POST`)
    - `$WEBHOOK_HEADERS` — JSON-encoded header map
    - `$WEBHOOK_QUERY` — JSON-encoded query params
- `verifier` (object, required)
    - `type` (string, required) — one of `stripe`, `github`, `slack`, or `none`.
      - `stripe` / `github` / `slack` — HMAC-SHA256 with vendor-specific signing template and header format. Requires `secret_key` to point at a real credential.
      - `none` — no signature check; relies on URL entropy (~192 bits) + transport-level trust. Still requires `secret_key` for API consistency; use any non-empty placeholder (the credential is not read).
    - `secret_key` (string, required) — name of a credential registered in the app's `SkillKit.CredentialProvider`. The host is responsible for knowing which keys are available; ask the user if unsure.
    - `max_skew` (int, optional) — timestamp tolerance in seconds; only used by vendors that sign timestamps.
- `idempotency` (object, optional)
    - `key` (object, required) — either `{"header": "x-github-delivery"}` or `{"json_path": "$.id"}`.
    - `ttl` (int, optional) — dedup window in seconds. Default 86400 (24h).

## Response

- Success: `"Webhook registered. URL: <full URL>"`. Hand the URL to the user and tell them inbound HTTP requests to that URL will deliver messages to this agent.
- Failure: an error string describing the specific reason (missing field, unknown verifier type, etc.).

## Examples

Simplest echo with no signature:

```json
{
  "operation": "register",
  "prompt": "Webhook fired: $WEBHOOK_BODY",
  "verifier": {"type": "none", "secret_key": "_"}
}
```

Signed GitHub push webhook:

```json
{
  "operation": "register",
  "prompt": "GitHub push: $WEBHOOK_BODY",
  "verifier": {"type": "github", "secret_key": "GITHUB_WEBHOOK_SECRET"}
}
```
