defmodule SkillKit.Webhook.Verifier.HmacTest do
  use ExUnit.Case, async: false

  import Mox

  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.Webhook.Verifier.Hmac

  setup :verify_on_exit!

  @secret "whsec_test123"

  defp agent, do: %SkAgent{name: "a", description: "t", system_prompt: ""}

  defp hex_hmac(body, secret) do
    :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp stub_secret(value) do
    SkillKit.CredentialProvider.Mock
    |> stub(:fetch, fn _tool, _agent, "WH_SECRET" -> {:ok, value} end)
  end

  defp base_config do
    %{
      algorithm: :sha256,
      signing_template: "$BODY",
      signature_header: "x-sig",
      signature_pattern: ~r/([a-f0-9]+)/,
      timestamp_header: nil,
      timestamp_pattern: nil,
      max_skew: 300,
      secret_key: "WH_SECRET"
    }
  end

  test "returns :ok for a valid signature over $BODY" do
    stub_secret(@secret)
    body = "payload"
    sig = hex_hmac(body, @secret)
    conn = Plug.Test.conn(:post, "/") |> Plug.Conn.put_req_header("x-sig", sig)

    assert :ok = Hmac.verify(body, conn, base_config(), agent())
  end

  test "returns :invalid_signature on mismatched digest" do
    stub_secret(@secret)

    conn =
      Plug.Test.conn(:post, "/") |> Plug.Conn.put_req_header("x-sig", String.duplicate("0", 64))

    assert {:error, :invalid_signature} = Hmac.verify("payload", conn, base_config(), agent())
  end

  test "returns :invalid_signature when header is missing" do
    stub_secret(@secret)
    conn = Plug.Test.conn(:post, "/")

    assert {:error, :invalid_signature} = Hmac.verify("payload", conn, base_config(), agent())
  end

  test "returns :misconfigured when credential provider yields nil" do
    SkillKit.CredentialProvider.Mock
    |> stub(:fetch, fn _tool, _agent, "WH_SECRET" -> {:ok, nil} end)

    conn = Plug.Test.conn(:post, "/") |> Plug.Conn.put_req_header("x-sig", "ff")

    assert {:error, :misconfigured} = Hmac.verify("x", conn, base_config(), agent())
  end

  test "returns :misconfigured when credential provider errors" do
    SkillKit.CredentialProvider.Mock
    |> stub(:fetch, fn _tool, _agent, "WH_SECRET" -> :error end)

    conn = Plug.Test.conn(:post, "/") |> Plug.Conn.put_req_header("x-sig", "ff")

    assert {:error, :misconfigured} = Hmac.verify("x", conn, base_config(), agent())
  end

  test "validates a $TIMESTAMP.$BODY Stripe-style signature" do
    stub_secret(@secret)
    ts = Integer.to_string(System.system_time(:second))
    body = "{\"evt\":1}"
    sig = hex_hmac("#{ts}.#{body}", @secret)

    config = %{
      base_config()
      | signing_template: "$TIMESTAMP.$BODY",
        signature_header: "stripe-signature",
        signature_pattern: ~r/v1=([a-f0-9]+)/,
        timestamp_header: "stripe-signature",
        timestamp_pattern: ~r/t=(\d+)/
    }

    header = "t=#{ts},v1=#{sig}"

    conn =
      :post
      |> Plug.Test.conn("/")
      |> Plug.Conn.put_req_header("stripe-signature", header)

    assert :ok = Hmac.verify(body, conn, config, agent())
  end

  test "returns :stale_timestamp when timestamp exceeds max_skew" do
    stub_secret(@secret)
    old_ts = Integer.to_string(System.system_time(:second) - 10_000)
    body = "x"
    sig = hex_hmac("#{old_ts}.#{body}", @secret)

    config = %{
      base_config()
      | signing_template: "$TIMESTAMP.$BODY",
        signature_header: "stripe-signature",
        signature_pattern: ~r/v1=([a-f0-9]+)/,
        timestamp_header: "stripe-signature",
        timestamp_pattern: ~r/t=(\d+)/,
        max_skew: 300
    }

    header = "t=#{old_ts},v1=#{sig}"

    conn =
      :post
      |> Plug.Test.conn("/")
      |> Plug.Conn.put_req_header("stripe-signature", header)

    assert {:error, :stale_timestamp} = Hmac.verify(body, conn, config, agent())
  end
end
