defmodule Anthropic.ClientTest do
  use ExUnit.Case, async: true

  alias Anthropic.Client

  describe "new/1" do
    test "creates client with required fields" do
      client = Client.new(api_key: "sk-test", endpoint: "https://api.anthropic.com")
      assert client.api_key == "sk-test"
      assert client.endpoint == "https://api.anthropic.com"
    end

    test "uses default endpoint when not provided" do
      client = Client.new(api_key: "sk-test")
      assert client.endpoint == "https://api.anthropic.com"
    end

    test "raises when api_key is missing" do
      assert_raise KeyError, fn -> Client.new([]) end
    end
  end

  describe "stream/3" do
    setup do
      bypass = Bypass.open()
      client = Client.new(api_key: "sk-test", endpoint: "http://localhost:#{bypass.port}")
      {:ok, bypass: bypass, client: client}
    end

    test "streams parsed SSE events from messages endpoint", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        chunks = [
          "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-sonnet-4-20250514\",\"stop_reason\":null}}\n\n",
          "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\n",
          "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        ]

        Enum.reduce(chunks, conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]

      assert {:ok, stream} =
               Client.stream(client, messages, model: "claude-sonnet-4-20250514", max_tokens: 1024)

      events = Enum.to_list(stream)
      assert length(events) == 3
      assert %{"type" => "message_start"} = List.first(events)
      assert %{"type" => "message_stop"} = List.last(events)
    end

    test "returns error tuple with readable body on non-200 response", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        Plug.Conn.send_resp(
          conn,
          401,
          ~s({"error":{"type":"authentication_error","message":"invalid api key"}})
        )
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]

      assert {:error, {401, body}} =
               Client.stream(client, messages,
                 model: "claude-sonnet-4-20250514",
                 max_tokens: 1024
               )

      assert is_binary(body)
      assert body =~ "authentication_error"
    end

    test "retries on 429 with retry-after header", %{bypass: bypass, client: client} do
      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/v1/messages", fn conn ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)

        if count == 1 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.send_resp(429, ~s({"error":{"type":"rate_limit_error"}}))
        else
          conn =
            conn
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_chunked(200)

          {:ok, conn} = Plug.Conn.chunk(conn, "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
          conn
        end
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]
      assert {:ok, stream} = Client.stream(client, messages, model: "claude-sonnet-4-20250514", max_tokens: 1024)
      assert [%{"type" => "message_stop"}] = Enum.to_list(stream)
      assert :counters.get(call_count, 1) == 2
    end

    test "sends correct headers and body", %{bypass: bypass, client: client} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["sk-test"]
        assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]
        assert decoded["model"] == "claude-sonnet-4-20250514"
        assert decoded["max_tokens"] == 1024
        assert decoded["stream"] == true
        assert [%{"role" => "user", "content" => "Hi"}] = decoded["messages"]

        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} =
          Plug.Conn.chunk(conn, "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")

        conn
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]

      {:ok, stream} =
        Client.stream(client, messages, model: "claude-sonnet-4-20250514", max_tokens: 1024)

      Enum.to_list(stream)
    end
  end
end
