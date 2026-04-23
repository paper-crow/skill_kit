---
name: "update"
description: "Modify an existing webhook's prompt or verifier. The URL stays the same so external senders don't need to be reconfigured."
---
Update a previously registered webhook.

## When to use

Reach for this skill when the user wants to change how an existing webhook behaves — typically the on-hit `prompt` (the instruction the agent follows on each inbound request) or the `verifier` (signature scheme + secret). The webhook's ID and URL do NOT change, so any external system already POSTing to that URL keeps working.

Typical triggers:

- "change the webhook to do X instead"
- "make the webhook just log silently"
- "rotate the webhook secret to a new credential"
- "switch the github webhook to require a valid signature now that it's in prod"

## How to call it

Use the `webhook` tool with `operation: "update"` plus:

- `id` (string, required) — the webhook id. Either the tail segment of the webhook URL, or the `id` returned by `webhook:list`. Ask the user (or run `webhook:list`) if you don't already have it.
- `prompt` (string, optional) — new on-hit instruction. Same token set as register (`$WEBHOOK_METHOD`, `$WEBHOOK_BODY`, `$WEBHOOK_HEADERS`, `$WEBHOOK_QUERY`). Treat it as a mini task brief for the receiving agent; see `webhook:register` for details on how to write a good prompt.
- `verifier` (object, optional) — new verifier binding. Same shape as register: `{"type": "stripe|github|slack|none", "secret_key": "<credential-name>", "max_skew": <int>}`.

At least one of `prompt` or `verifier` should be present — otherwise the update is a no-op. If the user wants to keep the existing value for a field, simply omit that field from the call.

Fields you CANNOT change with `update` (unregister + register instead):

- `agent_name` — a webhook is bound to the agent that created it.
- `idempotency` — swap the registration entirely.
- `id` / URL — that's the entire point of having `update` (the URL is stable).

## Response

- Success: `"Webhook updated. URL: <full URL>"`. Confirm to the user which fields were changed and re-state the URL.
- Failure: an error string. If the id is unknown, the error is `"webhook not found: <id>"` — treat that as the user possibly referring to a different webhook, and offer to `webhook:list` to clarify.

## Example

Change the on-hit instruction on an existing webhook:

```json
{
  "operation": "update",
  "id": "oEGmLCCrmT_0GUSJGVhUPuAyi2EcFt7a",
  "prompt": "A webhook request arrived. Silently append one line to webhook_log.txt: '[<iso-timestamp>] $WEBHOOK_METHOD $WEBHOOK_BODY'. Acknowledge with just 'logged.'"
}
```

Rotate a verifier secret:

```json
{
  "operation": "update",
  "id": "oEGmLCCrmT_0GUSJGVhUPuAyi2EcFt7a",
  "verifier": {"type": "github", "secret_key": "GITHUB_WEBHOOK_SECRET_V2"}
}
```
