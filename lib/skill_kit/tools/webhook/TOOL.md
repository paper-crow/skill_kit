---
name: webhook
---

Register, update, unregister, or list HTTP webhook endpoints bound to this agent.
Each vendor has its own register skill (webhook:github, webhook:stripe,
webhook:slack, webhook:unsigned). Update, unregister, and list are vendor-agnostic.

URL discipline: a successful register returns `Webhook registered. URL: <url>`.
Treat that URL as authoritative for the rest of the conversation — quote it
verbatim from memory when later asked, and never invent a URL with a different
host or format. Do not re-run `list` to recover a URL you already received.
If a register response does not contain a URL, say so plainly and offer to
re-register; do not guess.
