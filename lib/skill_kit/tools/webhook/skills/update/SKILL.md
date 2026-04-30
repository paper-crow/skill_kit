---
name: "update"
description: "Modify an existing webhook's prompt. The URL stays the same so external senders don't need to be reconfigured."
---
Update a previously registered webhook.

## When to use

Reach for this skill when the user wants to change how an existing webhook behaves — specifically the on-hit `prompt` (the instruction the agent follows on each inbound request). The webhook's ID and URL do NOT change, so any external system already POSTing to that URL keeps working.

Typical triggers:

- "change the webhook to do X instead"
- "make the webhook just log silently"
- "tweak the wording on what the github webhook does"

## How to call it

Use the `webhook` tool with `operation: "update"` plus:

- `id` (string, required) — the webhook id. Either the tail segment of the webhook URL, or the `id` returned by `webhook:list`. Ask the user (or run `webhook:list`) if you don't already have it.
- `prompt` (string, required) — new handler brief. Plain-English intent for what the agent should do when a delivery arrives; the agent reads the payload via the `webhook_inbox` tool. See the per-vendor register skills (`webhook:github`, `webhook:stripe`, `webhook:slack`, `webhook:unsigned`) for prompt-writing guidance.

Fields you CANNOT change with `update` (unregister + register instead):

- `verifier` — to rotate a verifier secret or switch signature scheme, call `webhook:unregister` and then re-register with the same handler brief. The URL will change, so the external sender will need to be reconfigured.
- `agent_name` — a webhook is bound to the agent that created it.
- `idempotency` — swap the registration entirely.
- `id` / URL — that's the entire point of having `update` (the URL is stable).

## Response

- Success: `"Webhook updated. URL: <full URL>"`. Confirm to the user that the prompt was changed and re-state the URL.
- Failure: an error string. If the id is unknown, the error is `"webhook not found: <id>"` — treat that as the user possibly referring to a different webhook, and offer to `webhook:list` to clarify.

## Example

Change the on-hit instruction on an existing webhook:

```json
{
  "operation": "update",
  "id": "oEGmLCCrmT_0GUSJGVhUPuAyi2EcFt7a",
  "prompt": "Silently append one line to webhook_log.txt: '[<iso-timestamp>] <method> <body>'. Acknowledge with just 'logged.'"
}
```
