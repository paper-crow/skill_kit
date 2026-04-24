---
name: "register"
description: "Register a webhook endpoint bound to this agent. Returns a unique URL that inbound HTTP requests can target; the agent processes each verified request as a scoped sub-loop."
---
Register a new webhook endpoint for this agent.

## Your role

You are the **receiver**, not the sender.

This skill configures an HTTP endpoint hosted by this agent's process. Each verified inbound request fires a bounded sub-loop where the agent handles one delivery — reads the payload, does whatever the handler prompt directs, produces a final answer — and that final answer becomes a single assistant turn in the agent's conversation. Intermediate steps (reading body fields, tool calls) stay inside the sub-loop and don't pollute the primary conversation.

That means: `prompt` is **not** a log format string. It is the **handler brief** the agent will follow every time a request arrives. Write it as plain-English intent, not as a template with `$`-tokens.

Do **not**:
- Write source scripts, cron jobs, or schedulers that CALL the endpoint (that's the user's problem, or a separate system).
- Create external webhook receivers in other languages (Python Flask, Node, etc.) — this skill IS the receiver; those would run in parallel and ignore this one.
- Set up log tailers, file watchers, or background daemons that "listen" for requests alongside the framework. Nothing runs alongside — every request flows through the `prompt` you register.

OK to do, if the handler genuinely needs it:
- Create helper scripts or files the **`prompt` references** (e.g., a Python script whose path appears in the prompt text). The agent will invoke those helpers on each hit because the prompt told it to.
- Create directories (e.g., `mkdir -p webhook_logs`) that the on-hit handler will write into.

## How inbound requests reach the agent

When a verified request arrives, the framework runs a scoped sub-loop for the agent:

- Your registered `prompt` becomes the handler brief (appended to the system prompt).
- The framework automatically prepends standing guidance on how to read webhook deliveries — you do **not** need to tell the agent to call `webhook_inbox`; that's baked in.
- A `<webhook-delivery id="..." .../>` pointer arrives as the user message; the payload is NOT inlined.
- The `webhook_inbox` tool is available for the duration of the sub-loop so the agent can read the delivery on-demand.

**Your `prompt` should be pure intent — what the handler is for, what to do with the delivery, how to reply.** Don't explain the mechanics of `webhook_inbox`; the framework already does that.

## Writing a good `prompt`

Treat it as a job description for the receiver's sub-loop turn. Describe:

- What kind of event just happened (a webhook from which vendor? what does it represent?)
- What action to take (summarize, log, forward, invoke a helper script)
- Brevity expectations if the user wanted "silent" behavior (e.g., "acknowledge in one short line and stop")

Examples of `prompt` values for different user intents:

| User intent | Good `prompt` |
|---|---|
| "just echo what comes in" | `"Echo the webhook body back verbatim."` |
| "silently log to a file, don't bother me" | `"Append one line to webhook_log.txt with this shape: '[<iso-timestamp>] <method> <body>'. Acknowledge with just 'logged.' — no other output."` |
| "use webhook_logger.py to process" | `"Invoke: python3 webhook_logger.py '<method>' '<body>' — passing the request's method and body. Do not explain; just run it and stop."` |
| "summarize GitHub pushes" | `"A GitHub push webhook fired. Summarize the pushed commits in two sentences."` |

## How to call the tool

Use the `webhook` tool available in this turn. Set `operation: "register"` plus:

- `prompt` (string, required) — plain-English handler brief (see above).
- `verifier` (object, required)
    - `type` (string, required) — one of `stripe`, `github`, or `slack`. HMAC-SHA256 with vendor-specific signing template and header format. Requires `secret_key` to point at a real credential. Hosts may enable additional verifier types (e.g. unsigned endpoints) by overriding the kit's `verifiers:` config; if so they will tell you.
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

## Full example

Signed GitHub push webhook:

```json
{
  "operation": "register",
  "prompt": "A GitHub push webhook fired. Summarize the pushed commits in two sentences.",
  "verifier": {"type": "github", "secret_key": "GITHUB_WEBHOOK_SECRET"}
}
```
