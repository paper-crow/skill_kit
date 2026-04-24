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
  append, webhook config tools stripped, `webhook_inbox` injected, parent
  skills kept, `activate_skill` available, initial messages empty.
  """
  @spec send_event_opts(String.t(), Inbox.delivery()) :: keyword()
  def send_event_opts(prompt, delivery) when is_binary(prompt) and is_map(delivery) do
    [
      system_append: prompt,
      initial_messages: :empty,
      tools_add: [{SkillKit.Tools.WebhookInbox, inbox_context(delivery)}],
      tools_remove: [SkillKit.Tools.Webhook],
      skills_remove_prefix: "webhook:",
      allow_activate_skill: true,
      sub_agent_name: "#{delivery.agent_name}/delivery:#{delivery.webhook_id}"
    ]
  end

  defp inbox_context(delivery) do
    %{agent_name: delivery.agent_name, delivery_id: delivery.id}
  end
end
