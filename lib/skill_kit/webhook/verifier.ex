defmodule SkillKit.Webhook.Verifier do
  @moduledoc """
  Behaviour for webhook signature verifiers.

  A verifier validates that an inbound request was issued by the expected
  sender. Called by `SkillKit.Webhook.Plug` with the raw request body, the
  `Plug.Conn`, the verifier config, and the agent the webhook is bound to.

  ## Return values

  - `:ok` — signature valid; Plug continues to idempotency and dispatch.
  - `{:error, :invalid_signature}` — HMAC mismatch. Plug responds 401.
  - `{:error, :stale_timestamp}` — request older than `max_skew`. Plug
    responds 401.
  - `{:error, :misconfigured}` — secret could not be resolved via
    `CredentialProvider.fetch/3`. Plug responds 500.
  - `{:handshake, conn}` — the verifier wrote the response itself
    (e.g. Slack `url_verification`); Plug returns the conn unchanged.

  The `agent` argument is required because all shipped verifiers resolve
  secrets via `SkillKit.CredentialProvider.fetch(tool, agent, key)`, which
  needs the agent's scope to decide what's authorized.
  """

  alias SkillKit.Agent, as: SkAgent

  @type verify_error :: :invalid_signature | :stale_timestamp | :misconfigured

  @callback verify(
              raw_body :: binary(),
              conn :: Plug.Conn.t(),
              config :: map(),
              agent :: SkAgent.t()
            ) ::
              :ok
              | {:error, verify_error()}
              | {:handshake, Plug.Conn.t()}
end
