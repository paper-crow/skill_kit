defmodule SkillKit.Webhook.BodyReaderTest do
  use ExUnit.Case, async: true

  alias SkillKit.Webhook.BodyReader

  test "read_body/2 stashes the raw binary in conn.assigns.raw_body" do
    conn =
      :post
      |> Plug.Test.conn("/hooks/abc", "hello-world")
      |> Plug.Conn.put_req_header("content-type", "text/plain")

    {:ok, body, conn} = BodyReader.read_body(conn, [])
    assert body == "hello-world"
    assert conn.assigns.raw_body == "hello-world"
  end

  test "appends chunks when called repeatedly" do
    {:ok, full, _conn} =
      :post
      |> Plug.Test.conn("/", "abcdef")
      |> BodyReader.read_body(length: 3)
      |> read_more()

    assert full == "abcdef"
  end

  defp read_more({:more, partial, conn}) do
    {:ok, rest, conn} = BodyReader.read_body(conn, [])
    {:ok, partial <> rest, conn}
  end

  defp read_more({:ok, _, _} = done), do: done
end
