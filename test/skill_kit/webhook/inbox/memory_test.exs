defmodule SkillKit.Webhook.Inbox.MemoryTest do
  use SkillKit.Webhook.Inbox.ContractCase,
    async: false,
    impl: SkillKit.Webhook.Inbox.Memory

  alias SkillKit.Webhook.Inbox.Memory

  setup do
    name = :"#{__MODULE__}_#{System.unique_integer([:positive])}"
    parent = self()
    dispatch = fn entry -> send(parent, {:dispatch, entry}) end

    {:ok, _pid} =
      Memory.start_link(
        name: name,
        max_deliveries: 10,
        ttl_ms: :timer.hours(1),
        default_limit_bytes: 4096,
        dispatch: dispatch
      )

    {:ok, inbox: name}
  end

  # -- Memory-specific behavior (not part of the shared contract) ---------

  describe "dispatch" do
    test "fires with the full entry when :dispatch is a 1-arity fn", %{inbox: inbox} do
      e = build_entry(%{prompt: "My intent"})
      assert :ok = Memory.put(inbox, e)

      assert_receive {:dispatch, entry}
      assert entry.prompt == "My intent"
      assert entry.delivery.id == e.delivery.id
    end

    test "skipped when :dispatch is :none" do
      name = :"nodispatch_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Memory.start_link(name: name, dispatch: :none)

      assert :ok = Memory.put(name, build_entry())
      refute_receive {:dispatch, _}, 50
    end
  end

  describe "LRU cap (max_deliveries)" do
    @tag :capture_log
    test "oldest delivery evicted when max exceeded" do
      parent = self()
      dispatch = fn _entry -> send(parent, :dispatched) end
      name = :"lru_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Memory.start_link(
          name: name,
          max_deliveries: 3,
          ttl_ms: :timer.hours(1),
          dispatch: dispatch
        )

      for i <- 1..5 do
        Memory.put(name, %{
          agent: %SkillKit.AgentRef{name: "a", registry: :r, supervisor_pid: nil},
          prompt: "p",
          delivery: %{
            id: "d#{i}",
            webhook_id: "w",
            agent_name: "a",
            received_at: DateTime.add(~U[2026-01-01 00:00:00Z], i, :second),
            method: "POST",
            headers: %{},
            query: %{},
            body: "{}"
          }
        })
      end

      {:ok, summaries} = Memory.list(name, "a", [])
      assert Enum.map(summaries, & &1.id) == ["d5", "d4", "d3"]
    end
  end

  describe "TTL (ttl_ms)" do
    test "expired entries return :not_found" do
      parent = self()
      dispatch = fn _entry -> send(parent, :dispatched) end
      name = :"ttl_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Memory.start_link(name: name, max_deliveries: 10, ttl_ms: 50, dispatch: dispatch)

      Memory.put(name, %{
        agent: %SkillKit.AgentRef{name: "a", registry: :r, supervisor_pid: nil},
        prompt: "p",
        delivery: %{
          id: "short",
          webhook_id: "w",
          agent_name: "a",
          received_at: DateTime.utc_now(),
          method: "POST",
          headers: %{},
          query: %{},
          body: "{}"
        }
      })

      assert {:ok, _} = Memory.summary(name, "a", "short")
      Process.sleep(100)
      assert {:error, :not_found} = Memory.summary(name, "a", "short")
    end
  end
end
