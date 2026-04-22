defmodule SkillKit.Webhook.Template do
  @moduledoc """
  Token substitution for webhook prompts and HMAC signing inputs.

  Two separate vocabularies:

  - Prompt tokens — `$WEBHOOK_BODY`, `$WEBHOOK_METHOD`, `$WEBHOOK_HEADERS`,
    `$WEBHOOK_QUERY`. Used on `%Webhook{}.prompt` at request time.
  - Signing tokens — `$BODY`, `$TIMESTAMP`. Used inside `Verifier.Hmac`
    when building the input to the MAC function.

  The two sets never mix; each is rendered by its own function.
  """

  @prompt_tokens ~w(WEBHOOK_BODY WEBHOOK_METHOD WEBHOOK_HEADERS WEBHOOK_QUERY)

  @doc """
  Substitutes `$WEBHOOK_*` tokens in `template` using `context`.

  `context` is a map with atom keys `:body`, `:method`, `:headers`, `:query`.
  Missing values render as empty strings. Unrecognized `$NAME` sequences
  pass through unchanged.
  """
  @spec render_prompt(String.t(), map()) :: String.t()
  def render_prompt(template, context) when is_binary(template) and is_map(context) do
    Enum.reduce(@prompt_tokens, template, &replace_prompt_token(&2, &1, context))
  end

  defp replace_prompt_token(acc, token, context) do
    value = context |> Map.get(prompt_token_key(token), "") |> to_string()
    String.replace(acc, "$" <> token, value)
  end

  defp prompt_token_key("WEBHOOK_BODY"), do: :body
  defp prompt_token_key("WEBHOOK_METHOD"), do: :method
  defp prompt_token_key("WEBHOOK_HEADERS"), do: :headers
  defp prompt_token_key("WEBHOOK_QUERY"), do: :query

  @doc """
  Substitutes `$BODY` and `$TIMESTAMP` tokens in a signing template.

  Used by `Verifier.Hmac` to assemble the HMAC input from vendor-specific
  formats like `"$BODY"`, `"$TIMESTAMP.$BODY"`, or `"v0:$TIMESTAMP:$BODY"`.
  """
  @spec render_signing(String.t(), binary(), String.t()) :: binary()
  def render_signing(template, body, timestamp)
      when is_binary(template) and is_binary(body) and is_binary(timestamp) do
    template
    |> String.replace("$BODY", body)
    |> String.replace("$TIMESTAMP", timestamp)
  end
end
