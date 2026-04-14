defmodule SkillKit.Agent.ToolDispatchTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.ToolDispatch
  alias SkillKit.Catalog

  setup do
    registry_name = :"tool_dispatch_test_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    agent_name = "test-agent-#{:erlang.unique_integer([:positive])}"

    start_supervised!(
      {Catalog, name: {:via, Registry, {registry_name, {agent_name, :catalog}}}, providers: []}
    )

    agent = %SkillKit.Agent{
      name: agent_name,
      description: "d",
      system_prompt: "s",
      scope: :my_scope,
      registry: registry_name
    }

    {:ok, agent: agent}
  end

  test "build_context/1 returns the full context map", %{agent: agent} do
    assert ToolDispatch.build_context(%{agent: agent}) == %{
             agent: agent,
             scope: :my_scope
           }
  end

  test "build_context/1 returns a context map with nil scope when the agent has none", %{
    agent: agent
  } do
    agent = %{agent | scope: nil}

    assert ToolDispatch.build_context(%{agent: agent}) == %{
             agent: agent,
             scope: nil
           }
  end
end
