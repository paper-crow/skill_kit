---
name: "list"
description: "List webhooks registered to this agent."
---
Return all webhooks currently bound to this agent.

Takes no arguments. Responds with a compact JSON array, one object per webhook, including `id`, `url`, `prompt`, `verifier.type`, and `inserted_at`.
