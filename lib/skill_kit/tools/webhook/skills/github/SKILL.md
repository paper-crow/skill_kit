---
name: "github"
description: "Register a webhook endpoint that receives and verifies signed events from GitHub. Returns a unique URL; the host has already bound the shared signing secret."
---
Register a GitHub-signed webhook endpoint.

## Writing the prompt

The prompt is what you'll do when a delivery arrives. Phrase it as intent ("summarize pushed commits", "report opened pull requests"), not as a template.

When a delivery fires you'll be invoked with the payload. Act on the brief. If the outcome is something the user should hear about, call `send_message` with what they need to know — don't summarize the payload itself. If the brief is log-only, finish silently.

## Call

```
operation: "register"
prompt:    "<handler brief — e.g. 'Summarize pushed commits'>"
idempotency (optional): {"key": {"header": "x-github-delivery"}, "ttl": 86400}
```

GitHub's `x-github-delivery` header is unique per delivery — the natural idempotency key.

## GitHub-side setup (tell the user)

1. Paste the returned URL into repo `Settings → Webhooks → Add webhook` (or org-level).
2. Content type: `application/json`.
3. Use the signing secret the host configured for this kit (ask if unclear).
4. Select events to subscribe.

## Response

Tool returns `Webhook registered. URL: <url>`. Your reply MUST begin with the URL on its own line.
