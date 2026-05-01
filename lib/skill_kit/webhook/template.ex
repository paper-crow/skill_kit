defmodule SkillKit.Webhook.Template do
  @moduledoc """
  Token substitution for HMAC signing inputs.

  Vendors describe their HMAC signing format as a short template like
  `"$BODY"`, `"$TIMESTAMP.$BODY"`, or `"v0:$TIMESTAMP:$BODY"`. This
  module renders those templates against a given raw body + timestamp
  so `SkillKit.Webhook.Verifier.Hmac` can assemble the input to the
  MAC function.

  Webhook prompt templating (the `$WEBHOOK_BODY` / `$WEBHOOK_METHOD`
  etc. vocabulary) has been retired — the Plug now hands deliveries
  to `SkillKit.Webhook.Inbox` which composes a structured pointer
  message the agent dereferences via the `webhook_inbox` tool.
  """

  @doc """
  Substitutes `$BODY` and `$TIMESTAMP` tokens in a signing template.
  """
  @spec render_signing(String.t(), binary(), String.t()) :: binary()
  def render_signing(template, body, timestamp)
      when is_binary(template) and is_binary(body) and is_binary(timestamp) do
    template
    |> String.replace("$BODY", body)
    |> String.replace("$TIMESTAMP", timestamp)
  end
end
