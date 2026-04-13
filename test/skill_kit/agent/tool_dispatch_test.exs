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

  test "build_context/1 includes :agent and :scope", %{agent: agent} do
    ctx = ToolDispatch.build_context(%{agent: agent})
    assert ctx.agent == agent
    assert ctx.scope == :my_scope
  end

  test "build_context/1 returns a map with :agent and :scope keys even when scope is nil", %{
    agent: agent
  } do
    agent = %{agent | scope: nil}
    ctx = ToolDispatch.build_context(%{agent: agent})
    assert Map.has_key?(ctx, :agent)
    assert Map.has_key?(ctx, :scope)
  end
end
