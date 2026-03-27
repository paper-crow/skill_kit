defmodule SkillKit.Hooks.HttpTest do
  use ExUnit.Case, async: true

  alias SkillKit.Hooks.Http

  describe "execute/2" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass}
    end

    test "returns :ok when server responds 200 with allow decision", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"decision": "allow"}))
      end)

      config = %{"url" => "http://localhost:#{bypass.port}/hook"}

      assert :ok = Http.execute(config, %{"tool" => "Shell"})
    end

    test "returns {:deny, reason} when server responds with deny decision", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"decision": "deny", "reason": "not allowed"}))
      end)

      config = %{"url" => "http://localhost:#{bypass.port}/hook"}

      assert {:deny, "not allowed"} = Http.execute(config, %{"tool" => "Shell"})
    end

    test "returns {:deny, reason} on non-2xx status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, ~s({"error": "forbidden"}))
      end)

      config = %{"url" => "http://localhost:#{bypass.port}/hook"}

      assert {:deny, "HTTP hook returned status 403"} = Http.execute(config, %{})
    end

    test "returns :ok on connection error (non-blocking)", %{bypass: bypass} do
      Bypass.down(bypass)

      config = %{"url" => "http://localhost:#{bypass.port}/hook"}

      assert :ok = Http.execute(config, %{})
    end

    test "returns :ok when response has no decision field", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"status": "ok"}))
      end)

      config = %{"url" => "http://localhost:#{bypass.port}/hook"}

      assert :ok = Http.execute(config, %{})
    end
  end
end
