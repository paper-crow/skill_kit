defmodule SkillKit.Webhook.Verifier.StripeTest do
  use ExUnit.Case, async: false

  import Mox

  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.Webhook.Verifier.Stripe

  setup :verify_on_exit!

  @secret "whsec_abc"

  defp agent, do: %SkAgent{name: "a", description: "t", system_prompt: ""}

  test "delegates to Hmac with Stripe defaults merged" do
    SkillKit.CredentialProvider.Mock
    |> stub(:fetch, fn _tool, _agent, "STRIPE" -> {:ok, @secret} end)

    ts = Integer.to_string(System.system_time(:second))
    body = ~s({"type":"charge.succeeded"})
    sig = :hmac |> :crypto.mac(:sha256, @secret, "#{ts}.#{body}") |> Base.encode16(case: :lower)

    conn =
      :post
      |> Plug.Test.conn(body)
      |> Plug.Conn.put_req_header("stripe-signature", "t=#{ts},v1=#{sig}")

    assert :ok = Stripe.verify(body, conn, %{secret_key: "STRIPE"}, agent())
  end

  test "rejects tampered payload" do
    SkillKit.CredentialProvider.Mock
    |> stub(:fetch, fn _tool, _agent, "STRIPE" -> {:ok, @secret} end)

    ts = Integer.to_string(System.system_time(:second))
    sig = :hmac |> :crypto.mac(:sha256, @secret, "#{ts}.original") |> Base.encode16(case: :lower)

    conn =
      :post
      |> Plug.Test.conn("tampered")
      |> Plug.Conn.put_req_header("stripe-signature", "t=#{ts},v1=#{sig}")

    assert {:error, :invalid_signature} =
             Stripe.verify("tampered", conn, %{secret_key: "STRIPE"}, agent())
  end
end
