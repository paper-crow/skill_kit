defmodule SkillKit.Webhook.Inbox.MemoryTest do
  use SkillKit.Webhook.Inbox.ContractCase,
    async: false,
    impl: SkillKit.Webhook.Inbox.Memory

  alias SkillKit.Webhook.Inbox.Memory

  setup do
    name = :"#{__MODULE__}_#{System.unique_integer([:positive])}"
    parent = self()
    dispatch = fn agent, text, opts -> send(parent, {:dispatch, agent, text, opts}) end

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

  describe "dispatch callback" do
    test "fires with pointer text and standard send_event opts", %{inbox: inbox} do
      e = build_entry(%{prompt: "My intent"})
      assert :ok = Memory.put(inbox, e)

      assert_receive {:dispatch, _agent, text, opts}
      assert text =~ e.delivery.id
      assert text =~ "<webhook-delivery"
      refute text =~ "My intent"
      assert Keyword.fetch!(opts, :system_append) == "My intent"
      assert [{SkillKit.Tools.WebhookInbox, _ctx}] = Keyword.fetch!(opts, :tools_add)
      assert Keyword.fetch!(opts, :tools_remove) == [SkillKit.Tools.Webhook]
      assert Keyword.fetch!(opts, :skills_remove_prefix) == "webhook:"
    end

    test "not called when start_link has no :dispatch option" do
      name = :"nodispatch_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Memory.start_link(name: name)

      assert :ok = Memory.put(name, build_entry())
      refute_receive {:dispatch, _, _, _}, 50
    end
  end

  describe "LRU cap (max_deliveries)" do
    @tag :capture_log
    test "oldest delivery evicted when max exceeded" do
      parent = self()
      dispatch = fn _a, _t, _o -> send(parent, :dispatched) end
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
      dispatch = fn _a, _t, _o -> send(parent, :dispatched) end
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
