defmodule SkillKit.Webhook.Verifier.None do
  @moduledoc """
  Verifier that accepts every request without a signature check.

  Use when authentication comes from something other than a payload
  signature:

  - **URL as bearer token.** `SkillKit.Webhook` registration ids are 24
    bytes of `:crypto.strong_rand_bytes/1` encoded as base64url — 192
    bits of entropy, the same order of magnitude as the secrets Stripe
    and GitHub use to sign payloads. If the sender received the URL over
    a trusted channel (TLS, a handoff in a control plane), possession of
    the URL is the authentication. Do not log the URL, do not put it in
    error messages, do not publish it anywhere a third party can see.
  - **Network-level trust.** The endpoint only accepts traffic from a
    known network (service mesh, VPC, on-host socket, IP allowlist at
    the edge). Transport-level identity authenticates the caller.
  - **Senders that do not sign.** Plain HTTP callbacks from upstream
    systems without HMAC support — internal scripts, legacy integrations,
    cron pingers. Rejecting them is not an option; the host accepts
    whatever arrives and the agent treats the body as untrusted input.

  Config is ignored.

  ## Registration example

      %SkillKit.Webhook{
        id: "...",
        agent_name: "support",
        prompt: "A webhook arrived; echo the body back.",
        verifier: {SkillKit.Webhook.Verifier.None, %{}},
        inserted_at: DateTime.utc_now()
      }
  """

  @behaviour SkillKit.Webhook.Verifier

  @impl true
  def verify(_raw_body, _conn, _config, _agent), do: :ok
end
