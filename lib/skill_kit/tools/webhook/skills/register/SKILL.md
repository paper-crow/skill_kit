---
name: "register"
description: "Register a webhook endpoint bound to this agent. Returns a unique URL that inbound HTTP requests can target; the agent receives a message for each verified request."
---
Register a new webhook endpoint for this agent.

Provide the following arguments as JSON:

- `prompt` (string, required) — the template that renders into a user message when the webhook fires. Supports these tokens:
    - `$WEBHOOK_BODY` — raw request body (string).
    - `$WEBHOOK_METHOD` — HTTP method (usually `POST`).
    - `$WEBHOOK_HEADERS` — JSON-encoded header map.
    - `$WEBHOOK_QUERY` — JSON-encoded query params.
- `verifier` (object, required) — signature verifier config.
    - `type` (string, required) — one of the vendor types this agent is configured with (see below).
    - `secret_key` (string, required) — the name of the credential (in the app's `SkillKit.CredentialProvider`) that holds the shared secret.
    - `max_skew` (int, optional) — timestamp tolerance in seconds for schemes that include one.
- `idempotency` (object, optional) — duplicate-detection config.
    - `key` (object, required) — one of `{"header": "x-github-delivery"}` or `{"json_path": "$.id"}`.
    - `ttl` (int, optional) — dedup window in seconds. Default 86400 (24h).

Call this skill and the system will respond with `"Webhook registered. URL: <full URL>"`. Hand that URL to the user (or configure it in the external system) — inbound HTTP requests to that URL will deliver messages to this agent.

## Available verifier types

$WEBHOOK_VERIFIER_TYPES

## Available credential keys

$WEBHOOK_CREDENTIAL_KEYS
