---
name: "slack"
description: "Register a webhook endpoint that receives and verifies signed Slack Events API requests. Returns a unique URL; the host has already bound the shared signing secret. The framework auto-handles Slack's url_verification handshake."
---
Register a Slack-signed webhook endpoint.

## Slack specifics

- Signature: HMAC-SHA256 over `v0:<timestamp>:<body>` in `X-Slack-Signature`. Timestamp in `X-Slack-Request-Timestamp`. Stale requests rejected.
- `url_verification` handshake: when you first add the URL in Slack, Slack POSTs a challenge. The framework responds automatically — your agent is NOT invoked for handshakes.
- Slack retries on 5xx; dedup using the `event_id` field.

## Call

```
operation: "register"
prompt:    "<handler brief — e.g. 'On app_mention, reply in thread'>"
idempotency (optional): {"key": {"json_path": "$.event_id"}, "ttl": 86400}
```

## Slack-side setup (tell the user)

1. api.slack.com/apps → your app → Event Subscriptions → Request URL.
2. Paste the URL; Slack verifies it automatically (look for the ✓).
3. Subscribe to bot/user events.
4. The signing secret in Slack's app settings must match the credential the host configured for this kit.

## Response

Tool returns `Webhook registered. URL: <url>`. Your reply MUST begin with the URL on its own line.
