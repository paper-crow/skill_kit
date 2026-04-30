---
name: "slack"
description: "Register a webhook endpoint that receives and verifies signed Slack Events API requests. Returns a unique URL; the host has already bound the shared signing secret. The framework auto-handles Slack's url_verification handshake."
---
Register a Slack-signed webhook endpoint.

## Writing the prompt

The prompt is what you'll do when a delivery arrives. Phrase it as intent ("on app_mention, reply in thread", "summarize message events"), not as a template.

When a delivery fires you'll be invoked with the payload. To tell the user about it, call `send_message` with a summary. If it's log-only and there's nothing the user needs to hear, finish silently.

## Call

```
operation: "register"
prompt:    "<handler brief>"
idempotency (optional): {"key": {"json_path": "$.event_id"}, "ttl": 86400}
```

Use the `event_id` field for idempotency — Slack retries on 5xx.

## Slack-side setup (tell the user)

1. api.slack.com/apps → your app → Event Subscriptions → Request URL.
2. Paste the URL; Slack verifies it automatically (look for the ✓).
3. Subscribe to bot/user events.
4. The signing secret in Slack's app settings must match the credential the host configured for this kit.

## Response

Tool returns `Webhook registered. URL: <url>`. Your reply MUST begin with the URL on its own line.
