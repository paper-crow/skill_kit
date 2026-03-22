defmodule SkillKit.Agent.InfrastructureTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.{Definition, Infrastructure}

  setup do
    registry_name = :"infra_test_registry_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    agent_name = "test-agent-#{:erlang.unique_integer([:positive])}"

    definition = %Definition{
      name: agent_name,
      description: "Test agent",
      system_prompt: "You are a test.",
      path: "/tmp/test",
      workspace: "/tmp/test"
    }

    {:ok, registry: registry_name, agent_name: agent_name, definition: definition}
  end

  describe "start_link" do
    test "starts SkillKit.Supervisor and registers skill registry", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      {:ok, _sup} = Infrastructure.start_link({agent_name, definition, [], registry})

      # Skill registry should be registered via :via naming through SkillKit.Supervisor
      assert [{_, _}] = Registry.lookup(registry, {agent_name, :skill_registry})
    end
  end
end
