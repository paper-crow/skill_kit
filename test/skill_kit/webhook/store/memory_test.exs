defmodule SkillKit.Webhook.Store.MemoryTest do
  use ExUnit.Case, async: true

  alias SkillKit.Webhook
  alias SkillKit.Webhook.Store.Memory

  setup do
    {:ok, pid} = Memory.start_link([])
    {:ok, config: [pid: pid]}
  end

  defp sample_webhook(id \\ "id-1", agent_name \\ "agent") do
    %Webhook{
      id: id,
      agent_name: agent_name,
      prompt: "hi",
      verifier: {SomeVerifier, %{}},
      inserted_at: DateTime.utc_now()
    }
  end

  test "put/2 then get/2 round-trips", %{config: config} do
    webhook = sample_webhook()
    assert :ok = Memory.put(config, webhook)
    assert {:ok, ^webhook} = Memory.get(config, "id-1")
  end

  test "get/2 returns :not_found for unknown id", %{config: config} do
    assert {:error, :not_found} = Memory.get(config, "nope")
  end

  test "delete/2 removes the webhook", %{config: config} do
    Memory.put(config, sample_webhook())
    assert :ok = Memory.delete(config, "id-1")
    assert {:error, :not_found} = Memory.get(config, "id-1")
  end

  test "list/2 returns all stored webhooks when filter is empty", %{config: config} do
    Memory.put(config, sample_webhook("id-1"))
    Memory.put(config, sample_webhook("id-2"))
    assert {:ok, list} = Memory.list(config, %{})
    assert length(list) == 2
  end

  test "list/2 filters by agent_name", %{config: config} do
    Memory.put(config, sample_webhook("id-1", "alice"))
    Memory.put(config, sample_webhook("id-2", "bob"))
    assert {:ok, [%Webhook{agent_name: "alice"}]} = Memory.list(config, %{agent_name: "alice"})
  end
end
