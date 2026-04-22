defmodule SkillKit.Webhook.RegistryTest do
  use ExUnit.Case, async: false

  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.Webhook.Registry, as: WebhookRegistry

  setup do
    Process.flag(:trap_exit, true)
    name = :"#{__MODULE__}_#{System.unique_integer([:positive])}"
    {:ok, _pid} = WebhookRegistry.start_link(name: name)
    {:ok, registry: name}
  end

  defp running_agent(agent_name) do
    # Simulate an agent by starting a named Registry process; the
    # Webhook.Registry monitors it and cleans up on :DOWN.
    reg_atom = :"#{agent_name}_#{System.unique_integer([:positive])}"
    {:ok, pid} = Registry.start_link(keys: :unique, name: reg_atom)

    agent = %SkAgent{
      name: agent_name,
      description: "test",
      system_prompt: "",
      registry: reg_atom
    }

    {agent, pid}
  end

  test "attach stores agent; whereis returns it", %{registry: reg} do
    {agent, _pid} = running_agent("alice")
    assert :ok = WebhookRegistry.attach(agent, registry: reg)
    assert {:ok, ^agent} = WebhookRegistry.whereis("alice", registry: reg)
  end

  test "whereis returns :agent_not_running for unknown name", %{registry: reg} do
    assert {:error, :agent_not_running} = WebhookRegistry.whereis("nobody", registry: reg)
  end

  test ":DOWN on the monitored registry removes the entry", %{registry: reg} do
    {agent, pid} = running_agent("bob")
    WebhookRegistry.attach(agent, registry: reg)
    Process.exit(pid, :shutdown)
    # Give the Webhook.Registry's handle_info time to process the :DOWN.
    Process.sleep(50)
    assert {:error, :agent_not_running} = WebhookRegistry.whereis("bob", registry: reg)
  end

  test "re-attach overwrites the prior entry", %{registry: reg} do
    {agent_v1, pid_v1} = running_agent("carol")
    WebhookRegistry.attach(agent_v1, registry: reg)

    {agent_v2, _pid_v2} = running_agent("carol")
    WebhookRegistry.attach(agent_v2, registry: reg)

    assert {:ok, ^agent_v2} = WebhookRegistry.whereis("carol", registry: reg)
    refute agent_v1.registry == agent_v2.registry

    Process.exit(pid_v1, :shutdown)
    # The stale :DOWN must not delete the fresh entry.
    Process.sleep(50)
    assert {:ok, ^agent_v2} = WebhookRegistry.whereis("carol", registry: reg)
  end

  test "detach removes the entry", %{registry: reg} do
    {agent, _pid} = running_agent("dan")
    WebhookRegistry.attach(agent, registry: reg)
    assert :ok = WebhookRegistry.detach("dan", registry: reg)
    assert {:error, :agent_not_running} = WebhookRegistry.whereis("dan", registry: reg)
  end
end
