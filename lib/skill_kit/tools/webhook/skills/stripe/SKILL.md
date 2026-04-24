---
name: "stripe"
description: "Register a webhook endpoint that receives and verifies signed events from Stripe. Returns a unique URL; the host has already bound the shared signing secret."
---
Register a Stripe-signed webhook endpoint.

## Stripe specifics

- Signature: HMAC-SHA256 delivered in `Stripe-Signature` with timestamp. Stale requests (default 5m tolerance) are rejected.
- Stripe events carry a stable top-level `id` — use it for idempotency.
- Stripe retries on non-2xx for up to 3 days.

## Call

```
operation: "register"
prompt:    "<handler brief — plain intent, e.g. 'On charge.succeeded, confirm and log'>"
idempotency (optional): {"key": {"json_path": "$.id"}, "ttl": 86400}
```

## Stripe-side setup (tell the user)

1. Dashboard → Developers → Webhooks → Add endpoint.
2. Paste the returned URL.
3. Select events to send.
4. Stripe shows a signing secret after creation — it must match the credential the host configured for this kit.

## Response

Tool returns `Webhook registered. URL: <url>`. Your reply MUST begin with the URL on its own line.
