defmodule SkillKit.Webhook.Verifier.Stripe do
  @moduledoc """
  Stripe webhook signature verifier.

  Delegates to `SkillKit.Webhook.Verifier.Hmac` with Stripe's well-known
  scheme baked in: HMAC-SHA256 over `"<timestamp>.<body>"`, with both the
  timestamp and the signature pulled from the `Stripe-Signature` header.

  ## Registration config (passed through)

  - `secret_key` (required) — the key name resolved via `CredentialProvider`.
  - `max_skew` (optional) — timestamp tolerance in seconds. Default 300.
  """

  @behaviour SkillKit.Webhook.Verifier

  alias SkillKit.Webhook.Verifier.Hmac

  # Compiled regexes can't be escaped into a module attribute under OTP 28
  # (they hold a #Reference), so build the defaults map in a function.
  defp defaults do
    %{
      algorithm: :sha256,
      signing_template: "$TIMESTAMP.$BODY",
      signature_header: "stripe-signature",
      signature_pattern: ~r/v1=([a-f0-9]+)/,
      timestamp_header: "stripe-signature",
      timestamp_pattern: ~r/t=(\d+)/,
      max_skew: 300
    }
  end

  @impl true
  def verify(raw_body, conn, config, agent) do
    Hmac.verify(raw_body, conn, Map.merge(defaults(), config), agent)
  end
end
