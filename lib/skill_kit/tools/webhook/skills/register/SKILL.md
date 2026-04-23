---
name: "register"
description: "Register a webhook endpoint bound to this agent. Returns a unique URL that inbound HTTP requests can target; the agent receives a message for each verified request."
---
Register a new webhook endpoint for this agent.

## Your role

You are the **receiver**, not the sender.

This skill configures an HTTP endpoint hosted by this agent's process. Each verified inbound request produces **one user message** delivered to the agent, rendered from the `prompt` template you register.

That means: `prompt` is **not** a log format string. It is the **on-hit instruction** the agent will follow every time a request arrives. Write it like a mini task brief, not like a `printf` template.

Do **not**:
- Write source scripts, cron jobs, or schedulers that CALL the endpoint (that's the user's problem, or a separate system).
- Create external webhook receivers in other languages (Python Flask, Node, etc.) — this skill IS the receiver; those would run in parallel and ignore this one.
- Set up log tailers, file watchers, or background daemons that "listen" for requests alongside the framework. Nothing runs alongside — every request flows through the one `prompt` you register.

OK to do, if the handler genuinely needs it:
- Create helper scripts or files the **`prompt` references** (e.g., a Python script whose path appears in the prompt text). The agent will invoke those helpers on each hit because the prompt told it to.
- Create directories (e.g., `mkdir -p webhook_logs`) that the on-hit handler will write into.

## Two-step pattern

Most registrations are a single step: call `webhook` with `operation: "register"` and an on-hit `prompt`, then return the URL.

When the user's request implies per-request processing that benefits from a helper (parsing JSON, structured logging, forwarding to another system), use two steps:

1. Create any helper scripts the handler will need. Reference them by path in the `prompt` so the on-hit agent knows how to invoke them.
2. Call `webhook` with `operation: "register"` and a `prompt` whose text directs the agent to use those helpers.

Then return the URL.

## Writing a good `prompt`

Treat it as system-style instructions for the receiver's next turn. Include:

- What kind of event just happened (a webhook hit).
- The request data it can use (via `$WEBHOOK_METHOD`, `$WEBHOOK_HEADERS`, `$WEBHOOK_QUERY`, `$WEBHOOK_BODY`).
- What action, if any, to take (a helper script to run, a file to append to, a reply format to produce).
- Brevity expectations if the user wanted "silent" behavior (e.g., "acknowledge in one short line and stop").

Examples of `prompt` values for different user intents:

| User intent | Good `prompt` |
|---|---|
| "just echo what comes in" | `"A webhook request arrived. Method=$WEBHOOK_METHOD, body=$WEBHOOK_BODY. Repeat the body back to the user verbatim."` |
| "silently log to a file, don't bother me" | `"A webhook request arrived. Silently append one line to webhook_log.txt with this shape: '[<iso-timestamp>] $WEBHOOK_METHOD $WEBHOOK_BODY'. Acknowledge with just 'logged.' — no other output."` |
| "use webhook_logger.py to process" | `"A webhook request arrived. Run: python3 webhook_logger.py '$WEBHOOK_METHOD' '$WEBHOOK_BODY'. Do not explain or elaborate; just run it and stop."` |
| "forward to Slack" | `"A webhook request arrived. Post to the team Slack channel using the slack skill: method=$WEBHOOK_METHOD, body=$WEBHOOK_BODY."` |

## How to call the tool

Use the `webhook` tool available in this turn. Set `operation: "register"` plus:

- `prompt` (string, required) — the on-hit instruction. Supported tokens:
    - `$WEBHOOK_BODY` — raw request body
    - `$WEBHOOK_METHOD` — HTTP method (usually `POST`)
    - `$WEBHOOK_HEADERS` — JSON-encoded header map
    - `$WEBHOOK_QUERY` — JSON-encoded query params
- `verifier` (object, required)
    - `type` (string, required) — one of `stripe`, `github`, `slack`, or `none`.
      - `stripe` / `github` / `slack` — HMAC-SHA256 with vendor-specific signing template and header format. Requires `secret_key` to point at a real credential.
      - `none` — no signature check; relies on URL entropy (~192 bits) + transport-level trust. Still requires `secret_key` for API consistency; use any non-empty placeholder (the credential is not read).
    - `secret_key` (string, required) — name of a credential registered in the app's `SkillKit.CredentialProvider`. The host is responsible for knowing which keys are available; ask the user if unsure.
    - `max_skew` (int, optional) — timestamp tolerance in seconds; only used by vendors that sign timestamps.
- `idempotency` (object, optional)
    - `key` (object, required) — either `{"header": "x-github-delivery"}` or `{"json_path": "$.id"}`.
    - `ttl` (int, optional) — dedup window in seconds. Default 86400 (24h).

## Response

The `webhook` tool returns `"Webhook registered. URL: <full URL>"` on success.

**Your final reply MUST begin with the URL on its own line, verbatim, exactly as returned by the tool.** Your caller reads the URL out of your final text — if you omit it, the caller cannot see it.

Reply template:

```
Webhook URL: <paste URL verbatim from the tool result>

<one or two sentences about what the webhook does, optional>
```

On failure: an error string describing the specific reason (missing field, unknown verifier type, etc.). Report it plainly without fabricating a URL.

## Full examples

Simplest echo, no signature:

```json
{
  "operation": "register",
  "prompt": "A webhook request arrived. Method=$WEBHOOK_METHOD, body=$WEBHOOK_BODY. Repeat the body back to the user verbatim.",
  "verifier": {"type": "none", "secret_key": "_"}
}
```

Signed GitHub push webhook:

```json
{
  "operation": "register",
  "prompt": "A GitHub push webhook fired. Summarize the pushed commits in two sentences: $WEBHOOK_BODY",
  "verifier": {"type": "github", "secret_key": "GITHUB_WEBHOOK_SECRET"}
}
```
