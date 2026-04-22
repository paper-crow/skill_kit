defmodule SkillKit.Webhook.Verifier.GithubTest do
  use ExUnit.Case, async: false

  import Mox

  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.Webhook.Verifier.Github

  setup :verify_on_exit!

  @secret "ghs_abc"

  defp agent, do: %SkAgent{name: "a", description: "t", system_prompt: ""}

  test "accepts a valid X-Hub-Signature-256 over the raw body" do
    SkillKit.CredentialProvider.Mock
    |> stub(:fetch, fn _tool, _agent, "GH" -> {:ok, @secret} end)

    body = ~s({"action":"opened"})
    sig = :hmac |> :crypto.mac(:sha256, @secret, body) |> Base.encode16(case: :lower)

    conn =
      :post
      |> Plug.Test.conn(body)
      |> Plug.Conn.put_req_header("x-hub-signature-256", "sha256=#{sig}")

    assert :ok = Github.verify(body, conn, %{secret_key: "GH"}, agent())
  end

  test "rejects mismatched signature" do
    SkillKit.CredentialProvider.Mock
    |> stub(:fetch, fn _tool, _agent, "GH" -> {:ok, @secret} end)

    conn =
      :post
      |> Plug.Test.conn("body")
      |> Plug.Conn.put_req_header("x-hub-signature-256", "sha256=" <> String.duplicate("0", 64))

    assert {:error, :invalid_signature} =
             Github.verify("body", conn, %{secret_key: "GH"}, agent())
  end
end
