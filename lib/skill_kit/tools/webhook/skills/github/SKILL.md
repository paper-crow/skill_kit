---
name: "github"
description: "Register a webhook endpoint that receives and verifies signed events from GitHub. Returns a unique URL; the host has already bound the shared signing secret."
---
Register a GitHub-signed webhook endpoint.

## GitHub specifics

- Signature: HMAC-SHA256 over the raw body, delivered as `X-Hub-Signature-256: sha256=<hex>`.
- Delivery id: GitHub sends a unique `X-GitHub-Delivery` header on every request — use it for idempotency.
- Common events: `push`, `pull_request`, `issues`, `release`.

## Prompt guidance

The handler's text output stays inside the sub-loop. To reach the user's chat the handler must call `send_message` with a summary. Phrase the prompt around what the handler should send (e.g. "report the pushed branch and author") rather than passive output. If the handler brief is purely log-only, leave `send_message` out and the event is handled silently.

## Call

```
operation: "register"
prompt:    "<handler brief — plain intent, e.g. 'Summarize pushed commits'>"
idempotency (optional): {"key": {"header": "x-github-delivery"}, "ttl": 86400}
```

## GitHub-side setup (tell the user)

1. Paste the returned URL into repo `Settings → Webhooks → Add webhook` (or org-level).
2. Content type: `application/json`.
3. Use the signing secret the host configured for this kit (ask if unclear).
4. Select events to subscribe.

## Response

Tool returns `Webhook registered. URL: <url>`. Your reply MUST begin with the URL on its own line.
