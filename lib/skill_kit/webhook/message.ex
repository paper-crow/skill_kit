defmodule SkillKit.Webhook.Message do
  @moduledoc """
  Composes the user-facing text and `send_event/3` opts that an `Inbox`
  impl passes when emitting a delivery to the receiving agent.

  This is a shared convention — any inbox impl that wants the default
  pointer-tag format calls these helpers. Impls with custom dispatch text
  (e.g. coalesced batches) can use `pointer/1` as a building block or
  bypass this module entirely.
  """

  alias SkillKit.Webhook.Inbox

  @on_hit_guidance """
  You just received a webhook delivery. The user message contains a \
  `<webhook-delivery id="..." webhook_id="..." method="..." body_bytes="..."/>` \
  pointer — the payload itself is NOT inlined, to keep the context small. \
  Use the `webhook_inbox` tool to read the delivery:

    - `operation: "summary", id: "<id>"` — structural shape (types, sizes, \
      header list) with no leaf values. Use this first for large payloads to \
      see what's inside before reading specific fields.
    - `operation: "read", id: "<id>", selector: "<path>"` — one slice. \
      Selectors: `body.field`, `body.arr[0].field`, `body.arr[].field` \
      (array projection), `headers.x-name`, `headers`, `query`, `method`.
    - `operation: "read", id: "<id>", selector: "body", limit_bytes: N` — \
      byte-capped read for very large bodies; paginate with \
      `offset_bytes` if needed.
    - `operation: "delete", id: "<id>"` — evict after processing, if \
      retention matters.

  ## IMPORTANT: where your output goes

  The HTTP sender ALREADY received a 202 Accepted response the moment \
  the webhook fired — before this sub-loop ran. Your text output is NOT \
  the HTTP response body; the sender will never see it. Your output \
  becomes a turn in the agent's CHAT conversation, surfaced to the \
  human who registered the webhook. If the user's handler brief says \
  "echo back" or "return X", it means "produce that as your chat output \
  for the human to see" — NOT "send as an HTTP response." Never claim \
  the response was "sent back to the client"; it wasn't.

  The handler brief authored by the user follows. Act on what it asks; \
  call `webhook_inbox` as needed to inspect or extract payload data.
  """

  @doc """
  The standalone pointer tag for a delivery. Attributes carry the cheap
  metadata inline so the agent can branch without a tool call for trivial
  cases. This is the user message content for a webhook delivery event.
  """
  @spec pointer(Inbox.delivery()) :: String.t()
  def pointer(delivery) when is_map(delivery) do
    ~s(<webhook-delivery id="#{delivery.id}" webhook_id="#{delivery.webhook_id}" method="#{delivery.method}" received_at="#{DateTime.to_iso8601(delivery.received_at)}" body_bytes="#{byte_size(delivery.body)}" />)
  end

  @doc """
  Standard `send_event/3` opts for webhook delivery dispatch. Produces a
  scoped processing context: webhook.prompt becomes the sub-loop's system
  append, webhook config tools stripped, `webhook_inbox` injected (bound
  to the supplied `inbox_ref`), parent skills kept, `activate_skill`
  available, initial messages empty.

  `inbox_ref` is `{InboxModule, inbox_name}` — the Inbox behaviour impl
  and its registered process name, so the `webhook_inbox` tool knows
  which inbox to query at runtime.
  """
  @spec send_event_opts(String.t(), Inbox.delivery(), {module(), term()}) :: keyword()
  def send_event_opts(prompt, delivery, inbox_ref)
      when is_binary(prompt) and is_map(delivery) and is_tuple(inbox_ref) do
    [
      system_append: @on_hit_guidance <> "\n---\n\n" <> prompt,
      initial_messages: :empty,
      tools_add: [{SkillKit.Tools.WebhookInbox, inbox_context(inbox_ref)}],
      tools_remove: [SkillKit.Tools.Webhook],
      skills_remove_prefix: "webhook:",
      allow_activate_skill: true,
      sub_agent_name: "#{delivery.agent_name}/delivery:#{delivery.webhook_id}"
    ]
  end

  defp inbox_context({module, name}) do
    %{inbox_module: module, inbox: name}
  end
end
