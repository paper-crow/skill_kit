defmodule SkillKit.LLM.AnthropicTest do
  use ExUnit.Case, async: true

  alias SkillKit.LLM.Anthropic, as: Adapter
  alias SkillKit.Types.UserMessage

  describe "stream/2" do
    setup do
      bypass = Bypass.open()
      config = [api_key: "sk-test", endpoint: "http://localhost:#{bypass.port}"]
      {:ok, bypass: bypass, config: config}
    end

    test "encodes native messages and streams response", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Verify the encoder produced Anthropic-format messages
        assert [%{"role" => "user", "content" => "Hi"}] = decoded["messages"]

        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        chunks = [
          "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[]}}\n\n",
          "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
          "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\n",
          "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
          "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n",
          "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        ]

        Enum.reduce(chunks, conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)

      messages = [%UserMessage{content: "Hi"}]

      assert {:ok, stream} =
               Adapter.stream(
                 messages,
                 Keyword.merge(config, model: "claude-sonnet-4-20250514", max_tokens: 1024)
               )

      events = Enum.to_list(stream)
      assert events != []
      # Verify we got a text delta and a done event (SkillKit events)
      assert Enum.any?(events, &match?(%SkillKit.Event.Delta{}, &1))
      assert Enum.any?(events, &match?(%SkillKit.Event.Done{}, &1))
    end

    test "coerces and merges the :params query map into the request body, dropping unknown params",
         %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["max_tokens"] == 4096
        assert decoded["temperature"] == 0.7
        assert decoded["top_p"] == 0.9
        refute Map.has_key?(decoded, "custom")

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)
        |> stream_chunks()
      end)

      messages = [%UserMessage{content: "Hi"}]

      params = %{
        "max_tokens" => "4096",
        "temperature" => "0.7",
        "top_p" => "0.9",
        "custom" => "x"
      }

      assert {:ok, stream} =
               Adapter.stream(
                 messages,
                 Keyword.merge(config, model: "claude-sonnet-4-20250514", params: params)
               )

      Enum.to_list(stream)
    end
  end

  defp stream_chunks(conn) do
    chunks = [
      "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"content\":[]}}\n\n",
      "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n",
      "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
    ]

    Enum.reduce(chunks, conn, fn chunk, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, chunk)
      conn
    end)
  end
end
