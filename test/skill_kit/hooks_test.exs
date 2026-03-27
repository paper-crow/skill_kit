defmodule SkillKit.HooksTest do
  use ExUnit.Case, async: true

  import SkillKit.TelemetryHelper

  alias SkillKit.Hook
  alias SkillKit.Hooks
  alias SkillKit.Kit.Memory
  alias SkillKit.Skill

  setup :telemetry

  setup do
    {:ok, provider} = Memory.start_link([])
    catalog = start_supervised!({SkillKit.Catalog, providers: [{Memory, provider: provider}]})
    %{catalog: catalog, provider: provider}
  end

  defp skill_with_hooks(hooks) do
    %Skill{
      name: "test:hooks",
      namespace: "test",
      description: "Hook test skill",
      body: "test",
      hooks: hooks
    }
  end

  defp tool_use_context do
    %{tool: SkillKit.Tools.Shell, input: %{"command" => "echo hi"}, skill: nil, scope: nil}
  end

  describe "call/4" do
    test "returns result of func when no hooks registered", %{catalog: catalog} do
      result =
        Hooks.call(catalog, :tool_use, tool_use_context(), fn ->
          {:the_result, tool_use_context()}
        end)

      assert :the_result = result
    end

    test "returns {:deny, reason} when pre-hook denies", %{catalog: catalog, provider: provider} do
      hook = %Hook{
        event: :pre_tool_use,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:deny, "blocked"} end
      }

      Memory.put(provider, skill_with_hooks([hook]))

      result =
        Hooks.call(catalog, :tool_use, tool_use_context(), fn ->
          {:should_not_reach, tool_use_context()}
        end)

      assert {:deny, "blocked"} = result
    end

    test "returns {:pending, state} when pre-hook suspends", %{
      catalog: catalog,
      provider: provider
    } do
      hook = %Hook{
        event: :pre_tool_use,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:pending, %{needs: :approval}} end
      }

      Memory.put(provider, skill_with_hooks([hook]))

      result =
        Hooks.call(catalog, :tool_use, tool_use_context(), fn ->
          {:should_not_reach, tool_use_context()}
        end)

      assert {:pending, %{needs: :approval}} = result
    end

    test "short-circuits on first deny with multiple hooks", %{
      catalog: catalog,
      provider: provider
    } do
      hook1 = %Hook{event: :pre_tool_use, matcher: ~r/Shell/, handler: fn _ctx -> :ok end}

      hook2 = %Hook{
        event: :pre_tool_use,
        matcher: ~r/Shell/,
        handler: fn _ctx -> {:deny, "second hook blocked"} end
      }

      hook3 = %Hook{
        event: :pre_tool_use,
        matcher: ~r/Shell/,
        handler: fn _ctx ->
          send(self(), :hook3_should_not_fire)
          :ok
        end
      }

      Memory.put(provider, skill_with_hooks([hook1, hook2, hook3]))

      result =
        Hooks.call(catalog, :tool_use, tool_use_context(), fn ->
          {:should_not_reach, tool_use_context()}
        end)

      assert {:deny, "second hook blocked"} = result
      refute_receive :hook3_should_not_fire
    end

    test "fires post-event hooks after func completes", %{catalog: catalog, provider: provider} do
      hook = %Hook{
        event: :post_tool_use,
        handler: fn ctx ->
          send(self(), {:post_fired, ctx})
          :ok
        end
      }

      Memory.put(provider, skill_with_hooks([hook]))
      context = tool_use_context()

      Hooks.call(catalog, :tool_use, context, fn ->
        {:ok, Map.put(context, :result, "hello")}
      end)

      assert_receive {:post_fired, %{result: "hello"}}
    end

    test "matcher filters hooks by tool name", %{catalog: catalog, provider: provider} do
      hook = %Hook{
        event: :pre_tool_use,
        matcher: ~r/Sandbox/,
        handler: fn _ctx -> {:deny, "wrong tool"} end
      }

      Memory.put(provider, skill_with_hooks([hook]))

      result =
        Hooks.call(catalog, :tool_use, tool_use_context(), fn ->
          {:ok, tool_use_context()}
        end)

      assert :ok = result
    end

    test "nil matcher matches everything", %{catalog: catalog, provider: provider} do
      hook = %Hook{
        event: :pre_tool_use,
        matcher: nil,
        handler: fn _ctx -> {:deny, "catch all"} end
      }

      Memory.put(provider, skill_with_hooks([hook]))

      result =
        Hooks.call(catalog, :tool_use, tool_use_context(), fn ->
          {:should_not_reach, tool_use_context()}
        end)

      assert {:deny, "catch all"} = result
    end

    test "invokes {module, config} handler form", %{catalog: catalog, provider: provider} do
      start_supervised!({SkillKit.Test.HookHandler, test_pid: self()})

      hook = %Hook{
        event: :pre_tool_use,
        matcher: ~r/Shell/,
        handler: {SkillKit.Test.HookHandler, %{"source" => "test"}}
      }

      Memory.put(provider, skill_with_hooks([hook]))

      Hooks.call(catalog, :tool_use, tool_use_context(), fn ->
        {:ok, tool_use_context()}
      end)

      assert_receive {:hook_fired, %{"source" => "test"}, _context}
    end

    @tag telemetry: [[:skill_kit, :tool_use, :start], [:skill_kit, :tool_use, :stop]]
    test "emits telemetry span", %{catalog: catalog} do
      Hooks.call(catalog, :tool_use, tool_use_context(), fn ->
        {:ok, tool_use_context()}
      end)

      assert_receive {__MODULE__, [:skill_kit, :tool_use, :start], _meta}
      assert_receive {__MODULE__, [:skill_kit, :tool_use, :stop], _meta}
    end
  end

  describe "cast/3" do
    test "fires hooks and returns :ok", %{catalog: catalog, provider: provider} do
      hook = %Hook{
        event: :post_tool_use,
        handler: fn ctx ->
          send(self(), {:cast_fired, ctx})
          :ok
        end
      }

      Memory.put(provider, skill_with_hooks([hook]))

      assert :ok = Hooks.cast(catalog, :post_tool_use, %{result: "hello"})
      assert_receive {:cast_fired, %{result: "hello"}}
    end

    test "returns :ok when no hooks registered", %{catalog: catalog} do
      assert :ok = Hooks.cast(catalog, :post_tool_use, %{})
    end
  end

  describe "matcher targets" do
    test "subagent boundary matches on name", %{catalog: catalog, provider: provider} do
      hook = %Hook{
        event: :pre_subagent,
        matcher: ~r/researcher/,
        handler: fn _ctx -> {:deny, "no researchers"} end
      }

      Memory.put(provider, skill_with_hooks([hook]))
      context = %{name: "researcher", task: "find info", agent_name: "test"}

      result =
        Hooks.call(catalog, :subagent, context, fn ->
          {:should_not_reach, context}
        end)

      assert {:deny, "no researchers"} = result
    end

    test "llm_request boundary matches on model", %{catalog: catalog, provider: provider} do
      hook = %Hook{
        event: :pre_llm_request,
        matcher: ~r/claude-opus/,
        handler: fn _ctx -> {:deny, "too expensive"} end
      }

      Memory.put(provider, skill_with_hooks([hook]))
      context = %{model: "claude-opus-4-6", agent_name: "test", messages: [], tools: []}

      result =
        Hooks.call(catalog, :llm_request, context, fn ->
          {:should_not_reach, context}
        end)

      assert {:deny, "too expensive"} = result
    end

    test "agent_name used as fallback matcher target", %{catalog: catalog, provider: provider} do
      hook = %Hook{
        event: :pre_turn,
        matcher: ~r/my-agent/,
        handler: fn _ctx -> {:deny, "paused"} end
      }

      Memory.put(provider, skill_with_hooks([hook]))
      context = %{agent_name: "my-agent"}

      result =
        Hooks.call(catalog, :turn, context, fn ->
          {:should_not_reach, context}
        end)

      assert {:deny, "paused"} = result
    end
  end
end
