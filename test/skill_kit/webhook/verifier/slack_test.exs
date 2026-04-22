defmodule SkillKit.Webhook.Verifier.SlackTest do
  use ExUnit.Case, async: false

  import Mox

  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.Webhook.Verifier.Slack

  setup :verify_on_exit!

  @secret "slack_secret"

  defp agent, do: %SkAgent{name: "a", description: "t", system_prompt: ""}

  test "short-circuits url_verification with the challenge response" do
    body = ~s({"type":"url_verification","challenge":"chal_abc"})

    conn =
      :post
      |> Plug.Test.conn(body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    assert {:handshake, conn} = Slack.verify(body, conn, %{secret_key: "SL"}, agent())
    assert conn.state == :sent
    assert conn.status == 200
    assert conn.resp_body == ~s({"challenge":"chal_abc"})
    assert {"content-type", "application/json; charset=utf-8"} in conn.resp_headers
  end

  test "validates v0 signature on normal events" do
    SkillKit.CredentialProvider.Mock
    |> stub(:fetch, fn _tool, _agent, "SL" -> {:ok, @secret} end)

    ts = Integer.to_string(System.system_time(:second))
    body = ~s({"type":"event_callback","event":{"type":"message"}})

    sig =
      :hmac |> :crypto.mac(:sha256, @secret, "v0:#{ts}:#{body}") |> Base.encode16(case: :lower)

    conn =
      :post
      |> Plug.Test.conn(body)
      |> Plug.Conn.put_req_header("x-slack-request-timestamp", ts)
      |> Plug.Conn.put_req_header("x-slack-signature", "v0=#{sig}")

    assert :ok = Slack.verify(body, conn, %{secret_key: "SL"}, agent())
  end

  test "rejects body that doesn't match v0 signature" do
    SkillKit.CredentialProvider.Mock
    |> stub(:fetch, fn _tool, _agent, "SL" -> {:ok, @secret} end)

    ts = Integer.to_string(System.system_time(:second))

    conn =
      :post
      |> Plug.Test.conn("different")
      |> Plug.Conn.put_req_header("x-slack-request-timestamp", ts)
      |> Plug.Conn.put_req_header("x-slack-signature", "v0=" <> String.duplicate("0", 64))

    assert {:error, :invalid_signature} =
             Slack.verify("different", conn, %{secret_key: "SL"}, agent())
  end
end
