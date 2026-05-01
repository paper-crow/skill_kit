defmodule SkillKit.Webhook.Verifier.Hmac do
  @moduledoc """
  Config-driven HMAC signature verification engine.

  Covers the GitHub / Stripe / Slack / most-vendors family of webhook
  schemes through three knobs: the signing template (what bytes go into
  the MAC), the signature-extraction pattern (how to pull the hex digest
  out of the header), and an optional timestamp header + pattern for
  replay protection.

  Vendor modules (`Verifier.Stripe`, `Verifier.Github`, `Verifier.Slack`)
  are thin wrappers that bake in vendor-specific defaults and delegate
  here. Host apps can use this engine directly for custom schemes by
  passing a full config map to `verify/4`.

  Secret resolution always goes through the configured
  `SkillKit.CredentialProvider` — the module never holds a plaintext
  secret across a tool call boundary.
  """

  @behaviour SkillKit.Webhook.Verifier

  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.Tools.Webhook, as: WebhookKit
  alias SkillKit.Webhook.Template

  @impl true
  def verify(raw_body, conn, config, %SkAgent{} = agent)
      when is_binary(raw_body) and is_map(config) do
    SkillKit.Telemetry.span(
      [:webhook, :verification],
      %{verifier_mod: __MODULE__},
      fn ->
        result = check(raw_body, conn, config, agent)
        {result, %{outcome: verification_outcome(result)}}
      end
    )
  end

  defp check(raw_body, conn, config, agent) do
    with {:ok, secret} <- resolve_secret(config, agent),
         {:ok, timestamp} <- extract_timestamp(conn, config),
         :ok <- check_skew(timestamp, config),
         {:ok, expected} <- extract_signature(conn, config) do
      compare_signatures(raw_body, expected, secret, timestamp, config)
    end
  end

  defp resolve_secret(%{secret_key: key}, agent) do
    provider = Application.get_env(:skill_kit, :credential_provider, SkillKit.CredentialProvider)
    fetch_credential(apply(provider, :fetch, [WebhookKit, agent, key]))
  end

  defp fetch_credential({:ok, secret}) when is_binary(secret) and byte_size(secret) > 0,
    do: {:ok, secret}

  defp fetch_credential(_), do: {:error, :misconfigured}

  defp extract_timestamp(_conn, %{timestamp_header: nil}), do: {:ok, ""}

  defp extract_timestamp(conn, %{timestamp_header: header, timestamp_pattern: pattern}) do
    conn
    |> Plug.Conn.get_req_header(String.downcase(header))
    |> List.first()
    |> match_timestamp(pattern)
  end

  defp match_timestamp(nil, _pattern), do: {:error, :invalid_signature}

  defp match_timestamp(value, pattern) when is_binary(value) do
    case Regex.run(pattern, value) do
      [_, captured | _] -> {:ok, captured}
      _ -> {:error, :invalid_signature}
    end
  end

  defp check_skew("", _config), do: :ok

  defp check_skew(timestamp, %{max_skew: max}) when is_binary(timestamp) do
    now = System.system_time(:second)

    case Integer.parse(timestamp) do
      {ts, ""} when abs(now - ts) <= max -> :ok
      {_ts, ""} -> {:error, :stale_timestamp}
      _ -> {:error, :invalid_signature}
    end
  end

  defp extract_signature(conn, %{signature_header: header, signature_pattern: pattern}) do
    conn
    |> Plug.Conn.get_req_header(String.downcase(header))
    |> List.first()
    |> match_signature(pattern)
  end

  defp match_signature(nil, _pattern), do: {:error, :invalid_signature}

  defp match_signature(value, pattern) when is_binary(value) do
    case Regex.run(pattern, value) do
      [_, captured | _] -> {:ok, captured}
      _ -> {:error, :invalid_signature}
    end
  end

  defp compare_signatures(raw_body, expected, secret, timestamp, config) do
    signing_input = Template.render_signing(config.signing_template, raw_body, timestamp)
    computed = compute_hmac(config.algorithm, secret, signing_input)

    ok_or_invalid(Plug.Crypto.secure_compare(expected, computed))
  end

  defp compute_hmac(algorithm, secret, input) do
    :hmac |> :crypto.mac(algorithm, secret, input) |> Base.encode16(case: :lower)
  end

  defp ok_or_invalid(true), do: :ok
  defp ok_or_invalid(false), do: {:error, :invalid_signature}

  defp verification_outcome(:ok), do: :ok
  defp verification_outcome({:error, reason}), do: reason
  defp verification_outcome({:handshake, _conn}), do: :handshake
end
