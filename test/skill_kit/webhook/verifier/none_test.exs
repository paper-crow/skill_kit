defmodule SkillKit.Webhook.Verifier.NoneTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.Webhook.Verifier.None

  defp agent, do: %SkAgent{name: "a", description: "", system_prompt: ""}

  test "accepts an empty body with no headers" do
    conn = Plug.Test.conn(:post, "/", "")
    assert :ok = None.verify("", conn, %{}, agent())
  end

  test "accepts arbitrary body + unsigned headers" do
    conn =
      :post
      |> Plug.Test.conn("/", ~s({"x":1}))
      |> Plug.Conn.put_req_header("x-custom", "anything")

    assert :ok = None.verify(~s({"x":1}), conn, %{secret_key: "ignored"}, agent())
  end
end
