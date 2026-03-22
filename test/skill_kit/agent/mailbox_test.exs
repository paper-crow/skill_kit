defmodule SkillKit.Agent.MailboxTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.Mailbox

  setup do
    registry_name = :"mailbox_test_registry_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    agent_name = "test-agent-#{:erlang.unique_integer([:positive])}"

    {:ok, registry: registry_name, agent_name: agent_name}
  end

  describe "init" do
    test "registers in the agent registry", %{registry: registry, agent_name: agent_name} do
      config = %{max_messages: 10, flush_interval: 500}
      {:ok, pid} = Mailbox.start_link({agent_name, config, registry})

      assert [{^pid, _}] = Registry.lookup(registry, {agent_name, :mailbox})
    end
  end

  describe "message buffering" do
    test "buffers messages until flush interval", %{registry: registry, agent_name: agent_name} do
      Registry.register(registry, {agent_name, :server}, [])

      config = %{max_messages: 100, flush_interval: 50}
      {:ok, mailbox} = Mailbox.start_link({agent_name, config, registry})

      GenServer.cast(mailbox, {:message, "msg1"})
      GenServer.cast(mailbox, {:message, "msg2"})

      assert_receive {:mailbox_flush, ["msg1", "msg2"]}, 200
    end

    test "flushes immediately when max_messages reached", %{registry: registry, agent_name: agent_name} do
      Registry.register(registry, {agent_name, :server}, [])

      config = %{max_messages: 2, flush_interval: 60_000}
      {:ok, mailbox} = Mailbox.start_link({agent_name, config, registry})

      GenServer.cast(mailbox, {:message, "msg1"})
      GenServer.cast(mailbox, {:message, "msg2"})

      assert_receive {:mailbox_flush, ["msg1", "msg2"]}, 100
    end

    test "does not flush when buffer is empty", %{registry: registry, agent_name: agent_name} do
      Registry.register(registry, {agent_name, :server}, [])

      config = %{max_messages: 10, flush_interval: 50}
      _mailbox = Mailbox.start_link({agent_name, config, registry})

      Process.sleep(100)
      refute_received {:mailbox_flush, _}
    end
  end
end
