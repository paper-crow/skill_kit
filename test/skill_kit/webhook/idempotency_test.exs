defmodule SkillKit.Webhook.IdempotencyTest do
  use ExUnit.Case, async: false

  alias SkillKit.Webhook.Idempotency

  setup do
    name = :"#{__MODULE__}_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Idempotency.start_link(name: name)
    {:ok, name: name}
  end

  test "check/3 returns :ok on first sight and :duplicate on repeat", %{name: name} do
    key = "delivery-1"
    assert :ok = Idempotency.check(name, key, ttl: 60)
    assert :duplicate = Idempotency.check(name, key, ttl: 60)
  end

  test "different keys do not collide", %{name: name} do
    assert :ok = Idempotency.check(name, "a", ttl: 60)
    assert :ok = Idempotency.check(name, "b", ttl: 60)
  end

  test "entries expire after ttl", %{name: name} do
    assert :ok = Idempotency.check(name, "gone", ttl: 1)
    Process.sleep(1100)
    assert :ok = Idempotency.check(name, "gone", ttl: 1)
  end

  test "extract_key/2 reads a header", _ do
    conn = Plug.Test.conn(:post, "/") |> Plug.Conn.put_req_header("x-delivery", "evt_1")
    assert Idempotency.extract_key(conn, %{key: %{"header" => "x-delivery"}}) == {:ok, "evt_1"}
  end

  test "extract_key/2 reads a JSON path from raw body", _ do
    conn =
      :post
      |> Plug.Test.conn("/")
      |> Plug.Conn.assign(:raw_body, ~s({"id":"evt_42","object":"charge"}))

    assert Idempotency.extract_key(conn, %{key: %{"json_path" => "$.id"}}) == {:ok, "evt_42"}
  end

  test "extract_key/2 returns :no_key when config is nil", _ do
    conn = Plug.Test.conn(:post, "/")
    assert Idempotency.extract_key(conn, nil) == :no_key
  end

  test "check/3 is atomic under concurrent contention on the same key", %{name: name} do
    key = "concurrent-key"
    workers = 100
    parent = self()
    ref = make_ref()

    pids =
      for _ <- 1..workers do
        spawn_link(fn ->
          send(parent, {:ready, ref})

          receive do
            {:go, ^ref} -> :ok
          end

          send(parent, {:result, ref, Idempotency.check(name, key, ttl: 60)})
        end)
      end

    for _ <- 1..workers do
      receive do
        {:ready, ^ref} -> :ok
      end
    end

    for pid <- pids, do: send(pid, {:go, ref})

    results =
      for _ <- 1..workers do
        receive do
          {:result, ^ref, result} -> result
        end
      end

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == :duplicate)) == workers - 1
  end
end
