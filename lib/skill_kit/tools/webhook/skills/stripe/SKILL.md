---
name: "stripe"
description: "Register a webhook endpoint that receives and verifies signed events from Stripe. Returns a unique URL; the host has already bound the shared signing secret."
---
Register a Stripe-signed webhook endpoint.

## Writing the prompt

The prompt is what you'll do when a delivery arrives. Phrase it as intent ("on charge.succeeded, confirm and log", "alert on disputes"), not as a template.

When a delivery fires you'll be invoked with the payload. To tell the user about it, call `send_message` with a summary. If it's log-only and there's nothing the user needs to hear, finish silently.

## Call

```
operation: "register"
prompt:    "<handler brief>"
idempotency (optional): {"key": {"json_path": "$.id"}, "ttl": 86400}
```

Stripe events carry a stable top-level `id` — use it for idempotency. Stripe retries failed deliveries for up to 3 days.

## Stripe-side setup (tell the user)

1. Dashboard → Developers → Webhooks → Add endpoint.
2. Paste the returned URL.
3. Select events to send.
4. Stripe shows a signing secret after creation — it must match the credential the host configured for this kit.

## Response

Tool returns `Webhook registered. URL: <url>`. Your reply MUST begin with the URL on its own line.
