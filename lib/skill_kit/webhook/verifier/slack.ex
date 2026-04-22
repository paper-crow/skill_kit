defmodule SkillKit.Webhook.Verifier.Slack do
  @moduledoc """
  Slack webhook signature verifier.

  HMAC-SHA256 over `"v0:<timestamp>:<body>"`, digest in the
  `X-Slack-Signature` header with a `v0=` prefix. Timestamp in
  `X-Slack-Request-Timestamp`.

  Also handles the one-shot `url_verification` handshake Slack issues
  when an endpoint URL is first registered in the app's config. That
  handshake arrives as a JSON body of the form
  `{"type": "url_verification", "challenge": "..."}` and expects a 200
  response echoing the challenge. This module short-circuits that case
  and returns `{:handshake, conn}` so the Plug sends the response and
  skips dispatch.

  ## Registration config

  - `secret_key` (required) — the key name resolved via `CredentialProvider`.
  - `max_skew` (optional) — timestamp tolerance in seconds. Default 300.
  """

  @behaviour SkillKit.Webhook.Verifier

  alias SkillKit.Webhook.Verifier.Hmac

  @defaults %{
    algorithm: :sha256,
    signing_template: "v0:$TIMESTAMP:$BODY",
    signature_header: "x-slack-signature",
    signature_pattern: ~r/v0=([a-f0-9]+)/,
    timestamp_header: "x-slack-request-timestamp",
    timestamp_pattern: ~r/(\d+)/,
    max_skew: 300
  }

  @impl true
  def verify(raw_body, conn, config, agent) do
    handle_request(classify(raw_body), raw_body, conn, config, agent)
  end

  defp classify(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"type" => "url_verification", "challenge" => challenge}}
      when is_binary(challenge) ->
        {:handshake, challenge}

      _ ->
        :normal
    end
  end

  defp handle_request({:handshake, challenge}, _raw_body, conn, _config, _agent) do
    response = Jason.encode!(%{challenge: challenge})

    resp_conn =
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, response)

    {:handshake, resp_conn}
  end

  defp handle_request(:normal, raw_body, conn, config, agent) do
    Hmac.verify(raw_body, conn, Map.merge(@defaults, config), agent)
  end
end
