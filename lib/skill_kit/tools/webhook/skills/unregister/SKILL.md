---
name: "unregister"
description: "Remove a previously registered webhook. The URL immediately stops accepting requests."
---
Delete a webhook registration by id.

Provide:

- `id` (string, required) — the id returned at registration (the tail segment of the webhook URL).

Returns `"OK"` on success; `"Webhook not found"` if the id is unknown.
