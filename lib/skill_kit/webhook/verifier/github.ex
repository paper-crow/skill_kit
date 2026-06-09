defmodule SkillKit.Webhook.Verifier.Github do
  @moduledoc """
  GitHub webhook signature verifier.

  HMAC-SHA256 over the raw request body, digest in the
  `X-Hub-Signature-256` header with a `sha256=` prefix. No timestamp
  header — GitHub doesn't send one.

  ## Registration config

  - `secret_key` (required) — the key name resolved via `CredentialProvider`.
  """

  @behaviour SkillKit.Webhook.Verifier

  alias SkillKit.Webhook.Verifier.Hmac

  # Compiled regexes can't be escaped into a module attribute under OTP 28
  # (they hold a #Reference), so build the defaults map in a function.
  defp defaults do
    %{
      algorithm: :sha256,
      signing_template: "$BODY",
      signature_header: "x-hub-signature-256",
      signature_pattern: ~r/sha256=([a-f0-9]+)/,
      timestamp_header: nil,
      timestamp_pattern: nil,
      max_skew: 0
    }
  end

  @impl true
  def verify(raw_body, conn, config, agent) do
    Hmac.verify(raw_body, conn, Map.merge(defaults(), config), agent)
  end
end
