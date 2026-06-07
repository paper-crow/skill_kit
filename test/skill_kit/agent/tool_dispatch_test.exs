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

  test "build_context/2 returns the full context map", %{agent: agent} do
    assert ToolDispatch.build_context(%{agent: agent}, "bash") == %{
             agent: agent,
             agent_name: agent.name,
             scope: :my_scope
           }
  end

  test "build_context/2 returns a context map with nil scope when the agent has none", %{
    agent: agent
  } do
    agent = %{agent | scope: nil}

    assert ToolDispatch.build_context(%{agent: agent}, "bash") == %{
             agent: agent,
             agent_name: agent.name,
             scope: nil
           }
  end

  test "build_context/2 uses parent agent name for activate_skill children", %{agent: agent} do
    # Construct a "child" agent sharing the parent's registry + name so the
    # Catalog lookup resolves, but with a parent_ref pointing at a different
    # name — verifying build_context picks the parent_ref's name over the
    # agent's own.
    child = %{
      agent
      | parent_ref: %SkillKit.AgentRef{
          name: "root-parent",
          registry: agent.registry,
          supervisor_pid: self()
        }
    }

    context = ToolDispatch.build_context(%{agent: child}, "bash")
    assert context.agent_name == "root-parent"
    assert context.agent == child
  end

  describe "extract_output/1 with content blocks" do
    test "passes a list of content-block maps through unchanged" do
      blocks = [
        %{"type" => "text", "text" => "resolved data"},
        %{
          "type" => "image",
          "source" => %{"type" => "base64", "media_type" => "image/webp", "data" => "AAAA"}
        }
      ]

      assert ToolDispatch.extract_output({:ok, blocks}) == blocks
    end

    test "still stringifies a bare string result" do
      assert ToolDispatch.extract_output({:ok, "hello"}) == "hello"
    end
  end
end
