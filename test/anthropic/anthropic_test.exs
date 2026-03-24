defmodule AnthropicTest do
  use ExUnit.Case, async: true

  describe "stream/3" do
    setup do
      bypass = Bypass.open()
      config = [api_key: "sk-test", endpoint: "http://localhost:#{bypass.port}"]
      {:ok, bypass: bypass, config: config}
    end

    test "delegates to Client.stream", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} =
          Plug.Conn.chunk(conn, "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")

        conn
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]

      assert {:ok, stream} =
               Anthropic.stream(config, messages,
                 model: "claude-sonnet-4-20250514",
                 max_tokens: 1024
               )

      assert [%Anthropic.Event.MessageStop{}] = Enum.to_list(stream)
    end
  end
end
