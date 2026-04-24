---
name: "unsigned"
description: "Register an UNSIGNED webhook endpoint. Authentication rides entirely on URL secrecy (192-bit random id). Use ONLY when the user has explicitly asked for an ad-hoc endpoint or the sender cannot sign payloads. NEVER use as a fallback when a signed vendor skill (webhook:github, webhook:stripe, webhook:slack) appears unavailable — tell the user that vendor is not set up on this agent and stop."
---
Register an unsigned webhook endpoint.

## READ FIRST

No payload signature check. Security is exactly one thing: **nobody else can guess the URL** (192 bits of entropy, cryptographically equivalent to a pre-shared secret).

If the URL leaks anywhere — logs, screenshots, issues, chat messages — the endpoint is compromised. Anyone who sees it can POST anything.

## When to use

Use ONLY if:

1. The user explicitly asked for ad-hoc/testing ("just give me a webhook I can curl", "for quick testing")
2. The sender is a legacy system that cannot sign
3. The user explicitly accepts URL-secrecy-only security for a known non-vendor source

Do NOT use:

- As a fallback when a signed vendor skill appears unavailable. Tell the user the vendor is not configured and stop.
- For payments, auth events, or anything affecting other users.

## Prompt guidance

The handler's text output becomes the agent's chat turn, NOT the HTTP response body. The HTTP sender already got a 202 before your handler ran. Write the prompt accordingly — say "echo the body verbatim" rather than "echo it back to the client" or "return it in the response."

## Call

```
operation: "register"
prompt:    "<handler brief>"
idempotency (optional): {"key": {"header": "..."} | {"json_path": "$.field"}, "ttl": 86400}
```

## Response

Tool returns `Webhook registered. URL: <url>`. Your reply MUST begin with the URL. Warn the user about URL secrecy if they haven't already acknowledged the tradeoff.
